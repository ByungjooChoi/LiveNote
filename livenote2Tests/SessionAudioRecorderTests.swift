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
        SessionAudioRecorder.onCancellationExitForTesting = nil
        SessionAudioRecorder.onPurgeBatchDrainedForTesting = nil
        SessionAudioRecorder.beforeEnumerationForTesting = nil
        SessionAudioRecorder.cancelPurgeRetry()
        AppLog.flush()
        AppLog.directoryOverride = TestLogSandbox.directory
        if let tempDir {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
            try? FileManager.default.removeItem(at: tempDir)
        }
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

        XCTAssertEqual(box.count, 1, "Remover should be attempted once and succeed via not-found mapping")
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

    // MARK: - Fix Round 1: F1-7 and F1-8

    func testPurgeRetryCancelledTaskDoesNotClearNewerSchedule() async throws {
        let rootA = tempDir.appendingPathComponent("rootA", isDirectory: true)
        let rootB = tempDir.appendingPathComponent("rootB", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)

        let staleA = rootA.appendingPathComponent("livenote2-session-A", isDirectory: true)
        let staleB = rootB.appendingPathComponent("livenote2-session-B", isDirectory: true)
        try FileManager.default.createDirectory(at: staleA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staleB, withIntermediateDirectories: true)

        let gateA = AsyncTestGate()
        SessionAudioRecorder.onCancellationExitForTesting = {
            await gateA.wait()
        }

        // Schedule A
        let scheduledA = SessionAudioRecorder.schedulePurgeRetry(after: 0.01, in: rootA)
        XCTAssertTrue(scheduledA)

        // Cancel A (triggers cancellation and bumps generation)
        SessionAudioRecorder.cancelPurgeRetry()

        // Schedule B
        let scheduledB = SessionAudioRecorder.schedulePurgeRetry(after: 0.05, in: rootB)
        XCTAssertTrue(scheduledB)

        // Release A's cancellation exit
        await gateA.open()

        // B must still be pending with its roots
        XCTAssertTrue(SessionAudioRecorder.purgeRetryPending, "Task B must remain pending even after Task A exits")

        // Wait for B to finish purging
        var completedB = false
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if !SessionAudioRecorder.purgeRetryPending {
                completedB = true
                break
            }
        }
        XCTAssertTrue(completedB)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleB.path), "staleB must be purged by task B")
    }

    func testPurgeRetryRootsAddedDuringPurgeRunArePurgedInNextIteration() async throws {
        let root1 = tempDir.appendingPathComponent("root1", isDirectory: true)
        let root2 = tempDir.appendingPathComponent("root2", isDirectory: true)
        try FileManager.default.createDirectory(at: root1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root2, withIntermediateDirectories: true)

        let stale1 = root1.appendingPathComponent("livenote2-session-1", isDirectory: true)
        let stale2 = root2.appendingPathComponent("livenote2-session-2", isDirectory: true)
        try FileManager.default.createDirectory(at: stale1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stale2, withIntermediateDirectories: true)

        let holdGate = AsyncTestGate()
        actor FirstBatchTracker {
            var isFirst = true
            func checkFirst() -> Bool {
                if isFirst {
                    isFirst = false
                    return true
                }
                return false
            }
        }
        let tracker = FirstBatchTracker()

        SessionAudioRecorder.onPurgeBatchDrainedForTesting = { _ in
            if await tracker.checkFirst() {
                await holdGate.wait()
            }
        }

        // Schedule first root (delay 0 for fast execution)
        let scheduled1 = SessionAudioRecorder.schedulePurgeRetry(after: 0, in: root1)
        XCTAssertTrue(scheduled1)

        // Yield slightly so task starts and enters onPurgeBatchDrainedForTesting
        try? await Task.sleep(nanoseconds: 10_000_000)

        // While task is held after draining root1, schedule root2
        let scheduled2 = SessionAudioRecorder.schedulePurgeRetry(after: 0, in: root2)
        XCTAssertFalse(scheduled2, "Scheduling a second root while purge task is active must return false")
        XCTAssertTrue(SessionAudioRecorder.purgeRetryPending)

        // Release gate
        await holdGate.open()

        // Wait for both iterations to finish
        var completed = false
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if !SessionAudioRecorder.purgeRetryPending {
                completed = true
                break
            }
        }
        XCTAssertTrue(completed)
        XCTAssertFalse(SessionAudioRecorder.purgeRetryPending, "Pending flag must be cleared at the end")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale1.path), "stale1 must be purged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale2.path), "stale2 must be purged in next iteration")
    }

    // MARK: - Fix Round 2: F2-5 Live check in purgeStale

    func testPurgeStaleLiveCheckPreservesFolderRegisteredAfterStaleFolderExists() throws {
        let staleFolder = tempDir.appendingPathComponent("livenote2-session-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staleFolder, withIntermediateDirectories: true)
        let staleFile = staleFolder.appendingPathComponent("test.txt")
        FileManager.default.createFile(atPath: staleFile.path, contents: Data("stale".utf8))

        // Register a new folder name after the stale folder exists
        let activeFolderName = "livenote2-session-active-\(UUID().uuidString)"
        let activeFolder = tempDir.appendingPathComponent(activeFolderName, isDirectory: true)
        SessionAudioRecorder.registerActiveFolderForTesting(activeFolderName)
        defer {
            SessionAudioRecorder.unregisterActiveFolderForTesting(activeFolderName)
        }

        // Folder is created on disk between registration and purge
        try FileManager.default.createDirectory(at: activeFolder, withIntermediateDirectories: true)
        let activeFile = activeFolder.appendingPathComponent("active.txt")
        FileManager.default.createFile(atPath: activeFile.path, contents: Data("active".utf8))

        // purgeStale without explicit excluding set: checks activeFolders live
        SessionAudioRecorder.purgeStale(in: tempDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFolder.path), "Stale folder must be removed by purgeStale")
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeFolder.path), "Registered folder must be kept by purgeStale live check")
    }

    // MARK: - Fix Round 3: F3-4 deleteFiles Direct Removal and Error Mapping

    func testDeleteFilesUnreadableRootAttemptsRemovalAndSchedulesPurgeRetry() async throws {
        let recorder = SessionAudioRecorder(rootDirectory: tempDir)
        await recorder.start()
        let folder = recorder.sessionFolder
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        // Remove search permissions on tempDir so removeItem cannot access folder
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tempDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        }

        await recorder.deleteFiles(retryDelays: [0.01], purgeRetryDelay: 0.05)

        XCTAssertFalse(SessionAudioRecorder.isActiveFolder(folder), "Folder must be unregistered after last attempt fails")
        XCTAssertTrue(SessionAudioRecorder.purgeRetryPending, "Purge retry must be pending")

        // Restore permissions so scheduled purge can succeed
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)

        // Wait up to 1s for scheduled purge to complete
        var completed = false
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if !SessionAudioRecorder.purgeRetryPending {
                completed = true
                break
            }
        }
        XCTAssertTrue(completed, "Purge retry must complete and clear flag")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "Folder must be removed by scheduled purge")
    }

    // MARK: - Fix Round 3: F3-5 purgeStale beforeEnumerationForTesting Live Check

    func testPurgeStaleBeforeEnumerationHookPreservesDynamicallyRegisteredFolder() throws {
        let staleFolder = tempDir.appendingPathComponent("livenote2-session-stale-hook", isDirectory: true)
        try FileManager.default.createDirectory(at: staleFolder, withIntermediateDirectories: true)
        let staleFile = staleFolder.appendingPathComponent("stale.txt")
        FileManager.default.createFile(atPath: staleFile.path, contents: Data("stale".utf8))

        let activeName = "livenote2-session-active-hook-\(UUID().uuidString)"
        let activeFolder = tempDir.appendingPathComponent(activeName, isDirectory: true)

        SessionAudioRecorder.beforeEnumerationForTesting = {
            SessionAudioRecorder.registerActiveFolderForTesting(activeName)
            try? FileManager.default.createDirectory(at: activeFolder, withIntermediateDirectories: true)
            let activeFile = activeFolder.appendingPathComponent("active.txt")
            FileManager.default.createFile(atPath: activeFile.path, contents: Data("active".utf8))
        }
        defer {
            SessionAudioRecorder.unregisterActiveFolderForTesting(activeName)
            SessionAudioRecorder.beforeEnumerationForTesting = nil
        }

        SessionAudioRecorder.purgeStale(in: tempDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFolder.path), "Stale folder must be removed by purgeStale")
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeFolder.path), "Folder registered in beforeEnumeration hook must be preserved")
    }

    // MARK: - Fix Round 4: F4-1 Single-use recorder and start after deleteFiles

    func testSingleUseRecorderSequenceStartAppendDeleteStartAppendDelete() async throws {
        let recorder = SessionAudioRecorder(rootDirectory: tempDir)
        let folder = recorder.sessionFolder

        // 1. Initial start & append
        await recorder.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(SessionAudioRecorder.isActiveFolder(folder))
        await recorder.append([0.1, 0.2, 0.3], channel: .me)

        // 2. Initial deleteFiles
        await recorder.deleteFiles(retryDelays: [0.01])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(SessionAudioRecorder.isActiveFolder(folder))

        // Check: start after deleteFiles creates no files (directory listing of root is empty)
        await recorder.start()
        let contentsAfterSecondStart = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(contentsAfterSecondStart.isEmpty, "start after deleteFiles must create no files")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(SessionAudioRecorder.isActiveFolder(folder))

        // 3. Append on inert instance is a no-op
        await recorder.append([0.4, 0.5], channel: .me)
        let contentsAfterSecondAppend = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(contentsAfterSecondAppend.isEmpty, "append after deleteFiles must create no files")

        // 4. Second deleteFiles is a no-op
        await recorder.deleteFiles(retryDelays: [0.01])

        // Assertions after the sequence:
        // - folder does not exist
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "Folder must not exist after sequence")
        // - folder name is not registered
        XCTAssertFalse(SessionAudioRecorder.isActiveFolder(folder), "Folder must not be registered in active folders")
        // - purgeStale with explicit empty exclusion set finds nothing to remove
        SessionAudioRecorder.purgeStale(in: tempDir, excluding: [])
        let contentsAfterPurge = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(contentsAfterPurge.isEmpty, "Root directory must remain empty with nothing for purgeStale to remove")
        // - purgeRetryPending is false
        XCTAssertFalse(SessionAudioRecorder.purgeRetryPending, "purgeRetryPending must be false")
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
