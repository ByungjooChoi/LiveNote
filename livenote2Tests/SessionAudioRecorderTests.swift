import XCTest
@testable import LiveNote

final class SessionAudioRecorderTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        TestLogSandbox.activate()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionAudioRecorderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        SessionAudioRecorder.cancelPurgeRetry()
        AppLog.flush()
        AppLog.directoryOverride = TestLogSandbox.directory
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - S2 (a): Remover fails twice then succeeds

    func testDeleteFilesRemoverFailsTwiceThenSucceeds() async throws {
        final class CounterBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return _count
            }
            func increment() -> Int {
                lock.lock()
                defer { lock.unlock() }
                _count += 1
                return _count
            }
        }

        let box = CounterBox()
        struct MockError: LocalizedError {
            var errorDescription: String? { "remover mock failure" }
        }

        let recorder = SessionAudioRecorder(rootDirectory: tempDir, remover: { url in
            let c = box.increment()
            if c < 3 {
                throw MockError()
            }
            try FileManager.default.removeItem(at: url)
        })

        await recorder.start()
        let folder = recorder.sessionFolder
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        await recorder.deleteFiles(retryDelays: [0.01, 0.01], purgeRetryDelay: 0.05)

        XCTAssertEqual(box.count, 3, "Remover should have been attempted 3 times")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "Folder must be removed on third attempt")
        XCTAssertFalse(SessionAudioRecorder.purgeRetryPending, "Purge retry must not be pending on success")
        XCTAssertFalse(SessionAudioRecorder.isActiveFolder(folder))
    }

    // MARK: - S2 (b): Remover always fails schedules purge retry which clears all roots

    func testDeleteFilesRemoverAlwaysFailsSchedulesPurgeRetry() async throws {
        final class CounterBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return _count
            }
            func increment() {
                lock.lock()
                _count += 1
                lock.unlock()
            }
        }

        let box = CounterBox()
        struct AlwaysFailError: LocalizedError {
            var errorDescription: String? { "always fails" }
        }

        let recorder = SessionAudioRecorder(rootDirectory: tempDir, remover: { _ in
            box.increment()
            throw AlwaysFailError()
        })

        await recorder.start()
        let folderA = recorder.sessionFolder
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderA.path))

        let anotherRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionAudioRecorderTests-root2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: anotherRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: anotherRoot) }

        let folderB = anotherRoot.appendingPathComponent("livenote2-session-B", isDirectory: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)

        let delays: [TimeInterval] = [0.01, 0.01]
        await recorder.deleteFiles(retryDelays: delays, purgeRetryDelay: 0.05)

        XCTAssertEqual(box.count, delays.count + 1, "Must attempt 1 + delays.count times")
        XCTAssertFalse(SessionAudioRecorder.isActiveFolder(folderA), "Failed folder must be unregistered")
        XCTAssertTrue(SessionAudioRecorder.purgeRetryPending, "Purge retry must be pending")

        // Second call while pending returns false
        let secondScheduled = SessionAudioRecorder.schedulePurgeRetry(after: 0.05, in: anotherRoot)
        XCTAssertFalse(secondScheduled, "Subsequent schedule while pending must return false")

        // Wait up to 1s for purge to run
        var completed = false
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if !SessionAudioRecorder.purgeRetryPending {
                completed = true
                break
            }
        }

        XCTAssertTrue(completed, "Purge retry must complete within 1s")
        XCTAssertFalse(SessionAudioRecorder.purgeRetryPending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderA.path), "folderA must be purged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderB.path), "folderB must be purged")
    }

    // MARK: - S2 (c): cancelPurgeRetry while pending clears flag and leaves folder

    func testCancelPurgeRetryClearsFlagAndLeavesFolder() async throws {
        struct AlwaysFailError: LocalizedError {
            var errorDescription: String? { "always fails" }
        }

        let recorder = SessionAudioRecorder(rootDirectory: tempDir, remover: { _ in
            throw AlwaysFailError()
        })

        await recorder.start()
        let folder = recorder.sessionFolder
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        await recorder.deleteFiles(retryDelays: [0.01], purgeRetryDelay: 10.0)

        XCTAssertTrue(SessionAudioRecorder.purgeRetryPending, "Purge retry must be pending")
        SessionAudioRecorder.cancelPurgeRetry()
        XCTAssertFalse(SessionAudioRecorder.purgeRetryPending, "Flag must be cleared after cancellation")

        // Folder remains in place
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "Folder must remain in place")
    }

    // MARK: - S2 (d): Folder already removed by someone else

    func testDeleteFilesFolderAlreadyRemovedSucceedsImmediately() async throws {
        final class CounterBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return _count
            }
            func increment() {
                lock.lock()
                _count += 1
                lock.unlock()
            }
        }

        let box = CounterBox()
        let recorder = SessionAudioRecorder(rootDirectory: tempDir, remover: { url in
            box.increment()
            try FileManager.default.removeItem(at: url)
        })

        await recorder.start()
        let folder = recorder.sessionFolder
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        // Pre-remove the folder externally
        try FileManager.default.removeItem(at: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

        await recorder.deleteFiles(retryDelays: [0.01, 0.01], purgeRetryDelay: 0.05)

        XCTAssertEqual(box.count, 0, "Remover should not be called if folder does not exist")
        XCTAssertFalse(SessionAudioRecorder.purgeRetryPending, "No purge retry should be scheduled")
        XCTAssertFalse(SessionAudioRecorder.isActiveFolder(folder))
    }

    // MARK: - S2 (e): Two overlapping deleteFiles calls invoke remover once

    func testOverlappingDeleteFilesInvokesRemoverOnce() async throws {
        final class CounterBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return _count
            }
            func increment() {
                lock.lock()
                _count += 1
                lock.unlock()
            }
        }

        let box = CounterBox()
        let recorder = SessionAudioRecorder(rootDirectory: tempDir, remover: { url in
            box.increment()
            // Artificial delay inside remover
            Thread.sleep(forTimeInterval: 0.05)
            try FileManager.default.removeItem(at: url)
        })

        await recorder.start()

        async let task1: Void = recorder.deleteFiles(retryDelays: [0.01], purgeRetryDelay: 0.05)
        async let task2: Void = recorder.deleteFiles(retryDelays: [0.01], purgeRetryDelay: 0.05)

        _ = await (task1, task2)

        XCTAssertEqual(box.count, 1, "Remover must only be invoked once across overlapping calls")
    }

    // MARK: - T1: purgeStale with explicit exclusion set

    func testPurgeStaleWithExclusion() throws {
        let folderA = tempDir.appendingPathComponent("livenote2-session-A", isDirectory: true)
        let folderB = tempDir.appendingPathComponent("livenote2-session-B", isDirectory: true)
        let otherFolder = tempDir.appendingPathComponent("other-folder", isDirectory: true)

        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)

        SessionAudioRecorder.purgeStale(in: tempDir, excluding: ["livenote2-session-A"])

        XCTAssertTrue(FileManager.default.fileExists(atPath: folderA.path), "folderA must be preserved because it is excluded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderB.path), "folderB must be purged")
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherFolder.path), "non-session folder must not be touched")
    }

    // MARK: - T2: Guarded cleanup timeout retains folder until async deletion finishes

    func testGuardedCleanupTimeoutPreservesActiveFolderDuringPurgeStale() async throws {
        let recorder = SessionAudioRecorder(rootDirectory: tempDir)
        let folder = recorder.sessionFolder
        let gate = AsyncTestGate()

        await recorder.start()
        await recorder.append([0.1, 0.2, 0.3], channel: .me)
        _ = await recorder.finish()

        let cleanupTask = Task {
            await AppState.runGuardedCleanup(
                hardLimitSeconds: 0.2,
                work: {
                    await gate.wait()
                },
                deleteFiles: {
                    await recorder.deleteFiles()
                },
                markRetained: {
                    await recorder.markRetainedUntilRestart()
                }
            )
        }

        let completedInTime = await cleanupTask.value
        XCTAssertFalse(completedInTime, "Guarded cleanup should return false due to timeout")

        // Registry-based purgeStale should skip the active recorder's folder
        SessionAudioRecorder.purgeStale(in: tempDir)

        let markerURL = folder.appendingPathComponent("retained-until-restart")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "Folder must still exist after purgeStale while active")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path), "Retained marker must exist")
        XCTAssertTrue(SessionAudioRecorder.isActiveFolder(folder), "Folder must be considered active in registry")

        // Open gate to let inner background deletion finish
        await gate.open()

        var isDeleted = false
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms * 40 = 2s max
            if !FileManager.default.fileExists(atPath: folder.path) {
                isDeleted = true
                break
            }
        }

        XCTAssertTrue(isDeleted, "Folder must be deleted once inner work finishes")
        XCTAssertFalse(SessionAudioRecorder.isActiveFolder(folder), "Folder must be unregistered after deletion")

        // Second purgeStale is a no-op and does not crash
        SessionAudioRecorder.purgeStale(in: tempDir)
    }

    // MARK: - T3: Stale folder with retained marker from previous process is purged

    func testPurgeStaleRemovesUnregisteredRetainedFolder() throws {
        let staleFolder = tempDir.appendingPathComponent("livenote2-session-stale-prev-process", isDirectory: true)
        try FileManager.default.createDirectory(at: staleFolder, withIntermediateDirectories: true)
        let marker = staleFolder.appendingPathComponent("retained-until-restart")
        FileManager.default.createFile(atPath: marker.path, contents: nil)

        XCTAssertFalse(SessionAudioRecorder.isActiveFolder(staleFolder), "Stale folder from previous process is not active")

        SessionAudioRecorder.purgeStale(in: tempDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFolder.path), "Unregistered retained folder must be purged")
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { cont in
            continuations.append(cont)
        }
    }

    func open() {
        isOpen = true
        for cont in continuations {
            cont.resume()
        }
        continuations.removeAll()
    }
}
