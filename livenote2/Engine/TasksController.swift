import Foundation
import Observation

@MainActor
@Observable
final class TasksController {
    enum Filter: String, CaseIterable {
        case open = "Open"
        case done = "Done"
        case mine = "Mine"
        case all = "All"
    }

    enum Grouping: String, CaseIterable {
        case meeting = "By meeting"
        case owner = "By owner"
    }

    let store: TaskStore
    private(set) var tasks: [TaskItem] = []
    var filter: Filter = .open
    var grouping: Grouping = .meeting
    var lastError: String?

    init(store: TaskStore = TaskStore()) {
        self.store = store
        do {
            let outcome = try store.recoverInterruptedCommit()
            if outcome != .none {
                AppLog.write("tasks", "태스크 커밋 저널 복구: \(outcome)")
            }
        } catch {
            lastError = "Task index recovery failed: \(error.localizedDescription)"
            AppLog.write("tasks", "태스크 커밋 저널 복구 실패: \(error.localizedDescription)")
        }
        refresh()
    }

    func refresh() {
        do {
            tasks = try store.all()
        } catch {
            tasks = []
            lastError = error.localizedDescription
            AppLog.write("tasks", "태스크 목록 로드 실패: \(error.localizedDescription)")
        }
    }

    func record(
        summaryOutput: SummaryOutput,
        meetingURL: URL,
        meetingTitle: String?,
        meetingDate: Date?,
        attendees: [Attendee],
        speakerNames: [String],
        myName: String
    ) {
        switch TaskExtractor.parse(summaryOutput.tasksJSON) {
        case .absent:
            AppLog.write("tasks", "tasks 블록 없음, 기존 태스크 유지 url=\(meetingURL.lastPathComponent)")
            return
        case .malformed:
            lastError = "Minutes did not include a readable tasks block; existing tasks kept."
            AppLog.write("tasks", "tasks 블록 파싱 실패, 기존 태스크 유지 url=\(meetingURL.lastPathComponent)")
            return
        case .noUsableItems:
            lastError = "Minutes tasks block had no usable items; existing tasks kept."
            AppLog.write("tasks", "tasks 블록에 유효한 태스크 없음, 기존 태스크 유지 url=\(meetingURL.lastPathComponent)")
            return
        case .valid(let rawTasks):
            let items = TaskExtractor.items(
                from: rawTasks,
                meetingURL: meetingURL,
                meetingTitle: meetingTitle,
                meetingDate: meetingDate,
                attendees: attendees,
                speakerNames: speakerNames,
                myName: myName
            )
            do {
                let (recordedItems, warnings) = try store.replaceTasks(items, for: meetingURL)
                refresh()
                if let firstWarn = warnings.first {
                    lastError = firstWarn
                    AppLog.write("tasks", "회의 태스크 경고 url=\(meetingURL.lastPathComponent): \(firstWarn)")
                }
                AppLog.write("tasks", "회의 태스크 기록 완료 count=\(recordedItems.count) url=\(meetingURL.lastPathComponent)")
            } catch TaskStoreError.recoveryPending {
                refresh()
                let errDesc = "Task index needs recovery: previous commit was interrupted"
                lastError = errDesc
                AppLog.write("tasks", "회의 태스크 기록 실패 url=\(meetingURL.lastPathComponent): \(errDesc)")
            } catch {
                refresh()
                lastError = error.localizedDescription
                AppLog.write("tasks", "회의 태스크 기록 실패 url=\(meetingURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    enum ImportResult: Equatable {
        case invalidJSON(String)
        case done(imported: Int, failed: Int, message: String)

        var message: String {
            switch self {
            case .invalidJSON(let msg): return msg
            case .done(_, _, let msg): return msg
            }
        }
    }

    @discardableResult
    func importRecipeJSON(_ text: String, usedMeetings: [MeetingSummary], myName: String) -> ImportResult {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
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

        guard let data = cleaned.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let rawArray = jsonObject as? [[String: Any]] else {
            let msg = "Recipe output was not valid JSON; nothing imported."
            lastError = msg
            AppLog.write("tasks", "레시피 출력 JSON 파싱 실패: \(msg)")
            return .invalidJSON(msg)
        }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"

        var importedTasks: [TaskItem] = []

        for dict in rawArray {
            guard let rawTitle = dict["title"] as? String else { continue }
            let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { continue }

            let rawOwner = (dict["owner"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawDue = (dict["due"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawQuote = (dict["quote"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawMeetingTitle = (dict["meetingTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawMeetingDate = (dict["meetingDate"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            let matchedMeeting = usedMeetings.first { meeting in
                guard let itemTitle = rawMeetingTitle, !itemTitle.isEmpty else {
                    return false
                }
                let titleMatches = meeting.title.caseInsensitiveCompare(itemTitle) == .orderedSame
                if !titleMatches { return false }

                if let itemDateStr = rawMeetingDate, !itemDateStr.isEmpty {
                    if let itemDate = df.date(from: itemDateStr) {
                        return Calendar.current.isDate(meeting.startedAt, inSameDayAs: itemDate)
                    }
                }
                return true
            }

            let meetingURL = matchedMeeting?.url
            let meetingTitle = matchedMeeting?.title ?? rawMeetingTitle
            let meetingDate = matchedMeeting?.startedAt ?? rawMeetingDate.flatMap { df.date(from: $0) }
            let attendees = matchedMeeting?.attendees ?? []

            let normalizedOwner = TaskOwnerNormalizer.normalize(
                rawOwner,
                attendees: attendees,
                speakerNames: [],
                myName: myName
            )

            let validDue = (rawDue != nil && TaskExtractor.isValidDueDate(rawDue!)) ? rawDue : nil

            let taskItem = TaskItem(
                id: UUID().uuidString,
                meetingURL: meetingURL,
                meetingTitle: (meetingTitle?.isEmpty == false) ? meetingTitle : nil,
                meetingDate: meetingDate,
                title: trimmedTitle,
                owner: normalizedOwner,
                due: validDue,
                quote: (rawQuote?.isEmpty == false) ? rawQuote : nil,
                status: .open,
                createdAt: Date(),
                completedAt: nil
            )
            importedTasks.append(taskItem)
        }

        guard !importedTasks.isEmpty else {
            let msg = "Imported 0 tasks."
            AppLog.write("tasks", "레시피 태스크 임포트 완료 count=0")
            return .done(imported: 0, failed: 0, message: msg)
        }

        do {
            let outcome = try store.appendImported(importedTasks)
            refresh()
            let savedCount = outcome.saved.count
            let failedCount = outcome.failures.count
            let message: String
            if failedCount > 0 {
                let firstErr = outcome.failures.first?.error
                let firstErrDesc: String
                if let commitErr = firstErr as? TaskStoreError,
                   case let .commitFailed(move, rollback) = commitErr {
                    if let rollback = rollback {
                        firstErrDesc = "\(move.localizedDescription); cleanup also failed: \(rollback.localizedDescription)"
                    } else {
                        firstErrDesc = move.localizedDescription
                    }
                } else {
                    firstErrDesc = firstErr?.localizedDescription ?? "Write error"
                }
                let prefix = savedCount == 1 ? "Imported 1 task." : "Imported \(savedCount) tasks."
                message = "\(prefix) \(failedCount) could not be saved: \(firstErrDesc)"
                lastError = "\(failedCount) could not be saved: \(firstErrDesc)"
                AppLog.write("tasks", "레시피 태스크 임포트 일부 실패 saved=\(savedCount) failed=\(failedCount): \(firstErrDesc)")
            } else {
                message = savedCount == 1 ? "Imported 1 task." : "Imported \(savedCount) tasks."
                if let firstWarn = outcome.warnings.first {
                    lastError = firstWarn
                    AppLog.write("tasks", "레시피 태스크 임포트 경고: \(firstWarn)")
                }
                AppLog.write("tasks", "레시피 태스크 임포트 완료 count=\(savedCount)")
            }
            return .done(imported: savedCount, failed: failedCount, message: message)
        } catch TaskStoreError.recoveryPending {
            let errDesc = "Task index needs recovery: previous commit was interrupted"
            lastError = errDesc
            AppLog.write("tasks", "레시피 태스크 저장 실패: \(errDesc)")
            let message = "0 tasks imported. \(importedTasks.count) could not be saved: \(errDesc)"
            return .done(imported: 0, failed: importedTasks.count, message: message)
        } catch {
            let errDesc: String
            if let commitErr = error as? TaskStoreError,
               case let .commitFailed(move, rollback) = commitErr {
                if let rollback = rollback {
                    errDesc = "\(move.localizedDescription); cleanup also failed: \(rollback.localizedDescription)"
                } else {
                    errDesc = move.localizedDescription
                }
            } else {
                errDesc = error.localizedDescription
            }
            lastError = errDesc
            AppLog.write("tasks", "레시피 태스크 저장 실패: \(errDesc)")
            let message = "0 tasks imported. \(importedTasks.count) could not be saved: \(errDesc)"
            return .done(imported: 0, failed: importedTasks.count, message: message)
        }
    }

    func toggle(_ task: TaskItem) {
        let newDone = task.status != .done
        do {
            try store.setStatus(id: task.id, done: newDone)
            refresh()
        } catch {
            lastError = error.localizedDescription
            AppLog.write("tasks", "태스크 상태 변경 실패 id=\(task.id): \(error.localizedDescription)")
        }
    }

    func addManual(title: String, owner: String?, due: String?) {
        do {
            _ = try store.addManual(title: title, owner: owner, due: due)
            refresh()
        } catch {
            lastError = error.localizedDescription
            AppLog.write("tasks", "수동 태스크 추가 실패: \(error.localizedDescription)")
        }
    }

    func delete(_ task: TaskItem) {
        do {
            try store.delete(id: task.id)
            refresh()
        } catch {
            lastError = error.localizedDescription
            AppLog.write("tasks", "태스크 삭제 실패 id=\(task.id): \(error.localizedDescription)")
        }
    }

    func visible(filter: Filter, myName: String) -> [TaskItem] {
        switch filter {
        case .open:
            return tasks.filter { $0.status == .open }
        case .done:
            return tasks.filter { $0.status == .done }
        case .mine:
            let normalizedMyName = myName.trimmingCharacters(in: .whitespacesAndNewlines)
            return tasks.filter { task in
                guard task.status == .open else { return false }
                guard let owner = task.owner else { return false }
                let normalizedOwner = TaskOwnerNormalizer.normalize(owner, attendees: [], speakerNames: [], myName: normalizedMyName)
                return normalizedOwner?.caseInsensitiveCompare(normalizedMyName) == .orderedSame
            }
        case .all:
            return tasks
        }
    }

    func openCount(forAttendeeNames names: [String]) -> Int {
        let candidateTokens = Set(names.flatMap { TaskOwnerNormalizer.tokens($0) })
        guard !candidateTokens.isEmpty else { return 0 }

        return tasks.filter { item in
            guard item.status == .open, let owner = item.owner else { return false }
            let ownerTokens = TaskOwnerNormalizer.tokens(owner)
            for token in ownerTokens {
                if candidateTokens.contains(token) {
                    return true
                }
            }
            return false
        }.count
    }

    static func grouped(_ tasks: [TaskItem], by grouping: Grouping) -> [(key: String, tasks: [TaskItem])] {
        let sortTasks: ([TaskItem]) -> [TaskItem] = { items in
            items.sorted { a, b in
                if let dueA = a.due, let dueB = b.due {
                    if dueA != dueB { return dueA < dueB }
                } else if a.due != nil {
                    return true
                } else if b.due != nil {
                    return false
                }
                return a.createdAt > b.createdAt
            }
        }

        switch grouping {
        case .meeting:
            let dict = Dictionary(grouping: tasks) { item -> String in
                if let title = item.meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    return title
                }
                return "Manual"
            }
            return dict.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
                (key: key, tasks: sortTasks(dict[key] ?? []))
            }
        case .owner:
            let dict = Dictionary(grouping: tasks) { item -> String in
                if let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
                    return owner
                }
                return "Unassigned"
            }
            return dict.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
                (key: key, tasks: sortTasks(dict[key] ?? []))
            }
        }
    }
}
