import Foundation
import Security

/// SecItem 호출을 감싸는 얇은 프로토콜 (테스트에서 ACL 실패 상태를 주입하기 위함)
protocol KeychainAPI: Sendable {
    func add(_ query: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

struct SystemKeychainAPI: KeychainAPI {
    func add(_ query: CFDictionary) -> OSStatus {
        SecItemAdd(query, nil)
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

enum GeminiKeychainError: LocalizedError, Equatable {
    case accessDenied(OSStatus)   // errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled(-128), errSecNotAvailable 등
    case writeFailed(OSStatus)    // add/update 기타 실패
    case readFailed(OSStatus)     // copyMatching 기타 실패
    case corruptData
    case invalidKeyData
    case inaccessibleItem(OSStatus)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let status):
            let msg = (SecCopyErrorMessageString(status, nil) as String?) ?? "Unknown error"
            return "Keychain denied access to the saved key (\(msg), \(status)). The entry was created by an earlier LiveNote build. Open Keychain Access, delete the item '\(GeminiKeychain.defaultService)', then save the key again."
        case .writeFailed(let status):
            let msg = (SecCopyErrorMessageString(status, nil) as String?) ?? "Unknown error"
            return "Keychain could not store the key (\(msg), \(status))."
        case .readFailed(let status):
            let msg = (SecCopyErrorMessageString(status, nil) as String?) ?? "Unknown error"
            return "Keychain read failed (\(msg), \(status)). Try again; if it persists, remove and re-add the key."
        case .corruptData:
            return "The saved key data in Keychain is corrupted (status 0). Please remove and re-add the key."
        case .invalidKeyData:
            return "Keychain holds an empty key entry (status 0). Remove it and save the key again."
        case .inaccessibleItem(let status):
            let msg = (SecCopyErrorMessageString(status, nil) as String?) ?? "Unknown error"
            return "An existing key entry exists but this build cannot access it (\(msg), \(status)). Open Keychain Access, delete '\(GeminiKeychain.defaultService)', then save again."
        }
    }
}

struct GeminiKeychain: Sendable {
    static let defaultService = "com.byungjoo.livenote2.gemini"   // never change
    static let account = "apiKey"
    static let shared = GeminiKeychain()

    let service: String
    let api: KeychainAPI

    init(service: String = defaultService, api: KeychainAPI = SystemKeychainAPI()) {
        self.service = service
        self.api = api
    }

    /// nil = 항목 없음(errSecItemNotFound). 손상/빈 데이터는 에러 throw. 그 외 실패는 throw.
    func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = api.copyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, let str = String(data: data, encoding: .utf8) else {
                AppLog.write("cloud", "Keychain load 실패: corruptData (status=0)")
                throw GeminiKeychainError.corruptData
            }
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                AppLog.write("cloud", "Keychain load 실패: invalidKeyData (status=0)")
                throw GeminiKeychainError.invalidKeyData
            }
            return trimmed
        }
        if status == errSecItemNotFound {
            return nil
        }
        AppLog.write("cloud", "Keychain load 실패 (status=\(status))")
        if Self.isAccessDeniedStatus(status) {
            throw GeminiKeychainError.accessDenied(status)
        } else {
            throw GeminiKeychainError.readFailed(status)
        }
    }

    /// 기존 항목이 있으면 SecItemUpdate로 갱신, 없으면(errSecItemNotFound) SecItemAdd.
    /// 앱은 갱신할 수 없는 항목을 임의로 삭제하지 않는다.
    func save(_ key: String) throws {
        guard let data = key.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = api.update(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            AppLog.write("cloud", "API key saved to keychain")
            return
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = api.add(addQuery as CFDictionary)
            if addStatus == errSecSuccess {
                AppLog.write("cloud", "API key saved to keychain")
                return
            }
            AppLog.write("cloud", "Keychain add 실패 (status=\(addStatus))")
            if addStatus == errSecDuplicateItem {
                throw GeminiKeychainError.inaccessibleItem(addStatus)
            } else if Self.isAccessDeniedStatus(addStatus) {
                throw GeminiKeychainError.accessDenied(addStatus)
            } else {
                throw GeminiKeychainError.writeFailed(addStatus)
            }
        }

        AppLog.write("cloud", "Keychain update 실패 (status=\(updateStatus))")
        if Self.isAccessDeniedStatus(updateStatus) {
            throw GeminiKeychainError.accessDenied(updateStatus)
        } else {
            throw GeminiKeychainError.writeFailed(updateStatus)
        }
    }

    /// errSecItemNotFound는 성공으로 취급.
    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
        let status = api.delete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            AppLog.write("cloud", "API key deleted")
            return
        }
        AppLog.write("cloud", "Keychain delete 실패 (status=\(status))")
        if Self.isAccessDeniedStatus(status) {
            throw GeminiKeychainError.accessDenied(status)
        } else {
            throw GeminiKeychainError.writeFailed(status)
        }
    }

    private static func isAccessDeniedStatus(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed
            || status == errSecInteractionNotAllowed
            || status == -128 // errSecUserCanceled
            || status == errSecNotAvailable
    }
}
