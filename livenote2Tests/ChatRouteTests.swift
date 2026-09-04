import XCTest
@testable import LiveNote

final class ChatRouteTests: XCTestCase {

    func testLocalModelSelectedReturnsLocalWithoutNotice() {
        let routeWithoutKey = AppState.chatRoute(model: .localQwen, key: nil, keyError: nil)
        XCTAssertEqual(routeWithoutKey, .local(notice: nil))

        let routeWithKey = AppState.chatRoute(model: .localQwen, key: "some-key", keyError: nil)
        XCTAssertEqual(routeWithKey, .local(notice: nil))
    }

    func testGeminiModelWithKeyReturnsCloud() {
        let route = AppState.chatRoute(model: .gemini37Flash, key: "AIza-test-key", keyError: nil)
        XCTAssertEqual(route, .cloud(apiModel: "gemini-3.7-flash"))

        let routePro = AppState.chatRoute(model: .gemini31Pro, key: "AIza-test-key", keyError: nil)
        XCTAssertEqual(routePro, .cloud(apiModel: "gemini-3.1-pro"))
    }

    func testGeminiModelWithoutKeyReturnsLocalWithDefaultNotice() {
        let route = AppState.chatRoute(model: .gemini37Flash, key: nil, keyError: nil)
        let expectedNotice = "(No Gemini API key. Answered with the local model. Add a key in Settings for cloud answers.)\n\n"
        XCTAssertEqual(route, .local(notice: expectedNotice))

        let routeEmptyKey = AppState.chatRoute(model: .gemini37Flash, key: "   ", keyError: nil)
        XCTAssertEqual(routeEmptyKey, .local(notice: expectedNotice))
    }

    func testGeminiModelWithWhitespaceOnlyKeyReturnsLocalWithNotice() {
        let expectedDefaultNotice = "(No Gemini API key. Answered with the local model. Add a key in Settings for cloud answers.)\n\n"
        let routeWhitespace = AppState.chatRoute(model: .gemini37Flash, key: "   \t\n  ", keyError: nil)
        XCTAssertEqual(routeWhitespace, .local(notice: expectedDefaultNotice))

        let errorMsg = "Keychain read failed (-25300)"
        let routeWhitespaceWithError = AppState.chatRoute(model: .gemini37Flash, key: "   ", keyError: errorMsg)
        let expectedCustomNotice = "(\(errorMsg). Answered with the local model. Add a key in Settings for cloud answers.)\n\n"
        XCTAssertEqual(routeWhitespaceWithError, .local(notice: expectedCustomNotice))
    }

    func testGeminiModelWithoutKeyAndKeyErrorReturnsLocalWithCustomNotice() {
        let errorMsg = "Keychain denied access (-25293)"
        let route = AppState.chatRoute(model: .gemini37Flash, key: nil, keyError: errorMsg)
        let expectedNotice = "(\(errorMsg). Answered with the local model. Add a key in Settings for cloud answers.)\n\n"
        XCTAssertEqual(route, .local(notice: expectedNotice))
    }

    func testLocalFallbackNoticeWithNilOrBlankReasonUsesDefault() {
        let nilNotice = AppState.localFallbackNotice(
            reason: nil,
            feature: "Minutes were generated with the local model."
        )
        XCTAssertEqual(nilNotice, "No Gemini API key. Minutes were generated with the local model.")

        let blankNotice = AppState.localFallbackNotice(
            reason: "   ",
            feature: "Minutes were generated with the local model."
        )
        XCTAssertEqual(blankNotice, "No Gemini API key. Minutes were generated with the local model.")
    }

    func testLocalFallbackNoticeWithCustomReasonPreservesError() {
        let customNotice = AppState.localFallbackNotice(
            reason: "Keychain denied access (-25293)",
            feature: "Minutes were generated with the local model."
        )
        XCTAssertEqual(customNotice, "Keychain denied access (-25293). Minutes were generated with the local model.")

        let chatNotice = AppState.localFallbackNotice(
            reason: "Keychain denied access (-25293)",
            feature: "Answered with the local model. Add a key in Settings for cloud answers."
        )
        XCTAssertEqual(chatNotice, "Keychain denied access (-25293). Answered with the local model. Add a key in Settings for cloud answers.")
    }

