import Foundation

enum TaskStatus: String, Codable, Sendable {
    case open
    case done
}

struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    var id: String            // UUID string
    var meetingURL: URL?      // nil for manual tasks or unmatched imports
    var meetingTitle: String?
    var meetingDate: Date?
    var title: String
    var owner: String?        // normalized display name, nil if unknown
    var due: String?          // "yyyy-MM-dd" or nil
    var quote: String?
    var status: TaskStatus
    var createdAt: Date
    var completedAt: Date?
}

enum TaskStoreError: LocalizedError, Equatable {
    case cannotDeleteMeetingTask
    case taskNotFound
    case indexUnreadable(String)
    case meetingFileUnreadable(String)
    case invalidDueDate
    case commitFailed(move: any Error, rollback: (any Error)?)
    case cleanupFailed(path: String, underlying: any Error)

    static func == (lhs: TaskStoreError, rhs: TaskStoreError) -> Bool {
        switch (lhs, rhs) {
        case (.cannotDeleteMeetingTask, .cannotDeleteMeetingTask),
             (.taskNotFound, .taskNotFound),
             (.invalidDueDate, .invalidDueDate):
            return true
        case (.indexUnreadable(let a), .indexUnreadable(let b)):
            return a == b
        case (.meetingFileUnreadable(let a), .meetingFileUnreadable(let b)):
            return a == b
        case (.commitFailed(let m1, let r1), .commitFailed(let m2, let r2)):
            let mSame = (m1 as NSError) == (m2 as NSError) || m1.localizedDescription == m2.localizedDescription
            let rSame = (r1 == nil && r2 == nil) || ((r1 != nil && r2 != nil) && ((r1! as NSError) == (r2! as NSError) || r1!.localizedDescription == r2!.localizedDescription))
            return mSame && rSame
        case (.cleanupFailed(let p1, let u1), .cleanupFailed(let p2, let u2)):
            let uSame = (u1 as NSError) == (u2 as NSError) || u1.localizedDescription == u2.localizedDescription
            return p1 == p2 && uSame
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .cannotDeleteMeetingTask:
            return "Meeting tasks cannot be deleted individually. They are updated when minutes are regenerated."
        case .taskNotFound:
            return "Task not found."
        case .indexUnreadable(let detail):
            return "Tasks index is unreadable: \(detail)"
        case .meetingFileUnreadable(let detail):
            return "Meeting tasks file is unreadable: \(detail)"
        case .invalidDueDate:
            return "Due must be yyyy-MM-dd"
        case .commitFailed(let move, let rollback):
            if let rollback = rollback {
                return "Failed to commit tasks (\(move.localizedDescription)) and rollback also failed (\(rollback.localizedDescription))."
            } else {
                return "Failed to commit tasks: \(move.localizedDescription)"
            }
        case .cleanupFailed(let path, let underlying):
            return "Failed to clean up file at \(path): \(underlying.localizedDescription)"
        }
    }
}

struct ImportOutcome: Sendable {
    var saved: [TaskItem]
    var failures: [(meetingURL: URL?, error: any Error)]
    var warnings: [String]

    init(
        saved: [TaskItem],
        failures: [(meetingURL: URL?, error: any Error)],
        warnings: [String] = []
    ) {
        self.saved = saved
        self.failures = failures
        self.warnings = warnings
    }
}

struct TaskStore: Sendable {
    let rootURL: URL
    let indexWriter: (@Sendable (Data, URL) throws -> Void)?
    let fileRemover: (@Sendable (URL) throws -> Void)?

