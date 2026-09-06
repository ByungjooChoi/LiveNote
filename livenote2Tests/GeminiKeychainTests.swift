import XCTest
import Security
@testable import LiveNote

final class FakeKeychainAPI: KeychainAPI, @unchecked Sendable {
    var calls: [String] = []
    var storage: [String: Data] = [:]
    var copyMatchingStatusOverride: OSStatus?
    var addStatusOverride: OSStatus?
    var updateStatusOverride: OSStatus?
    var deleteStatusOverride: OSStatus?

    func key(from query: CFDictionary) -> String {
        let dict = query as NSDictionary
        let service = (dict[kSecAttrService as String] as? String) ?? ""
        let account = (dict[kSecAttrAccount as String] as? String) ?? ""
        return "\(service):\(account)"
    }

    func add(_ query: CFDictionary) -> OSStatus {
        calls.append("add")
        if let override = addStatusOverride { return override }
        let dict = query as NSDictionary
        let k = key(from: query)
        if storage[k] != nil {
            return errSecDuplicateItem
        }
        guard let data = dict[kSecValueData as String] as? Data else {
            return errSecParam
        }
        storage[k] = data
        return errSecSuccess
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        calls.append("update")
        if let override = updateStatusOverride { return override }
        let k = key(from: query)
        guard storage[k] != nil else {
            return errSecItemNotFound
        }
        let attrDict = attributes as NSDictionary
        guard let data = attrDict[kSecValueData as String] as? Data else {
            return errSecParam
        }
        storage[k] = data
        return errSecSuccess
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        calls.append("copyMatching")
        if let override = copyMatchingStatusOverride { return override }
        let k = key(from: query)
        guard let data = storage[k] else {
            return errSecItemNotFound
        }
        result?.pointee = data as CFData
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        calls.append("delete")
        if let override = deleteStatusOverride { return override }
        let k = key(from: query)
        guard storage[k] != nil else {
            return errSecItemNotFound
        }
        storage.removeValue(forKey: k)
        return errSecSuccess
    }
}

final class GeminiKeychainTests: XCTestCase {

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

    func testRealKeychainRoundTrip() throws {
        let testService = "com.byungjoo.livenote2.test.\(UUID().uuidString)"
        let keychain = GeminiKeychain(service: testService)
        addTeardownBlock {
            try? keychain.delete()
        }

        XCTAssertNil(try keychain.load())

        try keychain.save("secret-key-1")
        XCTAssertEqual(try keychain.load(), "secret-key-1")

        try keychain.save("secret-key-2")
        XCTAssertEqual(try keychain.load(), "secret-key-2")

        try keychain.delete()
        XCTAssertNil(try keychain.load())
    }

    func testLoadWhenCopyMatchingReturnsAuthFailedThrowsAccessDenied() {
        let fake = FakeKeychainAPI()
        fake.copyMatchingStatusOverride = errSecAuthFailed
        let keychain = GeminiKeychain(service: "test-service", api: fake)

        XCTAssertThrowsError(try keychain.load()) { error in
            XCTAssertEqual(error as? GeminiKeychainError, .accessDenied(errSecAuthFailed))
        }
    }

    func testLoadWhenCopyMatchingReturnsDecodeErrorThrowsReadFailed() {
        let fake = FakeKeychainAPI()
        fake.copyMatchingStatusOverride = errSecDecode
        let keychain = GeminiKeychain(service: "test-service", api: fake)

        XCTAssertThrowsError(try keychain.load()) { error in
            XCTAssertEqual(error as? GeminiKeychainError, .readFailed(errSecDecode))
        }
    }

    func testLoadWhenItemNotFoundReturnsNil() throws {
        let fake = FakeKeychainAPI()
        fake.copyMatchingStatusOverride = errSecItemNotFound
        let keychain = GeminiKeychain(service: "test-service", api: fake)

        XCTAssertNil(try keychain.load())
    }

