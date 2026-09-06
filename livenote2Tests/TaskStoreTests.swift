import XCTest

@testable import LiveNote

private final class FailOnNthWrite: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let failOnCall: Int
    let errorToThrow: any Error

    init(failOnCall: Int, errorToThrow: any Error) {
        self.failOnCall = failOnCall
        self.errorToThrow = errorToThrow
    }

    func write(data: Data, url: URL) throws {
        lock.lock()
        count += 1
        let current = count
        lock.unlock()

        if current == failOnCall {
            throw errorToThrow
        }
        try data.write(to: url, options: .atomic)
    }
}

@MainActor
final class TaskStoreTests: XCTestCase {

    private var root: URL!
    private var logRoot: URL!
    private var store: TaskStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TestLogSandbox.activate()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveNoteTaskStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        logRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveNoteTaskStoreLogs-\(UUID().uuidString)", isDirectory: true)
        AppLog.directoryOverride = logRoot
        store = TaskStore(rootURL: root)
    }

    override func tearDown() {
        AppLog.flush()
        AppLog.directoryOverride = TestLogSandbox.directory
        if let root { try? FileManager.default.removeItem(at: root) }
        if let logRoot { try? FileManager.default.removeItem(at: logRoot) }
        store = nil
        root = nil
        logRoot = nil
        super.tearDown()
    }

    func testManualAddAndAllAndOpen() throws {
        let task1 = try store.addManual(title: "Task 1", owner: "Craig", due: "2026-09-10")
        let task2 = try store.addManual(title: "Task 2", owner: nil, due: nil)

        let allTasks = try store.all()
        XCTAssertEqual(allTasks.count, 2)
        XCTAssertEqual(try store.openTasks().count, 2)
        XCTAssertEqual(task1.title, "Task 1")
        XCTAssertEqual(task1.owner, "Craig")
        XCTAssertEqual(task1.due, "2026-09-10")
        XCTAssertEqual(task1.status, .open)
        XCTAssertNil(task2.owner)
    }

    func testSetStatusUpdatesIndexOnly() throws {
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 Sync", isDirectory: true)
        let item = TaskItem(
            id: UUID().uuidString,
            meetingURL: meetingFolder,
            meetingTitle: "Sync",
            meetingDate: Date(),
            title: "Follow up with design",
            owner: "Alice",
            due: "2026-09-05",
            quote: "I will follow up",
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([item], for: meetingFolder)

        let saved = try XCTUnwrap(store.all().first)
        XCTAssertEqual(saved.status, .open)

        try store.setStatus(id: saved.id, done: true)

        let updated = try XCTUnwrap(store.all().first)
        XCTAssertEqual(updated.status, .done)
        XCTAssertNotNil(updated.completedAt)
        XCTAssertTrue(try store.openTasks().isEmpty)

        // Check that meeting tasks.json retains original status
        let meetingTasksData = try Data(contentsOf: meetingFolder.appendingPathComponent("tasks.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meetingTasks = try decoder.decode([TaskItem].self, from: meetingTasksData)
        XCTAssertEqual(meetingTasks.first?.status, .open, "Meeting tasks.json should remain original")
    }

    func testReplaceTasksPreservesDoneStatusAndID() throws {
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 Sync", isDirectory: true)
        let item1 = TaskItem(
            id: "uuid-1",
            meetingURL: meetingFolder,
            meetingTitle: "Sync",
            meetingDate: Date(),
            title: "Write design doc",
            owner: "Bob",
            due: "2026-09-06",
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 1000),
            completedAt: nil
        )
        try store.replaceTasks([item1], for: meetingFolder)
        try store.setStatus(id: "uuid-1", done: true)

        let doneTask = try XCTUnwrap(store.all().first)
        let completedAt = doneTask.completedAt

        // Regenerate summary with new item having same title (different case/trim)
        let item2 = TaskItem(
            id: "uuid-2-new",
            meetingURL: meetingFolder,
            meetingTitle: "Sync",
            meetingDate: Date(),
            title: "  WRITE DESIGN DOC  ",
            owner: "Bob",
            due: "2026-09-07",
            quote: "I will write the design doc",
            status: .open,
            createdAt: Date(timeIntervalSince1970: 2000),
            completedAt: nil
        )
        let (merged, _) = try store.replaceTasks([item2], for: meetingFolder)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "uuid-1", "ID should be preserved")
        XCTAssertEqual(merged[0].status, .done, "Done status should be preserved in index")
        XCTAssertEqual(merged[0].completedAt, completedAt, "CompletedAt should be preserved in index")
        XCTAssertEqual(merged[0].createdAt, Date(timeIntervalSince1970: 1000))

        // T2: Meeting file gets status = .open, completedAt = nil as the extraction original
        let meetingTasks = try store.loadMeetingTasks(at: meetingFolder)
        XCTAssertEqual(meetingTasks.count, 1)
        XCTAssertEqual(meetingTasks[0].id, "uuid-1", "Meeting file item reuses ID")
        XCTAssertEqual(meetingTasks[0].status, .open, "Meeting tasks.json must have status = .open")
        XCTAssertNil(meetingTasks[0].completedAt, "Meeting tasks.json must have completedAt = nil")
    }

    func testDuplicateTitleIdReuseOnce() throws {
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 Sync", isDirectory: true)
        let item1 = TaskItem(
            id: "uuid-1",
            meetingURL: meetingFolder,
            meetingTitle: "Sync",
            meetingDate: Date(),
            title: "Review PR",
            owner: "Bob",
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 1000),
            completedAt: nil
        )
        try store.replaceTasks([item1], for: meetingFolder)

        // Incoming has two items with same title "Review PR"
        let incomingA = TaskItem(
            id: "fresh-a",
            meetingURL: meetingFolder,
            meetingTitle: "Sync",
            meetingDate: Date(),
            title: "Review PR",
            owner: "Bob",
            due: "2026-09-10",
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 2000),
            completedAt: nil
        )
        let incomingB = TaskItem(
            id: "fresh-b",
            meetingURL: meetingFolder,
            meetingTitle: "Sync",
            meetingDate: Date(),
            title: "Review PR",
            owner: "Alice",
            due: "2026-09-12",
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 2000),
            completedAt: nil
        )

        let (merged, _) = try store.replaceTasks([incomingA, incomingB], for: meetingFolder)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].id, "uuid-1", "First item reuses existing ID")
        XCTAssertEqual(merged[1].id, "fresh-b", "Second duplicate item gets fresh ID")
    }

    func testCorruptIndexThrowsAndCreatesCorruptBackup() throws {
        let tasksDir = root.appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        let indexURL = tasksDir.appendingPathComponent("index.json")

        // Write corrupt JSON
        let badContent = "{ this is not valid json }"
        try badContent.write(to: indexURL, atomically: true, encoding: .utf8)

        // Mutating call throws TaskStoreError.indexUnreadable
        XCTAssertThrowsError(try store.addManual(title: "Test", owner: nil, due: nil)) { error in
            guard case TaskStoreError.indexUnreadable = error else {
                XCTFail("Expected indexUnreadable error, got \(error)")
                return
            }
        }

        // Verify bad index file is unchanged
        let currentContent = try String(contentsOf: indexURL, encoding: .utf8)
        XCTAssertEqual(currentContent, badContent)

        // Verify .corrupt- copy exists
        let files = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        let corruptFiles = files.filter { $0.hasPrefix("index.json.corrupt-") }
        XCTAssertFalse(corruptFiles.isEmpty, "Corrupt backup copy should exist")
    }

    func testAppendImportedMergesByTitleAndPreservesStatus() throws {
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 Sync", isDirectory: true)
        let initialTask = TaskItem(
            id: "orig-id-1",
            meetingURL: meetingFolder,
            meetingTitle: "Team Sync",
            meetingDate: Date(timeIntervalSince1970: 10000),
            title: "Update Roadmap",
            owner: "Craig",
            due: "2026-09-10",
            quote: "Original quote",
            status: .done,
            createdAt: Date(timeIntervalSince1970: 1000),
            completedAt: Date(timeIntervalSince1970: 2000)
        )
        try store.replaceTasks([initialTask], for: meetingFolder)

        let imported1 = TaskItem(
            id: "new-import-1",
            meetingURL: meetingFolder,
            meetingTitle: "Team Sync",
            meetingDate: Date(timeIntervalSince1970: 10000),
            title: "update roadmap",
            owner: "Craig",
            due: "2026-09-15",
            quote: "New quote",
            status: .open,
            createdAt: Date(timeIntervalSince1970: 3000),
            completedAt: nil
        )
        let imported2 = TaskItem(
            id: "new-import-2",
            meetingURL: meetingFolder,
            meetingTitle: "Team Sync",
            meetingDate: Date(timeIntervalSince1970: 10000),
            title: "Send Recap",
            owner: "Alice",
            due: nil,
            quote: "Recap quote",
            status: .open,
            createdAt: Date(timeIntervalSince1970: 3000),
            completedAt: nil
        )

        let result = try store.appendImported([imported1, imported2])
        XCTAssertEqual(result.saved.count, 2)
        XCTAssertEqual(result.failures.count, 0)

        let all = try store.all()
        XCTAssertEqual(all.count, 2)

        let updatedRoadmap = try XCTUnwrap(all.first(where: { $0.title.lowercased() == "update roadmap" }))
        XCTAssertEqual(updatedRoadmap.id, "orig-id-1", "Existing ID must be preserved")
        XCTAssertEqual(updatedRoadmap.status, .done, "Done status must be preserved")
        XCTAssertEqual(updatedRoadmap.createdAt, Date(timeIntervalSince1970: 1000))

        let newRecap = try XCTUnwrap(all.first(where: { $0.title == "Send Recap" }))
        XCTAssertEqual(newRecap.id, "new-import-2")
        XCTAssertEqual(newRecap.status, .open)
    }

    func testCorruptMeetingTasksJsonThrowsAndCopiesCorruptFile() throws {
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 CorruptMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)
        let meetingTasksFile = meetingFolder.appendingPathComponent("tasks.json")

        let corruptContent = "{ bad json content"
        try corruptContent.write(to: meetingTasksFile, atomically: true, encoding: .utf8)

        let incoming = TaskItem(
            id: "inc-1",
            meetingURL: meetingFolder,
            meetingTitle: "CorruptMeeting",
            meetingDate: Date(),
            title: "Incoming task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        XCTAssertThrowsError(try store.appendImported([incoming])) { error in
            guard case TaskStoreError.meetingFileUnreadable = error else {
                XCTFail("Expected meetingFileUnreadable, got \(error)")
                return
            }
        }

        // Verify meeting tasks.json is unchanged
        let currentContent = try String(contentsOf: meetingTasksFile, encoding: .utf8)
        XCTAssertEqual(currentContent, corruptContent)

        // Verify .corrupt- copy exists in meeting folder
        let files = try FileManager.default.contentsOfDirectory(atPath: meetingFolder.path)
        let corruptCopies = files.filter { $0.hasPrefix("tasks.json.corrupt-") }
        XCTAssertFalse(corruptCopies.isEmpty, "tasks.json.corrupt- backup must exist")
    }

    func testReplaceTasksWithReadOnlyMeetingFolderLeavesBothFilesUnchangedAndThrows() throws {
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 ReadOnlyMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        let initialTask = try store.addManual(title: "Existing Task", owner: "Craig", due: nil)
        let initialIndex = try store.all()
        XCTAssertEqual(initialIndex.count, 1)

        // Make meeting folder read-only
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: meetingFolder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: meetingFolder.path)
        }

        let item = TaskItem(
            id: "m-item-1",
            meetingURL: meetingFolder,
            meetingTitle: "ReadOnlyMeeting",
            meetingDate: Date(),
            title: "Task in read-only meeting",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        XCTAssertThrowsError(try store.replaceTasks([item], for: meetingFolder)) { error in
            XCTAssertNotNil(error)
        }

        // Assert index is unchanged
        let currentIndex = try store.all()
        XCTAssertEqual(currentIndex.count, 1)
        XCTAssertEqual(currentIndex.first?.id, initialTask.id)

        // Assert meeting file was not created or modified
        let meetingTasks = try store.loadMeetingTasks(at: meetingFolder)
        XCTAssertTrue(meetingTasks.isEmpty)
    }

    func testReplaceTasksIndexWriteFailsRollbackRestoresMeetingFileAndLeavesIndexUnchanged() throws {
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 RollbackMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        let originalMeetingTask = TaskItem(
            id: "orig-1",
            meetingURL: meetingFolder,
            meetingTitle: "RollbackMeeting",
            meetingDate: Date(),
            title: "Original Meeting Task",
            owner: "Alice",
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 1000),
            completedAt: nil
        )
        try store.replaceTasks([originalMeetingTask], for: meetingFolder)

        let initialIndex = try store.all()
        XCTAssertEqual(initialIndex.count, 1)
        XCTAssertEqual(initialIndex.first?.title, "Original Meeting Task")

        struct MockIndexError: LocalizedError, Equatable {
            var errorDescription: String? { "Deterministic index save failure" }
        }

        let mockIndexError = MockIndexError()
        let storeWithFailingIndex = TaskStore(rootURL: root, indexWriter: { data, url in
            throw mockIndexError
        })

        let newMeetingTask = TaskItem(
            id: "new-1",
            meetingURL: meetingFolder,
            meetingTitle: "RollbackMeeting",
            meetingDate: Date(),
            title: "Regenerated Task",
            owner: "Bob",
            due: "2026-09-20",
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 2000),
            completedAt: nil
        )

        XCTAssertThrowsError(try storeWithFailingIndex.replaceTasks([newMeetingTask], for: meetingFolder)) { error in
            guard case let TaskStoreError.commitFailed(move, rollback) = error else {
                XCTFail("Expected commitFailed, got \(error)")
                return
            }
            XCTAssertEqual(move.localizedDescription, mockIndexError.localizedDescription)
            XCTAssertNil(rollback, "Rollback should succeed so rollback error is nil")
            XCTAssertTrue(error.localizedDescription.contains("Failed to commit tasks"))
        }

        // Assert index is unchanged
        let currentIndex = try store.all()
        XCTAssertEqual(currentIndex.count, 1)
        XCTAssertEqual(currentIndex.first?.title, "Original Meeting Task")

        // Assert meeting file was restored to original
        let currentMeetingTasks = try store.loadMeetingTasks(at: meetingFolder)
        XCTAssertEqual(currentMeetingTasks.count, 1)
        XCTAssertEqual(currentMeetingTasks.first?.title, "Original Meeting Task")

        // Assert no temp or prev files remain
        XCTAssertFalse(FileManager.default.fileExists(atPath: meetingFolder.appendingPathComponent("tasks.json.tmp").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meetingFolder.appendingPathComponent("tasks.json.prev").path))
    }

    func testReplaceTasksIndexWriteFailsRollbackFailsThrowsCommitFailedWithBothErrors() throws {
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 ReadOnlyMeetingBothFail", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        let initialMeetingTask = TaskItem(
            id: "orig-both",
            meetingURL: meetingFolder,
            meetingTitle: "ReadOnlyMeetingBothFail",
            meetingDate: Date(),
            title: "Existing Task",
            owner: "Craig",
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialMeetingTask], for: meetingFolder)

        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: meetingFolder.path)
        }

        struct MockIndexError: LocalizedError, Equatable {
            var errorDescription: String? { "Deterministic index save failure" }
        }

        let mockIndexError = MockIndexError()
        let storeWithFailingIndexAndRollback = TaskStore(rootURL: root, indexWriter: { data, url in
            // Make meeting folder read-only right before failing index write so rollback cannot restore meeting file
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: meetingFolder.path)
            throw mockIndexError
        })

        let newItem = TaskItem(
            id: "m-item-1",
            meetingURL: meetingFolder,
            meetingTitle: "ReadOnlyMeetingBothFail",
            meetingDate: Date(),
            title: "New Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        XCTAssertThrowsError(try storeWithFailingIndexAndRollback.replaceTasks([newItem], for: meetingFolder)) { error in
            guard case let TaskStoreError.commitFailed(move, rollback) = error else {
                XCTFail("Expected commitFailed, got \(error)")
                return
            }
            XCTAssertNotNil(move)
            XCTAssertNotNil(rollback, "Rollback should fail deterministically")
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("Failed to commit tasks"), "Description must mention commit failure: \(description)")
            XCTAssertTrue(description.contains("rollback also failed"), "Description must mention rollback failure: \(description)")
        }
    }

    func testMeetingFileNeverContainsStatusDoneAfterMutations() throws {
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 StatusIsolationTest", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        let item1 = TaskItem(
            id: "task-1",
            meetingURL: meetingFolder,
            meetingTitle: "StatusIsolationTest",
            meetingDate: Date(),
            title: "Item 1",
            owner: "Alice",
            due: "2026-09-10",
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 1000),
            completedAt: nil
        )
        let item2 = TaskItem(
            id: "task-2",
            meetingURL: meetingFolder,
            meetingTitle: "StatusIsolationTest",
            meetingDate: Date(),
            title: "Item 2",
            owner: "Bob",
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 1000),
            completedAt: nil
        )

        // 1. Initial replaceTasks
        try store.replaceTasks([item1, item2], for: meetingFolder)

        // 2. Mark item 1 done in index
        try store.setStatus(id: "task-1", done: true)

        // Verify index is done, meeting file is open
        var indexTasks = try store.all()
        XCTAssertEqual(indexTasks.first(where: { $0.id == "task-1" })?.status, .done)

        // 3. Regenerate with replaceTasks
        let item1New = TaskItem(
            id: "task-1-new",
            meetingURL: meetingFolder,
            meetingTitle: "StatusIsolationTest",
            meetingDate: Date(),
            title: "Item 1",
            owner: "Alice",
            due: "2026-09-11",
            quote: "Updated quote",
            status: .open,
            createdAt: Date(timeIntervalSince1970: 2000),
            completedAt: nil
        )
        let item3 = TaskItem(
            id: "task-3",
            meetingURL: meetingFolder,
            meetingTitle: "StatusIsolationTest",
            meetingDate: Date(),
            title: "Item 3",
            owner: "Charlie",
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 2000),
            completedAt: nil
        )
        try store.replaceTasks([item1New, item3], for: meetingFolder)

        // 4. Mark all items done in index
        indexTasks = try store.all()
        for t in indexTasks {
            try store.setStatus(id: t.id, done: true)
        }

        // 5. Append imported tasks
        let itemImported = TaskItem(
            id: "task-4",
            meetingURL: meetingFolder,
            meetingTitle: "StatusIsolationTest",
            meetingDate: Date(),
            title: "Item 1",
            owner: "Alice",
            due: "2026-09-12",
            quote: "Import quote",
            status: .open,
            createdAt: Date(timeIntervalSince1970: 3000),
            completedAt: nil
        )
        try store.appendImported([itemImported])

        // Verify meeting file content
        let meetingTasksFile = meetingFolder.appendingPathComponent("tasks.json")
        let rawMeetingJson = try String(contentsOf: meetingTasksFile, encoding: .utf8)
        XCTAssertFalse(rawMeetingJson.contains("\"status\" : \"done\""), "Raw tasks.json must never contain status:done")
        XCTAssertFalse(rawMeetingJson.contains("\"done\""), "Raw tasks.json must never contain 'done'")

        let meetingTasks = try store.loadMeetingTasks(at: meetingFolder)
        XCTAssertFalse(meetingTasks.isEmpty)
        for task in meetingTasks {
            XCTAssertEqual(task.status, .open, "Every task in meeting file must be .open")
            XCTAssertNil(task.completedAt, "Every task in meeting file must have nil completedAt")
        }
    }

    func testAddManualInvalidDueRejected() throws {
        XCTAssertThrowsError(try store.addManual(title: "Bad due 1", owner: nil, due: "2026-99-99")) { error in
            XCTAssertEqual(error as? TaskStoreError, .invalidDueDate)
        }
        XCTAssertThrowsError(try store.addManual(title: "Bad due 2", owner: nil, due: "tomorrow")) { error in
            XCTAssertEqual(error as? TaskStoreError, .invalidDueDate)
        }

        let valid = try store.addManual(title: "Good due", owner: nil, due: "2026-09-10")
        XCTAssertEqual(valid.due, "2026-09-10")
    }

    func testAppendImportedMeetingFileWriteFailure() throws {
        let readOnlyFolder = root.appendingPathComponent("2026-09-01 1000 WriteFailMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyFolder, withIntermediateDirectories: true)

        // Make meeting folder read-only
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyFolder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyFolder.path)
        }

        let task1 = TaskItem(
            id: "fail-1",
            meetingURL: readOnlyFolder,
            meetingTitle: "WriteFailMeeting",
            meetingDate: Date(),
            title: "Meeting task write fail",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        let task2 = TaskItem(
            id: "unmatched-2",
            meetingURL: nil,
            meetingTitle: "Unmatched",
            meetingDate: nil,
            title: "Unmatched task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        let outcome = try store.appendImported([task1, task2])
        XCTAssertEqual(outcome.saved.count, 1, "Only URL-less task persisted because meeting file write failed")
        XCTAssertEqual(outcome.failures.count, 1, "Meeting folder write failure counted")
        XCTAssertEqual(outcome.failures.first?.meetingURL, readOnlyFolder)

        let all = try store.all()
        XCTAssertEqual(all.count, 1, "Only saved items are in the index")
        XCTAssertEqual(all.first?.title, "Unmatched task")
    }

    func testAppendImportedTwoMeetingsOneReadOnlyOnlyGoodMeetingSavedToIndex() throws {
        let goodFolder = root.appendingPathComponent("2026-09-01 1000 GoodMeeting", isDirectory: true)
        let readOnlyFolder = root.appendingPathComponent("2026-09-01 1100 BadMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: goodFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readOnlyFolder, withIntermediateDirectories: true)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyFolder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyFolder.path)
        }

        let goodTask = TaskItem(
            id: "good-1",
            meetingURL: goodFolder,
            meetingTitle: "GoodMeeting",
            meetingDate: Date(),
            title: "Good task",
            owner: "Alice",
            due: "2026-09-10",
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        let badTask = TaskItem(
            id: "bad-1",
            meetingURL: readOnlyFolder,
            meetingTitle: "BadMeeting",
            meetingDate: Date(),
            title: "Bad task",
            owner: "Bob",
            due: "2026-09-12",
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        let outcome = try store.appendImported([goodTask, badTask])
        XCTAssertEqual(outcome.saved.count, 1, "Only good meeting task saved")
        XCTAssertEqual(outcome.failures.count, 1, "Bad meeting recorded failure")

        let all = try store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "Good task")

        let goodMeetingTasks = try store.loadMeetingTasks(at: goodFolder)
        XCTAssertEqual(goodMeetingTasks.count, 1)
        XCTAssertEqual(goodMeetingTasks.first?.title, "Good task")
    }

    func testReplaceTasksStaleUnremovablePrevThrowsCleanupFailed() throws {
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 StalePrev", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        let prevFile = meetingFolder.appendingPathComponent("tasks.json.prev")
        try "stale prev".write(to: prevFile, atomically: true, encoding: .utf8)

        struct MockCleanupError: LocalizedError, Equatable {
            var errorDescription: String? { "Permission denied removing stale prev" }
        }

        let storeWithFailingRemover = TaskStore(rootURL: root, fileRemover: { url in
            if url.path.hasSuffix("tasks.json.prev") {
                throw MockCleanupError()
            }
            try FileManager.default.removeItem(at: url)
        })

        let task = TaskItem(
            id: "task-1",
            meetingURL: meetingFolder,
            meetingTitle: "StalePrev",
            meetingDate: Date(),
            title: "Test Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        XCTAssertThrowsError(try storeWithFailingRemover.replaceTasks([task], for: meetingFolder)) { error in
            guard case let TaskStoreError.cleanupFailed(path, underlying) = error else {
                XCTFail("Expected cleanupFailed, got \(error)")
                return
            }
            XCTAssertEqual(path, prevFile.path)
            XCTAssertEqual(underlying.localizedDescription, MockCleanupError().localizedDescription)
        }
    }

    func testReplaceTasksPostCommitPrevRemovalFailureReturnsWarning() throws {
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 PostCommitWarning", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        // Initial task so tasks.json exists and gets copied to tasks.json.prev
        let initialTask = TaskItem(
            id: "initial-1",
            meetingURL: meetingFolder,
            meetingTitle: "PostCommitWarning",
            meetingDate: Date(),
            title: "Initial Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 1000),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meetingFolder)

        struct MockPostCommitError: LocalizedError, Equatable {
            var errorDescription: String? { "Simulated post-commit .prev removal failure" }
        }

        let storeWithFailingRemover = TaskStore(rootURL: root, fileRemover: { url in
            if url.path.hasSuffix("tasks.json.prev") {
                throw MockPostCommitError()
            }
            try FileManager.default.removeItem(at: url)
        })

        let newTask = TaskItem(
            id: "new-1",
            meetingURL: meetingFolder,
            meetingTitle: "PostCommitWarning",
            meetingDate: Date(),
            title: "Updated Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 2000),
            completedAt: nil
        )

        let result = try storeWithFailingRemover.replaceTasks([newTask], for: meetingFolder)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.title, "Updated Task")
        XCTAssertFalse(result.warnings.isEmpty, "Post-commit cleanup failure must return a warning")
        XCTAssertTrue(result.warnings.first?.contains("Simulated post-commit .prev removal failure") == true)

        // Task is committed successfully
        let all = try store.all()
        XCTAssertEqual(all.first?.title, "Updated Task")
    }

    func testAppendImportedStaleUnremovableTmpThrowsCleanupFailed() throws {
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 StaleTmpImport", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        let tmpFile = meetingFolder.appendingPathComponent("tasks.json.tmp")
        try "stale tmp".write(to: tmpFile, atomically: true, encoding: .utf8)

        struct MockTmpCleanupError: LocalizedError, Equatable {
            var errorDescription: String? { "Cannot remove stale tmp during import" }
        }

        let storeWithFailingRemover = TaskStore(rootURL: root, fileRemover: { url in
            if url.path.hasSuffix("tasks.json.tmp") {
                throw MockTmpCleanupError()
            }
            try FileManager.default.removeItem(at: url)
        })

        let task = TaskItem(
            id: "imp-task",
            meetingURL: meetingFolder,
            meetingTitle: "StaleTmpImport",
            meetingDate: Date(),
            title: "Import Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        XCTAssertThrowsError(try storeWithFailingRemover.appendImported([task])) { error in
            guard case let TaskStoreError.cleanupFailed(path, underlying) = error else {
                XCTFail("Expected cleanupFailed, got \(error)")
                return
            }
            XCTAssertEqual(path, tmpFile.path)
            XCTAssertEqual(underlying.localizedDescription, MockTmpCleanupError().localizedDescription)
        }
    }

    func testAppendImportedPostCommitPrevRemovalFailureReturnsWarning() throws {
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 ImportWarning", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        let initialTask = TaskItem(
            id: "init-m",
            meetingURL: meetingFolder,
            meetingTitle: "ImportWarning",
            meetingDate: Date(),
            title: "Initial Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meetingFolder)

        struct MockImportPrevError: LocalizedError, Equatable {
            var errorDescription: String? { "Cannot remove prev after import" }
        }

        let storeWithFailingRemover = TaskStore(rootURL: root, fileRemover: { url in
            if url.path.hasSuffix("tasks.json.prev") {
                throw MockImportPrevError()
            }
            try FileManager.default.removeItem(at: url)
        })

        let importedTask = TaskItem(
            id: "imp-m",
            meetingURL: meetingFolder,
            meetingTitle: "ImportWarning",
            meetingDate: Date(),
            title: "Imported Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        let outcome = try storeWithFailingRemover.appendImported([importedTask])
        XCTAssertEqual(outcome.saved.count, 1)
        XCTAssertFalse(outcome.warnings.isEmpty, "Outcome should contain warnings")
        XCTAssertTrue(outcome.warnings.first?.contains("Cannot remove prev after import") == true)
    }

    func testAppendImportedIndexWriteFailsRollbackRestoresMeetingFileAndLeavesIndexUnchanged() throws {
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 AppendImportRollback", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        let initialMeetingTask = TaskItem(
            id: "initial-m1",
            meetingURL: meetingFolder,
            meetingTitle: "AppendImportRollback",
            meetingDate: Date(),
            title: "Original Meeting Task",
            owner: "Alice",
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 1000),
            completedAt: nil
        )
        try store.replaceTasks([initialMeetingTask], for: meetingFolder)

        struct MockIndexError: LocalizedError, Equatable {
            var errorDescription: String? { "Deterministic index save failure during import" }
        }

        let mockIndexError = MockIndexError()
        let storeWithFailingIndex = TaskStore(rootURL: root, indexWriter: { data, url in
            throw mockIndexError
        })

        let importedTask = TaskItem(
            id: "imp-1",
            meetingURL: meetingFolder,
            meetingTitle: "AppendImportRollback",
            meetingDate: Date(),
            title: "Imported New Task",
            owner: "Bob",
            due: "2026-09-25",
            quote: "New commitment",
            status: .open,
            createdAt: Date(timeIntervalSince1970: 2000),
            completedAt: nil
        )

        XCTAssertThrowsError(try storeWithFailingIndex.appendImported([importedTask])) { error in
            guard case let TaskStoreError.commitFailed(move, rollback) = error else {
                XCTFail("Expected commitFailed, got \(error)")
                return
            }
            XCTAssertEqual(move.localizedDescription, mockIndexError.localizedDescription)
            XCTAssertNil(rollback, "Rollback should succeed so rollback error is nil")
        }

        // Assert index is unchanged
        let currentIndex = try store.all()
        XCTAssertEqual(currentIndex.count, 1)
        XCTAssertEqual(currentIndex.first?.title, "Original Meeting Task")

        // Assert meeting file was restored to original
        let currentMeetingTasks = try store.loadMeetingTasks(at: meetingFolder)
        XCTAssertEqual(currentMeetingTasks.count, 1)
        XCTAssertEqual(currentMeetingTasks.first?.title, "Original Meeting Task")
    }

    func testUnmatchedImportKeepsAttribution() throws {
        let unmatched = TaskItem(
            id: "unmatched-1",
            meetingURL: nil,
            meetingTitle: "Past Offsite",
            meetingDate: Date(timeIntervalSince1970: 50000),
            title: "File expenses",
            owner: "Me",
            due: "2026-09-20",
            quote: "Please file expenses",
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        try store.appendImported([unmatched])

        let all = try store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(all[0].meetingURL)
        XCTAssertEqual(all[0].meetingTitle, "Past Offsite")
        XCTAssertEqual(all[0].quote, "Please file expenses")
        XCTAssertEqual(all[0].due, "2026-09-20")
    }

    func testManualDeleteRemovesTaskAndRejectsMeetingTask() throws {
        let manual = try store.addManual(title: "Manual task", owner: nil, due: nil)
        XCTAssertEqual(try store.all().count, 1)

        try store.delete(id: manual.id)
        XCTAssertEqual(try store.all().count, 0)

        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 Sync", isDirectory: true)
        let meetingTask = TaskItem(
            id: "m-task-1",
            meetingURL: meetingFolder,
            meetingTitle: "Sync",
            meetingDate: Date(),
            title: "Meeting task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([meetingTask], for: meetingFolder)

        XCTAssertThrowsError(try store.delete(id: "m-task-1")) { error in
            XCTAssertEqual(error as? TaskStoreError, .cannotDeleteMeetingTask)
        }
    }

    func testOpenTasksMatchingNames() throws {
        _ = try store.addManual(title: "Task Craig", owner: "Craig Angulo", due: nil)
        _ = try store.addManual(title: "Task Alice", owner: "Alice Smith", due: nil)
        _ = try store.addManual(title: "Task Bob", owner: "Bob Jones", due: nil)

        let matchedCraig = try store.openTasks(matchingNames: ["craig"])
        XCTAssertEqual(matchedCraig.count, 1)
        XCTAssertEqual(matchedCraig.first?.title, "Task Craig")

        let matchedBoth = try store.openTasks(matchingNames: ["craig", "alice.smith@apple.com"])
        XCTAssertEqual(matchedBoth.count, 2)

        let noMatch = try store.openTasks(matchingNames: ["Unknown Person"])
        XCTAssertTrue(noMatch.isEmpty)
    }

    func testAppendImportedMeetingFileWriteFailureAndCleanupFailureReportsCommitFailedWithBothErrors() throws {
        let meetingFolder = root.appendingPathComponent("2026-09-01 1000 WriteAndCleanupFail", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        let meetingTasksFile = meetingFolder.appendingPathComponent("tasks.json")
        try "[]".write(to: meetingTasksFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: meetingTasksFile.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: meetingTasksFile.path)
        }

        let mockCleanupError = NSError(domain: "test.cleanup", code: 42, userInfo: [NSLocalizedDescriptionKey: "disk cleanup failed"])
        let storeWithFailingCleanup = TaskStore(rootURL: root, indexWriter: nil, fileRemover: { url in
            throw mockCleanupError
        })

        let taskToImport = TaskItem(
            id: "import-1",
            meetingURL: meetingFolder,
            meetingTitle: "WriteAndCleanupFail",
            meetingDate: Date(),
            title: "Task that fails write and cleanup",
            owner: "Craig",
            due: "2026-09-20",
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        XCTAssertThrowsError(try storeWithFailingCleanup.appendImported([taskToImport])) { error in
            guard case let TaskStoreError.commitFailed(move, rollback) = error else {
                XCTFail("Expected TaskStoreError.commitFailed, got \(error)")
                return
            }
            XCTAssertNotNil(move, "Move error should be captured")
            XCTAssertNotNil(rollback, "Rollback cleanup error should be captured")
            XCTAssertEqual(rollback?.localizedDescription, mockCleanupError.localizedDescription)
        }
    }
}
