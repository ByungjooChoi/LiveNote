import XCTest
import CryptoKit
@testable import LiveNote

@MainActor
final class TaskStoreJournalTests: XCTestCase {

    private var root: URL!
    private var store: TaskStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TestLogSandbox.activate()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskStoreJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = TaskStore(rootURL: root)
    }

    override func tearDown() {
        AppLog.flush()
        if let root {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("tasks").path)
            if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let fileURL as URL in enumerator {
                    _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        store = nil
        root = nil
        super.tearDown()
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func tasksDirectory() -> URL {
        root.appendingPathComponent("tasks", isDirectory: true)
    }

    private func journalURL() -> URL {
        tasksDirectory().appendingPathComponent("commit-journal.json")
    }

    private func writeJournal(_ journal: TaskCommitJournal) throws {
        try FileManager.default.createDirectory(at: tasksDirectory(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(journal)
        try data.write(to: journalURL(), options: .atomic)
    }

    // MARK: - Success Leaves No Residual Files

    func testSuccessfulReplaceTasksLeavesNoJournalOrTempFiles() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 MeetingA", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let task = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "MeetingA",
            meetingDate: Date(),
            title: "Task 1",
            owner: "Alice",
            due: "2026-09-10",
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        let (items, warnings) = try store.replaceTasks([task], for: meeting)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(warnings.isEmpty)

        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.appendingPathComponent("tasks.json.prev").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.appendingPathComponent("tasks.json.prev.tmp").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.appendingPathComponent("tasks.json.tmp").path))
    }

    func testSuccessfulAppendImportedLeavesNoJournalOrTempFiles() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 MeetingB", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let task = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "MeetingB",
            meetingDate: Date(),
            title: "Task 2",
            owner: "Bob",
            due: "2026-09-12",
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        let outcome = try store.appendImported([task])
        XCTAssertEqual(outcome.saved.count, 1)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertTrue(outcome.warnings.isEmpty)

        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.appendingPathComponent("tasks.json.prev").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.appendingPathComponent("tasks.json.prev.tmp").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.appendingPathComponent("tasks.json.tmp").path))
    }

    // MARK: - (a) Roll Forward

    func testRecoverInterruptedCommitRollForward() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 RollForwardMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let oldData = Data("old tasks content".utf8)
        let newData = Data("new tasks content".utf8)

        let meetingTasks = meeting.appendingPathComponent("tasks.json")
        let meetingPrev = meeting.appendingPathComponent("tasks.json.prev")
        try newData.write(to: meetingTasks, options: .atomic)
        try oldData.write(to: meetingPrev, options: .atomic)

        let newIndexData = Data("committed index content".utf8)
        let indexFile = tasksDirectory().appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: tasksDirectory(), withIntermediateDirectories: true)
        try newIndexData.write(to: indexFile, options: .atomic)

        let journal = TaskCommitJournal(
            version: 1,
            token: UUID().uuidString,
            previousIndexDigest: sha256Hex(Data("previous index".utf8)),
            indexDigest: sha256Hex(newIndexData),
            entries: [
                TaskCommitJournal.Entry(
                    meetingPath: meeting.resolvingSymlinksInPath().standardizedFileURL.path,
                    hadPrevious: true
                )
            ]
        )
        try writeJournal(journal)

        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .rolledForward(meetings: 1))

        XCTAssertFalse(FileManager.default.fileExists(atPath: meetingPrev.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))
        let remainingData = try Data(contentsOf: meetingTasks)
        XCTAssertEqual(remainingData, newData)
    }

    // MARK: - (b) Roll Back With Previous

    func testRecoverInterruptedCommitRollBackWithPrevious() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 RollBackMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let oldData = Data("old tasks content".utf8)
        let newData = Data("new uncommitted tasks".utf8)

        let meetingTasks = meeting.appendingPathComponent("tasks.json")
        let meetingPrev = meeting.appendingPathComponent("tasks.json.prev")
        try newData.write(to: meetingTasks, options: .atomic)
        try oldData.write(to: meetingPrev, options: .atomic)

        let oldIndexData = Data("old index content".utf8)
        let indexFile = tasksDirectory().appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: tasksDirectory(), withIntermediateDirectories: true)
        try oldIndexData.write(to: indexFile, options: .atomic)

        let targetIndexData = Data("target index that never committed".utf8)
        let journal = TaskCommitJournal(
            version: 1,
            token: UUID().uuidString,
            previousIndexDigest: sha256Hex(oldIndexData),
            indexDigest: sha256Hex(targetIndexData),
            entries: [
                TaskCommitJournal.Entry(
                    meetingPath: meeting.resolvingSymlinksInPath().standardizedFileURL.path,
                    hadPrevious: true
                )
            ]
        )
        try writeJournal(journal)

        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .rolledBack(meetings: 1))

        XCTAssertFalse(FileManager.default.fileExists(atPath: meetingPrev.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))
        let remainingData = try Data(contentsOf: meetingTasks)
        XCTAssertEqual(remainingData, oldData)
    }

    // MARK: - (c) Roll Back Without Previous

    func testRecoverInterruptedCommitRollBackWithoutPrevious() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 RollBackNoPrev", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let meetingTasks = meeting.appendingPathComponent("tasks.json")
        try Data("new tasks in brand new meeting".utf8).write(to: meetingTasks, options: .atomic)

        let oldIndexData = Data("old index".utf8)
        let indexFile = tasksDirectory().appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: tasksDirectory(), withIntermediateDirectories: true)
        try oldIndexData.write(to: indexFile, options: .atomic)

        let journal = TaskCommitJournal(
            version: 1,
            token: UUID().uuidString,
            previousIndexDigest: sha256Hex(oldIndexData),
            indexDigest: sha256Hex(Data("different index".utf8)),
            entries: [
                TaskCommitJournal.Entry(
                    meetingPath: meeting.resolvingSymlinksInPath().standardizedFileURL.path,
                    hadPrevious: false
                )
            ]
        )
        try writeJournal(journal)

        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .rolledBack(meetings: 1))

        XCTAssertFalse(FileManager.default.fileExists(atPath: meetingTasks.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))
    }

    // MARK: - (d) HadPrevious But Prev Missing

    func testRecoverInterruptedCommitHadPreviousMissingPrevPreservesTasksJson() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 CrashBeforePrevPublished", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let meetingTasks = meeting.appendingPathComponent("tasks.json")
        let tasksContent = Data("existing tasks content".utf8)
        try tasksContent.write(to: meetingTasks, options: .atomic)

        let prevTmp = meeting.appendingPathComponent("tasks.json.prev.tmp")
        try Data("partial prev".utf8).write(to: prevTmp, options: .atomic)

        let oldIndex = Data("old index".utf8)
        let indexFile = tasksDirectory().appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: tasksDirectory(), withIntermediateDirectories: true)
        try oldIndex.write(to: indexFile, options: .atomic)

        let journal = TaskCommitJournal(
            version: 1,
            token: UUID().uuidString,
            previousIndexDigest: sha256Hex(oldIndex),
            indexDigest: sha256Hex(Data("new index".utf8)),
            entries: [
                TaskCommitJournal.Entry(
                    meetingPath: meeting.resolvingSymlinksInPath().standardizedFileURL.path,
                    hadPrevious: true
                )
            ]
        )
        try writeJournal(journal)

        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .rolledBack(meetings: 1))

        XCTAssertFalse(FileManager.default.fileExists(atPath: prevTmp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: meetingTasks.path))
        let remaining = try Data(contentsOf: meetingTasks)
        XCTAssertEqual(remaining, tasksContent)
    }

    // MARK: - (e) Undecodable Journal

    func testRecoverInterruptedCommitUndecodableJournalMovesToCorruptAndLoadIndexWorks() throws {
        try FileManager.default.createDirectory(at: tasksDirectory(), withIntermediateDirectories: true)
        try "bad json content not a journal".write(to: journalURL(), atomically: true, encoding: .utf8)

        let indexFile = tasksDirectory().appendingPathComponent("index.json")
        let task = TaskItem(
            id: UUID().uuidString,
            meetingURL: nil,
            meetingTitle: nil,
            meetingDate: nil,
            title: "Indexed manual task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        let indexData = try store.encodeIndex([task])
        try indexData.write(to: indexFile, options: .atomic)

        let outcome = try store.recoverInterruptedCommit()
        guard case let .journalCorrupt(movedTo) = outcome else {
            XCTFail("Expected journalCorrupt, got \(outcome)")
            return
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedTo.path))
        XCTAssertTrue(movedTo.lastPathComponent.hasPrefix("commit-journal.json.corrupt-"))

        let loaded = try store.loadIndex()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Indexed manual task")
    }

    // MARK: - (f) Decodable But Invalid Journal

    func testRecoverInterruptedCommitInvalidJournals() throws {
        let validMeeting = root.appendingPathComponent("2026-09-01 1000 ValidMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: validMeeting, withIntermediateDirectories: true)
        let validMeetingPath = validMeeting.resolvingSymlinksInPath().standardizedFileURL.path

        let outsideFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutsideFolder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideFolder) }

        let symlinkMeeting = root.appendingPathComponent("MeetingSymlink")
        try? FileManager.default.createSymbolicLink(at: symlinkMeeting, withDestinationURL: validMeeting)
        defer { try? FileManager.default.removeItem(at: symlinkMeeting) }

        let validDigest64 = String(repeating: "a", count: 64)

        struct TestCase {
            let name: String
            let journal: TaskCommitJournal
        }

        let cases: [TestCase] = [
            TestCase(
                name: "unknown version",
                journal: TaskCommitJournal(
                    version: 99,
                    token: UUID().uuidString,
                    previousIndexDigest: "",
                    indexDigest: validDigest64,
                    entries: [TaskCommitJournal.Entry(meetingPath: validMeetingPath, hadPrevious: false)]
                )
            ),
            TestCase(
                name: "invalid UUID token",
                journal: TaskCommitJournal(
                    version: 1,
                    token: "not-a-valid-uuid",
                    previousIndexDigest: "",
                    indexDigest: validDigest64,
                    entries: [TaskCommitJournal.Entry(meetingPath: validMeetingPath, hadPrevious: false)]
                )
            ),
            TestCase(
                name: "bad index digest length",
                journal: TaskCommitJournal(
                    version: 1,
                    token: UUID().uuidString,
                    previousIndexDigest: "",
                    indexDigest: "shortdigest",
                    entries: [TaskCommitJournal.Entry(meetingPath: validMeetingPath, hadPrevious: false)]
                )
            ),
            TestCase(
                name: "bad previous index digest non-hex",
                journal: TaskCommitJournal(
                    version: 1,
                    token: UUID().uuidString,
                    previousIndexDigest: String(repeating: "z", count: 64),
                    indexDigest: validDigest64,
                    entries: [TaskCommitJournal.Entry(meetingPath: validMeetingPath, hadPrevious: false)]
                )
            ),
            TestCase(
                name: "duplicate meetingPath",
                journal: TaskCommitJournal(
                    version: 1,
                    token: UUID().uuidString,
                    previousIndexDigest: "",
                    indexDigest: validDigest64,
                    entries: [
                        TaskCommitJournal.Entry(meetingPath: validMeetingPath, hadPrevious: false),
                        TaskCommitJournal.Entry(meetingPath: validMeetingPath, hadPrevious: false)
                    ]
                )
            ),
            TestCase(
                name: "meetingPath outside rootURL",
                journal: TaskCommitJournal(
                    version: 1,
                    token: UUID().uuidString,
                    previousIndexDigest: "",
                    indexDigest: validDigest64,
                    entries: [
                        TaskCommitJournal.Entry(
                            meetingPath: outsideFolder.resolvingSymlinksInPath().standardizedFileURL.path,
                            hadPrevious: false
                        )
                    ]
                )
            ),
            TestCase(
                name: "meetingPath is a symlink",
                journal: TaskCommitJournal(
                    version: 1,
                    token: UUID().uuidString,
                    previousIndexDigest: "",
                    indexDigest: validDigest64,
                    entries: [
                        TaskCommitJournal.Entry(meetingPath: symlinkMeeting.path, hadPrevious: false)
                    ]
                )
            )
        ]

        for tc in cases {
            try writeJournal(tc.journal)
            let outcome = try store.recoverInterruptedCommit()
            guard case let .journalCorrupt(movedTo) = outcome else {
                XCTFail("Case '\(tc.name)' expected .journalCorrupt, got \(outcome)")
                continue
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: movedTo.path))
            try? FileManager.default.removeItem(at: movedTo)
        }
    }

    // MARK: - (g) No Journal

    func testRecoverInterruptedCommitNoJournalReturnsNone() throws {
        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .none)
    }

    // MARK: - (h) IndexWriter Throws Without Writing

    func testIndexWriterThrowsWithoutWritingRollsBackAndRemovesJournal() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 FailingIndexMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let initialTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "FailingIndexMeeting",
            meetingDate: Date(),
            title: "Initial Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meeting)

        struct MockIndexError: LocalizedError, Equatable {
            var errorDescription: String? { "Mock index write failed without writing" }
        }

        let storeWithFailingIndex = TaskStore(
            rootURL: root,
            indexWriter: { _, _ in throw MockIndexError() },
            fileRemover: nil
        )

        let updatedTask = TaskItem(
            id: initialTask.id,
            meetingURL: meeting,
            meetingTitle: "FailingIndexMeeting",
            meetingDate: Date(),
            title: "Updated Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: initialTask.createdAt,
            completedAt: nil
        )

        XCTAssertThrowsError(try storeWithFailingIndex.replaceTasks([updatedTask], for: meeting)) { error in
            guard case let TaskStoreError.commitFailed(move, rollback) = error else {
                XCTFail("Expected commitFailed, got \(error)")
                return
            }
            XCTAssertEqual(move.localizedDescription, MockIndexError().localizedDescription)
            XCTAssertNil(rollback)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))
        let tasksOnDisk = try store.loadMeetingTasks(at: meeting)
        XCTAssertEqual(tasksOnDisk.first?.title, "Initial Task")
    }

    // MARK: - (i) IndexWriter Writes Then Throws

    func testIndexWriterWritesThenThrowsReturnsSuccessWithWarning() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 WriteThenThrowMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        struct MockPostWriteError: LocalizedError, Equatable {
            var errorDescription: String? { "Failed right after disk flush" }
        }

        let storeWithFailingIndex = TaskStore(
            rootURL: root,
            indexWriter: { data, url in
                try data.write(to: url, options: .atomic)
                throw MockPostWriteError()
            },
            fileRemover: nil
        )

        let task = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "WriteThenThrowMeeting",
            meetingDate: Date(),
            title: "Committed task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        let (items, warnings) = try storeWithFailingIndex.replaceTasks([task], for: meeting)
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(warnings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))

        let tasksOnDisk = try store.loadMeetingTasks(at: meeting)
        XCTAssertEqual(tasksOnDisk.first?.title, "Committed task")
    }

    // MARK: - (j) FileRemover Fails on .prev Deletion After Successful Index Write

    func testFileRemoverFailsOnPrevDeletionReturnsSuccessWithWarning() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 PrevRemovalFail", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let initialTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "PrevRemovalFail",
            meetingDate: Date(),
            title: "Task v1",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meeting)

        struct MockPrevRemovalError: LocalizedError, Equatable {
            var errorDescription: String? { "Failed to remove prev" }
        }

        let storeWithFailingRemover = TaskStore(
            rootURL: root,
            indexWriter: nil,
            fileRemover: { url in
                if url.path.hasSuffix("tasks.json.prev") {
                    throw MockPrevRemovalError()
                }
                try FileManager.default.removeItem(at: url)
            }
        )

        let updatedTask = TaskItem(
            id: initialTask.id,
            meetingURL: meeting,
            meetingTitle: "PrevRemovalFail",
            meetingDate: Date(),
            title: "Task v2",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: initialTask.createdAt,
            completedAt: nil
        )

        let (items, warnings) = try storeWithFailingRemover.replaceTasks([updatedTask], for: meeting)
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(warnings.isEmpty)
        XCTAssertTrue(warnings.first?.contains("Failed to remove backup file") == true)

        let tasksOnDisk = try store.loadMeetingTasks(at: meeting)
        XCTAssertEqual(tasksOnDisk.first?.title, "Task v2")
    }

    // MARK: - (k) FileRemover Fails During Rollback Leaves Journal And Blocks Next Commit

    func testFileRemoverFailsDuringRollbackLeavesJournalAndBlocksNextCommit() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 RollbackCleanupFail", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        struct MockIndexFail: LocalizedError, Equatable {
            var errorDescription: String? { "Index write failed" }
        }
        struct MockRollbackCleanupFail: LocalizedError, Equatable {
            var errorDescription: String? { "Cannot remove file during rollback" }
        }

        // Initially create a task
        let initialTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "RollbackCleanupFail",
            meetingDate: Date(),
            title: "Initial",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meeting)

        let storeWithErrors = TaskStore(
            rootURL: root,
            indexWriter: { _, _ in throw MockIndexFail() },
            fileRemover: { url in
                if url.path.hasSuffix("tasks.json.prev") {
                    throw MockRollbackCleanupFail()
                }
                try FileManager.default.removeItem(at: url)
            }
        )

        let updatedTask = TaskItem(
            id: initialTask.id,
            meetingURL: meeting,
            meetingTitle: "RollbackCleanupFail",
            meetingDate: Date(),
            title: "Updated",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: initialTask.createdAt,
            completedAt: nil
        )

        XCTAssertThrowsError(try storeWithErrors.replaceTasks([updatedTask], for: meeting)) { error in
            guard case let TaskStoreError.commitFailed(move, rollback) = error else {
                XCTFail("Expected commitFailed, got \(error)")
                return
            }
            XCTAssertEqual(move.localizedDescription, MockIndexFail().localizedDescription)
            XCTAssertNotNil(rollback)
        }

        // Journal must still be on disk
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL().path))

        // Subsequent replaceTasks must throw recoveryPending
        XCTAssertThrowsError(try store.replaceTasks([updatedTask], for: meeting)) { error in
            XCTAssertEqual(error as? TaskStoreError, .recoveryPending)
        }

        // recoverInterruptedCommit repairs the state
        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .rolledBack(meetings: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))
    }

    // MARK: - (l) Re-saving Identical Logical Index (indexDigest == previousIndexDigest)

    func testReSavingIdenticalLogicalIndexSimulatedCrashRollsBack() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 SameIndexMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let task = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "SameIndexMeeting",
            meetingDate: Date(),
            title: "Existing Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([task], for: meeting)

        let indexFile = tasksDirectory().appendingPathComponent("index.json")
        let indexData = try Data(contentsOf: indexFile)
        let digest = sha256Hex(indexData)

        let meetingPrev = meeting.appendingPathComponent("tasks.json.prev")
        try Data("previous tasks".utf8).write(to: meetingPrev, options: .atomic)

        // Journal where indexDigest == previousIndexDigest
        let journal = TaskCommitJournal(
            version: 1,
            token: UUID().uuidString,
            previousIndexDigest: digest,
            indexDigest: digest,
            entries: [
                TaskCommitJournal.Entry(
                    meetingPath: meeting.resolvingSymlinksInPath().standardizedFileURL.path,
                    hadPrevious: true
                )
            ]
        )
        try writeJournal(journal)

        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .rolledBack(meetings: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meetingPrev.path))
    }

    // MARK: - (m) Journal Write Failure (Read-Only tasks/ Directory)

    func testJournalWriteFailureThrowsBeforeMeetingTasksChange() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 ReadOnlyTasksMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let originalTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "ReadOnlyTasksMeeting",
            meetingDate: Date(),
            title: "Original Valid Task",
            owner: "Owner",
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let originalMeetingData = try encoder.encode([originalTask])
        let meetingTasks = meeting.appendingPathComponent("tasks.json")
        try originalMeetingData.write(to: meetingTasks, options: .atomic)

        try FileManager.default.createDirectory(at: tasksDirectory(), withIntermediateDirectories: true)
        let originalIndexData = try encoder.encode([originalTask])
        let indexFile = tasksDirectory().appendingPathComponent("index.json")
        try originalIndexData.write(to: indexFile, options: .atomic)

        // Make tasks directory read-only so journal write fails
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tasksDirectory().path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tasksDirectory().path)
        }

        let incomingTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "ReadOnlyTasksMeeting",
            meetingDate: Date(),
            title: "Incoming Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        var thrownError: (any Error)?
        XCTAssertThrowsError(try store.replaceTasks([incomingTask], for: meeting)) { err in
            thrownError = err
        }
        XCTAssertNotNil(thrownError)
        let nsErr = (thrownError as? NSError)
        XCTAssertTrue(nsErr?.domain == NSCocoaErrorDomain || nsErr?.domain == NSPOSIXErrorDomain)

        let meetingTasksAfter = try Data(contentsOf: meetingTasks)
        XCTAssertEqual(meetingTasksAfter, originalMeetingData, "Meeting tasks must not change when journal write fails")
        let indexAfter = try Data(contentsOf: indexFile)
        XCTAssertEqual(indexAfter, originalIndexData, "Index must not change when journal write fails")
    }

    // MARK: - Fix Round 1 Tests (F1-1 through F1-6)

    func testAppendImportedWritesJournalBeforeMeetingFilesAndHookRecoversInterruptedCommit() throws {
        let meeting1 = root.appendingPathComponent("2026-09-01 1000 Meeting1", isDirectory: true)
        let meeting2 = root.appendingPathComponent("2026-09-01 1100 Meeting2", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: meeting2, withIntermediateDirectories: true)

        let initialTask1 = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting1,
            meetingTitle: "Meeting1",
            meetingDate: Date(),
            title: "Original Task 1",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask1], for: meeting1)

        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotRoot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshotRoot) }

        enum TestAbortError: Error { case abortAtSecondMeeting }

        let expectedJournalURL = journalURL()
        let currentRoot = root!

        store.beforeMeetingReplaceForTesting = { url in
            // Assert journal exists on disk before meeting file is replaced
            XCTAssertTrue(FileManager.default.fileExists(atPath: expectedJournalURL.path), "Journal must exist on disk before meeting replace")
            if url == meeting2 {
                // Meeting1 has already been replaced! Snapshot the disk state now.
                try? FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
                let items = (try? FileManager.default.contentsOfDirectory(at: currentRoot, includingPropertiesForKeys: nil)) ?? []
                for item in items {
                    let dest = snapshotRoot.appendingPathComponent(item.lastPathComponent)
                    try? FileManager.default.copyItem(at: item, to: dest)
                }
                throw TestAbortError.abortAtSecondMeeting
            }
        }

        let importTask1 = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting1,
            meetingTitle: "Meeting1",
            meetingDate: Date(),
            title: "Imported Task 1",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        let importTask2 = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting2,
            meetingTitle: "Meeting2",
            meetingDate: Date(),
            title: "Imported Task 2",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        // Run appendImported which will abort at meeting2 after capturing the snapshot
        _ = try? store.appendImported([importTask1, importTask2])

        // Restore snapshot into ORIGINAL root so canonical paths in journal remain valid
        let itemsToRemove = (try? FileManager.default.contentsOfDirectory(at: currentRoot, includingPropertiesForKeys: nil)) ?? []
        for item in itemsToRemove {
            try? FileManager.default.removeItem(at: item)
        }
        let snapshotItems = try FileManager.default.contentsOfDirectory(at: snapshotRoot, includingPropertiesForKeys: nil)
        for item in snapshotItems {
            let dest = currentRoot.appendingPathComponent(item.lastPathComponent)
            try FileManager.default.copyItem(at: item, to: dest)
        }

        // Assert at least one meeting file had already changed when the snapshot was taken
        let prerecoveryStore = TaskStore(rootURL: currentRoot)
        let prerecoveryMeeting1Tasks = try prerecoveryStore.loadMeetingTasks(at: meeting1)
        XCTAssertEqual(prerecoveryMeeting1Tasks.count, 2)
        XCTAssertTrue(prerecoveryMeeting1Tasks.contains { $0.title == "Imported Task 1" }, "Meeting 1 must have been updated in snapshot before recovery")

        // Initialize TasksController on original root -> recovers interrupted commit to previous generation
        let freshStore = TaskStore(rootURL: currentRoot)
        let controller = TasksController(store: freshStore)
        XCTAssertNil(controller.lastError)

        let restoredTasks = try freshStore.loadMeetingTasks(at: meeting1)
        XCTAssertEqual(restoredTasks.count, 1)
        XCTAssertEqual(restoredTasks.first?.title, "Original Task 1", "Meeting 1 must be rolled back to previous generation")

        let indexTasks = try freshStore.loadIndex()
        XCTAssertEqual(indexTasks.count, 1)
        XCTAssertEqual(indexTasks.first?.title, "Original Task 1", "Index must be at previous generation")

        let corruptSidecars = (try? FileManager.default.contentsOfDirectory(at: tasksDirectory(), includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.contains("commit-journal.json.corrupt") } ?? []
        XCTAssertTrue(corruptSidecars.isEmpty, "No .corrupt sidecar should exist")
    }

    func testPrevPreservedAndRecoverableWhenMeetingRestoreFails() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 RestoreFailMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let initialTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "RestoreFailMeeting",
            meetingDate: Date(),
            title: "Initial Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meeting)

        let meetingTasksFile = meeting.appendingPathComponent("tasks.json")
        let initialData = try Data(contentsOf: meetingTasksFile)

        struct FailingIndexWriter: Error {}

        // Make store with failing index writer, and make meeting directory read-only so rollback restore fails
        let failingStore = TaskStore(
            rootURL: root,
            indexWriter: { _, _ in
                // Make meeting directory read-only during index write so rollback restore fails to replace tasks.json
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: meeting.path)
                throw FailingIndexWriter()
            },
            fileRemover: nil
        )

        let updatedTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "RestoreFailMeeting",
            meetingDate: Date(),
            title: "Updated Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: meeting.path)
        }

        XCTAssertThrowsError(try failingStore.replaceTasks([updatedTask], for: meeting)) { error in
            guard case .commitFailed(let move, let rollback) = (error as? TaskStoreError) else {
                XCTFail("Expected commitFailed error, got: \(error)")
                return
            }
            XCTAssertNotNil(move)
            XCTAssertNotNil(rollback)
        }

        let meetingPrev = meeting.appendingPathComponent("tasks.json.prev")
        XCTAssertTrue(FileManager.default.fileExists(atPath: meetingPrev.path), ".prev file must be preserved on restore failure")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL().path), "Journal must be preserved on restore failure")

        // Restore permissions and run recoverInterruptedCommit
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: meeting.path)
        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .rolledBack(meetings: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meetingPrev.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))
        let restoredData = try Data(contentsOf: meetingTasksFile)
        XCTAssertEqual(restoredData, initialData)
    }

    func testIndexReadErrorDuringRecoveryThrowsAndPreservesJournal() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 ReadErrorMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let task = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "ReadErrorMeeting",
            meetingDate: Date(),
            title: "Task In Meeting",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([task], for: meeting)

        let indexFile = tasksDirectory().appendingPathComponent("index.json")
        let indexData = try Data(contentsOf: indexFile)
        let digest = sha256Hex(indexData)

        let journal = TaskCommitJournal(
            version: 1,
            token: UUID().uuidString,
            previousIndexDigest: sha256Hex(Data("old".utf8)),
            indexDigest: digest,
            entries: [
                TaskCommitJournal.Entry(
                    meetingPath: meeting.resolvingSymlinksInPath().standardizedFileURL.path,
                    hadPrevious: false
                )
            ]
        )
        try writeJournal(journal)

        // Make index.json unreadable
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: indexFile.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: indexFile.path)
        }

        XCTAssertThrowsError(try store.recoverInterruptedCommit())
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL().path), "Journal must not be quarantined on index read error")

        // Restore permissions: same call should roll forward
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: indexFile.path)
        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .rolledForward(meetings: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))

        // Valid journal with read error throws without quarantining
        try writeJournal(journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: journalURL().path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: journalURL().path)
        }
        XCTAssertThrowsError(try store.recoverInterruptedCommit())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: journalURL().path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL().path), "Journal must still be in place")
    }

    func testPublicIndexWritesThrowRecoveryPendingWhenJournalExists() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 PendingJournalMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let initialTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "PendingJournalMeeting",
            meetingDate: Date(),
            title: "Task 1",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        struct FailJournalDelete: Error {}
        let failingStore = TaskStore(
            rootURL: root,
            indexWriter: nil,
            fileRemover: { url in
                if url.lastPathComponent == "commit-journal.json" {
                    throw FailJournalDelete()
                }
                try FileManager.default.removeItem(at: url)
            }
        )

        // replaceTasks succeeds with warning that journal could not be deleted
        let (items, warnings) = try failingStore.replaceTasks([initialTask], for: meeting)
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL().path))

        let indexFile = tasksDirectory().appendingPathComponent("index.json")
        let indexBefore = try Data(contentsOf: indexFile)

        // Public index writers must throw recoveryPending
        XCTAssertThrowsError(try store.setStatus(id: initialTask.id, done: true)) { error in
            XCTAssertEqual(error as? TaskStoreError, .recoveryPending)
        }
        XCTAssertThrowsError(try store.addManual(title: "Manual Task", owner: nil, due: nil)) { error in
            XCTAssertEqual(error as? TaskStoreError, .recoveryPending)
        }
        XCTAssertThrowsError(try store.delete(id: initialTask.id)) { error in
            XCTAssertEqual(error as? TaskStoreError, .recoveryPending)
        }

        let indexAfter = try Data(contentsOf: indexFile)
        XCTAssertEqual(indexBefore, indexAfter, "Index bytes must remain unchanged when recoveryPending is thrown")

        // recoverInterruptedCommit rolls forward and subsequent writes succeed
        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .rolledForward(meetings: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))

        let manual = try store.addManual(title: "New Manual", owner: nil, due: nil)
        XCTAssertEqual(manual.title, "New Manual")
    }

    func testJournalValidationRejectsNonCanonicalPathsAndDuplicates() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 CanonicalMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let initialTasks = Data("tasks".utf8)
        let initialPrev = Data("prev".utf8)
        let meetingTasks = meeting.appendingPathComponent("tasks.json")
        let meetingPrev = meeting.appendingPathComponent("tasks.json.prev")
        try initialTasks.write(to: meetingTasks, options: .atomic)
        try initialPrev.write(to: meetingPrev, options: .atomic)

        let canonicalPath = meeting.resolvingSymlinksInPath().standardizedFileURL.path
        let nonCanonicalPath = canonicalPath + "/."

        let journal = TaskCommitJournal(
            version: 1,
            token: UUID().uuidString,
            previousIndexDigest: sha256Hex(Data("old".utf8)),
            indexDigest: sha256Hex(Data("new".utf8)),
            entries: [
                TaskCommitJournal.Entry(meetingPath: canonicalPath, hadPrevious: true),
                TaskCommitJournal.Entry(meetingPath: nonCanonicalPath, hadPrevious: false)
            ]
        )
        try writeJournal(journal)

        let outcome = try store.recoverInterruptedCommit()
        guard case .journalCorrupt = outcome else {
            XCTFail("Expected .journalCorrupt, got \(outcome)")
            return
        }

        // tasks.json and .prev bytes must be untouched
        XCTAssertEqual(try Data(contentsOf: meetingTasks), initialTasks)
        XCTAssertEqual(try Data(contentsOf: meetingPrev), initialPrev)
    }

    func testMarkCorruptThrowsOnMoveFailureAndCollisionGetsDistinctName() throws {
        let invalidJournal = TaskCommitJournal(
            version: 999,
            token: UUID().uuidString,
            previousIndexDigest: "",
            indexDigest: "abc",
            entries: []
        )
        try writeJournal(invalidJournal)

        // Make tasks directory read-only so moving journal to corrupt fails
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tasksDirectory().path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tasksDirectory().path)
        }

        XCTAssertThrowsError(try store.recoverInterruptedCommit())
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL().path), "Journal must remain in place when move fails")

        // Restore permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tasksDirectory().path)

        // Create pre-existing corrupt file to test collision handling
        let timestamp = Int(Date().timeIntervalSince1970)
        let existingCorrupt = tasksDirectory().appendingPathComponent("commit-journal.json.corrupt-\(timestamp)")
        try Data("existing corrupt".utf8).write(to: existingCorrupt, options: .atomic)

        let outcome = try store.recoverInterruptedCommit()
        guard case .journalCorrupt(let movedTo) = outcome else {
            XCTFail("Expected .journalCorrupt, got \(outcome)")
            return
        }
        XCTAssertTrue(movedTo.lastPathComponent.contains("-\(timestamp)-1") || movedTo.lastPathComponent != existingCorrupt.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingCorrupt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedTo.path))
    }

    // MARK: - Fix Round 1b Tests

    func testReplaceTasksThrowsWhenIndexUnreadableAndLeavesDiskUntouched() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 UnreadableIndexMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let initialTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "UnreadableIndexMeeting",
            meetingDate: Date(),
            title: "Initial Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let initialTasksData = try encoder.encode([initialTask])
        let meetingTasks = meeting.appendingPathComponent("tasks.json")
        try initialTasksData.write(to: meetingTasks, options: .atomic)

        let indexFile = tasksDirectory().appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: tasksDirectory(), withIntermediateDirectories: true)
        try Data("initial index content".utf8).write(to: indexFile, options: .atomic)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: indexFile.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: indexFile.path)
        }

        let newTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "UnreadableIndexMeeting",
            meetingDate: Date(),
            title: "Task New",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        XCTAssertThrowsError(try store.replaceTasks([newTask], for: meeting))

        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path), "No journal must be created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.appendingPathComponent("tasks.json.prev").path), "No .prev backup must be created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.appendingPathComponent("tasks.json.prev.tmp").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.appendingPathComponent("tasks.json.tmp").path))
        XCTAssertEqual(try Data(contentsOf: meetingTasks), initialTasksData, "Meeting tasks file must be unchanged")
    }

    func testRecoverInterruptedCommitRejectsSymlinkMeetingFolder() throws {
        let realMeeting = root.appendingPathComponent("2026-09-01 1000 RealMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: realMeeting, withIntermediateDirectories: true)

        let symlinkMeeting = root.appendingPathComponent("2026-09-01 1000 SymlinkMeeting")
        try FileManager.default.createSymbolicLink(at: symlinkMeeting, withDestinationURL: realMeeting)

        let journal = TaskCommitJournal(
            version: 1,
            token: UUID().uuidString,
            previousIndexDigest: sha256Hex(Data("old".utf8)),
            indexDigest: sha256Hex(Data("new".utf8)),
            entries: [
                TaskCommitJournal.Entry(
                    meetingPath: symlinkMeeting.path,
                    hadPrevious: false
                )
            ]
        )
        try writeJournal(journal)

        let outcome = try store.recoverInterruptedCommit()
        guard case .journalCorrupt = outcome else {
            XCTFail("Expected .journalCorrupt for symlink meeting folder, got \(outcome)")
            return
        }
    }

    func testRecoverInterruptedCommitRejectsMissingMeetingFolder() throws {
        let missingMeeting = root.appendingPathComponent("2026-09-01 1000 MissingMeeting", isDirectory: true)

        let journal = TaskCommitJournal(
            version: 1,
            token: UUID().uuidString,
            previousIndexDigest: sha256Hex(Data("old".utf8)),
            indexDigest: sha256Hex(Data("new".utf8)),
            entries: [
                TaskCommitJournal.Entry(
                    meetingPath: missingMeeting.path,
                    hadPrevious: false
                )
            ]
        )
        try writeJournal(journal)

        let outcome = try store.recoverInterruptedCommit()
        guard case .journalCorrupt = outcome else {
            XCTFail("Expected .journalCorrupt for missing meeting folder, got \(outcome)")
            return
        }
    }

    func testRecoverInterruptedCommitThrowsWhenFolderAttributesCannotBeReadAndKeepsJournal() throws {
        let parentDir = root.appendingPathComponent("ParentDir", isDirectory: true)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let childMeeting = parentDir.appendingPathComponent("2026-09-01 1000 ChildMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: childMeeting, withIntermediateDirectories: true)

        let journal = TaskCommitJournal(
            version: 1,
            token: UUID().uuidString,
            previousIndexDigest: sha256Hex(Data("old".utf8)),
            indexDigest: sha256Hex(Data("new".utf8)),
            entries: [
                TaskCommitJournal.Entry(
                    meetingPath: childMeeting.path,
                    hadPrevious: false
                )
            ]
        )
        try writeJournal(journal)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parentDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parentDir.path)
        }

        XCTAssertThrowsError(try store.recoverInterruptedCommit())
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL().path), "Journal must be kept on attribute read error")

        // Restore permissions and verify journal was not moved to corrupt
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parentDir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL().path), "Journal still present")
        let corruptFiles = try FileManager.default.contentsOfDirectory(at: tasksDirectory(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("commit-journal.json.corrupt") }
        XCTAssertTrue(corruptFiles.isEmpty, "No corrupt journal file must be created")
    }

    // MARK: - Fix Round 2 Tests (F2-1 through F2-6)

    // F2-1: appendImported aborts entire transaction when restore fails
    func testAppendImportedAbortsTransactionWhenRestoreFails() throws {
        let meetingA = root.appendingPathComponent("2026-09-01 1000 MeetingA", isDirectory: true)
        let meetingB = root.appendingPathComponent("2026-09-01 1100 MeetingB", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: meetingB, withIntermediateDirectories: true)

        let initialTaskA = TaskItem(
            id: UUID().uuidString,
            meetingURL: meetingA,
            meetingTitle: "MeetingA",
            meetingDate: Date(),
            title: "Original Task A",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTaskA], for: meetingA)

        let initialIndexData = try Data(contentsOf: tasksDirectory().appendingPathComponent("index.json"))

        enum InjectedReplaceError: Error { case testFailure }

        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meetingA.path)
        }

        // When meetingA is about to be replaced, make meetingA directory read-only so rollback restore fails
        store.beforeMeetingReplaceForTesting = { url in
            if url == meetingA {
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: meetingA.path)
                throw InjectedReplaceError.testFailure
            }
        }

        let importTaskA = TaskItem(
            id: UUID().uuidString,
            meetingURL: meetingA,
            meetingTitle: "MeetingA",
            meetingDate: Date(),
            title: "Import Task A",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        let importTaskB = TaskItem(
            id: UUID().uuidString,
            meetingURL: meetingB,
            meetingTitle: "MeetingB",
            meetingDate: Date(),
            title: "Import Task B",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        XCTAssertThrowsError(try store.appendImported([importTaskA, importTaskB])) { error in
            guard case .commitFailed(let move, let rollback) = (error as? TaskStoreError) else {
                XCTFail("Expected commitFailed, got \(error)")
                return
            }
            XCTAssertNotNil(move)
            XCTAssertNotNil(rollback)
        }

        // Assert previous index bytes unchanged
        let currentIndexData = try Data(contentsOf: tasksDirectory().appendingPathComponent("index.json"))
        XCTAssertEqual(currentIndexData, initialIndexData, "Previous index bytes must be unchanged")

        // Journal must be present on disk
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL().path), "Journal must remain on disk")

        // A's .prev must be present on disk
        let prevFileA = meetingA.appendingPathComponent("tasks.json.prev")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prevFileA.path), "A's .prev must remain present")

        // Meeting B was not modified
        let meetingBTasksFile = meetingB.appendingPathComponent("tasks.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: meetingBTasksFile.path), "Meeting B must not have been processed")

        // Restore permissions and verify recoverInterruptedCommit rolls back to previous generation
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meetingA.path)
        let outcome = try store.recoverInterruptedCommit()
        guard case .rolledBack = outcome else {
            XCTFail("Expected .rolledBack, got \(outcome)")
            return
        }

        let meetingATasks = try store.loadMeetingTasks(at: meetingA)
        XCTAssertEqual(meetingATasks.count, 1)
        XCTAssertEqual(meetingATasks.first?.title, "Original Task A")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path), "Journal must be deleted after recovery")
    }

    // F2-1 variant: all meetings fail but roll back cleanly -> deletes journal
    func testAppendImportedAllFailDeletesJournalWhenAllRolledBackCleanly() throws {
        let meetingA = root.appendingPathComponent("2026-09-01 1000 AllFailCleanA", isDirectory: true)
        let meetingB = root.appendingPathComponent("2026-09-01 1100 AllFailCleanB", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: meetingB, withIntermediateDirectories: true)

        let initialTaskA = TaskItem(
            id: UUID().uuidString,
            meetingURL: meetingA,
            meetingTitle: "AllFailCleanA",
            meetingDate: Date(),
            title: "Original A",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTaskA], for: meetingA)

        enum InjectedReplaceError: Error { case failBoth }

        store.beforeMeetingReplaceForTesting = { _ in
            throw InjectedReplaceError.failBoth
        }

        let importTaskA = TaskItem(
            id: UUID().uuidString,
            meetingURL: meetingA,
            meetingTitle: "AllFailCleanA",
            meetingDate: Date(),
            title: "Import A",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        let importTaskB = TaskItem(
            id: UUID().uuidString,
            meetingURL: meetingB,
            meetingTitle: "AllFailCleanB",
            meetingDate: Date(),
            title: "Import B",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        let outcome = try store.appendImported([importTaskA, importTaskB])
        XCTAssertEqual(outcome.saved.count, 0)
        XCTAssertEqual(outcome.failures.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path), "Journal must be deleted when all failed meetings rolled back cleanly")

        let tasksA = try store.loadMeetingTasks(at: meetingA)
        XCTAssertEqual(tasksA.count, 1)
        XCTAssertEqual(tasksA.first?.title, "Original A")
    }

    // F2-2: index write throws + tasks directory unreadable -> replaceTasks throws, journal kept, recovers on permission restore
    func testIndexWriteThrowsAndDirectoryUnreadablePreservesJournalAndRecoversOnPermissionRestore() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 PermTestMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let initialTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "PermTestMeeting",
            meetingDate: Date(),
            title: "Initial Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meeting)

        let updatedTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "PermTestMeeting",
            meetingDate: Date(),
            title: "Updated Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        struct SimulatedWriterError: Error {}

        let tasksDir = tasksDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tasksDir.path)
        }

        let unreadableStore = TaskStore(
            rootURL: root,
            indexWriter: { data, dest in
                try data.write(to: dest, options: .atomic)
                // Remove read and execute permission on tasks directory
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tasksDir.path)
                throw SimulatedWriterError()
            },
            fileRemover: nil
        )

        XCTAssertThrowsError(try unreadableStore.replaceTasks([updatedTask], for: meeting))

        // Restore permissions temporarily to inspect meeting file & prev & journal
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tasksDir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL().path), "Journal must be kept")
        let prevFile = meeting.appendingPathComponent("tasks.json.prev")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prevFile.path), ".prev file must be present")

        // Recovery with tasks directory unreadable throws (not .none)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tasksDir.path)
        XCTAssertThrowsError(try store.recoverInterruptedCommit(), "Recovery with tasks directory unreadable must throw")

        // Restore permission and recover -> rolls forward because index was already written with new digest
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tasksDir.path)
        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .rolledForward(meetings: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path), "Journal deleted after roll forward")
        let meetingTasks = try store.loadMeetingTasks(at: meeting)
        XCTAssertEqual(meetingTasks.first?.title, "Updated Task")
    }

    // F2-3: appendImported creates and validates meeting directory before writing journal
    func testAppendImportedCreatesAndValidatesMeetingDirectoryBeforeWritingJournal() throws {
        let meetingA = root.appendingPathComponent("2026-09-01 1000 DirValA", isDirectory: true)
        let meetingB = root.appendingPathComponent("2026-09-01 1100 DirValB", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingA, withIntermediateDirectories: true)

        let initialTaskA = TaskItem(
            id: UUID().uuidString,
            meetingURL: meetingA,
            meetingTitle: "DirValA",
            meetingDate: Date(),
            title: "Original Task A",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTaskA], for: meetingA)

        // Ensure meetingB does NOT exist on disk before appendImported is called
        XCTAssertFalse(FileManager.default.fileExists(atPath: meetingB.path), "Meeting B must not exist yet")

        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotDirVal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshotRoot) }

        enum TestAbortError: Error { case abortAtMeetingA }
        let currentRoot = root!

        store.beforeMeetingReplaceForTesting = { url in
            if url == meetingA {
                // Every journal entry's directory must exist!
                XCTAssertTrue(FileManager.default.fileExists(atPath: meetingB.path), "Meeting B directory must already exist before meeting replace")

                // Snapshot disk state
                try? FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
                let items = (try? FileManager.default.contentsOfDirectory(at: currentRoot, includingPropertiesForKeys: nil)) ?? []
                for item in items {
                    let dest = snapshotRoot.appendingPathComponent(item.lastPathComponent)
                    try? FileManager.default.copyItem(at: item, to: dest)
                }
                throw TestAbortError.abortAtMeetingA
            }
        }

        let taskA = TaskItem(
            id: UUID().uuidString,
            meetingURL: meetingA,
            meetingTitle: "DirValA",
            meetingDate: Date(),
            title: "Imported Task A",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        let taskB = TaskItem(
            id: UUID().uuidString,
            meetingURL: meetingB,
            meetingTitle: "DirValB",
            meetingDate: Date(),
            title: "Imported Task B",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        _ = try? store.appendImported([taskA, taskB])

        // Restore snapshot to original root
        let itemsToRemove = (try? FileManager.default.contentsOfDirectory(at: currentRoot, includingPropertiesForKeys: nil)) ?? []
        for item in itemsToRemove {
            try? FileManager.default.removeItem(at: item)
        }
        let snapshotItems = try FileManager.default.contentsOfDirectory(at: snapshotRoot, includingPropertiesForKeys: nil)
        for item in snapshotItems {
            let dest = currentRoot.appendingPathComponent(item.lastPathComponent)
            try FileManager.default.copyItem(at: item, to: dest)
        }

        // Recover: must succeed via .rolledBack, NOT .journalCorrupt
        let recoveryStore = TaskStore(rootURL: currentRoot)
        let outcome = try recoveryStore.recoverInterruptedCommit()
        guard case .rolledBack = outcome else {
            XCTFail("Expected .rolledBack, got \(outcome)")
            return
        }

        let tasksA = try recoveryStore.loadMeetingTasks(at: meetingA)
        XCTAssertEqual(tasksA.count, 1)
        XCTAssertEqual(tasksA.first?.title, "Original Task A", "A's previous content must be back")
    }

    // F2-4: recovery inside meeting folder distinguishes access errors
    func testRecoveryInsideMeetingFolderDistinguishesAccessErrorsAndPreservesJournal() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 AccessErrMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let initialTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "AccessErrMeeting",
            meetingDate: Date(),
            title: "Initial Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meeting)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let prevData = try encoder.encode([initialTask])
        let updatedTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "AccessErrMeeting",
            meetingDate: Date(),
            title: "Updated Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        let updatedData = try encoder.encode([updatedTask])

        let meetingFile = meeting.appendingPathComponent("tasks.json")
        let prevFile = meeting.appendingPathComponent("tasks.json.prev")
        try prevData.write(to: prevFile, options: .atomic)
        try updatedData.write(to: meetingFile, options: .atomic)

        // Write a valid journal pointing to an old index digest so rollback is triggered
        let oldIndexData = try Data(contentsOf: tasksDirectory().appendingPathComponent("index.json"))
        let newIndexData = Data("different-index".utf8)
        let journal = TaskCommitJournal(
            version: 1,
            token: UUID().uuidString,
            previousIndexDigest: sha256Hex(oldIndexData),
            indexDigest: sha256Hex(newIndexData),
            entries: [
                TaskCommitJournal.Entry(
                    meetingPath: meeting.resolvingSymlinksInPath().standardizedFileURL.path,
                    hadPrevious: true
                )
            ]
        )
        try writeJournal(journal)

        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meeting.path)
        }

        // Make meeting folder unreadable
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: meeting.path)

        // recoverInterruptedCommit must throw and keep the journal
        XCTAssertThrowsError(try store.recoverInterruptedCommit(), "Access error inside meeting folder must throw")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL().path), "Journal must be kept on access error")

        // Restore permission and recover
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meeting.path)
        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .rolledBack(meetings: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path), "Journal must be deleted after rollback")

        let restoredData = try Data(contentsOf: meetingFile)
        XCTAssertEqual(restoredData, prevData, "tasks.json must equal .prev after rollback")
    }

    // F2-6: tasks.json.restore.tmp cleaned up across recovery and commit
    func testRestoreTmpCleanedUpAcrossRecoveryAndCommit() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 RestoreTmpMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let initialTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "RestoreTmpMeeting",
            meetingDate: Date(),
            title: "Initial Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meeting)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let prevData = try encoder.encode([initialTask])
        let prevFile = meeting.appendingPathComponent("tasks.json.prev")
        let restoreTmp = meeting.appendingPathComponent("tasks.json.restore.tmp")
        try prevData.write(to: prevFile, options: .atomic)
        try Data("leftover-restore-tmp".utf8).write(to: restoreTmp, options: .atomic)

        // Write a valid journal with old index
        let oldIndexData = try Data(contentsOf: tasksDirectory().appendingPathComponent("index.json"))
        let journal = TaskCommitJournal(
            version: 1,
            token: UUID().uuidString,
            previousIndexDigest: sha256Hex(oldIndexData),
            indexDigest: sha256Hex(Data("new-index".utf8)),
            entries: [
                TaskCommitJournal.Entry(
                    meetingPath: meeting.resolvingSymlinksInPath().standardizedFileURL.path,
                    hadPrevious: true
                )
            ]
        )
        try writeJournal(journal)

        // Recovery cleans up restore.tmp
        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .rolledBack(meetings: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreTmp.path), "restore.tmp must be removed by recovery")

        // Place a leftover restore.tmp again and run a successful replaceTasks
        try Data("another-leftover-restore-tmp".utf8).write(to: restoreTmp, options: .atomic)
        let newTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "RestoreTmpMeeting",
            meetingDate: Date(),
            title: "New Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        _ = try store.replaceTasks([newTask], for: meeting)

        // Assert no temp files remain in meeting folder
        for name in ["tasks.json.restore.tmp", "tasks.json.tmp", "tasks.json.prev.tmp", "tasks.json.prev"] {
            let file = meeting.appendingPathComponent(name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "\(name) must not remain in meeting folder")
        }
    }

    // MARK: - F2b-1 Rollback With Unreadable Directory Aborts and Keeps Journal

    func testIndexWriterFailsAndRollbackEncounteringUnreadableDirectoryAbortsAndKeepsJournal() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 UnreadableRollbackMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let initialTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "UnreadableRollbackMeeting",
            meetingDate: Date(),
            title: "Initial Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meeting)

        let prevFile = meeting.appendingPathComponent("tasks.json.prev")
        let tasksFile = meeting.appendingPathComponent("tasks.json")
        let initialData = try Data(contentsOf: tasksFile)

        struct MockIndexFail: LocalizedError, Equatable {
            var errorDescription: String? { "Mock index write failed" }
        }

        let storeWithFailingIndex = TaskStore(
            rootURL: root,
            indexWriter: { _, _ in
                // Flip permissions so meeting folder is unreadable/unsearchable before rollback checks fileState
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: meeting.path)
                throw MockIndexFail()
            },
            fileRemover: nil
        )

        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meeting.path)
        }

        let updatedTask = TaskItem(
            id: initialTask.id,
            meetingURL: meeting,
            meetingTitle: "UnreadableRollbackMeeting",
            meetingDate: Date(),
            title: "Updated Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: initialTask.createdAt,
            completedAt: nil
        )

        XCTAssertThrowsError(try storeWithFailingIndex.replaceTasks([updatedTask], for: meeting)) { error in
            guard case let TaskStoreError.commitFailed(move, rollback) = error else {
                XCTFail("Expected commitFailed, got \(error)")
                return
            }
            XCTAssertTrue(move is MockIndexFail)
            XCTAssertNotNil(rollback)
        }

        // Journal must remain on disk because rollback could not complete safely
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL().path), "Journal must remain on disk when rollback fails to check fileState")

        // Restore permissions so we can inspect and recover
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meeting.path)

        // .prev file must remain intact
        XCTAssertTrue(FileManager.default.fileExists(atPath: prevFile.path), "tasks.json.prev must remain intact")

        // Calling recoverInterruptedCommit after restoring permissions must roll back
        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .rolledBack(meetings: 1))

        // tasks.json must equal the .prev bytes (initialTask)
        let restoredData = try Data(contentsOf: tasksFile)
        XCTAssertEqual(restoredData, initialData)

        // Journal and .prev must be gone
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prevFile.path))
    }

    // MARK: - Fix Round 3: F3-1 Commit Start Guard Uses fileState

    func testInterruptedStateWithUnreadableTasksDirectoryThrowsOnBothCommitAPIsAndRecoversAfterRestore() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 UnreadableTasksDirMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let initialTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "UnreadableTasksDirMeeting",
            meetingDate: Date(),
            title: "Original Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meeting)

        let meetingTasksFile = meeting.appendingPathComponent("tasks.json")
        let meetingTasksPrev = meeting.appendingPathComponent("tasks.json.prev")
        let prevBytes = try Data(contentsOf: meetingTasksFile)

        // Simulate an interrupted commit:
        // meeting has new tasks.json, and tasks.json.prev with old content
        let newTask = TaskItem(
            id: initialTask.id,
            meetingURL: meeting,
            meetingTitle: "UnreadableTasksDirMeeting",
            meetingDate: Date(),
            title: "New Interrupted Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: initialTask.createdAt,
            completedAt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let newMeetingData = try encoder.encode([newTask])

        try prevBytes.write(to: meetingTasksPrev)
        try newMeetingData.write(to: meetingTasksFile)

        // Write a valid journal with mismatched indexDigest so recovery rolls back
        let journal = TaskCommitJournal(
            version: 1,
            token: UUID().uuidString,
            previousIndexDigest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            indexDigest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            entries: [
                TaskCommitJournal.Entry(
                    meetingPath: meeting.resolvingSymlinksInPath().standardizedFileURL.path,
                    hadPrevious: true
                )
            ]
        )
        try writeJournal(journal)

        // Set tasks directory to mode 000
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tasksDirectory().path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tasksDirectory().path)
        }

        // Both commit APIs must throw without changing .prev bytes
        let incomingTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "UnreadableTasksDirMeeting",
            meetingDate: Date(),
            title: "Incoming Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )

        XCTAssertThrowsError(try store.replaceTasks([incomingTask], for: meeting))
        let prevAfterReplace = try Data(contentsOf: meetingTasksPrev)
        XCTAssertEqual(prevAfterReplace, prevBytes, ".prev bytes must remain unchanged after replaceTasks throws")

        XCTAssertThrowsError(try store.appendImported([incomingTask]))
        let prevAfterAppend = try Data(contentsOf: meetingTasksPrev)
        XCTAssertEqual(prevAfterAppend, prevBytes, ".prev bytes must remain unchanged after appendImported throws")

        // Restore permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tasksDirectory().path)

        // recoverInterruptedCommit returns .rolledBack and tasks.json equals .prev
        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .rolledBack(meetings: 1))

        let restoredTasksBytes = try Data(contentsOf: meetingTasksFile)
        XCTAssertEqual(restoredTasksBytes, prevBytes, "tasks.json must equal .prev bytes after rollback")
        XCTAssertFalse(FileManager.default.fileExists(atPath: meetingTasksPrev.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))
    }

    // MARK: - Fix Round 3: F3-2 hadPrevious Computed with fileState

    func testHadPreviousComputedWithFileStateThrowsBeforeJournalExistsWhenDirectoryPermissionsLost() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 HadPreviousMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let initialTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "HadPreviousMeeting",
            meetingDate: Date(),
            title: "Original Content",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meeting)

        let meetingTasksFile = meeting.appendingPathComponent("tasks.json")
        let originalBytes = try Data(contentsOf: meetingTasksFile)

        // Create a stale restore.tmp in meeting
        let staleRestoreTmp = meeting.appendingPathComponent("tasks.json.restore.tmp")
        try Data("stale".utf8).write(to: staleRestoreTmp)

        let storeWithHookRemover = TaskStore(
            rootURL: root,
            indexWriter: nil,
            fileRemover: { url in
                try FileManager.default.removeItem(at: url)
                if url.path.hasSuffix("tasks.json.restore.tmp") {
                    // Right after removing the last stale file, flip meeting directory to 000
                    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: meeting.path)
                }
            }
        )
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meeting.path)
        }

        let updatedTask = TaskItem(
            id: initialTask.id,
            meetingURL: meeting,
            meetingTitle: "HadPreviousMeeting",
            meetingDate: Date(),
            title: "Updated Content",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: initialTask.createdAt,
            completedAt: nil
        )

        // The commit must throw before journal exists
        XCTAssertThrowsError(try storeWithHookRemover.replaceTasks([updatedTask], for: meeting))

        // Journal must NOT exist
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path), "Journal must not exist when hadPrevious fileState fails")

        // Restore permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meeting.path)

        // Original tasks.json preserved
        let currentBytes = try Data(contentsOf: meetingTasksFile)
        XCTAssertEqual(currentBytes, originalBytes, "Original tasks.json must be preserved")
    }

    // MARK: - Fix Round 3: F3-3 Post-Commit Cleanup Access Error Kept in Warnings and Keeps Journal

    func testPostCommitCleanupFailurePreservesJournalAndRecoversRollForward() throws {
        let meeting = root.appendingPathComponent("2026-09-01 1000 PostCommitCleanupMeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)

        let initialTask = TaskItem(
            id: UUID().uuidString,
            meetingURL: meeting,
            meetingTitle: "PostCommitCleanupMeeting",
            meetingDate: Date(),
            title: "Initial Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: Date(),
            completedAt: nil
        )
        try store.replaceTasks([initialTask], for: meeting)

        let storeWithIndexWriter = TaskStore(
            rootURL: root,
            indexWriter: { data, url in
                try data.write(to: url, options: .atomic)
                // Write index successfully, then set meeting directory to 000
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: meeting.path)
            },
            fileRemover: nil
        )
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meeting.path)
        }

        let updatedTask = TaskItem(
            id: initialTask.id,
            meetingURL: meeting,
            meetingTitle: "PostCommitCleanupMeeting",
            meetingDate: Date(),
            title: "New Rolled Forward Task",
            owner: nil,
            due: nil,
            quote: nil,
            status: .open,
            createdAt: initialTask.createdAt,
            completedAt: nil
        )

        // Commit returns with non-empty warnings
        let (items, warnings) = try storeWithIndexWriter.replaceTasks([updatedTask], for: meeting)
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(warnings.isEmpty, "Warnings must be non-empty when cleanup fails")

        // Journal must still be present
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL().path), "Journal must remain on disk when post-commit cleanup fails")

        // Restore permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meeting.path)

        // recoverInterruptedCommit returns .rolledForward
        let outcome = try store.recoverInterruptedCommit()
        XCTAssertEqual(outcome, .rolledForward(meetings: 1))

        // .prev is removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.appendingPathComponent("tasks.json.prev").path))

        // tasks.json keeps the new content
        let tasksOnDisk = try store.loadMeetingTasks(at: meeting)
        XCTAssertEqual(tasksOnDisk.first?.title, "New Rolled Forward Task")

        // Index has the new content
        let indexTasks = try store.loadIndex()
        XCTAssertEqual(indexTasks.first?.title, "New Rolled Forward Task")

        // Journal is deleted after roll forward
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL().path))
    }
}
