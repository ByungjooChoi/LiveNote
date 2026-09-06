import XCTest
import Security
@testable import LiveNote

@MainActor
final class GeminiKeyControllerTests: XCTestCase {

    private var tempDir: URL!
    private var previousLogOverride: URL?

    override func setUp() {
        super.setUp()
        TestLogSandbox.activate()
        previousLogOverride = AppLog.directoryOverride
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        AppLog.directoryOverride = tempDir
    }

    override func tearDown() {
        AppLog.flush()
        AppLog.directoryOverride = previousLogOverride
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testProductionBugUpdateAuthFailedKeepsOldStorageAndSetsError() {
        let fake = FakeKeychainAPI()
        let service = "test-service"
        fake.storage["\(service):apiKey"] = "old-key".data(using: .utf8)
        let keychain = GeminiKeychain(service: service, api: fake)
        let controller = GeminiKeyController(keychain: keychain)

        let loaded = controller.load()
        XCTAssertEqual(loaded, "old-key")
        XCTAssertTrue(controller.hasKey)
        XCTAssertNil(controller.errorText)

        fake.updateStatusOverride = errSecAuthFailed
        let saved = controller.save("new-key")

        XCTAssertFalse(saved)
        XCTAssertTrue(controller.showPrompt)
        XCTAssertNotNil(controller.errorText)
        XCTAssertTrue(controller.errorText?.contains("-25293") == true)
        XCTAssertTrue(controller.hasKey)
        XCTAssertEqual(fake.storage["\(service):apiKey"], "old-key".data(using: .utf8))
    }

    func testSaveEmptyOrWhitespaceInputSetsErrorAndKeepsPromptOpen() {
        let fake = FakeKeychainAPI()
        let service = "test-service"
        let keychain = GeminiKeychain(service: service, api: fake)
        let controller = GeminiKeyController(keychain: keychain)

        let savedEmpty = controller.save("")
        XCTAssertFalse(savedEmpty)
        XCTAssertEqual(controller.errorText, "Enter a Gemini API key.")
        XCTAssertTrue(controller.showPrompt)
        XCTAssertFalse(controller.hasKey)

        let savedWhitespace = controller.save("   \n\t  ")
        XCTAssertFalse(savedWhitespace)
        XCTAssertEqual(controller.errorText, "Enter a Gemini API key.")
        XCTAssertTrue(controller.showPrompt)
        XCTAssertFalse(controller.hasKey)
    }

    func testFailedSaveLeavesHasKeyFalseAndShowPromptTrue() {
        let fake = FakeKeychainAPI()
        let service = "test-service"
        fake.updateStatusOverride = errSecItemNotFound
        fake.addStatusOverride = errSecParam
        let keychain = GeminiKeychain(service: service, api: fake)
        let controller = GeminiKeyController(keychain: keychain)

        XCTAssertFalse(controller.hasKey)
        let saved = controller.save("some-invalid-key")

        XCTAssertFalse(saved)
        XCTAssertFalse(controller.hasKey)
        XCTAssertTrue(controller.showPrompt)
        XCTAssertNotNil(controller.errorText)
    }

    func testSuccessPathSavesKeyAndLoadsSuccessfully() {
        let fake = FakeKeychainAPI()
        let service = "test-service"
        let keychain = GeminiKeychain(service: service, api: fake)
        let controller = GeminiKeyController(keychain: keychain)

        controller.showPrompt = true
        let saved = controller.save("my-secret-key")

        XCTAssertTrue(saved)
        XCTAssertFalse(controller.showPrompt)
        XCTAssertTrue(controller.hasKey)
        XCTAssertNil(controller.errorText)
        XCTAssertEqual(controller.load(), "my-secret-key")
    }

    func testRemoveFailureKeepsShowPromptTrueWithError() {
        let fake = FakeKeychainAPI()
        let service = "test-service"
        fake.storage["\(service):apiKey"] = "existing-key".data(using: .utf8)
        fake.deleteStatusOverride = errSecAuthFailed
        let keychain = GeminiKeychain(service: service, api: fake)
        let controller = GeminiKeyController(keychain: keychain)

        controller.refresh()
        XCTAssertTrue(controller.hasKey)

        let removed = controller.remove()

        XCTAssertFalse(removed)
        XCTAssertTrue(controller.showPrompt)
        XCTAssertNotNil(controller.errorText)
    }

    func testLoadFailureSetsErrorAndHasKeyFalseAndSubsequentSuccessClearsError() {
        let fake = FakeKeychainAPI()
        let service = "test-service"
        fake.copyMatchingStatusOverride = errSecAuthFailed
        let keychain = GeminiKeychain(service: service, api: fake)
        let controller = GeminiKeyController(keychain: keychain)

        let initialLoad = controller.load()
        XCTAssertNil(initialLoad)
        XCTAssertFalse(controller.hasKey)
        XCTAssertNotNil(controller.errorText)

        fake.copyMatchingStatusOverride = nil
        fake.storage["\(service):apiKey"] = "valid-key".data(using: .utf8)

        let secondLoad = controller.load()
        XCTAssertEqual(secondLoad, "valid-key")
        XCTAssertTrue(controller.hasKey)
        XCTAssertNil(controller.errorText)
    }
}
