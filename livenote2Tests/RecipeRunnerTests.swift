import XCTest

@testable import LiveNote

@MainActor
final class RecipeRunnerTests: XCTestCase {

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = 12
        return Calendar.current.date(from: comps)!
    }

    // MARK: - renderPrompt

    func testRenderPromptReplacesAllPlaceholders() {
        let template = "Date: {{today}}, Lang: {{language}}\nRecords:\n{{meetings}}\nExtra: {{unknown}}"
        let fixedDate = date(2026, 9, 3)

        let rendered = RecipeRunner.renderPrompt(
            template: template,
            meetingsText: "Meeting 1 Notes",
            language: "Korean",
            today: fixedDate
        )

        XCTAssertTrue(rendered.contains("Date: 2026-09-03"))
        XCTAssertTrue(rendered.contains("Lang: Korean"))
        XCTAssertTrue(rendered.contains("Meeting 1 Notes"))
        XCTAssertTrue(rendered.contains("Extra: {{unknown}}"))
    }

    func testRenderPromptFormatTodayYYYYMMDD() {
        let template = "{{today}}"
        let fixedDate = date(2025, 1, 5)

        let rendered = RecipeRunner.renderPrompt(
            template: template,
            meetingsText: "m",
            language: "en",
            today: fixedDate
        )

        XCTAssertEqual(rendered, "2025-01-05")
    }

    // MARK: - defaultModel

    func testDefaultModelTable() {
        let standardRecipe = Recipe(
            id: "std", title: "Standard", scopeDefault: .thisWeek,
            modelHint: .standard, outputLanguage: "English",
            system: "sys", prompt: "{{meetings}}"
        )

        let thinkingRecipe = Recipe(
            id: "think", title: "Thinking", scopeDefault: .thisWeek,
            modelHint: .thinking, outputLanguage: "Korean",
            system: "sys", prompt: "{{meetings}}"
        )

        // For standard recipe, returns userChoice directly
        for choice in ChatModelChoice.allCases {
            XCTAssertEqual(
                RecipeRunner.defaultModel(for: standardRecipe, userChoice: choice),
                choice,
                "Standard recipe must preserve user choice \(choice)"
            )
        }

        // For thinking recipe:
        // standard choices -> .gemini37FlashThinkingMedium
        XCTAssertEqual(
            RecipeRunner.defaultModel(for: thinkingRecipe, userChoice: .gemini37Flash),
            .gemini37FlashThinkingMedium
        )
        XCTAssertEqual(
            RecipeRunner.defaultModel(for: thinkingRecipe, userChoice: .gemini35FlashLite),
            .gemini37FlashThinkingMedium
        )

        // thinking choices preserved
        XCTAssertEqual(
            RecipeRunner.defaultModel(for: thinkingRecipe, userChoice: .gemini37FlashThinkingHigh),
            .gemini37FlashThinkingHigh
        )
        XCTAssertEqual(
            RecipeRunner.defaultModel(for: thinkingRecipe, userChoice: .gemini37FlashThinkingMedium),
            .gemini37FlashThinkingMedium
        )
        XCTAssertEqual(
            RecipeRunner.defaultModel(for: thinkingRecipe, userChoice: .gemini31Pro),
            .gemini31Pro
        )

        // localQwen preserved
        XCTAssertEqual(
            RecipeRunner.defaultModel(for: thinkingRecipe, userChoice: .localQwen),
            .localQwen
        )
    }

    // MARK: - run([]) throws noMeetings

    func testRunWithEmptyMeetingsThrowsNoMeetings() async {
        let recipe = Recipe(
            id: "test", title: "Test", scopeDefault: .thisWeek,
            outputLanguage: "English", system: "sys", prompt: "{{meetings}}"
        )
        let store = MeetingStore()
        let localEngine = LocalChatEngine()

        do {
            _ = try await RecipeRunner.run(
                recipe: recipe,
                meetings: [],
                model: .gemini37Flash,
                language: "English",
                store: store,
                localEngine: localEngine
            )
            XCTFail("Expected RecipeError.noMeetings")
        } catch let error as RecipeError {
            XCTAssertEqual(error, .noMeetings)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
