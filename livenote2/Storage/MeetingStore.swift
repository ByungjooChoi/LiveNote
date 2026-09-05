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
    /// 캘린더 일정 제목 (없으면 nil — 사이드바는 날짜로 폴백)
    var title: String? = nil
    var myName: String
    var speakerNames: [Int: String]
    var rows: [TranscriptRow]
    /// LLM 생성 요약 (한국어). 없으면 nil. (구버전 파일과의 호환을 위해 옵셔널)
    var summary: String? = nil
    /// 회의 시작 시점 캘린더 참석자 (본인 제외). 구버전 파일 호환을 위해 옵셔널.
    var attendees: [Attendee]? = nil
}

/// 회의 저장소 — `~/Documents/livenote2/` 아래 회의별 폴더.
///
/// 각 회의 폴더 구성:
///   session.json  앱이 다시 열기 위한 원본 데이터
///   en.md         영어 전사 (화자·타임스탬프 포함)
///   ko.md         한국어 번역
///   combined.md   영어+한국어 통합본
///   summary.md    LLM 요약 (생성한 경우)
///
/// 오디오는 저장하지 않습니다.
@MainActor
@Observable
final class MeetingStore {

    private(set) var meetings: [MeetingSummary] = []

    let rootURL: URL

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

    /// 구 데이터 폴더 이행: ~/Documents/livenote2 → ~/Documents/LiveNote (1회, 앱 기동 최우선 실행)
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

    // MARK: - 저장

    /// 회의를 저장하고 폴더 URL을 반환. existingURL이 있으면 같은 폴더에 덮어씀(이름 변경·늦은 번역 반영).
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
    ) -> URL? {
        guard !rows.isEmpty else { return existingURL }

        let folder: URL
        if let existingURL {
            folder = existingURL
        } else {
            folder = makeUniqueFolder(for: startedAt, title: title)
        }

        let meeting = SavedMeeting(
            startedAt: startedAt,
            durationSeconds: durationSeconds,
            title: title,
            myName: myName,
            speakerNames: speakerNames,
            rows: rows,
            summary: summary,
            attendees: attendees
        )

        do {
            try writeAll(meeting, to: folder)
            refresh()
            return folder
        } catch {
            return existingURL
        }
    }

    /// 채널 간 에코 중복·빈 행 소급 정리 (v1.3.1, 2-pass 도입 이후 저장본 대상, 1회).
    /// 마이크 사본 행과 구두점만 남은 행을 제거하고 변경된 회의만 다시 쓴다.
    func cleanupEchoDuplicates(since date: Date) {
        let key = "echoCleanupDone.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        var cleaned = 0
        for summary in meetings where summary.startedAt >= date {
            guard var meeting = load(summary.url) else { continue }
            let result = EchoDedup.removeEchoRows(meeting.rows)
            guard result.removed > 0 else { continue }
            meeting.rows = result.rows
            try? writeAll(meeting, to: summary.url)
            cleaned += 1
            AppLog.write("app", "에코 소급 정리: \(summary.url.lastPathComponent) \(result.removed)행 제거")
        }
        UserDefaults.standard.set(true, forKey: key)
        if cleaned > 0 { refresh() }
    }

    /// 저장된 회의의 제목 변경: session.json 갱신 + 폴더명을 새 제목으로 rename.
    ///
    /// 순서가 계약이다. 제목(메타데이터)을 먼저 원본 폴더에 쓰고, 그 다음 폴더를 옮긴다.
    /// 이동이 실패해도 제목은 이미 남아 있으므로 원본 URL을 돌려준다(폴더명만 옛 이름).
    /// nil은 "아무것도 바뀌지 않았다"는 뜻으로만 쓴다: 불러오기 실패 또는 첫 쓰기 실패.
    func rename(at url: URL, title: String) -> URL? {
        guard var meeting = load(url) else { return nil }
        meeting.title = title

        do {
            try writeAll(meeting, to: url)
        } catch {
            return nil
        }

        // 이미 같은 이름이면 (2) 접미사가 붙지 않도록 이동 자체를 생략한다.
        // 충돌 회피로 붙은 " (N)" 접미사도 같은 이름으로 본다 (재호출마다 번호가 커지는 것 방지).
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

    /// 저장된 회의에 요약만 갱신.
    func updateSummary(at url: URL, summary: String) {
        guard var meeting = load(url) else { return }
        meeting.summary = summary
        try? writeAll(meeting, to: url)
    }

    private func writeAll(_ meeting: SavedMeeting, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meeting).write(to: folder.appendingPathComponent("session.json"))

        let resolve: (TranscriptRow) -> String = { row in
            Self.resolveName(row: row, myName: meeting.myName, speakerNames: meeting.speakerNames)
        }
        try Self.englishMarkdown(meeting, resolve: resolve)
            .write(to: folder.appendingPathComponent("en.md"), atomically: true, encoding: .utf8)
        // 번역이 하나도 없으면(번역 끔 모드) ko.md는 만들지 않음
        let koreanURL = folder.appendingPathComponent("ko.md")
        if meeting.rows.contains(where: { $0.korean != nil }) {
            try Self.koreanMarkdown(meeting, resolve: resolve)
                .write(to: koreanURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: koreanURL)
        }
        try Self.combinedMarkdown(meeting, resolve: resolve)
            .write(to: folder.appendingPathComponent("combined.md"), atomically: true, encoding: .utf8)
        if let summary = meeting.summary {
            let content = "# 회의 요약\n\n\(header(meeting, resolve: resolve))\n\n---\n\n\(summary)\n"
            try content.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
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
            // Zoom 태그 등 자동 인식 이름이 있으면 최우선
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

    /// LLM 요약 입력용 경량 전사 (영어만, 화자·시각 포함).
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
    /// 예: "2026-09-01 1950 Philip Craig"
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
    /// rename을 같은 제목으로 반복해도 번호가 계속 커지지 않게 하는 판정이다.
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