    func testLoadWhenDataCorruptThrowsCorruptData() {
        let fake = FakeKeychainAPI()
        fake.storage["test-service:apiKey"] = Data([0xFF, 0xFE, 0xFD])
        let keychain = GeminiKeychain(service: "test-service", api: fake)

        XCTAssertThrowsError(try keychain.load()) { error in
            XCTAssertEqual(error as? GeminiKeychainError, .corruptData)
        }
    }

    func testLoadWhenDataEmptyThrowsInvalidKeyData() {
        let fake = FakeKeychainAPI()
        fake.storage["test-service:apiKey"] = Data()
        let keychain = GeminiKeychain(service: "test-service", api: fake)

        XCTAssertThrowsError(try keychain.load()) { error in
            XCTAssertEqual(error as? GeminiKeychainError, .invalidKeyData)
        }
    }

    func testLoadWhenDataWhitespaceOnlyThrowsInvalidKeyData() {
        let fake = FakeKeychainAPI()
        fake.storage["test-service:apiKey"] = "   ".data(using: .utf8)
        let keychain = GeminiKeychain(service: "test-service", api: fake)

        XCTAssertThrowsError(try keychain.load()) { error in
            XCTAssertEqual(error as? GeminiKeychainError, .invalidKeyData)
        }
    }

    func testExactProductionBugThrowsAccessDeniedAndPreservesItem() {
        let fake = FakeKeychainAPI()
        fake.storage["test-service:apiKey"] = "old-key".data(using: .utf8)
        fake.updateStatusOverride = errSecAuthFailed

        let keychain = GeminiKeychain(service: "test-service", api: fake)
        XCTAssertThrowsError(try keychain.save("new-key")) { error in
            XCTAssertEqual(error as? GeminiKeychainError, .accessDenied(errSecAuthFailed))
        }
        XCTAssertEqual(fake.storage["test-service:apiKey"], "old-key".data(using: .utf8))
        XCTAssertEqual(fake.calls, ["update"])
    }

    func testUpdateItemNotFoundAndAddDuplicateThrowsInaccessibleItem() {
        let fake = FakeKeychainAPI()
        fake.updateStatusOverride = errSecItemNotFound
        fake.addStatusOverride = errSecDuplicateItem

        let keychain = GeminiKeychain(service: "test-service", api: fake)
        XCTAssertThrowsError(try keychain.save("new-key")) { error in
            XCTAssertEqual(error as? GeminiKeychainError, .inaccessibleItem(errSecDuplicateItem))
        }
        XCTAssertEqual(fake.calls, ["update", "add"])
    }

    func testUpdateReturnsItemNotFoundCallsAddAndSucceeds() throws {
        let fake = FakeKeychainAPI()
        let keychain = GeminiKeychain(service: "test-service", api: fake)

        try keychain.save("my-api-key")
        XCTAssertEqual(fake.storage["test-service:apiKey"], "my-api-key".data(using: .utf8))
        XCTAssertEqual(fake.calls, ["update", "add"])
    }

    func testAddReturnsParamErrorThrowsWriteFailed() {
        let fake = FakeKeychainAPI()
        fake.updateStatusOverride = errSecItemNotFound
        fake.addStatusOverride = errSecParam
        let keychain = GeminiKeychain(service: "test-service", api: fake)

        XCTAssertThrowsError(try keychain.save("new-key")) { error in
            XCTAssertEqual(error as? GeminiKeychainError, .writeFailed(errSecParam))
        }
        XCTAssertEqual(fake.calls, ["update", "add"])
    }

    func testDeleteWhenItemAbsentDoesNotThrow() throws {
        let fake = FakeKeychainAPI()
        fake.deleteStatusOverride = errSecItemNotFound
        let keychain = GeminiKeychain(service: "test-service", api: fake)

        XCTAssertNoThrow(try keychain.delete())
    }
}
