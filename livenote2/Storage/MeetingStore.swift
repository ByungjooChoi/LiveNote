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
        rootURL = documents.appendingPathComponent("livenote2", isDirectory: true)
        refresh()
    }

    // MARK: - 목록

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
                durationSeconds: meeting.durationSeconds
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
            summary: summary
        )

        do {
            try writeAll(meeting, to: folder)
            refresh()
            return folder
        } catch {
            return existingURL
        }
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
        var base = Self.folderFormatter.string(from: date)
        if let safeTitle = Self.folderSafeTitle(title), !safeTitle.isEmpty {
            base += " \(safeTitle)"
        }
        var candidate = rootURL.appendingPathComponent(base, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = rootURL.appendingPathComponent("\(base) (\(counter))", isDirectory: true)
            counter += 1
        }
        return candidate
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
