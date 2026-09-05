import Foundation

enum TasksParse: Equatable, Sendable {
    case absent
    case malformed
    case noUsableItems
    case valid([TaskExtractor.RawTask])
}

enum TaskExtractor {
    struct RawTask: Codable, Equatable, Sendable {
        var title: String
        var owner: String?
        var due: String?
        var quote: String?
    }

    private static let dueDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"
        df.isLenient = false
        return df
    }()

    static func isValidDueDate(_ str: String) -> Bool {
        let parts = str.split(separator: "-")
        guard parts.count == 3 else { return false }
        guard parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        guard let date = dueDateFormatter.date(from: str) else { return false }
        return dueDateFormatter.string(from: date) == str
    }

    /// Parses tasks JSON block: returns .absent if nil, .malformed if unparseable/invalid array, .valid([RawTask]) on success.
    /// Per-item lossy decoding skips bad elements instead of failing the whole array.
    static func parse(_ json: String?) -> TasksParse {
        guard let raw = json else {
            return .absent
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .malformed
        }
        var cleaned = trimmed
        // Strip markdown code fences if present
        if cleaned.hasPrefix("```") {
            let lines = cleaned.components(separatedBy: "\n")
            if lines.count >= 2 {
                let innerLines = lines.dropFirst().dropLast(lines.last?.hasPrefix("```") == true ? 1 : 0)
                cleaned = innerLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let startRange = cleaned.range(of: "```json"),
           let endRange = cleaned.range(of: "```", range: startRange.upperBound..<cleaned.endIndex) {
            cleaned = String(cleaned[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let startRange = cleaned.range(of: "```"),
                  let endRange = cleaned.range(of: "```", range: startRange.upperBound..<cleaned.endIndex) {
            cleaned = String(cleaned[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = cleaned.data(using: .utf8) else { return .malformed }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let array = jsonObject as? [[String: Any]] else {
            return .malformed
        }

        if array.isEmpty {
            return .valid([])
        }

        var results: [RawTask] = []
        for dict in array {
            guard let rawTitle = dict["title"] as? String else { continue }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            let owner: String?
            if let rawOwner = dict["owner"] as? String {
                let trimmed = rawOwner.trimmingCharacters(in: .whitespacesAndNewlines)
                owner = trimmed.isEmpty ? nil : trimmed
            } else {
                owner = nil
            }

            let due: String?
            if let rawDue = dict["due"] as? String {
                let trimmed = rawDue.trimmingCharacters(in: .whitespacesAndNewlines)
                due = (!trimmed.isEmpty && isValidDueDate(trimmed)) ? trimmed : nil
            } else {
                due = nil
            }

            let quote: String?
            if let rawQuote = dict["quote"] as? String {
                let trimmed = rawQuote.trimmingCharacters(in: .whitespacesAndNewlines)
                quote = trimmed.isEmpty ? nil : trimmed
            } else {
                quote = nil
            }

            results.append(RawTask(title: title, owner: owner, due: due, quote: quote))
            if results.count >= 8 { break }
        }

        if results.isEmpty {
            return .noUsableItems
        }

        return .valid(results)
    }

    /// Convenience method returning raw tasks or empty array.
    static func rawTasks(_ json: String?) -> [RawTask] {
        if case .valid(let tasks) = parse(json) {
            return tasks
        }
        return []
    }

    static func items(
        from raw: [RawTask],
        meetingURL: URL?,
        meetingTitle: String?,
        meetingDate: Date?,
        attendees: [Attendee],
        speakerNames: [String],
        myName: String,
        now: Date = Date()
    ) -> [TaskItem] {
        raw.map { rawTask in
            let normalizedOwner = TaskOwnerNormalizer.normalize(
                rawTask.owner,
                attendees: attendees,
                speakerNames: speakerNames,
                myName: myName
            )
            return TaskItem(
                id: UUID().uuidString,
                meetingURL: meetingURL,
                meetingTitle: meetingTitle,
                meetingDate: meetingDate,
                title: rawTask.title,
                owner: normalizedOwner,
                due: rawTask.due,
                quote: rawTask.quote,
                status: .open,
                createdAt: now,
                completedAt: nil
            )
        }
    }
}
