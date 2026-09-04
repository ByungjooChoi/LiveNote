import Foundation
import Observation

@MainActor
@Observable
final class GeminiKeyController {
    private(set) var hasKey = false
    var errorText: String?
    var showPrompt = false

    @ObservationIgnored private let keychain: GeminiKeychain
    @ObservationIgnored private var didLogKeychainLoadError = false

    init(keychain: GeminiKeychain = .shared) {
        self.keychain = keychain
    }

    /// nil on not-found or failure; sets hasKey/errorText; logs failure once per launch
    @discardableResult
    func load() -> String? {
        do {
            let key = try keychain.load()
            errorText = nil
            hasKey = (key != nil && !key!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            return key
        } catch {
            errorText = error.localizedDescription
            hasKey = false
            if !didLogKeychainLoadError {
                didLogKeychainLoadError = true
                AppLog.write("cloud", "Gemini 키 로드 실패: \(error.localizedDescription)")
            }
            return nil
        }
    }

    func refresh() {
        _ = load()
    }

    /// trims; empty -> sets errorText = "Enter a Gemini API key.", showPrompt = true, returns false; success -> hasKey = true, errorText = nil, showPrompt = false, returns true; failure -> errorText = message, showPrompt stays true, returns false
    @discardableResult
    func save(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            errorText = "Enter a Gemini API key."
            showPrompt = true
            return false
        }
        do {
            try keychain.save(trimmed)
            hasKey = true
            errorText = nil
            showPrompt = false
            return true
        } catch {
            errorText = error.localizedDescription
            showPrompt = true
            return false
        }
    }

    /// success -> hasKey = false, errorText = nil, showPrompt = false; failure -> errorText set, showPrompt stays true
    @discardableResult
    func remove() -> Bool {
        do {
            try keychain.delete()
            hasKey = false
            errorText = nil
            showPrompt = false
            return true
        } catch {
            errorText = error.localizedDescription
            showPrompt = true
            return false
        }
    }
}