    // MARK: - SummaryRoute Tests

    func testSummaryRouteLocalBackendReturnsLocalWithoutNotice() {
        let routeWithoutKey = AppState.summaryRoute(backend: .local, key: nil, keyError: nil)
        XCTAssertEqual(routeWithoutKey, .local(notice: nil))

        let routeWithKey = AppState.summaryRoute(backend: .local, key: "some-key", keyError: "Some error")
        XCTAssertEqual(routeWithKey, .local(notice: nil))
    }

    func testSummaryRouteCloudBackendWithKeyReturnsCloud() {
        let route = AppState.summaryRoute(backend: .cloud, key: "valid-gemini-key", keyError: nil)
        XCTAssertEqual(route, .cloud(key: "valid-gemini-key"))

        let routeTrimmed = AppState.summaryRoute(backend: .cloud, key: "  valid-gemini-key  ", keyError: nil)
        XCTAssertEqual(routeTrimmed, .cloud(key: "valid-gemini-key"))
    }

    func testSummaryRouteCloudBackendWithoutKeyReturnsLocalWithDefaultNotice() {
        let routeNilKey = AppState.summaryRoute(backend: .cloud, key: nil, keyError: nil)
        XCTAssertEqual(routeNilKey, .local(notice: "No Gemini API key. Minutes were generated with the local model."))

        let routeEmptyKey = AppState.summaryRoute(backend: .cloud, key: "   ", keyError: nil)
        XCTAssertEqual(routeEmptyKey, .local(notice: "No Gemini API key. Minutes were generated with the local model."))
    }

    func testSummaryRouteCloudBackendWithoutKeyAndKeyErrorReturnsLocalWithCustomNotice() {
        let errorMsg = "Keychain read failed (-25300)"
        let route = AppState.summaryRoute(backend: .cloud, key: nil, keyError: errorMsg)
        XCTAssertEqual(route, .local(notice: "\(errorMsg). Minutes were generated with the local model."))
    }

    // MARK: - RecipeAssistantText Tests

    func testRecipeAssistantTextLocalEngineGeminiModelAddsNoticePrefix() {
        let result = AppState.recipeAssistantText(
            resultText: "Recipe output text",
            usedLocalEngine: true,
            requestedModel: .gemini37Flash,
            keyError: nil
        )
        let expected = "(No Gemini API key. Answered with the local model. Add a key in Settings for cloud answers.)\n\nRecipe output text"
        XCTAssertEqual(result, expected)
    }

    func testRecipeAssistantTextLocalEngineGeminiModelWithKeyErrorAddsNoticePrefixWithReason() {
        let errorMsg = "Keychain denied access (-25293)"
        let result = AppState.recipeAssistantText(
            resultText: "Recipe output text",
            usedLocalEngine: true,
            requestedModel: .gemini37Flash,
            keyError: errorMsg
        )
        let expected = "(\(errorMsg). Answered with the local model. Add a key in Settings for cloud answers.)\n\nRecipe output text"
        XCTAssertEqual(result, expected)
    }

    func testRecipeAssistantTextLocalEngineLocalQwenModelHasNoPrefix() {
        let result = AppState.recipeAssistantText(
            resultText: "Recipe output text",
            usedLocalEngine: true,
            requestedModel: .localQwen,
            keyError: nil
        )
        XCTAssertEqual(result, "Recipe output text")
    }

    func testRecipeAssistantTextCloudExecutionHasNoPrefix() {
        let result = AppState.recipeAssistantText(
            resultText: "Recipe output text",
            usedLocalEngine: false,
            requestedModel: .gemini37Flash,
            keyError: nil
        )
        XCTAssertEqual(result, "Recipe output text")
    }
}