    init(
        rootURL: URL,
        indexWriter: (@Sendable (Data, URL) throws -> Void)? = nil,
        fileRemover: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.indexWriter = indexWriter
        self.fileRemover = fileRemover
    }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        self.init(rootURL: documents.appendingPathComponent("LiveNote", isDirectory: true), indexWriter: nil, fileRemover: nil)
    }

    private func removeFile(at url: URL) throws {
        if let fileRemover = fileRemover {
            try fileRemover(url)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }

    private var tasksDirectoryURL: URL {
        rootURL.appendingPathComponent("tasks", isDirectory: true)
    }

    private var indexURL: URL {
        tasksDirectoryURL.appendingPathComponent("index.json")
    }

    /// Reads <meeting>/tasks.json.
    /// Returns [] if file does not exist.
    /// On read or decode error, copies file to tasks.json.corrupt-<timestamp> and throws TaskStoreError.meetingFileUnreadable.
    func loadMeetingTasks(at meetingURL: URL) throws -> [TaskItem] {
        let meetingTasksFile = meetingURL.appendingPathComponent("tasks.json")
        guard FileManager.default.fileExists(atPath: meetingTasksFile.path) else {
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: meetingTasksFile)
        } catch {
            let timestamp = Int(Date().timeIntervalSince1970)
            let corruptURL = meetingURL.appendingPathComponent("tasks.json.corrupt-\(timestamp)")
            do {
                try FileManager.default.copyItem(at: meetingTasksFile, to: corruptURL)
            } catch let copyErr {
                AppLog.write("tasks", "손상 회의 태스크 백업 복사 실패: \(copyErr.localizedDescription)")
            }
            throw TaskStoreError.meetingFileUnreadable(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([TaskItem].self, from: data)
        } catch {
            let timestamp = Int(Date().timeIntervalSince1970)
            let corruptURL = meetingURL.appendingPathComponent("tasks.json.corrupt-\(timestamp)")
            do {
                try FileManager.default.copyItem(at: meetingTasksFile, to: corruptURL)
            } catch let copyErr {
                AppLog.write("tasks", "손상 회의 태스크 백업 복사 실패: \(copyErr.localizedDescription)")
            }
            throw TaskStoreError.meetingFileUnreadable(error.localizedDescription)
        }
    }

    /// Loads the index: returns [] if file does not exist.
    /// On read/decode error, copies the corrupt file to index.json.corrupt-<timestamp> and throws.
    func loadIndex() throws -> [TaskItem] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch {
            throw TaskStoreError.indexUnreadable(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([TaskItem].self, from: data)
        } catch {
            let timestamp = Int(Date().timeIntervalSince1970)
            let corruptURL = tasksDirectoryURL.appendingPathComponent("index.json.corrupt-\(timestamp)")
            do {
                try FileManager.default.copyItem(at: indexURL, to: corruptURL)
            } catch let copyErr {
                AppLog.write("tasks", "손상 인덱스 백업 복사 실패: \(copyErr.localizedDescription)")
            }
            throw TaskStoreError.indexUnreadable(error.localizedDescription)
        }
    }

    private func saveIndex(_ items: [TaskItem]) throws {
        try FileManager.default.createDirectory(at: tasksDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(items)
        if let indexWriter = indexWriter {
            try indexWriter(data, indexURL)
        } else {
            try data.write(to: indexURL, options: .atomic)
        }
    }

    func all() throws -> [TaskItem] {
        try loadIndex().sorted { $0.createdAt > $1.createdAt }
    }

    func openTasks() throws -> [TaskItem] {
        try all().filter { $0.status == .open }
    }

    func tasks(for meetingURL: URL) throws -> [TaskItem] {
        let standardMeetingPath = meetingURL.standardizedFileURL.path
        return try all().filter { item in
            item.meetingURL?.standardizedFileURL.path == standardMeetingPath
        }
    }

    func openTasks(matchingNames names: [String]) throws -> [TaskItem] {
        let candidateTokens = Set(names.flatMap { TaskOwnerNormalizer.tokens($0) })
        guard !candidateTokens.isEmpty else { return [] }

        return try openTasks().filter { item in
            guard let owner = item.owner else { return false }
            let ownerTokens = TaskOwnerNormalizer.tokens(owner)
            for token in ownerTokens {
                if candidateTokens.contains(token) {
                    return true
                }
            }
            return false
        }
    }

    /// Replaces meeting tasks upon summary regeneration.
    /// Commit order (T1):
    /// 1. Encode both payloads first (any encoding error throws before touching disk).
    /// 2. Write the meeting file to tasks.json.tmp; if old tasks.json exists, copy it to tasks.json.prev.
    /// 3. Move tasks.json.tmp -> tasks.json (replaceItemAt).
    /// 4. Save the index LAST (atomic write). If it fails: restore tasks.json from tasks.json.prev (or delete if none); throw TaskStoreError.commitFailed(move: indexError, rollback: restoreError?).
    /// 5. On success delete tasks.json.prev. Post-commit cleanup failures surface as warnings.
    /// Preserves existing IDs, creation dates, and done status for matching items in the index using queue matching.
    /// Meeting file gets status = .open, completedAt = nil as the extraction original.
    @discardableResult
    func replaceTasks(_ items: [TaskItem], for meetingURL: URL) throws -> (items: [TaskItem], warnings: [String]) {
        // Validate that existing meeting file is readable/not corrupt
        _ = try loadMeetingTasks(at: meetingURL)

        let previousIndex = try loadIndex()
        let standardMeetingPath = meetingURL.standardizedFileURL.path

        // Find existing tasks for this meeting
        let existingMeetingTasks = previousIndex.filter {
            $0.meetingURL?.standardizedFileURL.path == standardMeetingPath
        }

        // T8: Queue-based matching for existing tasks by normalized title so an ID is reused at most once
        var existingQueueByTitle: [String: [TaskItem]] = [:]
        for task in existingMeetingTasks {
            let key = task.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            existingQueueByTitle[key, default: []].append(task)
        }

        // Process incoming items
        var mergedIndexItems: [TaskItem] = []
        var meetingFileItems: [TaskItem] = []
        for newItem in items {
            let key = newItem.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var indexItem = newItem
            var meetingItem = newItem

            if var queue = existingQueueByTitle[key], !queue.isEmpty {
                let existing = queue.removeFirst()
                existingQueueByTitle[key] = queue
                indexItem.id = existing.id
                indexItem.createdAt = existing.createdAt
                if existing.status == .done {
                    indexItem.status = .done
                    indexItem.completedAt = existing.completedAt
                }

                meetingItem.id = existing.id
                meetingItem.createdAt = existing.createdAt
                meetingItem.status = .open
                meetingItem.completedAt = nil
            } else {
                meetingItem.status = .open
                meetingItem.completedAt = nil
            }
            mergedIndexItems.append(indexItem)
            meetingFileItems.append(meetingItem)
        }

        var newIndex = previousIndex
        newIndex.removeAll {
            $0.meetingURL?.standardizedFileURL.path == standardMeetingPath
        }
        newIndex.append(contentsOf: mergedIndexItems)

        // 1. Encode both payloads first (any encoding error throws before touching disk)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let meetingData = try encoder.encode(meetingFileItems)
        _ = try encoder.encode(newIndex)

        // 2. Pre-commit cleanup: remove stale .tmp / .prev
        try FileManager.default.createDirectory(at: meetingURL, withIntermediateDirectories: true)
        let meetingTasksFile = meetingURL.appendingPathComponent("tasks.json")
        let meetingTasksTmp = meetingURL.appendingPathComponent("tasks.json.tmp")
        let meetingTasksPrev = meetingURL.appendingPathComponent("tasks.json.prev")

        if FileManager.default.fileExists(atPath: meetingTasksTmp.path) {
            do {
                try removeFile(at: meetingTasksTmp)
            } catch {
                AppLog.write("tasks", "Pre-commit tmp cleanup failed path=\(meetingTasksTmp.path): \(error.localizedDescription)")
                throw TaskStoreError.cleanupFailed(path: meetingTasksTmp.path, underlying: error)
            }
        }
        if FileManager.default.fileExists(atPath: meetingTasksPrev.path) {
            do {
                try removeFile(at: meetingTasksPrev)
            } catch {
                AppLog.write("tasks", "Pre-commit prev cleanup failed path=\(meetingTasksPrev.path): \(error.localizedDescription)")
                throw TaskStoreError.cleanupFailed(path: meetingTasksPrev.path, underlying: error)
            }
        }

        try meetingData.write(to: meetingTasksTmp, options: .atomic)

        let hadPreviousMeetingFile = FileManager.default.fileExists(atPath: meetingTasksFile.path)
        if hadPreviousMeetingFile {
            try FileManager.default.copyItem(at: meetingTasksFile, to: meetingTasksPrev)
        }

        // 3. Move tasks.json.tmp -> tasks.json (replaceItemAt)
        do {
            if hadPreviousMeetingFile {
                _ = try FileManager.default.replaceItemAt(meetingTasksFile, withItemAt: meetingTasksTmp)
            } else {
                try FileManager.default.moveItem(at: meetingTasksTmp, to: meetingTasksFile)
            }
        } catch let moveError {
            var moveRollbackErr: (any Error)? = nil
            if FileManager.default.fileExists(atPath: meetingTasksTmp.path) {
                do {
                    try removeFile(at: meetingTasksTmp)
                } catch {
                    moveRollbackErr = error
                    AppLog.write("tasks", "이동 실패 후 tmp 정리 실패: \(error.localizedDescription)")
                }
            }
            if FileManager.default.fileExists(atPath: meetingTasksPrev.path) {
                do {
                    try removeFile(at: meetingTasksPrev)
                } catch {
                    if moveRollbackErr == nil { moveRollbackErr = error }
                    AppLog.write("tasks", "이동 실패 후 prev 정리 실패: \(error.localizedDescription)")
                }
            }
            AppLog.write("tasks", "회의 폴더 tasks.json 이동 실패 url=\(meetingURL.lastPathComponent): \(moveError.localizedDescription)")
            if let moveRollbackErr = moveRollbackErr {
                throw TaskStoreError.commitFailed(move: moveError, rollback: moveRollbackErr)
            }
            throw moveError
        }

        // 4. Save the index LAST (atomic write). If it fails: restore tasks.json from tasks.json.prev (or delete if none)
        do {
            try saveIndex(newIndex)
        } catch let indexError {
            var restoreError: (any Error)? = nil
            if hadPreviousMeetingFile {
                do {
                    if FileManager.default.fileExists(atPath: meetingTasksFile.path) {
                        _ = try FileManager.default.replaceItemAt(meetingTasksFile, withItemAt: meetingTasksPrev)
                    } else {
                        try FileManager.default.moveItem(at: meetingTasksPrev, to: meetingTasksFile)
                    }
                } catch let rErr {
                    restoreError = rErr
                    AppLog.write("tasks", "회의 tasks.json 롤백 복원 실패 url=\(meetingURL.lastPathComponent): \(rErr.localizedDescription)")
                }
            } else {
                do {
                    if FileManager.default.fileExists(atPath: meetingTasksFile.path) {
                        try removeFile(at: meetingTasksFile)
                    }
                } catch let rErr {
                    restoreError = rErr
                    AppLog.write("tasks", "신규 회의 tasks.json 정리 실패 url=\(meetingURL.lastPathComponent): \(rErr.localizedDescription)")
                }
            }

            if FileManager.default.fileExists(atPath: meetingTasksPrev.path) {
                do {
                    try removeFile(at: meetingTasksPrev)
                } catch let prevCleanupErr {
                    if restoreError == nil { restoreError = prevCleanupErr }
                    AppLog.write("tasks", "롤백 후 prev 정리 실패 url=\(meetingURL.lastPathComponent): \(prevCleanupErr.localizedDescription)")
                }
            }

            AppLog.write("tasks", "인덱스 저장 실패 및 회의 파일 롤백 url=\(meetingURL.lastPathComponent): \(indexError.localizedDescription)")
            throw TaskStoreError.commitFailed(move: indexError, rollback: restoreError)
        }

        // 5. Post-commit cleanup: delete tasks.json.prev. Failures surface as warnings.
        var warnings: [String] = []
        if FileManager.default.fileExists(atPath: meetingTasksPrev.path) {
            do {
                try removeFile(at: meetingTasksPrev)
            } catch let cleanupErr {
                let warn = "Failed to remove backup file at \(meetingTasksPrev.path): \(cleanupErr.localizedDescription)"
                AppLog.write("tasks", warn)
                warnings.append(warn)
            }
        }

        return (items: mergedIndexItems, warnings: warnings)
    }

    /// Upserts imported tasks into index by (meetingURL, normalized title).
    /// Items whose meeting-file write fails are NOT added to index or saved items.
    /// Existing items keep ID/status/createdAt; new ones are appended.
    /// Also appends to <meeting>/tasks.json when meetingURL is non-nil with status = .open, completedAt = nil.
    /// Returns ImportOutcome with saved items, per-meeting write failures, and warnings.
    @discardableResult
    func appendImported(_ items: [TaskItem]) throws -> ImportOutcome {
        let previousIndex = try loadIndex()

        // Check each meeting file for corruption before mutating anything
        let distinctMeetingURLs = Set(items.compactMap(\.meetingURL))
        var existingTasksByMeeting: [URL: [TaskItem]] = [:]
        for mURL in distinctMeetingURLs {
            existingTasksByMeeting[mURL] = try loadMeetingTasks(at: mURL)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let urlLessItems = items.filter { $0.meetingURL == nil }
        let itemsByMeeting = Dictionary(grouping: items.filter { $0.meetingURL != nil }) { $0.meetingURL! }

        // 1. Prepare meeting file payloads and perform pre-commit cleanups
        var meetingDataByUrl: [URL: (data: Data, tasks: [TaskItem])] = [:]
        for (meetingURL, meetingItems) in itemsByMeeting {
            let meetingTasksTmp = meetingURL.appendingPathComponent("tasks.json.tmp")
            let meetingTasksPrev = meetingURL.appendingPathComponent("tasks.json.prev")

            if FileManager.default.fileExists(atPath: meetingTasksTmp.path) {
                do {
                    try removeFile(at: meetingTasksTmp)
                } catch {
                    AppLog.write("tasks", "Pre-commit tmp cleanup failed path=\(meetingTasksTmp.path): \(error.localizedDescription)")
                    throw TaskStoreError.cleanupFailed(path: meetingTasksTmp.path, underlying: error)
                }
            }
            if FileManager.default.fileExists(atPath: meetingTasksPrev.path) {
                do {
                    try removeFile(at: meetingTasksPrev)
                } catch {
                    AppLog.write("tasks", "Pre-commit prev cleanup failed path=\(meetingTasksPrev.path): \(error.localizedDescription)")
                    throw TaskStoreError.cleanupFailed(path: meetingTasksPrev.path, underlying: error)
                }
            }

            let existingMeetingTasks = existingTasksByMeeting[meetingURL] ?? []
            var meetingQueues: [String: [TaskItem]] = [:]
            for t in existingMeetingTasks {
                let key = t.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                meetingQueues[key, default: []].append(t)
            }

            var mergedMeetingTasks = existingMeetingTasks
            for item in meetingItems {
                let key = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                var meetingItem = item
                // Status is index-only: meeting file items always have status = .open, completedAt = nil
                meetingItem.status = .open
                meetingItem.completedAt = nil

                if var queue = meetingQueues[key], !queue.isEmpty {
                    let existing = queue.removeFirst()
                    meetingQueues[key] = queue
                    meetingItem.id = existing.id
                    meetingItem.createdAt = existing.createdAt
                    if let idx = mergedMeetingTasks.firstIndex(where: { $0.id == existing.id }) {
                        mergedMeetingTasks[idx] = meetingItem
                    }
                } else {
                    mergedMeetingTasks.append(meetingItem)
                }
            }

            let data = try encoder.encode(mergedMeetingTasks)
            meetingDataByUrl[meetingURL] = (data, mergedMeetingTasks)
        }

        // 2 & 3. Write meeting files to .tmp, copy old to .prev, move .tmp -> tasks.json
        var failures: [(meetingURL: URL?, error: any Error)] = []
        var committedMeetings: [(url: URL, hadPrev: Bool, items: [TaskItem])] = []

        for (meetingURL, entry) in meetingDataByUrl {
            let meetingTasksFile = meetingURL.appendingPathComponent("tasks.json")
            let meetingTasksTmp = meetingURL.appendingPathComponent("tasks.json.tmp")
            let meetingTasksPrev = meetingURL.appendingPathComponent("tasks.json.prev")

            do {
                try FileManager.default.createDirectory(at: meetingURL, withIntermediateDirectories: true)
                try entry.data.write(to: meetingTasksTmp, options: .atomic)

                let hadPrev = FileManager.default.fileExists(atPath: meetingTasksFile.path)
                if hadPrev {
                    try FileManager.default.copyItem(at: meetingTasksFile, to: meetingTasksPrev)
                }

                if hadPrev {
                    _ = try FileManager.default.replaceItemAt(meetingTasksFile, withItemAt: meetingTasksTmp)
                } else {
                    try FileManager.default.moveItem(at: meetingTasksTmp, to: meetingTasksFile)
                }

                let originalItems = itemsByMeeting[meetingURL] ?? []
                committedMeetings.append((url: meetingURL, hadPrev: hadPrev, items: originalItems))
            } catch let writeError {
                var rollbackCleanupError: (any Error)? = nil
                if FileManager.default.fileExists(atPath: meetingTasksTmp.path) {
                    do {
                        try removeFile(at: meetingTasksTmp)
                    } catch let tmpErr {
                        if rollbackCleanupError == nil { rollbackCleanupError = tmpErr }
                        AppLog.write("tasks", "회의 실패 후 tmp 정리 실패: \(tmpErr.localizedDescription)")
                    }
                }
                if FileManager.default.fileExists(atPath: meetingTasksPrev.path) {
                    do {
                        try removeFile(at: meetingTasksPrev)
                    } catch let prevErr {
                        if rollbackCleanupError == nil { rollbackCleanupError = prevErr }
                        AppLog.write("tasks", "회의 실패 후 prev 정리 실패: \(prevErr.localizedDescription)")
                    }
                }
                AppLog.write("tasks", "회의 폴더 tasks.json 추가 실패 url=\(meetingURL.lastPathComponent): \(writeError.localizedDescription)")
                let reportedError: any Error
                if let cleanupErr = rollbackCleanupError {
                    reportedError = TaskStoreError.commitFailed(move: writeError, rollback: cleanupErr)
                } else {
                    reportedError = writeError
                }
                failures.append((meetingURL: meetingURL, error: reportedError))
            }
        }

        // Build newIndex only from items that committed to meeting files, plus url-less items
        var newIndex = previousIndex
        var existingQueues: [String: [TaskItem]] = [:]
        for item in previousIndex {
            let mPath = item.meetingURL?.standardizedFileURL.path ?? ""
            let key = "\(mPath)|\(item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            existingQueues[key, default: []].append(item)
        }

        let itemsToPersist = urlLessItems + committedMeetings.flatMap(\.items)
        var savedItems: [TaskItem] = []

        for var incoming in itemsToPersist {
            let mPath = incoming.meetingURL?.standardizedFileURL.path ?? ""
            let key = "\(mPath)|\(incoming.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"

            if var queue = existingQueues[key], !queue.isEmpty {
                let existing = queue.removeFirst()
                existingQueues[key] = queue
                incoming.id = existing.id
                incoming.createdAt = existing.createdAt
                if existing.status == .done {
                    incoming.status = .done
                    incoming.completedAt = existing.completedAt
                }
                if let idx = newIndex.firstIndex(where: { $0.id == existing.id }) {
                    newIndex[idx] = incoming
                }
            } else {
                newIndex.append(incoming)
            }
            savedItems.append(incoming)
        }

        // 4. Save the index LAST (authoritative). If it fails: restore all committed meeting files
        do {
            try saveIndex(newIndex)
        } catch let indexError {
            var firstRestoreError: (any Error)? = nil
            for (meetingURL, hadPrev, _) in committedMeetings {
                let meetingTasksFile = meetingURL.appendingPathComponent("tasks.json")
                let meetingTasksPrev = meetingURL.appendingPathComponent("tasks.json.prev")

                if hadPrev {
                    do {
                        if FileManager.default.fileExists(atPath: meetingTasksFile.path) {
                            _ = try FileManager.default.replaceItemAt(meetingTasksFile, withItemAt: meetingTasksPrev)
                        } else {
                            try FileManager.default.moveItem(at: meetingTasksPrev, to: meetingTasksFile)
                        }
                    } catch let rErr {
                        if firstRestoreError == nil { firstRestoreError = rErr }
                        AppLog.write("tasks", "회의 tasks.json 롤백 복원 실패 url=\(meetingURL.lastPathComponent): \(rErr.localizedDescription)")
                    }
                } else {
                    do {
                        if FileManager.default.fileExists(atPath: meetingTasksFile.path) {
                            try removeFile(at: meetingTasksFile)
                        }
                    } catch let rErr {
                        if firstRestoreError == nil { firstRestoreError = rErr }
                        AppLog.write("tasks", "신규 회의 tasks.json 정리 실패 url=\(meetingURL.lastPathComponent): \(rErr.localizedDescription)")
                    }
                }

                if FileManager.default.fileExists(atPath: meetingTasksPrev.path) {
                    do {
                        try removeFile(at: meetingTasksPrev)
                    } catch let rErr {
                        if firstRestoreError == nil { firstRestoreError = rErr }
                        AppLog.write("tasks", "롤백 후 prev 정리 실패: \(rErr.localizedDescription)")
                    }
                }
            }

            AppLog.write("tasks", "인덱스 저장 실패 및 회의 파일들 롤백: \(indexError.localizedDescription)")
            throw TaskStoreError.commitFailed(move: indexError, rollback: firstRestoreError)
        }

        // 5. Post-commit cleanup: delete tasks.json.prev for all committed meetings. Post-commit failures -> warnings
        var warnings: [String] = []
        for (meetingURL, _, _) in committedMeetings {
            let meetingTasksPrev = meetingURL.appendingPathComponent("tasks.json.prev")
            if FileManager.default.fileExists(atPath: meetingTasksPrev.path) {
                do {
                    try removeFile(at: meetingTasksPrev)
                } catch let cleanupErr {
                    let warn = "Failed to remove backup file at \(meetingTasksPrev.path): \(cleanupErr.localizedDescription)"
                    AppLog.write("tasks", warn)
                    warnings.append(warn)
                }
            }
        }

        return ImportOutcome(saved: savedItems, failures: failures, warnings: warnings)
    }

    func addManual(title: String, owner: String?, due: String?) throws -> TaskItem {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOwner = owner?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDue = due?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmedDue = trimmedDue, !trimmedDue.isEmpty {
            guard TaskExtractor.isValidDueDate(trimmedDue) else {
                throw TaskStoreError.invalidDueDate
            }
        }

        let item = TaskItem(
            id: UUID().uuidString,
            meetingURL: nil,
            meetingTitle: nil,
            meetingDate: nil,
            title: trimmedTitle,
            owner: (trimmedOwner?.isEmpty == false) ? trimmedOwner : nil,
            due: (trimmedDue?.isEmpty == false) ? trimmedDue : nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        var index = try loadIndex()
        index.append(item)
        try saveIndex(index)
        return item
    }

    func setStatus(id: String, done: Bool) throws {
        var index = try loadIndex()
        guard let indexPos = index.firstIndex(where: { $0.id == id }) else {
            throw TaskStoreError.taskNotFound
        }
        var item = index[indexPos]
        item.status = done ? .done : .open
        item.completedAt = done ? (item.completedAt ?? Date()) : nil
        index[indexPos] = item
        try saveIndex(index)
    }

    func delete(id: String) throws {
        var index = try loadIndex()
        guard let indexPos = index.firstIndex(where: { $0.id == id }) else {
            throw TaskStoreError.taskNotFound
        }
        let item = index[indexPos]
        if item.meetingURL != nil {
            throw TaskStoreError.cannotDeleteMeetingTask
        }
        index.remove(at: indexPos)
        try saveIndex(index)
    }
}

enum TaskOwnerNormalizer {
    /// "me"/"I"/"나"/"myself" (case-insensitive, trimmed) -> myName. Otherwise token match: raw's lowercase tokens vs each candidate name's tokens (split on space/dot/@; email local-part split on . and _), first candidate whose full name equals raw OR shares a token of length >= 3 wins (attendees first, then speakerNames, then myName). No match -> raw trimmed (nil if empty).
    static func normalize(_ raw: String?, attendees: [Attendee], speakerNames: [String], myName: String) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()
        if lower == "me" || lower == "i" || lower == "나" || lower == "myself" {
            let trimmedMy = myName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedMy.isEmpty ? raw : trimmedMy
        }

        let rawTokens = tokens(raw)

        // 1. Attendees (names, email local-parts)
        for attendee in attendees {
            let candidateName = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidateName.isEmpty {
                if candidateName.caseInsensitiveCompare(raw) == .orderedSame {
                    return candidateName
                }
                var candidateTokens = tokens(candidateName)
                if let email = attendee.email {
                    candidateTokens.append(contentsOf: tokens(email))
                }
                if sharesSignificantToken(rawTokens, candidateTokens) {
                    return candidateName
                }
            }
        }

        // 2. SpeakerNames
        for speaker in speakerNames {
            let candidate = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                if candidate.caseInsensitiveCompare(raw) == .orderedSame {
                    return candidate
                }
                let candidateTokens = tokens(candidate)
                if sharesSignificantToken(rawTokens, candidateTokens) {
                    return candidate
                }
            }
        }

        // 3. myName
        let trimmedMyName = myName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMyName.isEmpty {
            if trimmedMyName.caseInsensitiveCompare(raw) == .orderedSame {
                return trimmedMyName
            }
            let myTokens = tokens(trimmedMyName)
            if sharesSignificantToken(rawTokens, myTokens) {
                return trimmedMyName
            }
        }

        return raw
    }

    private static func sharesSignificantToken(_ a: [String], _ b: [String]) -> Bool {
        let bSet = Set(b)
        for token in a {
            if token.count >= 3 && bSet.contains(token) {
                return true
            }
        }
        return false
    }

    static func tokens(_ name: String) -> [String] {
        let separators = CharacterSet(charactersIn: " .@_-/,;:\t\n\r")
        return name.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}
