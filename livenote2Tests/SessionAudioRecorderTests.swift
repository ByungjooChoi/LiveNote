import XCTest
@testable import LiveNote

final class SessionAudioRecorderTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionAudioRecorderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        AppLog.directoryOverride = tempDir.appendingPathComponent("logs")
    }

    override func tearDown() {
        AppLog.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
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
