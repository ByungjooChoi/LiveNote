import CryptoKit
import Foundation

/// 사전 브리핑 모델.
struct Brief: Equatable, Sendable {
    var eventKey: String
    var markdown: String
    var generatedAt: Date
    var basedOn: [String]
    var suggestedAgendaFirstLine: String?
}

/// BriefStore 에러.
enum BriefStoreError: LocalizedError, Sendable, Equatable {
    case unreadable(path: String, underlying: any Error)
    case corrupt(path: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let path, let underlying):
            return "Cannot read brief at \(path): \(underlying.localizedDescription)"
        case .corrupt(let path):
            return "Corrupt brief at \(path): missing metadata header"
        }
    }

    static func == (lhs: BriefStoreError, rhs: BriefStoreError) -> Bool {
        switch (lhs, rhs) {
        case (.corrupt(let p1), .corrupt(let p2)):
            return p1 == p2
        case (.unreadable(let p1, _), .unreadable(let p2, _)):
            return p1 == p2
        default:
            return false
        }
    }
}

/// 사전 브리핑 파일 저장소 (`~/Documents/LiveNote/briefs/<safe eventKey>.md`).
struct BriefStore: Sendable {

    let rootURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        self.rootURL = documents.appendingPathComponent("LiveNote", isDirectory: true)
    }

    /// 테스트용: 임시 디렉터리 주입.
    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private var briefsDir: URL {
        rootURL.appendingPathComponent("briefs", isDirectory: true)
    }

    /// 브리핑 파일 로드. 파일이 없으면 nil, 읽기 실패 시 unreadable 에러, 헤더 누락 등 파싱 실패 시 corrupt 에러 발생.
    func load(eventKey: String) throws -> Brief? {
        let file = briefsDir.appendingPathComponent("\(Self.safeFileName(eventKey)).md")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let content: String
        do {
            content = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw BriefStoreError.unreadable(path: file.path, underlying: error)
        }
        guard let brief = Self.parse(content: content, eventKey: eventKey) else {
            throw BriefStoreError.corrupt(path: file.path)
        }
        return brief
    }

    /// 브리핑 저장 (헤더 주석 메타데이터 포함).
    func save(_ brief: Brief) throws {
        try FileManager.default.createDirectory(at: briefsDir, withIntermediateDirectories: true)
        let file = briefsDir.appendingPathComponent("\(Self.safeFileName(brief.eventKey)).md")
        let isoFormatter = ISO8601DateFormatter()
        let genStr = isoFormatter.string(from: brief.generatedAt)
        let basedStr = brief.basedOn.joined(separator: " | ")
        let header = "<!-- generated: \(genStr) -->\n<!-- based-on: \(basedStr) -->\n"
        let full = header + brief.markdown
        try full.write(to: file, atomically: true, encoding: .utf8)
    }

    /// 캐시된 브리핑 삭제 (무효화).
    func invalidate(eventKey: String) throws {
        let file = briefsDir.appendingPathComponent("\(Self.safeFileName(eventKey)).md")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// 회의 폴더 (<url>/brief.md)로 사본 복사.
    func copyBrief(_ brief: Brief, toMeetingFolder url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let target = url.appendingPathComponent("brief.md")
        let isoFormatter = ISO8601DateFormatter()
        let genStr = isoFormatter.string(from: brief.generatedAt)
        let basedStr = brief.basedOn.joined(separator: " | ")
        let header = "<!-- generated: \(genStr) -->\n<!-- based-on: \(basedStr) -->\n"
        let full = header + brief.markdown
        try full.write(to: target, atomically: true, encoding: .utf8)
    }

    /// 회의 폴더 (<url>/brief.md)로 사본 복사.
    func copyBrief(eventKey: String, toMeetingFolder url: URL) throws {
        guard let brief = try load(eventKey: eventKey) else { return }
        try copyBrief(brief, toMeetingFolder: url)
    }

    /// 파일명으로 안전한 문자열 변환 (원문 키의 SHA-256 앞 8자리 해시를 접미하여 충돌 방지).
    static func safeFileName(_ eventKey: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?*|<>\"").union(.newlines)
        let cleaned = eventKey.components(separatedBy: invalidCharacters).joined(separator: "_")
        let base = cleaned.isEmpty ? "unknown" : cleaned
        let digest = SHA256.hash(data: Data(eventKey.utf8))
        let hash = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(base)_\(hash)"
    }

    /// 마크다운에서 "# Suggested agenda" 이후 첫 "- " 또는 "* " 불릿 라인 추출.
    static func firstAgendaLine(in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        var inAgenda = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("# suggested agenda") || trimmed.lowercased().hasPrefix("## suggested agenda") {
                inAgenda = true
                continue
            }
            if inAgenda {
                if trimmed.hasPrefix("#") {
                    break
                }
                if trimmed.hasPrefix("- ") {
                    let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { return text }
                } else if trimmed.hasPrefix("* ") {
                    let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { return text }
                }
            }
        }
        return nil
    }

    /// 파일 내용 파싱 (헤더 주석 + 마크다운 본문). 헤더가 없거나 불완전하면 nil 반환.
    static func parse(content: String, eventKey: String) -> Brief? {
        let lines = content.components(separatedBy: .newlines)
        var generatedAt: Date?
        var basedOn: [String] = []
        var markdownLines: [String] = []
        var pastHeader = false

        let isoFormatter = ISO8601DateFormatter()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !pastHeader {
                if trimmed.hasPrefix("<!-- generated:") && trimmed.hasSuffix("-->") {
                    let inner = trimmed
                        .dropFirst("<!-- generated:".count)
                        .dropLast("-->".count)
                        .trimmingCharacters(in: .whitespaces)
                    if let d = isoFormatter.date(from: String(inner)) {
                        generatedAt = d
                    }
                    continue
                } else if trimmed.hasPrefix("<!-- based-on:") && trimmed.hasSuffix("-->") {
                    let inner = trimmed
                        .dropFirst("<!-- based-on:".count)
                        .dropLast("-->".count)
                        .trimmingCharacters(in: .whitespaces)
                    basedOn = inner.components(separatedBy: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    continue
                } else if trimmed.isEmpty {
                    continue
                } else {
                    pastHeader = true
                }
            }
            markdownLines.append(line)
        }

        guard let genDate = generatedAt else {
            return nil
        }

        let markdown = markdownLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let agenda = firstAgendaLine(in: markdown)
        return Brief(
            eventKey: eventKey,
            markdown: markdown,
            generatedAt: genDate,
            basedOn: basedOn,
            suggestedAgendaFirstLine: agenda
        )
    }
}
