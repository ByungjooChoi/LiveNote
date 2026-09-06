import XCTest

@testable import LiveNote

/// 백엔드 호출을 기록하는 가짜 구현. 테스트는 직렬 실행이라 잠금 없이 쓴다.
private final class BackendRecorder: @unchecked Sendable {
    struct CloudCall {
        var context: String
        var question: String
        var apiKey: String
        var apiModel: String
        var thinkingLevel: String?
        var systemPrompt: String
    }

    struct LocalCall {
        var context: String
        var question: String
        var systemPrompt: String
    }

    var cloudCalls: [CloudCall] = []
    var localCalls: [LocalCall] = []
    var response = "RESULT-BODY"
}

@MainActor
final class RecipeRunnerTests: XCTestCase {

    private var store: MeetingStore!
    private var logRoot: URL!
    private var previousLogOverride: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        TestLogSandbox.activate()
        previousLogOverride = AppLog.directoryOverride
        logRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveNoteRecipeRunnerLogs-\(UUID().uuidString)", isDirectory: true)
        AppLog.directoryOverride = logRoot
        store = try MeetingStoreFixture.makeStore()
    }

    override func tearDown() {
        if let store { MeetingStoreFixture.cleanUp(store) }
        store = nil
        AppLog.flush()
        AppLog.directoryOverride = previousLogOverride
        if let logRoot { try? FileManager.default.removeItem(at: logRoot) }
        logRoot = nil
        super.tearDown()
    }

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
        let standardRecipe = makeRecipe(id: "std", hint: .standard)
        let thinkingRecipe = makeRecipe(id: "think", hint: .thinking)

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

    // MARK: - run

    func testRunWithEmptyMeetingsThrowsNoMeetings() async {
        let recorder = BackendRecorder()
        do {
            _ = try await run(
                recipe: makeRecipe(),
                meetings: [],
                model: .gemini37Flash,
                key: "KEY",
                recorder: recorder
            )
            XCTFail("Expected RecipeError.noMeetings")
        } catch let error as RecipeError {
            XCTAssertEqual(error, .noMeetings)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// (a) 클라우드 모델 + 키 있음: cloud 호출, systemPrompt는 레시피 system,
    /// 질문에는 기록 자리 표시자만 들어가고 회의 원문은 들어가지 않는다.
    func testCloudModelWithKeyCallsCloudBackend() async throws {
        try saveMeeting(title: "Alpha", hour: 10, summary: "SUMMARY-BODY")
        let recorder = BackendRecorder()
        let recipe = makeRecipe(system: "SYSTEM-RULES")

        let result = try await run(
            recipe: recipe,
            meetings: store.meetings,
            model: .gemini37FlashThinkingMedium,
            key: "KEY-123",
            recorder: recorder
        )

        XCTAssertEqual(recorder.localCalls.count, 0)
        XCTAssertEqual(recorder.cloudCalls.count, 1)
        let call = try XCTUnwrap(recorder.cloudCalls.first)
        XCTAssertEqual(call.systemPrompt, recipe.system)
        XCTAssertEqual(call.apiKey, "KEY-123")
        XCTAssertEqual(call.apiModel, "gemini-3.7-flash")
        XCTAssertEqual(call.thinkingLevel, "medium")
        XCTAssertTrue(call.question.contains("(the meeting records above)"))
        XCTAssertFalse(call.question.contains("SUMMARY-BODY"))
        XCTAssertTrue(call.context.contains("SUMMARY-BODY"))
        XCTAssertFalse(result.usedLocalEngine)
        XCTAssertEqual(result.text, "RESULT-BODY")
    }

    /// (b) 클라우드 모델 + 키 없음: 로컬 엔진으로 폴백한다.
    func testCloudModelWithoutKeyFallsBackToLocalEngine() async throws {
        try saveMeeting(title: "Alpha", hour: 10, summary: "SUMMARY-BODY")
        let recorder = BackendRecorder()
        let recipe = makeRecipe(system: "SYSTEM-RULES")

        let result = try await run(
            recipe: recipe,
            meetings: store.meetings,
            model: .gemini37Flash,
            key: nil,
            recorder: recorder
        )

        XCTAssertEqual(recorder.cloudCalls.count, 0)
        XCTAssertEqual(recorder.localCalls.count, 1)
        XCTAssertEqual(recorder.localCalls.first?.systemPrompt, recipe.system)
        XCTAssertTrue(result.usedLocalEngine)
    }

    /// (c) 로컬 모델은 키가 있어도 로컬 엔진을 쓴다.
    func testLocalModelCallsLocalEngine() async throws {
        try saveMeeting(title: "Alpha", hour: 10, summary: "SUMMARY-BODY")
        let recorder = BackendRecorder()

        let result = try await run(
            recipe: makeRecipe(),
            meetings: store.meetings,
            model: .localQwen,
            key: "KEY-123",
            recorder: recorder
        )

        XCTAssertEqual(recorder.cloudCalls.count, 0)
        XCTAssertEqual(recorder.localCalls.count, 1)
        XCTAssertTrue(result.usedLocalEngine)
    }

    /// (d) contextText와 promptText 모두 회의 요약 원문을 담는다.
    func testResultCarriesContextAndPrompt() async throws {
        try saveMeeting(title: "Alpha", hour: 10, summary: "SUMMARY-BODY")
        let recorder = BackendRecorder()

        let result = try await run(
            recipe: makeRecipe(),
            meetings: store.meetings,
            model: .gemini37Flash,
            key: "KEY",
            recorder: recorder
        )

        XCTAssertTrue(result.contextText.contains("SUMMARY-BODY"))
        XCTAssertTrue(result.promptText.contains("SUMMARY-BODY"))
        XCTAssertEqual(result.usedMeetings.map(\.title), ["Alpha"])
        XCTAssertEqual(result.truncated, 0)
    }

    /// (e) 예산이 작으면 잘린 회의 수가 결과에 그대로 전달된다.
    func testTruncatedCountPropagatesWithTinyBudget() async throws {
        let long = String(repeating: "a", count: 300)
        try saveMeeting(title: "Alpha", hour: 11, summary: long)
        try saveMeeting(title: "Beta", hour: 10, summary: long)
        try saveMeeting(title: "Gamma", hour: 9, summary: long)
        let recorder = BackendRecorder()

        let result = try await run(
            recipe: makeRecipe(),
            meetings: store.meetings,
            model: .gemini37Flash,
            key: "KEY",
            recorder: recorder,
            contextBudget: 200
        )

        XCTAssertEqual(result.truncated, 3)
        XCTAssertTrue(result.usedMeetings.isEmpty)
        XCTAssertEqual(result.contextText.count, 200)
    }

    /// (f) 템플릿에 {{meetings}}가 없어도 promptText에는 기록이 붙는다.
    func testPromptTextKeepsContextWhenTemplateHasNoPlaceholder() async throws {
        try saveMeeting(title: "Alpha", hour: 10, summary: "SUMMARY-BODY")
        let recorder = BackendRecorder()
        let recipe = makeRecipe(prompt: "Summarize everything in {{language}}.")

        let result = try await run(
            recipe: recipe,
            meetings: store.meetings,
            model: .gemini37Flash,
            key: "KEY",
            recorder: recorder
        )

        XCTAssertTrue(result.promptText.hasPrefix("Summarize everything in Korean."))
        XCTAssertTrue(result.promptText.contains("SUMMARY-BODY"))
        XCTAssertTrue(recorder.cloudCalls.first?.context.contains("SUMMARY-BODY") ?? false)
    }

    /// (g) 빈 응답은 emptyResponse로 실패한다.
    func testEmptyResponseThrows() async throws {
        try saveMeeting(title: "Alpha", hour: 10, summary: "SUMMARY-BODY")
        let recorder = BackendRecorder()
        recorder.response = "   \n  "

        do {
            _ = try await run(
                recipe: makeRecipe(),
                meetings: store.meetings,
                model: .gemini37Flash,
                key: "KEY",
                recorder: recorder
            )
            XCTFail("Expected RecipeError.emptyResponse")
        } catch let error as RecipeError {
            XCTAssertEqual(error, .emptyResponse)
        }
    }

    /// (h) 주입된 apiKey 클로저가 호출되고 nil 반환 시 로컬 엔진으로 폴백한다 (usedLocalEngine == true).
    func testInjectedApiKeyClosureUsedWhenNilFallsBackToLocal() async throws {
        try saveMeeting(title: "Alpha", hour: 10, summary: "SUMMARY-BODY")
        let recorder = BackendRecorder()
        var apiKeyCalled = false
        var backend = makeBackend(key: nil, recorder: recorder)
        backend.apiKey = {
            apiKeyCalled = true
            return nil
        }

        let result = try await RecipeRunner.run(
            recipe: makeRecipe(),
            meetings: store.meetings,
            model: .gemini37Flash,
            language: "Korean",
            store: store,
            localEngine: LocalChatEngine(),
            backend: backend
        )

        XCTAssertTrue(apiKeyCalled)
        XCTAssertEqual(recorder.cloudCalls.count, 0)
        XCTAssertEqual(recorder.localCalls.count, 1)
        XCTAssertTrue(result.usedLocalEngine)
    }

    // MARK: - helpers

    private func makeRecipe(
        id: String = "test",
        hint: RecipeModelHint = .standard,
        system: String = "sys",
        prompt: String = "Answer in {{language}}:\n{{meetings}}"
    ) -> Recipe {
        Recipe(
            id: id, title: "Test", scopeDefault: .thisWeek,
            modelHint: hint, outputLanguage: "Korean",
            system: system, prompt: prompt
        )
    }

    private func makeBackend(key: String?, recorder: BackendRecorder) -> RecipeRunner.Backend {
        RecipeRunner.Backend(
            apiKey: { key },
            cloud: { context, question, apiKey, apiModel, thinkingLevel, systemPrompt in
                recorder.cloudCalls.append(BackendRecorder.CloudCall(
                    context: context, question: question, apiKey: apiKey,
                    apiModel: apiModel, thinkingLevel: thinkingLevel, systemPrompt: systemPrompt))
                return recorder.response
            },
            local: { _, context, question, systemPrompt in
                recorder.localCalls.append(BackendRecorder.LocalCall(
                    context: context, question: question, systemPrompt: systemPrompt))
                return recorder.response
            }
        )
    }

    private func run(
        recipe: Recipe,
        meetings: [MeetingSummary],
        model: ChatModelChoice,
        key: String?,
        recorder: BackendRecorder,
        contextBudget: Int = RecipeRunner.contextBudget
    ) async throws -> RecipeResult {
        try await RecipeRunner.run(
            recipe: recipe,
            meetings: meetings,
            model: model,
            language: "Korean",
            store: store,
            localEngine: LocalChatEngine(),
            backend: makeBackend(key: key, recorder: recorder),
            contextBudget: contextBudget
        )
    }

    private func saveMeeting(title: String, hour: Int, summary: String) throws {
        let saved = try store.save(
            rows: [MeetingStoreFixture.row(text: "transcript")],
            myName: "Philip",
            speakerNames: [0: "Craig"],
            startedAt: MeetingStoreFixture.date(hour: hour),
            durationSeconds: 60,
            title: title,
            summary: summary,
            attendees: nil,
            existingURL: nil
        )
        XCTAssertNotNil(saved)
    }
}
