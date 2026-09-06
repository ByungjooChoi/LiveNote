import Foundation

/// 내보내기 형식.
enum ExportFormat: String, CaseIterable, Sendable {
    case markdown = "md"
    case html = "html"

    var fileExtension: String { rawValue }

    var label: String {
        switch self {
        case .markdown:
            return "Markdown"
        case .html:
            return "HTML"
        }
    }
}

/// 생성된 내보내기 문서.
struct ExportDocument: Equatable, Sendable {
    var fileName: String
    var data: Data
    var format: ExportFormat
}

/// 내보낼 마크다운 및 메타데이터 원본.
struct ExportSource: Equatable, Sendable {
    var markdown: String
    var title: String
    var date: Date
}

/// 내보내기 오류.
enum ExportError: LocalizedError, Equatable {
    case emptyDocument
    case writeFailed(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .emptyDocument:
            return "Document is empty."
        case .writeFailed(let reason):
            return "Failed to write document: \(reason)"
        case .encodingFailed:
            return "Failed to encode document as UTF-8."
        }
    }
}

/// 마크다운 -> HTML 순수 변환기.
enum MarkdownHTML {

    /// HTML 특수문자 이스케이프 (& < > " ')
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&":
                result.append("&amp;")
            case "<":
                result.append("&lt;")
            case ">":
                result.append("&gt;")
            case "\"":
                result.append("&quot;")
            case "'":
                result.append("&#39;")
            default:
                result.append(String(scalar))
            }
        }
        return result
    }

    private static let inlineRegex = try? NSRegularExpression(
        pattern: #"`([^`]+)`|\[([^\]]+)\]\((https?://[^)\s"]+)\)"#,
        options: []
    )

    /// 인라인 서식 변환 (NUL 제거 -> HTML-escape -> 단일 스캔 토큰화 -> bold/italic -> 단일 패스 복원).
    static func inline(_ text: String) -> String {
        // NUL 문자 위조 방지: 입력에서 모든 U+0000 제거
        let sanitized = text.filter { $0 != "\u{0000}" }
        let escaped = escape(sanitized)
        return renderSegments(in: escaped)
    }

    private static func renderSegments(in text: String) -> String {
        guard let inlineRegex else { return text }

        var working = ""
        working.reserveCapacity(text.count)
        var codePlaceholders: [String] = []
        var linkPlaceholders: [String] = []

        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let matches = inlineRegex.matches(in: text, options: [], range: fullRange)

        var lastEnd = 0

        for match in matches {
            if match.range.location > lastEnd {
                let prefixRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
                working.append(nsString.substring(with: prefixRange))
            }

            if match.range(at: 1).location != NSNotFound {
                let codeContent = nsString.substring(with: match.range(at: 1))
                let placeholder = "\u{0000}C\(codePlaceholders.count)\u{0000}"
                codePlaceholders.append("<code>\(codeContent)</code>")
                working.append(placeholder)
            } else if match.range(at: 2).location != NSNotFound && match.range(at: 3).location != NSNotFound {
                let rawLabel = nsString.substring(with: match.range(at: 2))
                let url = nsString.substring(with: match.range(at: 3))
                let formattedLabel = renderSegments(in: rawLabel)
                let placeholder = "\u{0000}L\(linkPlaceholders.count)\u{0000}"
                linkPlaceholders.append("<a href=\"\(url)\">\(formattedLabel)</a>")
                working.append(placeholder)
            }

            lastEnd = match.range.location + match.range.length
        }

        if lastEnd < nsString.length {
            let suffixRange = NSRange(location: lastEnd, length: nsString.length - lastEnd)
            working.append(nsString.substring(with: suffixRange))
        }

        working = applyBoldItalic(working)

        return restorePlaceholders(
            in: working,
            codePlaceholders: codePlaceholders,
            linkPlaceholders: linkPlaceholders
        )
    }

    private static func restorePlaceholders(
        in text: String,
        codePlaceholders: [String],
        linkPlaceholders: [String]
    ) -> String {
        let parts = text.components(separatedBy: "\u{0000}")
        var result = ""
        result.reserveCapacity(text.count)
        for (index, part) in parts.enumerated() {
            if index % 2 == 1 {
                if part.hasPrefix("C"),
                   let codeIdx = Int(part.dropFirst()),
                   codeIdx >= 0,
                   codeIdx < codePlaceholders.count {
                    result.append(codePlaceholders[codeIdx])
                } else if part.hasPrefix("L"),
                          let linkIdx = Int(part.dropFirst()),
                          linkIdx >= 0,
                          linkIdx < linkPlaceholders.count {
                    result.append(linkPlaceholders[linkIdx])
                } else {
                    result.append(part)
                }
            } else {
                result.append(part)
            }
        }
        return result
    }

    private static func applyBoldItalic(_ text: String) -> String {
        var res = text

        // **bold**
        res = replaceRegex(in: res, pattern: "\\*\\*(.+?)\\*\\*") { match in
            "<strong>\(match[1])</strong>"
        }

        // *italic* (단, **의 일부가 아니어야 함)
        res = replaceRegex(in: res, pattern: "(?<!\\*)\\*([^\\*]+?)\\*(?!\\*)") { match in
            "<em>\(match[1])</em>"
        }

        // _italic_ (단어 내부의 snake_case 제외)
        res = replaceRegex(in: res, pattern: "(?<![a-zA-Z0-9_])_([^_]+?)_(?![a-zA-Z0-9_])") { match in
            "<em>\(match[1])</em>"
        }

        return res
    }

    private static func replaceRegex(
        in text: String,
        pattern: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = 0

        for match in matches {
            if match.range.location > lastEnd {
                let prefixRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
                result += nsString.substring(with: prefixRange)
            }
            var groups: [String] = []
            for idx in 0..<match.numberOfRanges {
                let r = match.range(at: idx)
                if r.location != NSNotFound {
                    groups.append(nsString.substring(with: r))
                } else {
                    groups.append("")
                }
            }
            result += transform(groups)
            lastEnd = match.range.location + match.range.length
        }

        if lastEnd < nsString.length {
            let suffixRange = NSRange(location: lastEnd, length: nsString.length - lastEnd)
            result += nsString.substring(with: suffixRange)
        }

        return result
    }

    /// 본문 블록 변환.
    static func renderBody(markdown: String) -> String {
        var html = ""
        struct ListLevel {
            var hasOpenLi: Bool
        }
        var listStack: [ListLevel] = []

        func closeLists(downTo targetDepth: Int) {
            while listStack.count > targetDepth {
                let level = listStack.removeLast()
                if listStack.isEmpty {
                    if level.hasOpenLi {
                        html.append("</li>\n")
                    }
                    html.append("</ul>\n")
                } else {
                    if level.hasOpenLi {
                        html.append("</li>")
                    }
                    html.append("</ul></li>\n")
                    listStack[listStack.count - 1].hasOpenLi = false
                }
            }
        }

        func closeAllLists() {
            closeLists(downTo: 0)
        }

        let lines = markdown.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                closeAllLists()
                continue
            }

            if trimmed.hasPrefix("# ") {
                closeAllLists()
                let heading = String(trimmed.dropFirst(2))
                html.append("<h1>\(inline(heading))</h1>\n")
            } else if trimmed.hasPrefix("## ") {
                closeAllLists()
                let heading = String(trimmed.dropFirst(3))
                html.append("<h2>\(inline(heading))</h2>\n")
            } else if trimmed.hasPrefix("- ") {
                let leadingSpaces = line.prefix(while: { $0 == " " }).count
                let indentLevel = leadingSpaces / 2
                let targetDepth = indentLevel + 1

                closeLists(downTo: targetDepth)

                while listStack.count < targetDepth {
                    if listStack.isEmpty {
                        html.append("<ul>\n")
                        listStack.append(ListLevel(hasOpenLi: false))
                    } else {
                        if !listStack[listStack.count - 1].hasOpenLi {
                            html.append("<li>")
                            listStack[listStack.count - 1].hasOpenLi = true
                        }
                        html.append("<ul>")
                        listStack.append(ListLevel(hasOpenLi: false))
                    }
                }

                if listStack[listStack.count - 1].hasOpenLi {
                    html.append("</li>\n")
                }
                let itemText = String(trimmed.dropFirst(2))
                html.append("<li>\(inline(itemText))")
                listStack[listStack.count - 1].hasOpenLi = true
            } else {
                closeAllLists()
                html.append("<p>\(inline(trimmed))</p>\n")
            }
        }

        closeAllLists()
        return html
    }

    /// 전체 HTML 문서 생성.
    static func render(markdown: String, title: String) -> String {
        let escapedTitle = escape(title)
        let bodyHtml = renderBody(markdown: markdown)

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapedTitle)</title>
        <style>
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          max-width: 720px;
          margin: 40px auto;
          padding: 0 20px;
          line-height: 1.6;
          color: #1a1a1a;
        }
        h1 {
          color: #274C9C;
          font-size: 1.8em;
          margin-top: 24px;
          margin-bottom: 12px;
        }
        h2 {
          font-size: 1.3em;
          margin-top: 20px;
          margin-bottom: 8px;
        }
        p {
          margin: 8px 0;
        }
        ul {
          margin: 8px 0;
          padding-left: 24px;
        }
        li {
          margin: 4px 0;
        }
        code {
          font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
          font-size: 0.9em;
          background-color: rgba(0, 0, 0, 0.05);
          padding: 2px 4px;
          border-radius: 4px;
        }
        a {
          color: #274C9C;
          text-decoration: underline;
        }
        </style>
        </head>
        <body>
        \(bodyHtml)</body>
        </html>
        """
    }
}

/// 회의 문서 내보내기 엔진.
@MainActor
enum MeetingExporter {

    /// 회의 참석자 목록 (고유 이름 목록, 본인 포함).
    static func participantNames(_ meeting: SavedMeeting) -> [String] {
        var seen = Set<String>()
        var names: [String] = []

        for row in meeting.rows {
            let name = MeetingStore.resolveName(row: row, myName: meeting.myName, speakerNames: meeting.speakerNames)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && seen.insert(trimmed).inserted {
                names.append(trimmed)
            }
        }

        let myName = meeting.myName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !myName.isEmpty && seen.insert(myName).inserted {
            names.append(myName)
        }

        return names
    }

    /// 회의 마크다운 생성.
    static func markdown(for meeting: SavedMeeting, includeTranscript: Bool) -> String {
        var lines: [String] = []

        let title = meeting.title ?? MeetingStore.resolveTitleFallback(meeting)
        lines.append("# \(title)")
        lines.append("")

        let dateLabel = MeetingStore.longDateLabel(meeting.startedAt)
        let durationMinutes = Int(meeting.durationSeconds) / 60
        let participants = participantNames(meeting)
        lines.append("\(dateLabel) · \(durationMinutes)m · \(participants.count) participants")
        lines.append("")

        if let attendees = meeting.attendees, !attendees.isEmpty {
            lines.append("## Attendees")
            for attendee in attendees {
                let emailPart: String
                if let email = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
                    emailPart = " <\(email)>"
                } else {
                    emailPart = ""
                }
                lines.append("- \(attendee.name)\(emailPart)")
            }
            lines.append("")
        }

        if let rawSummary = meeting.summary, !rawSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(rawSummary)
        } else {
            lines.append("_No minutes._")
        }

        if includeTranscript {
            lines.append("")
            lines.append("## Transcript")
            lines.append("")
            for row in meeting.rows {
                let name = MeetingStore.resolveName(row: row, myName: meeting.myName, speakerNames: meeting.speakerNames)
                lines.append("- **[\(row.timeLabel)] \(name):** \(row.english)")
                if let korean = row.korean?.trimmingCharacters(in: .whitespacesAndNewlines), !korean.isEmpty {
                    lines.append("  - \(korean)")
                }
            }
        }

        var result = lines.joined(separator: "\n")
        while result.hasSuffix("\n") {
            result.removeLast()
        }
        result.append("\n")
        return result
    }

    /// 내보내기 파일명 생성.
    static func fileName(title: String?, startedAt: Date, format: ExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let dateStr = formatter.string(from: startedAt)

        let rawTitle: String
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            rawTitle = title
        } else {
            rawTitle = "Meeting"
        }
        let safe = RecipeOutputStore.safeTitle(rawTitle)
        return "\(dateStr) \(safe).\(format.fileExtension)"
    }

    /// 회의 객체 기반 문서 생성.
    static func document(for meeting: SavedMeeting, format: ExportFormat, includeTranscript: Bool) throws -> ExportDocument {
        let md = markdown(for: meeting, includeTranscript: includeTranscript)
        let title = meeting.title ?? MeetingStore.resolveTitleFallback(meeting)
        return try document(markdown: md, title: title, format: format, date: meeting.startedAt)
    }

    /// 임의 마크다운 기반 문서 생성 (채팅/레시피 경로 포함).
    static func document(markdown: String, title: String, format: ExportFormat, date: Date = Date()) throws -> ExportDocument {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ExportError.emptyDocument
        }

        let name = fileName(title: title, startedAt: date, format: format)
        let content: String
        switch format {
        case .markdown:
            content = markdown
        case .html:
            content = MarkdownHTML.render(markdown: markdown, title: title)
        }

        guard let data = content.data(using: .utf8) else {
            throw ExportError.encodingFailed
        }

        return ExportDocument(fileName: name, data: data, format: format)
    }

    /// 원자적 파일 쓰기.
    nonisolated static func write(_ document: ExportDocument, to url: URL) throws {
        do {
            try document.data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }
}
