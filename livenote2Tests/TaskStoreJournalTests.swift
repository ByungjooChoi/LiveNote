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
        if let root { try? FileManager.default.removeItem(at: root) }
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

        let originalData = Data("original meeting tasks".utf8)
        let meetingTasks = meeting.appendingPathComponent("tasks.json")
        try originalData.write(to: meetingTasks, options: .atomic)

        try FileManager.default.createDirectory(at: tasksDirectory(), withIntermediateDirectories: true)
        // Make tasks directory read-only
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

        XCTAssertThrowsError(try store.replaceTasks([incomingTask], for: meeting))

        let meetingTasksAfter = try Data(contentsOf: meetingTasks)
        XCTAssertEqual(meetingTasksAfter, originalData, "Meeting tasks must not change when journal write fails")
    }
}
