import Foundation
import CryptoKit

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

struct TaskCommitJournal: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let meetingPath: String
        let hadPrevious: Bool
    }
    let version: Int
    let token: String
    let previousIndexDigest: String
    let indexDigest: String
    let entries: [Entry]
}

enum RecoveryOutcome: Equatable, Sendable {
    case none
    case rolledForward(meetings: Int)
    case rolledBack(meetings: Int)
    case journalCorrupt(movedTo: URL)
}

enum TaskStoreError: LocalizedError, Equatable {
    case cannotDeleteMeetingTask
    case taskNotFound
    case indexUnreadable(String)
    case meetingFileUnreadable(String)
    case invalidDueDate
    case commitFailed(move: any Error, rollback: (any Error)?)
    case cleanupFailed(path: String, underlying: any Error)
    case recoveryPending

    static func == (lhs: TaskStoreError, rhs: TaskStoreError) -> Bool {
        switch (lhs, rhs) {
        case (.cannotDeleteMeetingTask, .cannotDeleteMeetingTask),
             (.taskNotFound, .taskNotFound),
             (.invalidDueDate, .invalidDueDate),
             (.recoveryPending, .recoveryPending):
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
        case .recoveryPending:
            return "Task index needs recovery: previous commit was interrupted"
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

/// All TaskStore mutations must run on the main actor.
struct TaskStore: Sendable {
    let rootURL: URL
    let indexWriter: (@Sendable (Data, URL) throws -> Void)?
    let fileRemover: (@Sendable (URL) throws -> Void)?
    var beforeMeetingReplaceForTesting: (@Sendable (URL) throws -> Void)? = nil

    init(
        rootURL: URL,
        indexWriter: (@Sendable (Data, URL) throws -> Void)? = nil,
        fileRemover: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.indexWriter = indexWriter
        self.fileRemover = fileRemover
        self.beforeMeetingReplaceForTesting = nil
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

    private var journalURL: URL {
        tasksDirectoryURL.appendingPathComponent("commit-journal.json")
    }

    enum FileState {
        case present
        case missing
    }

    private func fileState(at url: URL) throws -> FileState {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return .present
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .missing
        } catch {
            let nsError = error as NSError
            if (nsError.domain == NSCocoaErrorDomain && (nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError)) ||
               (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)) {
                return .missing
            }
            AppLog.write("tasks", "파일 상태 확인 실패 path=\(url.path): \(error.localizedDescription)")
            throw error
        }
    }

    private func readIndexBytesForDecision() throws -> Data? {
        do {
            return try Data(contentsOf: indexURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            let nsError = error as NSError
            if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError) ||
               (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)) {
                return nil
            }
            AppLog.write("tasks", "인덱스 바이트 읽기 실패: \(error.localizedDescription)")
            throw error
        }
    }

    private static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidHex64(_ s: String) -> Bool {
        guard s.utf8.count == 64 else { return false }
        return s.allSatisfy { $0.isHexDigit }
    }

    func encodeIndex(_ items: [TaskItem]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(items)
    }

    func writeIndex(_ data: Data) throws {
        switch try fileState(at: journalURL) {
        case .present:
            throw TaskStoreError.recoveryPending
        case .missing:
            break
        }
        try writeIndexUnchecked(data)
    }

    private func writeIndexUnchecked(_ data: Data) throws {
        try FileManager.default.createDirectory(at: tasksDirectoryURL, withIntermediateDirectories: true)
        if let indexWriter = indexWriter {
            try indexWriter(data, indexURL)
        } else {
            try data.write(to: indexURL, options: .atomic)
        }
    }

    private func saveIndex(_ items: [TaskItem]) throws {
        switch try fileState(at: journalURL) {
        case .present:
            throw TaskStoreError.recoveryPending
        case .missing:
            break
        }
        let data = try encodeIndex(items)
        try writeIndexUnchecked(data)
    }

    /// Reads <meeting>/tasks.json.
    /// Returns [] if file does not exist.
    /// On read or decode error, copies file to tasks.json.corrupt-<timestamp> and throws TaskStoreError.meetingFileUnreadable.
    func loadMeetingTasks(at meetingURL: URL) throws -> [TaskItem] {
        let meetingTasksFile = meetingURL.appendingPathComponent("tasks.json")
        switch try fileState(at: meetingTasksFile) {
        case .missing:
            return []
        case .present:
            break
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
        switch try fileState(at: indexURL) {
        case .missing:
            return []
        case .present:
            break
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

    /// Recovers an interrupted commit by inspecting commit-journal.json.
    func recoverInterruptedCommit() throws -> RecoveryOutcome {
        let journalData: Data
        do {
            journalData = try Data(contentsOf: journalURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .none
        } catch {
            let nsError = error as NSError
            if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError) ||
               (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)) {
                return .none
            }
            AppLog.write("tasks", "커밋 저널 읽기 실패: \(error.localizedDescription)")
            throw error
        }

        func markCorrupt() throws -> RecoveryOutcome {
            let timestamp = Int(Date().timeIntervalSince1970)
            var corruptURL = tasksDirectoryURL.appendingPathComponent("commit-journal.json.corrupt-\(timestamp)")
            if (try? fileState(at: corruptURL)) == .present {
                var counter = 1
                while (try? fileState(at: tasksDirectoryURL.appendingPathComponent("commit-journal.json.corrupt-\(timestamp)-\(counter)"))) == .present {
                    counter += 1
                }
                corruptURL = tasksDirectoryURL.appendingPathComponent("commit-journal.json.corrupt-\(timestamp)-\(counter)")
            }
            do {
                try FileManager.default.moveItem(at: journalURL, to: corruptURL)
            } catch {
                AppLog.write("tasks", "손상 커밋 저널 이동 실패: \(error.localizedDescription)")
                throw error
            }
            AppLog.write("tasks", "손상된 커밋 저널 이동: \(corruptURL.lastPathComponent)")
            return .journalCorrupt(movedTo: corruptURL)
        }

        let decoder = JSONDecoder()
        let journal: TaskCommitJournal
        do {
            journal = try decoder.decode(TaskCommitJournal.self, from: journalData)
        } catch {
            return try markCorrupt()
        }

        guard journal.version == 1 else {
            return try markCorrupt()
        }

        guard UUID(uuidString: journal.token) != nil else {
            return try markCorrupt()
        }

        guard Self.isValidHex64(journal.indexDigest) else {
            return try markCorrupt()
        }

        if !journal.previousIndexDigest.isEmpty {
            guard Self.isValidHex64(journal.previousIndexDigest) else {
                return try markCorrupt()
            }
        }

        let rootStandard = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = rootStandard.hasSuffix("/") ? rootStandard : rootStandard + "/"

        var canonicalURLs: [URL] = []
        var canonicalPaths: [String] = []

        for entry in journal.entries {
            let rawPath = entry.meetingPath

            let attrs: [FileAttributeKey: Any]
            do {
                attrs = try FileManager.default.attributesOfItem(atPath: rawPath)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return try markCorrupt()
            } catch {
                let nsError = error as NSError
                if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError) ||
                   (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)) {
                    return try markCorrupt()
                }
                AppLog.write("tasks", "회의 폴더 속성 확인 실패 path=\(rawPath): \(error.localizedDescription)")
                throw error
            }

            let fileType = attrs[.type] as? FileAttributeType
            if fileType == .typeSymbolicLink {
                return try markCorrupt()
            }

            guard fileType == .typeDirectory else {
                return try markCorrupt()
            }

            let rawURL = URL(fileURLWithPath: rawPath)
            let canonicalURL = rawURL.resolvingSymlinksInPath().standardizedFileURL
            let canonicalPath = canonicalURL.path

            // Require that the stored string equals its own canonical form
            guard rawPath == canonicalPath else {
                return try markCorrupt()
            }

            guard canonicalPath.hasPrefix(rootPrefix), canonicalPath != rootStandard else {
                return try markCorrupt()
            }

            canonicalURLs.append(canonicalURL)
            canonicalPaths.append(canonicalPath)
        }

        // Check duplicates on canonical paths
        guard Set(canonicalPaths).count == canonicalPaths.count else {
            return try markCorrupt()
        }

        let currentIndexData = (try readIndexBytesForDecision()) ?? Data()
        let currentDigest = currentIndexData.isEmpty ? "" : Self.sha256Hex(of: currentIndexData)

        if currentDigest == journal.indexDigest && journal.indexDigest != journal.previousIndexDigest {
            // Roll forward
            for mURL in canonicalURLs {
                let prevFile = mURL.appendingPathComponent("tasks.json.prev")
                let prevTmpFile = mURL.appendingPathComponent("tasks.json.prev.tmp")
                let tmpFile = mURL.appendingPathComponent("tasks.json.tmp")
                let restoreTmp = mURL.appendingPathComponent("tasks.json.restore.tmp")

                for target in [prevFile, prevTmpFile, tmpFile, restoreTmp] {
                    if try fileState(at: target) == .present {
                        do {
                            try removeFile(at: target)
                        } catch {
                            AppLog.write("tasks", "롤포워드 중 파일 정리 실패: \(error.localizedDescription)")
                            throw error
                        }
                    }
                }
            }

            do {
                try removeFile(at: journalURL)
            } catch {
                AppLog.write("tasks", "롤포워드 중 저널 삭제 실패: \(error.localizedDescription)")
                throw error
            }

            AppLog.write("tasks", "커밋 저널 롤포워드 완료 count=\(journal.entries.count)")
            return .rolledForward(meetings: journal.entries.count)
        } else {
            // Roll back (including indexDigest == previousIndexDigest)
            for (entry, mURL) in zip(journal.entries, canonicalURLs) {
                let meetingFile = mURL.appendingPathComponent("tasks.json")
                let prevFile = mURL.appendingPathComponent("tasks.json.prev")
                let prevTmpFile = mURL.appendingPathComponent("tasks.json.prev.tmp")
                let tmpFile = mURL.appendingPathComponent("tasks.json.tmp")
                let restoreTmp = mURL.appendingPathComponent("tasks.json.restore.tmp")

                let prevState = try fileState(at: prevFile)
                let meetingFileState = try fileState(at: meetingFile)

                if entry.hadPrevious {
                    if prevState == .present {
                        do {
                            if meetingFileState == .present {
                                _ = try FileManager.default.replaceItemAt(meetingFile, withItemAt: prevFile)
                            } else {
                                try FileManager.default.moveItem(at: prevFile, to: meetingFile)
                            }
                        } catch {
                            AppLog.write("tasks", "롤백 중 prev 복원 실패: \(error.localizedDescription)")
                            throw error
                        }
                    } else {
                        AppLog.write("tasks", "롤백: hadPrevious=true이나 prev 파일 없음, tasks.json 유지 url=\(mURL.lastPathComponent)")
                    }
                } else {
                    if meetingFileState == .present {
                        do {
                            try removeFile(at: meetingFile)
                        } catch {
                            AppLog.write("tasks", "롤백 중 신규 tasks.json 삭제 실패: \(error.localizedDescription)")
                            throw error
                        }
                    }
                }

                for target in [prevTmpFile, tmpFile, restoreTmp] {
                    if try fileState(at: target) == .present {
                        do {
                            try removeFile(at: target)
                        } catch {
                            AppLog.write("tasks", "롤백 중 tmp 정리 실패: \(error.localizedDescription)")
                            throw error
                        }
                    }
                }
            }

            do {
                try removeFile(at: journalURL)
            } catch {
                AppLog.write("tasks", "롤백 중 저널 삭제 실패: \(error.localizedDescription)")
                throw error
            }

            AppLog.write("tasks", "커밋 저널 롤백 완료 count=\(journal.entries.count)")
            return .rolledBack(meetings: journal.entries.count)
        }
    }

    /// Replaces meeting tasks upon summary regeneration.
    /// Commit order:
    /// 0. Check unresolved recovery journal; encode every payload including the final index Data, compute digests.
    /// 1. Write the journal atomically (.atomic).
    /// 2. Per meeting: copy tasks.json to tasks.json.prev.tmp, rename atomically to tasks.json.prev; write tasks.json.tmp, replace tasks.json.
    /// 3. Write the index using the pre-encoded Data.
    /// 4. Delete .prev, .prev.tmp, .tmp files.
    /// 5. Delete the journal.
    @discardableResult
    func replaceTasks(_ items: [TaskItem], for meetingURL: URL) throws -> (items: [TaskItem], warnings: [String]) {
        switch try fileState(at: journalURL) {
        case .present:
            throw TaskStoreError.recoveryPending
        case .missing:
            break
        }

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

        // Pre-commit cleanup: remove stale .tmp / .prev / .prev.tmp / .restore.tmp
        try FileManager.default.createDirectory(at: meetingURL, withIntermediateDirectories: true)
        let meetingTasksFile = meetingURL.appendingPathComponent("tasks.json")
        let meetingTasksTmp = meetingURL.appendingPathComponent("tasks.json.tmp")
        let meetingTasksPrev = meetingURL.appendingPathComponent("tasks.json.prev")
        let meetingTasksPrevTmp = meetingURL.appendingPathComponent("tasks.json.prev.tmp")
        let meetingTasksRestoreTmp = meetingURL.appendingPathComponent("tasks.json.restore.tmp")

        for staleURL in [meetingTasksTmp, meetingTasksPrevTmp, meetingTasksPrev, meetingTasksRestoreTmp] {
            switch try fileState(at: staleURL) {
            case .missing:
                break
            case .present:
                do {
                    try removeFile(at: staleURL)
                } catch {
                    AppLog.write("tasks", "Pre-commit cleanup failed path=\(staleURL.path): \(error.localizedDescription)")
                    throw TaskStoreError.cleanupFailed(path: staleURL.path, underlying: error)
                }
            }
        }

        // 0. Encode every payload including the final index Data, compute both digests
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let meetingData = try encoder.encode(meetingFileItems)
        let newIndexData = try encodeIndex(newIndex)

        let previousIndexData = (try readIndexBytesForDecision()) ?? Data()
        let previousIndexDigest = previousIndexData.isEmpty ? "" : Self.sha256Hex(of: previousIndexData)
        let newIndexDigest = Self.sha256Hex(of: newIndexData)

        let hadPreviousMeetingFile: Bool
        switch try fileState(at: meetingTasksFile) {
        case .present:
            hadPreviousMeetingFile = true
        case .missing:
            hadPreviousMeetingFile = false
        }
        let stdMeetingPath = meetingURL.resolvingSymlinksInPath().standardizedFileURL.path

        let journal = TaskCommitJournal(
            version: 1,
            token: UUID().uuidString,
            previousIndexDigest: previousIndexDigest,
            indexDigest: newIndexDigest,
            entries: [
                TaskCommitJournal.Entry(meetingPath: stdMeetingPath, hadPrevious: hadPreviousMeetingFile)
            ]
        )
        let journalEncoder = JSONEncoder()
        journalEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let journalData = try journalEncoder.encode(journal)

        // 1. Write the journal atomically (.atomic)
        try FileManager.default.createDirectory(at: tasksDirectoryURL, withIntermediateDirectories: true)
        try journalData.write(to: journalURL, options: .atomic)

        // 2. Per meeting: backup to .prev.tmp -> .prev; write .tmp, replace tasks.json
        do {
            if hadPreviousMeetingFile {
                try FileManager.default.copyItem(at: meetingTasksFile, to: meetingTasksPrevTmp)
                try FileManager.default.moveItem(at: meetingTasksPrevTmp, to: meetingTasksPrev)
            }
            try meetingData.write(to: meetingTasksTmp, options: .atomic)
            try beforeMeetingReplaceForTesting?(meetingURL)
            if hadPreviousMeetingFile {
                _ = try FileManager.default.replaceItemAt(meetingTasksFile, withItemAt: meetingTasksTmp)
            } else {
                try FileManager.default.moveItem(at: meetingTasksTmp, to: meetingTasksFile)
            }
        } catch let moveError {
            var moveRollbackErr: (any Error)? = nil
            do {
                for stale in [meetingTasksTmp, meetingTasksPrevTmp, meetingTasksRestoreTmp] {
                    if try fileState(at: stale) == .present {
                        do { try removeFile(at: stale) } catch { if moveRollbackErr == nil { moveRollbackErr = error } }
                    }
                }
                if try fileState(at: meetingTasksPrev) == .present {
                    if hadPreviousMeetingFile {
                        var restored = false
                        do {
                            if try fileState(at: meetingTasksFile) == .present {
                                _ = try FileManager.default.replaceItemAt(meetingTasksFile, withItemAt: meetingTasksPrev)
                            } else {
                                try FileManager.default.moveItem(at: meetingTasksPrev, to: meetingTasksFile)
                            }
                            restored = true
                        } catch {
                            if moveRollbackErr == nil { moveRollbackErr = error }
                        }
                        if restored, try fileState(at: meetingTasksPrev) == .present {
                            do { try removeFile(at: meetingTasksPrev) } catch { if moveRollbackErr == nil { moveRollbackErr = error } }
                        }
                    } else {
                        do { try removeFile(at: meetingTasksPrev) } catch { if moveRollbackErr == nil { moveRollbackErr = error } }
                    }
                } else if !hadPreviousMeetingFile {
                    if try fileState(at: meetingTasksFile) == .present {
                        do { try removeFile(at: meetingTasksFile) } catch { if moveRollbackErr == nil { moveRollbackErr = error } }
                    }
                }
            } catch let checkErr {
                if moveRollbackErr == nil { moveRollbackErr = checkErr }
            }

            if moveRollbackErr == nil {
                do {
                    try removeFile(at: journalURL)
                } catch {
                    moveRollbackErr = error
                }
            }
            AppLog.write("tasks", "회의 폴더 tasks.json 이동 실패 url=\(meetingURL.lastPathComponent): \(moveError.localizedDescription)")
            if let moveRollbackErr = moveRollbackErr {
                throw TaskStoreError.commitFailed(move: moveError, rollback: moveRollbackErr)
            }
            throw moveError
        }

        // 3. Write the index using the pre-encoded Data
        var warnings: [String] = []

        do {
            try writeIndexUnchecked(newIndexData)
        } catch let indexError {
            let readBackData: Data?
            do {
                readBackData = try readIndexBytesForDecision()
            } catch {
                AppLog.write("tasks", "인덱스 검증 읽기 실패: \(error.localizedDescription)")
                throw TaskStoreError.commitFailed(move: indexError, rollback: error)
            }

            if let readBackData = readBackData, Self.sha256Hex(of: readBackData) == newIndexDigest {
                let warn = "Index write threw but file was committed: \(indexError.localizedDescription)"
                AppLog.write("tasks", warn)
                warnings.append(warn)
            } else {
                var restoreError: (any Error)? = nil
                do {
                    if hadPreviousMeetingFile {
                        if try fileState(at: meetingTasksPrev) == .present {
                            let restoreTmp = meetingURL.appendingPathComponent("tasks.json.restore.tmp")
                            var restored = false
                            do {
                                if try fileState(at: restoreTmp) == .present {
                                    try removeFile(at: restoreTmp)
                                }
                                try FileManager.default.copyItem(at: meetingTasksPrev, to: restoreTmp)
                                if try fileState(at: meetingTasksFile) == .present {
                                    _ = try FileManager.default.replaceItemAt(meetingTasksFile, withItemAt: restoreTmp)
                                } else {
                                    try FileManager.default.moveItem(at: restoreTmp, to: meetingTasksFile)
                                }
                                restored = true
                            } catch let rErr {
                                restoreError = rErr
                                AppLog.write("tasks", "회의 tasks.json 롤백 복원 실패 url=\(meetingURL.lastPathComponent): \(rErr.localizedDescription)")
                            }
                            if restored, try fileState(at: meetingTasksPrev) == .present {
                                do {
                                    try removeFile(at: meetingTasksPrev)
                                } catch let cleanupErr {
                                    if restoreError == nil { restoreError = cleanupErr }
                                }
                            }
                        }
                    } else {
                        if try fileState(at: meetingTasksFile) == .present {
                            do {
                                try removeFile(at: meetingTasksFile)
                            } catch let rErr {
                                restoreError = rErr
                                AppLog.write("tasks", "신규 회의 tasks.json 정리 실패 url=\(meetingURL.lastPathComponent): \(rErr.localizedDescription)")
                            }
                        }
                    }

                    for stale in [meetingTasksPrevTmp, meetingTasksTmp, meetingURL.appendingPathComponent("tasks.json.restore.tmp")] {
                        if try fileState(at: stale) == .present {
                            do {
                                try removeFile(at: stale)
                            } catch let cleanupErr {
                                if restoreError == nil { restoreError = cleanupErr }
                                AppLog.write("tasks", "롤백 후 파일 정리 실패 url=\(meetingURL.lastPathComponent): \(cleanupErr.localizedDescription)")
                            }
                        }
                    }
                } catch let checkErr {
                    if restoreError == nil { restoreError = checkErr }
                }

                if let restoreError = restoreError {
                    AppLog.write("tasks", "인덱스 저장 실패 및 롤백 실패, 저널 유지: \(indexError.localizedDescription)")
                    throw TaskStoreError.commitFailed(move: indexError, rollback: restoreError)
                } else {
                    do {
                        try removeFile(at: journalURL)
                    } catch {
                        AppLog.write("tasks", "롤백 후 저널 삭제 실패: \(error.localizedDescription)")
                        throw TaskStoreError.commitFailed(move: indexError, rollback: error)
                    }
                    AppLog.write("tasks", "인덱스 저장 실패 및 회의 파일 롤백 url=\(meetingURL.lastPathComponent): \(indexError.localizedDescription)")
                    throw TaskStoreError.commitFailed(move: indexError, rollback: nil)
                }
            }
        }

        // 4. Delete .prev, .prev.tmp, .tmp, .restore.tmp files
        var hasCleanupFailure = false
        for cleanupTarget in [meetingTasksPrev, meetingTasksPrevTmp, meetingTasksTmp, meetingTasksRestoreTmp] {
            do {
                switch try fileState(at: cleanupTarget) {
                case .missing:
                    break
                case .present:
                    do {
                        try removeFile(at: cleanupTarget)
                    } catch {
                        do {
                            try removeFile(at: cleanupTarget)
                        } catch let cleanupErr {
                            hasCleanupFailure = true
                            let warn = "Failed to remove backup file at \(cleanupTarget.path): \(cleanupErr.localizedDescription)"
                            AppLog.write("tasks", warn)
                            warnings.append(warn)
                        }
                    }
                }
            } catch let stateErr {
                hasCleanupFailure = true
                let warn = "Failed to determine file state for cleanup target at \(cleanupTarget.path): \(stateErr.localizedDescription)"
                AppLog.write("tasks", warn)
                warnings.append(warn)
            }
        }

        // 5. Delete the journal
        if !hasCleanupFailure {
            do {
                switch try fileState(at: journalURL) {
                case .missing:
                    break
                case .present:
                    do {
                        try removeFile(at: journalURL)
                    } catch {
                        do {
                            try removeFile(at: journalURL)
                        } catch let journalErr {
                            let warn = "Failed to delete commit journal at \(journalURL.path): \(journalErr.localizedDescription)"
                            AppLog.write("tasks", warn)
                            warnings.append(warn)
                        }
                    }
                }
            } catch let journalStateErr {
                let warn = "Failed to determine journal state at \(journalURL.path): \(journalStateErr.localizedDescription)"
                AppLog.write("tasks", warn)
                warnings.append(warn)
            }
        }

        return (items: mergedIndexItems, warnings: warnings)
    }

    /// Upserts imported tasks into index by (meetingURL, normalized title).
    @discardableResult
    func appendImported(_ items: [TaskItem]) throws -> ImportOutcome {
        switch try fileState(at: journalURL) {
        case .present:
            throw TaskStoreError.recoveryPending
        case .missing:
            break
        }

        let previousIndex = try loadIndex()

        let urlLessItems = items.filter { $0.meetingURL == nil }
        let distinctMeetingURLs = Set(items.compactMap(\.meetingURL))

        // F2-3: Create and validate every target meeting directory BEFORE writing the journal.
        // A target whose directory cannot be created is moved to failures and excluded from the plan/journal.
        var validatedMeetingURLs: [URL] = []
        var directoryFailures: [(meetingURL: URL?, error: any Error)] = []

        for mURL in distinctMeetingURLs {
            do {
                try FileManager.default.createDirectory(at: mURL, withIntermediateDirectories: true)
                let attrs = try FileManager.default.attributesOfItem(atPath: mURL.path)
                guard let fileType = attrs[.type] as? FileAttributeType, fileType == .typeDirectory else {
                    throw CocoaError(.fileNoSuchFile)
                }
                validatedMeetingURLs.append(mURL)
            } catch {
                AppLog.write("tasks", "회의 디렉토리 생성/검증 실패 url=\(mURL.path): \(error.localizedDescription)")
                directoryFailures.append((meetingURL: mURL, error: error))
            }
        }

        if validatedMeetingURLs.isEmpty && urlLessItems.isEmpty {
            return ImportOutcome(saved: [], failures: directoryFailures, warnings: [])
        }

        let validMeetingURLSet = Set(validatedMeetingURLs)
        var existingTasksByMeeting: [URL: [TaskItem]] = [:]
        for mURL in validatedMeetingURLs {
            existingTasksByMeeting[mURL] = try loadMeetingTasks(at: mURL)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let itemsByMeeting = Dictionary(grouping: items.filter { item in
            guard let u = item.meetingURL else { return false }
            return validMeetingURLSet.contains(u)
        }) { $0.meetingURL! }

        // Pre-commit cleanups: remove stale .tmp / .prev.tmp / .prev / .restore.tmp
        for meetingURL in validatedMeetingURLs {
            let meetingTasksTmp = meetingURL.appendingPathComponent("tasks.json.tmp")
            let meetingTasksPrev = meetingURL.appendingPathComponent("tasks.json.prev")
            let meetingTasksPrevTmp = meetingURL.appendingPathComponent("tasks.json.prev.tmp")
            let meetingTasksRestoreTmp = meetingURL.appendingPathComponent("tasks.json.restore.tmp")

            for stale in [meetingTasksTmp, meetingTasksPrevTmp, meetingTasksPrev, meetingTasksRestoreTmp] {
                switch try fileState(at: stale) {
                case .missing:
                    break
                case .present:
                    do {
                        try removeFile(at: stale)
                    } catch {
                        AppLog.write("tasks", "Pre-commit cleanup failed path=\(stale.path): \(error.localizedDescription)")
                        throw TaskStoreError.cleanupFailed(path: stale.path, underlying: error)
                    }
                }
            }
        }

        // Step 0: Plan payloads and index in memory before touching any file
        var meetingPayloads: [URL: (data: Data, hadPrev: Bool, items: [TaskItem])] = [:]
        for (meetingURL, meetingItems) in itemsByMeeting {
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

            let meetingTasksFile = meetingURL.appendingPathComponent("tasks.json")
            let hadPrev: Bool
            switch try fileState(at: meetingTasksFile) {
            case .present:
                hadPrev = true
            case .missing:
                hadPrev = false
            }
            let data = try encoder.encode(mergedMeetingTasks)
            meetingPayloads[meetingURL] = (data: data, hadPrev: hadPrev, items: meetingItems)
        }

        var plannedIndex = previousIndex
        var existingQueues: [String: [TaskItem]] = [:]
        for item in previousIndex {
            let mPath = item.meetingURL?.standardizedFileURL.path ?? ""
            let key = "\(mPath)|\(item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            existingQueues[key, default: []].append(item)
        }

        let allIncomingItems = urlLessItems + itemsByMeeting.values.flatMap { $0 }
        var plannedSavedItems: [TaskItem] = []

        for var incoming in allIncomingItems {
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
                if let idx = plannedIndex.firstIndex(where: { $0.id == existing.id }) {
                    plannedIndex[idx] = incoming
                }
            } else {
                plannedIndex.append(incoming)
            }
            plannedSavedItems.append(incoming)
        }

        let plannedIndexData = try encodeIndex(plannedIndex)
        let previousIndexData = (try readIndexBytesForDecision()) ?? Data()
        let previousIndexDigest = previousIndexData.isEmpty ? "" : Self.sha256Hex(of: previousIndexData)
        let plannedIndexDigest = Self.sha256Hex(of: plannedIndexData)

        let sortedMeetingURLs = validatedMeetingURLs.sorted(by: { $0.path < $1.path })

        let journalEntries = sortedMeetingURLs.compactMap { mURL -> TaskCommitJournal.Entry? in
            guard let payload = meetingPayloads[mURL] else { return nil }
            return TaskCommitJournal.Entry(
                meetingPath: mURL.resolvingSymlinksInPath().standardizedFileURL.path,
                hadPrevious: payload.hadPrev
            )
        }
        let journal = TaskCommitJournal(
            version: 1,
            token: UUID().uuidString,
            previousIndexDigest: previousIndexDigest,
            indexDigest: plannedIndexDigest,
            entries: journalEntries
        )
        let journalEncoder = JSONEncoder()
        journalEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let journalData = try journalEncoder.encode(journal)

        // Step 1: Write journal atomically BEFORE touching any meeting file
        try FileManager.default.createDirectory(at: tasksDirectoryURL, withIntermediateDirectories: true)
        try journalData.write(to: journalURL, options: .atomic)

        // Step 2: Per meeting: .prev.tmp -> .prev, write .tmp, replace tasks.json
        var failures: [(meetingURL: URL?, error: any Error)] = directoryFailures
        var committedMeetings: [(url: URL, hadPrev: Bool, items: [TaskItem])] = []

        for meetingURL in sortedMeetingURLs {
            guard let payload = meetingPayloads[meetingURL] else { continue }
            let meetingTasksTmp = meetingURL.appendingPathComponent("tasks.json.tmp")
            let meetingTasksPrev = meetingURL.appendingPathComponent("tasks.json.prev")
            let meetingTasksPrevTmp = meetingURL.appendingPathComponent("tasks.json.prev.tmp")
            let meetingTasksFile = meetingURL.appendingPathComponent("tasks.json")
            let restoreTmp = meetingURL.appendingPathComponent("tasks.json.restore.tmp")

            do {
                if payload.hadPrev {
                    try FileManager.default.copyItem(at: meetingTasksFile, to: meetingTasksPrevTmp)
                    try FileManager.default.moveItem(at: meetingTasksPrevTmp, to: meetingTasksPrev)
                }
                try payload.data.write(to: meetingTasksTmp, options: .atomic)
                try beforeMeetingReplaceForTesting?(meetingURL)
                if payload.hadPrev {
                    _ = try FileManager.default.replaceItemAt(meetingTasksFile, withItemAt: meetingTasksTmp)
                } else {
                    try FileManager.default.moveItem(at: meetingTasksTmp, to: meetingTasksFile)
                }
                committedMeetings.append((url: meetingURL, hadPrev: payload.hadPrev, items: payload.items))
            } catch let writeError {
                var rollbackCleanupError: (any Error)? = nil
                do {
                    for stale in [meetingTasksTmp, meetingTasksPrevTmp, restoreTmp] {
                        if try fileState(at: stale) == .present {
                            do {
                                try removeFile(at: stale)
                            } catch let tmpErr {
                                if rollbackCleanupError == nil { rollbackCleanupError = tmpErr }
                                AppLog.write("tasks", "회의 실패 후 정리 실패: \(tmpErr.localizedDescription)")
                            }
                        }
                    }
                    if payload.hadPrev {
                        if try fileState(at: meetingTasksPrev) == .present {
                            var restored = false
                            do {
                                if try fileState(at: restoreTmp) == .present {
                                    try removeFile(at: restoreTmp)
                                }
                                try FileManager.default.copyItem(at: meetingTasksPrev, to: restoreTmp)
                                if try fileState(at: meetingTasksFile) == .present {
                                    _ = try FileManager.default.replaceItemAt(meetingTasksFile, withItemAt: restoreTmp)
                                } else {
                                    try FileManager.default.moveItem(at: restoreTmp, to: meetingTasksFile)
                                }
                                restored = true
                            } catch let rErr {
                                if rollbackCleanupError == nil { rollbackCleanupError = rErr }
                                AppLog.write("tasks", "회의 실패 후 prev 복원 실패: \(rErr.localizedDescription)")
                            }
                            if restored, try fileState(at: meetingTasksPrev) == .present {
                                do { try removeFile(at: meetingTasksPrev) } catch {
                                    if rollbackCleanupError == nil { rollbackCleanupError = error }
                                }
                            }
                        }
                    } else {
                        if try fileState(at: meetingTasksFile) == .present {
                            do {
                                try removeFile(at: meetingTasksFile)
                            } catch let rErr {
                                if rollbackCleanupError == nil { rollbackCleanupError = rErr }
                                AppLog.write("tasks", "신규 회의 tasks.json 정리 실패 url=\(meetingURL.lastPathComponent): \(rErr.localizedDescription)")
                            }
                        }
                    }
                } catch let checkErr {
                    if rollbackCleanupError == nil { rollbackCleanupError = checkErr }
                }

                // F2-1: Any failure to restore from .prev or clean up aborts the whole transaction:
                // stop processing further meetings, do not write index, do not delete journal, throw commitFailed.
                if let cleanupErr = rollbackCleanupError {
                    AppLog.write("tasks", "회의 폴더 tasks.json 복원/정리 실패로 트랜잭션 중단 url=\(meetingURL.lastPathComponent): \(cleanupErr.localizedDescription)")
                    throw TaskStoreError.commitFailed(move: writeError, rollback: cleanupErr)
                }

                AppLog.write("tasks", "회의 폴더 tasks.json 추가 실패 url=\(meetingURL.lastPathComponent): \(writeError.localizedDescription)")
                failures.append((meetingURL: meetingURL, error: writeError))
            }
        }

        if committedMeetings.isEmpty && urlLessItems.isEmpty {
            do {
                try removeFile(at: journalURL)
            } catch {
                AppLog.write("tasks", "모든 회의 실패 후 저널 정리 실패: \(error.localizedDescription)")
            }
            return ImportOutcome(saved: [], failures: failures, warnings: [])
        }

        // Re-compute index if some meetings failed
        let finalIndexData: Data
        let finalIndexDigest: String
        var finalSavedItems: [TaskItem] = []

        if failures.isEmpty {
            finalIndexData = plannedIndexData
            finalIndexDigest = plannedIndexDigest
            finalSavedItems = plannedSavedItems
        } else {
            var revisedIndex = previousIndex
            var existingQueuesRev: [String: [TaskItem]] = [:]
            for item in previousIndex {
                let mPath = item.meetingURL?.standardizedFileURL.path ?? ""
                let key = "\(mPath)|\(item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
                existingQueuesRev[key, default: []].append(item)
            }
            let committedIncomingItems = urlLessItems + committedMeetings.flatMap(\.items)
            for var incoming in committedIncomingItems {
                let mPath = incoming.meetingURL?.standardizedFileURL.path ?? ""
                let key = "\(mPath)|\(incoming.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
                if var queue = existingQueuesRev[key], !queue.isEmpty {
                    let existing = queue.removeFirst()
                    existingQueuesRev[key] = queue
                    incoming.id = existing.id
                    incoming.createdAt = existing.createdAt
                    if existing.status == .done {
                        incoming.status = .done
                        incoming.completedAt = existing.completedAt
                    }
                    if let idx = revisedIndex.firstIndex(where: { $0.id == existing.id }) {
                        revisedIndex[idx] = incoming
                    }
                } else {
                    revisedIndex.append(incoming)
                }
                finalSavedItems.append(incoming)
            }
            finalIndexData = try encodeIndex(revisedIndex)
            finalIndexDigest = Self.sha256Hex(of: finalIndexData)

            // Update journal with revised indexDigest
            let revisedJournal = TaskCommitJournal(
                version: 1,
                token: UUID().uuidString,
                previousIndexDigest: previousIndexDigest,
                indexDigest: finalIndexDigest,
                entries: journalEntries
            )
            let revisedJournalData = try journalEncoder.encode(revisedJournal)
            try revisedJournalData.write(to: journalURL, options: .atomic)
        }

        // Step 3: Write the index using pre-encoded Data
        var warnings: [String] = []
        do {
            try writeIndexUnchecked(finalIndexData)
        } catch let indexError {
            let readBackData: Data?
            do {
                readBackData = try readIndexBytesForDecision()
            } catch {
                AppLog.write("tasks", "인덱스 검증 읽기 실패: \(error.localizedDescription)")
                throw TaskStoreError.commitFailed(move: indexError, rollback: error)
            }

            if let readBackData = readBackData, Self.sha256Hex(of: readBackData) == finalIndexDigest {
                let warn = "Index write threw but file was committed: \(indexError.localizedDescription)"
                AppLog.write("tasks", warn)
                warnings.append(warn)
            } else {
                var firstRestoreError: (any Error)? = nil
                for (meetingURL, hadPrev, _) in committedMeetings {
                    let meetingTasksFile = meetingURL.appendingPathComponent("tasks.json")
                    let meetingTasksPrev = meetingURL.appendingPathComponent("tasks.json.prev")
                    let meetingTasksPrevTmp = meetingURL.appendingPathComponent("tasks.json.prev.tmp")
                    let meetingTasksTmp = meetingURL.appendingPathComponent("tasks.json.tmp")

                    do {
                        if hadPrev {
                            if try fileState(at: meetingTasksPrev) == .present {
                                let restoreTmp = meetingURL.appendingPathComponent("tasks.json.restore.tmp")
                                var restored = false
                                do {
                                    if try fileState(at: restoreTmp) == .present {
                                        try removeFile(at: restoreTmp)
                                    }
                                    try FileManager.default.copyItem(at: meetingTasksPrev, to: restoreTmp)
                                    if try fileState(at: meetingTasksFile) == .present {
                                        _ = try FileManager.default.replaceItemAt(meetingTasksFile, withItemAt: restoreTmp)
                                    } else {
                                        try FileManager.default.moveItem(at: restoreTmp, to: meetingTasksFile)
                                    }
                                    restored = true
                                } catch let rErr {
                                    if firstRestoreError == nil { firstRestoreError = rErr }
                                    AppLog.write("tasks", "회의 tasks.json 롤백 복원 실패 url=\(meetingURL.lastPathComponent): \(rErr.localizedDescription)")
                                }
                                if restored, try fileState(at: meetingTasksPrev) == .present {
                                    do { try removeFile(at: meetingTasksPrev) } catch {
                                        if firstRestoreError == nil { firstRestoreError = error }
                                    }
                                }
                            }
                        } else {
                            if try fileState(at: meetingTasksFile) == .present {
                                do {
                                    try removeFile(at: meetingTasksFile)
                                } catch let rErr {
                                    if firstRestoreError == nil { firstRestoreError = rErr }
                                    AppLog.write("tasks", "신규 회의 tasks.json 정리 실패 url=\(meetingURL.lastPathComponent): \(rErr.localizedDescription)")
                                }
                            }
                        }

                        for stale in [meetingTasksPrevTmp, meetingTasksTmp, meetingURL.appendingPathComponent("tasks.json.restore.tmp")] {
                            if try fileState(at: stale) == .present {
                                do {
                                    try removeFile(at: stale)
                                } catch let cleanupErr {
                                    if firstRestoreError == nil { firstRestoreError = cleanupErr }
                                }
                            }
                        }
                    } catch let checkErr {
                        if firstRestoreError == nil { firstRestoreError = checkErr }
                    }
                }

                if let firstRestoreError = firstRestoreError {
                    AppLog.write("tasks", "인덱스 저장 실패 및 롤백 실패, 저널 유지: \(indexError.localizedDescription)")
                    throw TaskStoreError.commitFailed(move: indexError, rollback: firstRestoreError)
                } else {
                    do {
                        try removeFile(at: journalURL)
                    } catch {
                        AppLog.write("tasks", "롤백 후 저널 삭제 실패: \(error.localizedDescription)")
                        throw TaskStoreError.commitFailed(move: indexError, rollback: error)
                    }
                    AppLog.write("tasks", "인덱스 저장 실패 및 회의 파일들 롤백: \(indexError.localizedDescription)")
                    throw TaskStoreError.commitFailed(move: indexError, rollback: nil)
                }
            }
        }

        // Step 4: Delete .prev, .prev.tmp, .tmp, .restore.tmp files for all committed meetings
        var hasCleanupFailure = false
        for (meetingURL, _, _) in committedMeetings {
            let meetingTasksPrev = meetingURL.appendingPathComponent("tasks.json.prev")
            let meetingTasksPrevTmp = meetingURL.appendingPathComponent("tasks.json.prev.tmp")
            let meetingTasksTmp = meetingURL.appendingPathComponent("tasks.json.tmp")
            let meetingTasksRestoreTmp = meetingURL.appendingPathComponent("tasks.json.restore.tmp")

            for cleanupTarget in [meetingTasksPrev, meetingTasksPrevTmp, meetingTasksTmp, meetingTasksRestoreTmp] {
                do {
                    switch try fileState(at: cleanupTarget) {
                    case .missing:
                        break
                    case .present:
                        do {
                            try removeFile(at: cleanupTarget)
                        } catch {
                            do {
                                try removeFile(at: cleanupTarget)
                            } catch let cleanupErr {
                                hasCleanupFailure = true
                                let warn = "Failed to remove backup file at \(cleanupTarget.path): \(cleanupErr.localizedDescription)"
                                AppLog.write("tasks", warn)
                                warnings.append(warn)
                            }
                        }
                    }
                } catch let stateErr {
                    hasCleanupFailure = true
                    let warn = "Failed to determine file state for cleanup target at \(cleanupTarget.path): \(stateErr.localizedDescription)"
                    AppLog.write("tasks", warn)
                    warnings.append(warn)
                }
            }
        }

        // Step 5: Delete the journal
        if !hasCleanupFailure {
            do {
                switch try fileState(at: journalURL) {
                case .missing:
                    break
                case .present:
                    do {
                        try removeFile(at: journalURL)
                    } catch {
                        do {
                            try removeFile(at: journalURL)
                        } catch let journalErr {
                            let warn = "Failed to delete commit journal at \(journalURL.path): \(journalErr.localizedDescription)"
                            AppLog.write("tasks", warn)
                            warnings.append(warn)
                        }
                    }
                }
            } catch let journalStateErr {
                let warn = "Failed to determine journal state at \(journalURL.path): \(journalStateErr.localizedDescription)"
                AppLog.write("tasks", warn)
                warnings.append(warn)
            }
        }

        return ImportOutcome(saved: finalSavedItems, failures: failures, warnings: warnings)
    }

    func addManual(title: String, owner: String?, due: String?) throws -> TaskItem {
        switch try fileState(at: journalURL) {
        case .present:
            throw TaskStoreError.recoveryPending
        case .missing:
            break
        }

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
        switch try fileState(at: journalURL) {
        case .present:
            throw TaskStoreError.recoveryPending
        case .missing:
            break
        }

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
        switch try fileState(at: journalURL) {
        case .present:
            throw TaskStoreError.recoveryPending
        case .missing:
            break
        }

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
