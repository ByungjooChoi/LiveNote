import Foundation
import Observation

/// 저장된 회의 요약 (사이드바 목록용).
struct MeetingSummary: Identifiable, Hashable {
    let url: URL
    let title: String
    /// 사이드바 부제용 짧은 일시 ("8/27 09:01")
    let dateLabel: String
    let startedAt: Date
    let rowCount: Int
    let durationSeconds: Double
    /// 캘린더에서 캡처한 참석자 (구버전 저장본은 nil)
    let attendees: [Attendee]?

    var id: URL { url }

    var durationLabel: String {
        let total = Int(durationSeconds)
        if total >= 60 {
            return "\(total / 60)m \(total % 60)s"
        }
        return "\(total)s"
    }
}

/// 디스크에 저장되는 회의 전체 데이터 (session.json).
struct SavedMeeting: Codable {
    var startedAt: Date
    var durationSeconds: Double
    /// 캘린더 일정 제목 (없으면 nil, 사이드바는 날짜로 폴백)
    var title: String? = nil
    var myName: String
    var speakerNames: [Int: String]
    var rows: [TranscriptRow]
    /// LLM 생성 요약 (한국어). 없으면 nil. (구버전 파일과의 호환을 위해 옵셔널)
    var summary: String? = nil
    /// 회의 시작 시점 캘린더 참석자 (본인 제외). 구버전 파일 호환을 위해 옵셔널.
    var attendees: [Attendee]? = nil
}

/// 전사 편집 작업 결과.
struct EditResult {
    let meeting: SavedMeeting
    let log: TranscriptEditLog
    let changedRowCount: Int
    let warning: String?
}

/// 회의 저장소 관련 오류.
enum MeetingStoreError: LocalizedError, Equatable {
    case emptyRows
    case meetingNotFound
    case writeFailed(String)
    case rowNotFound(UUID)
    case duplicateRowID(UUID)
    case emptyText
    case noMatches
    case noChanges
    case nothingToUndo
    case undoConflict(UUID)
    case undoSummaryConflict
    case editLogCorrupt(String)

    var errorDescription: String? {
        switch self {
        case .emptyRows:
            return "Cannot save meeting with empty transcript."
        case .meetingNotFound:
            return "Meeting not found."
        case .writeFailed(let message):
            return "Failed to save meeting: \(message)"
        case .rowNotFound(let id):
            return "Row not found: \(id)."
        case .duplicateRowID(let id):
            return "Meeting data has a duplicate row id: \(id)."
        case .emptyText:
            return "Transcript text cannot be empty."
        case .noMatches:
            return "No matching text found."
        case .noChanges:
            return "The replacement text is identical to the matched text."
        case .nothingToUndo:
            return "No edits to undo."
        case .undoConflict:
            return "This row was changed after that edit; undo is not possible."
        case .undoSummaryConflict:
            return "The minutes changed after that edit; undo is not possible."
        case .editLogCorrupt(let message):
            return "Edit history is unreadable: \(message)"
        }
    }
}

/// 회의 저장소: `~/Documents/LiveNote/` 아래 회의별 폴더.
///
/// 각 회의 폴더 구성:
///   session.json  앱이 다시 열기 위한 원본 데이터 (SSOT)
///   edits.json    편집/되돌리기 이력 로그 (선택적)
///   en.md         영어 전사 (화자, 타임스탬프 포함)
///   ko.md         한국어 번역 (번역 행이 있는 경우만)
///   combined.md   영어+한국어 통합본
///   summary.md    LLM 요약 (생성한 경우)
///
/// Rationale for write ordering:
/// session.json is the truth, edits.json is the undo/audit log, md files are derived.
/// session.json before edits.json means a crash between the two can leave an edit
/// that is applied but not undoable (data preserved); the reverse order could leave
/// a log entry whose before text no longer matches. Undo therefore verifies
/// before/after instead of trusting the log blindly.
/// Removals of stale ko.md (when !hasKorean) and summary.md (when summary is nil) happen last;
/// failures during removal propagate as .writeFailed("remove <file>: <reason>").
@MainActor
@Observable
final class MeetingStore {

    private(set) var meetings: [MeetingSummary] = []

    let rootURL: URL

