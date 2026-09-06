import XCTest
@testable import LiveNote

@MainActor
final class AppLogSandboxTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppLog.directoryOverride = nil
        TestLogSandbox.activate()
    }

    override func tearDown() {
        AppLog.flush()
        AppLog.directoryOverride = nil
        TestLogSandbox.activate()
        super.tearDown()
    }

    func testMakeStoreActivatesSandboxAndWritesLog() throws {
        AppLog.directoryOverride = nil
        let store = try MeetingStoreFixture.makeStore()
        defer { MeetingStoreFixture.cleanUp(store) }

        XCTAssertEqual(AppLog.directoryOverride, TestLogSandbox.directory)

        let probeMessage = "sandbox probe \(UUID().uuidString)"
        AppLog.write("app", probeMessage)
        AppLog.flush()

        let logURL = TestLogSandbox.directory.appendingPathComponent("app.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        let content = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(content.contains(probeMessage))
    }

    func testReactivatingAfterNilRestoresSandbox() {
        AppLog.directoryOverride = nil
        XCTAssertNil(AppLog.directoryOverride)

        TestLogSandbox.activate()
        XCTAssertEqual(AppLog.directoryOverride, TestLogSandbox.directory)
    }

    func testCustomOverridePreserved() {
        let customDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CustomLogDir-\(UUID().uuidString)", isDirectory: true)
        AppLog.directoryOverride = customDir
        defer {
            AppLog.directoryOverride = nil
            TestLogSandbox.activate()
            try? FileManager.default.removeItem(at: customDir)
        }

        TestLogSandbox.activate()
        XCTAssertEqual(AppLog.directoryOverride, customDir)
    }
}