    private enum LogRecovery: Equatable {
        case corrupt(String)
    }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        rootURL = documents.appendingPathComponent("LiveNote", isDirectory: true)
        refresh()
    }

    /// 테스트용: 임시 폴더를 루트로 쓰는 저장소.
    init(rootURL: URL) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        refresh()
    }

    /// 구 데이터 폴더 이행: ~/Documents/livenote2 -> ~/Documents/LiveNote (1회, 앱 기동 최우선 실행)
    static func migrateLegacyRootIfNeeded() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        let legacy = documents.appendingPathComponent("livenote2", isDirectory: true)
        let current = documents.appendingPathComponent("LiveNote", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path),
              !FileManager.default.fileExists(atPath: current.path) else { return }
        try? FileManager.default.moveItem(at: legacy, to: current)
    }

    // MARK: - 목록

    /// 최근 회의의 화자 이름 매핑 (최대 limit건, session.json 지연 로딩).
    func speakerNamesByMeeting(since date: Date, limit: Int = 50) -> [URL: [String]] {
        var result: [URL: [String]] = [:]
        let recent = meetings.filter { $0.startedAt >= date }.prefix(limit)
        for summary in recent {
            if let saved = load(summary.url) {
                let names = Array(saved.speakerNames.values).filter { !$0.isEmpty }
                if !names.isEmpty {
                    result[summary.url] = names
                }
            }
        }
        return result
    }

    func refresh() {
        var found: [MeetingSummary] = []
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []

        for folder in folders {
            guard let meeting = load(folder) else { continue }
            found.append(MeetingSummary(
                url: folder,
                title: meeting.title ?? Self.titleFormatter.string(from: meeting.startedAt),
                dateLabel: Self.shortDateFormatter.string(from: meeting.startedAt),
                startedAt: meeting.startedAt,
                rowCount: meeting.rows.count,
                durationSeconds: meeting.durationSeconds,
                attendees: meeting.attendees
            ))
        }
        meetings = found.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - 저장 및 트랜잭션 쓰기

    /// 회의를 저장하고 폴더 URL을 반환. existingURL이 있으면 같은 폴더에 덮어씀(이름 변경, 늦은 번역 반영).
    ///
    /// Ownership rule for `existingURL`:
    /// Non-English state already on disk is preserved first:
    /// - `summary`: `existingMeeting.summary ?? summary` (a summary already on disk is owned by `updateSummary` / replace-all; caller fills it only when disk has none).
    /// - `title`: `existingMeeting.title ?? title` (auto-title and rename own it once set).
    /// - `attendees`: `existingMeeting.attendees ?? attendees`.
    /// - `speakerNames` and row speaker fields stay caller-owned (2-pass and diarization paths own them; AppState.mergePreservingManual protects manual names upstream).
    /// - `english` text on disk is preserved over stale incoming row text (`preservingDiskEnglish`).
    @discardableResult
    func save(
        rows: [TranscriptRow],
        myName: String,
        speakerNames: [Int: String],
        startedAt: Date,
        durationSeconds: Double,
        title: String?,
        summary: String?,
        attendees: [Attendee]?,
        existingURL: URL?
    ) throws -> URL {
        guard !rows.isEmpty else {
            if let existingURL { return existingURL }
            throw MeetingStoreError.emptyRows
        }
        try Self.validateUniqueIDs(rows)

        let folder: URL
        var finalRows = rows
        var finalSummary = summary
        var finalTitle = title
        var finalAttendees = attendees

        if let existingURL {
            folder = existingURL
            guard let existingMeeting = load(existingURL) else {
                throw MeetingStoreError.meetingNotFound
            }
            try Self.validateUniqueIDs(existingMeeting.rows)
            finalRows = try Self.preservingDiskEnglish(incoming: rows, disk: existingMeeting.rows)
            finalSummary = existingMeeting.summary ?? summary
            finalTitle = existingMeeting.title ?? title
            finalAttendees = existingMeeting.attendees ?? attendees
        } else {
            folder = makeUniqueFolder(for: startedAt, title: title)
        }

        let meeting = SavedMeeting(
            startedAt: startedAt,
            durationSeconds: durationSeconds,
            title: finalTitle,
            myName: myName,
            speakerNames: speakerNames,
            rows: finalRows,
            summary: finalSummary,
            attendees: finalAttendees
        )

        try stageAndCommit(meeting: meeting, editLog: nil, to: folder)
        refresh()
        return folder
    }

    /// 채널 간 에코 중복, 빈 행 소급 정리 (v1.3.1, 2-pass 도입 이후 저장본 대상, 1회).
    func cleanupEchoDuplicates(since date: Date) {
        let key = "echoCleanupDone.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        var cleaned = 0
        for summary in meetings where summary.startedAt >= date {
            guard var meeting = load(summary.url) else { continue }
            let result = EchoDedup.removeEchoRows(meeting.rows)
            guard result.removed > 0 else { continue }
            meeting.rows = result.rows
            do {
                try stageAndCommit(meeting: meeting, editLog: nil, to: summary.url)
                cleaned += 1
                AppLog.write("app", "에코 소급 정리: \(summary.url.lastPathComponent) \(result.removed)행 제거")
            } catch {
                AppLog.write("app", "에코 소급 정리 실패: \(summary.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.set(true, forKey: key)
        if cleaned > 0 { refresh() }
    }

    /// 저장된 회의의 제목 변경: session.json 갱신 + 폴더명을 새 제목으로 rename.
    func rename(at url: URL, title: String) -> URL? {
        guard var meeting = load(url) else { return nil }
        meeting.title = title

        do {
            try stageAndCommit(meeting: meeting, editLog: nil, to: url)
        } catch {
            return nil
        }

        guard !Self.folderName(
            url.lastPathComponent,
            matchesBase: Self.folderBaseName(for: meeting.startedAt, title: title)
        ) else {
            refresh()
            return url
        }

        let candidate = makeUniqueFolder(for: meeting.startedAt, title: title)
        do {
            try FileManager.default.moveItem(at: url, to: candidate)
        } catch {
            AppLog.write("app", "회의 폴더 rename 실패(제목만 반영): \(error.localizedDescription.prefix(120))")
            refresh()
            return url
        }
        refresh()
        return candidate
    }

    /// 요약 첫 H1을 회의 제목으로 (60자 컷). H1이 없으면 nil.
    static func titleFromSummary(_ summary: String) -> String? {
        for rawLine in summary.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("# ") else { continue }
            let title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            return String(title.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// 저장된 회의에 요약 갱신 및 editLog 동기화 (단일 트랜잭션).
    @discardableResult
    func updateSummary(at url: URL, summary: String) throws -> String? {
        guard var meeting = load(url) else {
            throw MeetingStoreError.meetingNotFound
        }
        try Self.validateUniqueIDs(meeting.rows)
        meeting.summary = summary
        var (log, recovery) = try loadLogForMutation(at: url)
        log.editsAtLastSummary = log.revision
        try stageAndCommit(meeting: meeting, editLog: log, recovery: recovery, to: url)
        refresh()
        return recovery != nil ? "Edit history was unreadable and has been reset" : nil
    }

    /// 요약 재생성 시점 동기화 마킹.
    @discardableResult
    func markSummaryRegenerated(at url: URL) throws -> String? {
        guard let meeting = load(url) else {
            throw MeetingStoreError.meetingNotFound
        }
        try Self.validateUniqueIDs(meeting.rows)
        var (log, recovery) = try loadLogForMutation(at: url)
        log.editsAtLastSummary = log.revision
        try stageAndCommit(meeting: meeting, editLog: log, recovery: recovery, to: url)
        refresh()
        return recovery != nil ? "Edit history was unreadable and has been reset" : nil
    }

    /// 저장된 회의의 rows 및 speakerNames 갱신 (다이어라이제이션 완료 후 소급 반영용).
    func updateRows(at url: URL, rows: [TranscriptRow], speakerNames: [Int: String]) throws {
        guard !rows.isEmpty else {
            throw MeetingStoreError.emptyRows
        }
        try Self.validateUniqueIDs(rows)
        guard var meeting = load(url) else {
            throw MeetingStoreError.meetingNotFound
        }
        try Self.validateUniqueIDs(meeting.rows)
        meeting.rows = try Self.preservingDiskEnglish(incoming: rows, disk: meeting.rows)
        meeting.speakerNames = speakerNames
        try stageAndCommit(meeting: meeting, editLog: nil, to: url)
        refresh()
    }

    // MARK: - 행 ID 및 디스크 텍스트 보존 헬퍼

    private static func validateUniqueIDs(_ rows: [TranscriptRow]) throws {
        _ = try englishByID(rows)
    }

    private static func englishByID(_ rows: [TranscriptRow]) throws -> [UUID: String] {
        var map: [UUID: String] = [:]
        for row in rows {
            if map[row.id] != nil {
                throw MeetingStoreError.duplicateRowID(row.id)
            }
            map[row.id] = row.english
        }
        return map
    }

    private static func preservingDiskEnglish(incoming: [TranscriptRow], disk: [TranscriptRow]) throws -> [TranscriptRow] {
        let diskMap = try englishByID(disk)
        var result = incoming
        for idx in result.indices {
            let id = result[idx].id
            if let diskEnglish = diskMap[id], diskEnglish != result[idx].english {
                result[idx].english = diskEnglish
            }
        }
        return result
    }

    // MARK: - 편집 및 되돌리기 API

    /// 회의 전사 편집 로그 읽기 (손상 시 빈 로그 반환, 디스크 이동 없음).
    func editLog(at url: URL) -> TranscriptEditLog {
        let editsURL = url.appendingPathComponent("edits.json")
        guard let data = try? Data(contentsOf: editsURL) else {
            return TranscriptEditLog()
        }
        do {
            return try TranscriptEditLog.load(from: data)
        } catch {
            AppLog.write("app", "Edit history corrupt at \(url.lastPathComponent): \(error.localizedDescription)")
            return TranscriptEditLog()
        }
    }

    /// 단일 행 인라인 편집.
    func updateRow(at url: URL, rowID: UUID, english: String) throws -> EditResult {
        do {
            guard var meeting = load(url) else {
                throw MeetingStoreError.meetingNotFound
            }
            try Self.validateUniqueIDs(meeting.rows)
            guard let rowIndex = meeting.rows.firstIndex(where: { $0.id == rowID }) else {
                throw MeetingStoreError.rowNotFound(rowID)
            }

            var trimmed = english
            while trimmed.last?.isWhitespace == true || trimmed.last?.isNewline == true {
                trimmed.removeLast()
            }
            guard !trimmed.isEmpty else {
                throw MeetingStoreError.emptyText
            }

            let beforeText = meeting.rows[rowIndex].english
            if beforeText == trimmed {
                return EditResult(meeting: meeting, log: editLog(at: url), changedRowCount: 0, warning: nil)
            }

            meeting.rows[rowIndex].english = trimmed
            let (log, recovery) = try loadLogForMutation(at: url)
            var mutatingLog = log

            let rowEdit = RowEdit(rowID: rowID, before: beforeText, after: trimmed)
            let batch = TranscriptEditBatch(
                id: UUID(),
                at: Date(),
                kind: .inline,
                find: nil,
                replacement: nil,
                caseSensitive: nil,
                wholeWord: nil,
                rowEdits: [rowEdit],
                summaryBefore: nil,
                summaryAfter: nil
            )
            let batchWeight = batch.rowEdits.count + (batch.summaryAfter != nil ? 1 : 0)
            _ = try mutatingLog.revisionAfterAppending(weight: batchWeight)
            mutatingLog.batches.append(batch)

            try stageAndCommit(meeting: meeting, editLog: mutatingLog, recovery: recovery, to: url)
            refresh()

            let warning = recovery != nil ? "Edit history was unreadable and has been reset" : nil
            AppLog.write("app", "Transcript edit: inline rows=1 total=\(mutatingLog.editCount) \(url.lastPathComponent)")
            return EditResult(meeting: meeting, log: mutatingLog, changedRowCount: 1, warning: warning)
        } catch {
            AppLog.write("app", "Transcript edit failed: inline \(url.lastPathComponent): \(error.localizedDescription)")
            throw error
        }
    }

    /// 일괄 찾아바꾸기.
    func replaceAll(
        at url: URL,
        find: String,
        replacement: String,
        caseSensitive: Bool,
        wholeWord: Bool,
        includeSummary: Bool
    ) throws -> EditResult {
        do {
            guard !find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingStoreError.noMatches
            }
            guard var meeting = load(url) else {
                throw MeetingStoreError.meetingNotFound
            }
            try Self.validateUniqueIDs(meeting.rows)

            let options = TranscriptReplace.Options(caseSensitive: caseSensitive, wholeWord: wholeWord)
            var rowEdits: [RowEdit] = []
            var matchedCount = 0

            for (idx, row) in meeting.rows.enumerated() {
                let count = TranscriptReplace.matchCount(in: row.english, find: find, options: options)
                if count > 0 {
                    matchedCount += count
                    let replaced = TranscriptReplace.replace(in: row.english, find: find, replacement: replacement, options: options)
                    if replaced != row.english {
                        rowEdits.append(RowEdit(rowID: row.id, before: row.english, after: replaced))
                        meeting.rows[idx].english = replaced
                    }
                }
            }

            var summaryBefore: String? = nil
            var summaryAfter: String? = nil
            if includeSummary, let currentSummary = meeting.summary {
                let sumCount = TranscriptReplace.matchCount(in: currentSummary, find: find, options: options)
                if sumCount > 0 {
                    matchedCount += sumCount
                    let replacedSummary = TranscriptReplace.replace(in: currentSummary, find: find, replacement: replacement, options: options)
                    if replacedSummary != currentSummary {
                        summaryBefore = currentSummary
                        summaryAfter = replacedSummary
                        meeting.summary = replacedSummary
                    }
                }
            }

            guard matchedCount > 0 else {
                throw MeetingStoreError.noMatches
            }

            guard !rowEdits.isEmpty || summaryBefore != nil else {
                throw MeetingStoreError.noChanges
            }

            let (log, recovery) = try loadLogForMutation(at: url)
            var mutatingLog = log
            let batch = TranscriptEditBatch(
                id: UUID(),
                at: Date(),
                kind: .replaceAll,
                find: find,
                replacement: replacement,
                caseSensitive: caseSensitive,
                wholeWord: wholeWord,
                rowEdits: rowEdits,
                summaryBefore: summaryBefore,
                summaryAfter: summaryAfter
            )
            let batchWeight = batch.rowEdits.count + (batch.summaryAfter != nil ? 1 : 0)
            _ = try mutatingLog.revisionAfterAppending(weight: batchWeight)
            mutatingLog.batches.append(batch)

            try stageAndCommit(meeting: meeting, editLog: mutatingLog, recovery: recovery, to: url)
            refresh()

            let warning = recovery != nil ? "Edit history was unreadable and has been reset" : nil
            AppLog.write("app", "Transcript edit: replaceAll rows=\(rowEdits.count) total=\(mutatingLog.editCount) \(url.lastPathComponent)")
            return EditResult(meeting: meeting, log: mutatingLog, changedRowCount: rowEdits.count, warning: warning)
        } catch {
            AppLog.write("app", "Transcript edit failed: replaceAll \(url.lastPathComponent): \(error.localizedDescription)")
            throw error
        }
    }

    /// 마지막 편집 배치 되돌리기 (Undo).
    func undoLastEdit(at url: URL) throws -> EditResult {
        do {
            guard var meeting = load(url) else {
                throw MeetingStoreError.meetingNotFound
            }
            try Self.validateUniqueIDs(meeting.rows)
            let (log, recovery) = try loadLogForMutation(at: url)
            if recovery != nil {
                // 손상 복구: 회의 본문은 유지하고 빈 로그로 커밋(손상 파일 백업)
                try stageAndCommit(meeting: meeting, editLog: log, recovery: recovery, to: url)
                refresh()
                AppLog.write("app", "Transcript edit: undo recovery reset total=0 \(url.lastPathComponent)")
                return EditResult(meeting: meeting, log: log, changedRowCount: 0, warning: "Edit history was unreadable and has been reset")
            }

            guard !log.batches.isEmpty else {
                throw MeetingStoreError.nothingToUndo
            }
            var mutatingLog = log
            let lastBatch = mutatingLog.batches.last!

            for rowEdit in lastBatch.rowEdits {
                guard let row = meeting.rows.first(where: { $0.id == rowEdit.rowID }) else {
                    throw MeetingStoreError.undoConflict(rowEdit.rowID)
                }
                if row.english != rowEdit.after {
                    throw MeetingStoreError.undoConflict(rowEdit.rowID)
                }
            }

            if let summaryAfter = lastBatch.summaryAfter {
                if meeting.summary != summaryAfter {
                    throw MeetingStoreError.undoSummaryConflict
                }
            }

            for rowEdit in lastBatch.rowEdits {
                if let idx = meeting.rows.firstIndex(where: { $0.id == rowEdit.rowID }) {
                    meeting.rows[idx].english = rowEdit.before
                }
            }
            if let summaryBefore = lastBatch.summaryBefore {
                meeting.summary = summaryBefore
            }

            let e0 = mutatingLog.editCount
            mutatingLog.batches.removeLast()
            let e1 = mutatingLog.editCount
            // 되돌리기(Undo)는 마지막 요약 시점 대비 전사 변경이 발생한 것이므로 1건의 미반영 변경으로 계산되며,
            // 오프셋을 통해 제거된 배치의 가중치를 보정한다.
            let deltaResult = (e0 - e1).addingReportingOverflow(1)
            let offsetResult = mutatingLog.revisionOffset.addingReportingOverflow(deltaResult.partialValue)
            let revResult = offsetResult.partialValue.addingReportingOverflow(e1)
            guard !deltaResult.overflow, !offsetResult.overflow, !revResult.overflow else {
                throw MeetingStoreError.editLogCorrupt("revision counter overflow")
            }
            mutatingLog.revisionOffset = offsetResult.partialValue

            try stageAndCommit(meeting: meeting, editLog: mutatingLog, recovery: recovery, to: url)
            refresh()

            AppLog.write("app", "Transcript edit: undo rows=\(lastBatch.rowEdits.count) total=\(mutatingLog.editCount) \(url.lastPathComponent)")
            return EditResult(meeting: meeting, log: mutatingLog, changedRowCount: lastBatch.rowEdits.count, warning: nil)
        } catch {
            AppLog.write("app", "Transcript edit failed: undo \(url.lastPathComponent): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - 내부 파일 쓰기 및 스테이징

    private func loadLogForMutation(at url: URL) throws -> (log: TranscriptEditLog, recovery: LogRecovery?) {
        let editsURL = url.appendingPathComponent("edits.json")
        guard FileManager.default.fileExists(atPath: editsURL.path) else {
            return (TranscriptEditLog(), nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: editsURL)
        } catch {
            throw MeetingStoreError.writeFailed("read edits.json: \(error.localizedDescription)")
        }
        do {
            let log = try TranscriptEditLog.load(from: data)
            return (log, nil)
        } catch let error as MeetingStoreError {
            switch error {
            case .editLogCorrupt(let reason):
                return (TranscriptEditLog(), .corrupt(reason))
            default:
                return (TranscriptEditLog(), .corrupt(error.localizedDescription))
            }
        } catch {
            return (TranscriptEditLog(), .corrupt(error.localizedDescription))
        }
    }

    /// 회의 폴더 내 모든 관련 파일을 원자적으로 스테이징 후 커밋.
    ///
    /// Note on `editLog`:
    /// When `editLog` is `nil` (such as 2-pass `save(existingURL:)` or `updateRows` after diarization),
    /// the on-disk `edits.json` is left untouched. Any stale rowIDs that might no longer match
    /// after a re-diarization or row replacement are safely caught by the undo conflict check
    /// (`MeetingStoreError.undoConflict`) when an undo is attempted.
    private func stageAndCommit(
        meeting: SavedMeeting,
        editLog: TranscriptEditLog?,
        recovery: LogRecovery? = nil,
        to folder: URL
    ) throws {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw MeetingStoreError.writeFailed("create folder: \(error.localizedDescription)")
        }

        // 잔여 임시 폴더 정리 (이전 실패분). 열거 실패 시에도 커밋은 계속 진행 (데이터 정합성 실패 아님).
        do {
            let existingItems = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])
            for item in existingItems where item.lastPathComponent.hasPrefix(".staging-") {
                do {
                    try FileManager.default.removeItem(at: item)
                    AppLog.write("app", "Removed leftover staging directory: \(item.lastPathComponent)")
                } catch {
                    AppLog.write("app", "Failed to remove leftover staging directory \(item.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            AppLog.write("app", "staging sweep failed: \(folder.lastPathComponent): \(error.localizedDescription)")
        }

        let stagingFolder = folder.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        } catch {
            throw MeetingStoreError.writeFailed("create staging: \(error.localizedDescription)")
        }
        defer {
            if FileManager.default.fileExists(atPath: stagingFolder.path) {
                do {
                    try FileManager.default.removeItem(at: stagingFolder)
                } catch {
                    AppLog.write("app", "staging cleanup failed: \(stagingFolder.path): \(error.localizedDescription)")
                }
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // 1. session.json
        do {
            let sessionData = try encoder.encode(meeting)
            try sessionData.write(to: stagingFolder.appendingPathComponent("session.json"))
        } catch {
            throw MeetingStoreError.writeFailed("stage session.json: \(error.localizedDescription)")
        }

        // 2. edits.json (로그가 비어있지 않거나 이미 디스크에 존재하는 경우, 또는 손상 복구 시)
        let diskEditsURL = folder.appendingPathComponent("edits.json")
        let hasDiskEdits = FileManager.default.fileExists(atPath: diskEditsURL.path)
        if let editLog, (!editLog.batches.isEmpty || hasDiskEdits || recovery != nil) {
            do {
                let logData = try encoder.encode(editLog)
                try logData.write(to: stagingFolder.appendingPathComponent("edits.json"))
            } catch {
                throw MeetingStoreError.writeFailed("stage edits.json: \(error.localizedDescription)")
            }
        }

        let resolve: (TranscriptRow) -> String = { row in
            Self.resolveName(row: row, myName: meeting.myName, speakerNames: meeting.speakerNames)
        }

        // 3. en.md
        do {
            let enText = Self.englishMarkdown(meeting, resolve: resolve)
            try enText.write(to: stagingFolder.appendingPathComponent("en.md"), atomically: false, encoding: .utf8)
        } catch {
            throw MeetingStoreError.writeFailed("stage en.md: \(error.localizedDescription)")
        }

        // 4. ko.md (한국어 번역 행이 있는 경우에만)
        let hasKorean = meeting.rows.contains(where: { $0.korean != nil })
        if hasKorean {
            do {
                let koText = Self.koreanMarkdown(meeting, resolve: resolve)
                try koText.write(to: stagingFolder.appendingPathComponent("ko.md"), atomically: false, encoding: .utf8)
            } catch {
                throw MeetingStoreError.writeFailed("stage ko.md: \(error.localizedDescription)")
            }
        }

        // 5. combined.md
        do {
            let combText = Self.combinedMarkdown(meeting, resolve: resolve)
            try combText.write(to: stagingFolder.appendingPathComponent("combined.md"), atomically: false, encoding: .utf8)
        } catch {
            throw MeetingStoreError.writeFailed("stage combined.md: \(error.localizedDescription)")
        }

        // 6. summary.md (요약이 있는 경우)
        if let summary = meeting.summary {
            let content = "# 회의 요약\n\n\(header(meeting, resolve: resolve))\n\n---\n\n\(summary)\n"
            do {
                try content.write(to: stagingFolder.appendingPathComponent("summary.md"), atomically: false, encoding: .utf8)
            } catch {
                throw MeetingStoreError.writeFailed("stage summary.md: \(error.localizedDescription)")
            }
        }

        // 스테이징 완료 후 손상된 이전 edits.json 백업 이동
        if let recovery {
            let ts = Int(Date().timeIntervalSince1970)
            let uuidPrefix = String(UUID().uuidString.prefix(8))
            let corruptURL = folder.appendingPathComponent("edits.json.corrupt-\(ts)-\(uuidPrefix)")
            if FileManager.default.fileExists(atPath: diskEditsURL.path) {
                do {
                    try FileManager.default.moveItem(at: diskEditsURL, to: corruptURL)
                    switch recovery {
                    case .corrupt(let reason):
                        AppLog.write("app", "Transcript edit log corrupt, moved to \(corruptURL.lastPathComponent): \(reason)")
                    }
                } catch {
                    throw MeetingStoreError.writeFailed("backup edits.json: \(error.localizedDescription)")
                }
            }
        }

        // 고정 순서 커밋: session.json -> edits.json -> en.md -> ko.md -> combined.md -> summary.md
        let commitFiles = ["session.json", "edits.json", "en.md", "ko.md", "combined.md", "summary.md"]
        for fileName in commitFiles {
            let stagedFile = stagingFolder.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: stagedFile.path) {
                let destFile = folder.appendingPathComponent(fileName)
                do {
                    if FileManager.default.fileExists(atPath: destFile.path) {
                        _ = try FileManager.default.replaceItemAt(destFile, withItemAt: stagedFile)
                    } else {
                        try FileManager.default.moveItem(at: stagedFile, to: destFile)
                    }
                } catch {
                    throw MeetingStoreError.writeFailed("commit \(fileName): \(error.localizedDescription)")
                }
            }
        }

        // 한국어 번역이 없으면 기존 ko.md 잔재 정리 (실패 시 writeFailed 전파)
        if !hasKorean {
            let koURL = folder.appendingPathComponent("ko.md")
            if FileManager.default.fileExists(atPath: koURL.path) {
                do {
                    try FileManager.default.removeItem(at: koURL)
                } catch {
                    throw MeetingStoreError.writeFailed("remove ko.md: \(error.localizedDescription)")
                }
            }
        }

        // 요약이 제거되었으면 기존 summary.md 잔재 정리 (실패 시 writeFailed 전파)
        if meeting.summary == nil {
            let summaryURL = folder.appendingPathComponent("summary.md")
            if FileManager.default.fileExists(atPath: summaryURL.path) {
                do {
                    try FileManager.default.removeItem(at: summaryURL)
                } catch {
                    throw MeetingStoreError.writeFailed("remove summary.md: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 불러오기 / 삭제

    func load(_ url: URL) -> SavedMeeting? {
        let jsonURL = url.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: jsonURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SavedMeeting.self, from: data)
    }

    func delete(_ summary: MeetingSummary) {
        try? FileManager.default.removeItem(at: summary.url)
        refresh()
    }

    // MARK: - 이름 해석 (저장 시점 고정)

    static func resolveName(row: TranscriptRow, myName: String, speakerNames: [Int: String]) -> String {
        switch row.channel {
        case .me:
            return myName
        case .them:
            if let name = row.speakerName, !name.isEmpty { return name }
            guard let slot = row.speakerSlot else { return "Them" }
            return speakerNames[slot] ?? "Speaker \(slot + 1)"
        }
    }

    /// 제목이 없는 회의의 표시 폴백 (날짜 문자열).
    static func resolveTitleFallback(_ meeting: SavedMeeting) -> String {
        titleFormatter.string(from: meeting.startedAt)
    }

    /// 상세 화면용 긴 일시 라벨.
    static func longDateLabel(_ date: Date) -> String {
        titleFormatter.string(from: date)
    }

    // MARK: - 마크다운 생성

    private static func header(_ meeting: SavedMeeting, resolve: (TranscriptRow) -> String) -> String {
        let participants = orderedParticipants(meeting, resolve: resolve).joined(separator: ", ")
        let total = Int(meeting.durationSeconds)
        let duration = total >= 60 ? "\(total / 60)분 \(total % 60)초" : "\(total)초"
        let titleLine = meeting.title.map { "제목: \($0)\n" } ?? ""
        return """
        \(titleLine)일시: \(titleFormatter.string(from: meeting.startedAt))
        길이: \(duration)
        참석: \(participants)
        """
    }

    private func header(_ meeting: SavedMeeting, resolve: (TranscriptRow) -> String) -> String {
        Self.header(meeting, resolve: resolve)
    }

    private static func orderedParticipants(_ meeting: SavedMeeting, resolve: (TranscriptRow) -> String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for row in meeting.rows {
            let name = resolve(row)
            if seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        return ordered
    }

    private static func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func englishMarkdown(_ meeting: SavedMeeting, resolve: (TranscriptRow) -> String) -> String {
        var lines = ["# Meeting Transcript (EN)", "", header(meeting, resolve: resolve), "", "---", ""]
        for row in meeting.rows {
            lines.append("**[\(timeLabel(row.startSeconds))] \(resolve(row))**  ")
            lines.append(row.english)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func koreanMarkdown(_ meeting: SavedMeeting, resolve: (TranscriptRow) -> String) -> String {
        var lines = ["# 회의 전사 (한국어)", "", header(meeting, resolve: resolve), "", "---", ""]
        for row in meeting.rows {
            lines.append("**[\(timeLabel(row.startSeconds))] \(resolve(row))**  ")
            lines.append(row.korean ?? "_(번역 없음)_ \(row.english)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func combinedMarkdown(_ meeting: SavedMeeting, resolve: (TranscriptRow) -> String) -> String {
        var lines = ["# Meeting Transcript (EN + 한국어)", "", header(meeting, resolve: resolve), "", "---", ""]
        for row in meeting.rows {
            lines.append("**[\(timeLabel(row.startSeconds))] \(resolve(row))**  ")
            lines.append(row.english)
            if let korean = row.korean {
                lines.append("> \(korean)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// LLM 요약 입력용 경량 전사 (영어만, 화자, 시각 포함).
    static func transcriptForSummary(_ meeting: SavedMeeting, resolve: (TranscriptRow) -> String) -> String {
        meeting.rows.map { row in
            "[\(timeLabel(row.startSeconds))] \(resolve(row)): \(row.english)"
        }.joined(separator: "\n")
    }

    // MARK: - 폴더 이름

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy년 M월 d일 HH:mm"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    private static let folderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter
    }()

    /// 폴더명: "yyyy-MM-dd HHmm" + 캘린더 회의 제목 (파일명 안전화, 40자 컷).
    private func makeUniqueFolder(for date: Date, title: String?) -> URL {
        let base = Self.folderBaseName(for: date, title: title)
        var candidate = rootURL.appendingPathComponent(base, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = rootURL.appendingPathComponent("\(base) (\(counter))", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    /// 중복 처리 전 폴더 기본 이름 ("yyyy-MM-dd HHmm[ 제목]").
    static func folderBaseName(for date: Date, title: String?) -> String {
        var base = folderFormatter.string(from: date)
        if let safeTitle = folderSafeTitle(title), !safeTitle.isEmpty {
            base += " \(safeTitle)"
        }
        return base
    }

    /// 폴더 이름이 이 기본 이름에서 온 것인지 (정확히 같거나 충돌 회피 접미사 " (N)"만 붙은 경우).
    static func folderName(_ name: String, matchesBase base: String) -> Bool {
        if name == base { return true }
        let pattern = "^\(NSRegularExpression.escapedPattern(for: base)) \\(\\d+\\)$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    /// 회의 제목을 폴더명에 안전한 형태로: 경로 예약 문자 제거, 공백 정리, 40자 제한.
    static func folderSafeTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = String(title.map { char -> Character in
            if let scalar = char.unicodeScalars.first, forbidden.contains(scalar) { return " " }
            return char
        })
        .replacingOccurrences(of: "  ", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(40)).trimmingCharacters(in: .whitespaces)
    }
}
