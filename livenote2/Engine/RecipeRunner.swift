import Foundation

enum RecipeError: LocalizedError, Equatable {
    case noMeetings
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noMeetings:
            return "No meetings in range"
        case .emptyResponse:
            return "Empty response received"
        }
    }
}

struct RecipeResult: Sendable {
    var text: String
    var usedMeetings: [MeetingSummary]
    var truncated: Int
    var promptText: String
    var contextText: String
    var usedLocalEngine: Bool
}

@MainActor
enum RecipeRunner {

    static let contextBudget = 120_000
    static let perMeetingTranscriptCap = 6_000

    /// 모델 호출 경로 주입점. 기본값 `.live`는 실제 Gemini·로컬 엔진을 부르고,
    /// 테스트는 호출을 기록하는 가짜 구현을 넣는다.
    struct Backend: Sendable {
        var apiKey: @Sendable () -> String?
        var cloud: @Sendable (
            _ context: String,
            _ question: String,
            _ apiKey: String,
            _ apiModel: String,
            _ thinkingLevel: String?,
            _ systemPrompt: String
        ) async throws -> String
        var local: @Sendable (
            _ engine: LocalChatEngine,
            _ context: String,
            _ question: String,
            _ systemPrompt: String
        ) async throws -> String

        static let live = Backend(
            apiKey: { GeminiKeychain.load() },
            cloud: { context, question, apiKey, apiModel, thinkingLevel, systemPrompt in
                try await GeminiChat.respond(
                    context: context,
                    history: [],
                    question: question,
                    apiKey: apiKey,
                    model: apiModel,
                    thinkingLevel: thinkingLevel,
                    systemPrompt: systemPrompt
                )
            },
            local: { engine, context, question, systemPrompt in
                try await engine.respond(
                    context: context,
                    history: [],
                    question: question,
                    systemPrompt: systemPrompt
                )
            }
        )
    }

    /// 프롬프트 템플릿의 플레이스홀더 치환: {{meetings}}, {{today}}, {{language}}.
    /// 알 수 없는 플레이스홀더는 그대로 유지된다.
    static func renderPrompt(
        template: String,
        meetingsText: String,
        language: String,
        today: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let todayString = formatter.string(from: today)

        var rendered = template
        rendered = rendered.replacingOccurrences(of: "{{meetings}}", with: meetingsText)
        rendered = rendered.replacingOccurrences(of: "{{today}}", with: todayString)
        rendered = rendered.replacingOccurrences(of: "{{language}}", with: language)
        return rendered
    }

    /// 레시피 힌트에 따른 기본 모델 결정.
    /// thinking 힌트이면 사용자가 이미 thinkingChoices 또는 .localQwen을 쓰지 않는 한 .gemini37FlashThinkingMedium 선택.
    /// standard 힌트이면 userChoice 그대로 유지.
    static func defaultModel(for recipe: Recipe, userChoice: ChatModelChoice) -> ChatModelChoice {
        switch recipe.modelHint {
        case .thinking:
            if ChatModelChoice.thinkingChoices.contains(userChoice) || userChoice == .localQwen {
                return userChoice
            }
            return .gemini37FlashThinkingMedium
        case .standard:
            return userChoice
        }
    }

    static func run(
        recipe: Recipe,
        meetings: [MeetingSummary],
        model: ChatModelChoice,
        language: String,
        store: MeetingStore,
        localEngine: LocalChatEngine,
        backend: Backend = .live,
        contextBudget: Int = RecipeRunner.contextBudget
    ) async throws -> RecipeResult {
        guard !meetings.isEmpty else {
            throw RecipeError.noMeetings
        }

        let context = ContextBuilder.build(
            meetings: meetings,
            store: store,
            budget: contextBudget,
            perMeetingTranscriptCap: perMeetingTranscriptCap
        )

        // 모델은 기록을 별도 context 인자로 받으므로 질문 안에서는 위치만 가리킨다.
        let questionForModel = renderPrompt(
            template: recipe.prompt,
            meetingsText: "(the meeting records above)",
            language: language
        )

        // promptText는 감사용 전문이라 기록 원문을 담는다.
        // 템플릿에 {{meetings}}가 없으면 자리가 없으니 뒤에 덧붙인다.
        let promptText: String
        if recipe.prompt.contains("{{meetings}}") {
            promptText = renderPrompt(
                template: recipe.prompt,
                meetingsText: context.text,
                language: language
            )
        } else {
            promptText = "\(questionForModel)\n\n--- 회의 기록 ---\n\(context.text)\n--- 기록 끝 ---"
        }

        try Task.checkCancellation()

        let responseText: String
        var usedLocalEngine = false

        if model != .localQwen, let apiModel = model.apiModel, let key = backend.apiKey() {
            responseText = try await backend.cloud(
                context.text,
                questionForModel,
                key,
                apiModel,
                model.thinkingLevel,
                recipe.system
            )
        } else {
            // 로컬 모델을 골랐거나 API 키가 없는 경우: 로컬 엔진으로 실행한다.
            usedLocalEngine = true
            responseText = try await backend.local(
                localEngine,
                context.text,
                questionForModel,
                recipe.system
            )
        }

        try Task.checkCancellation()

        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RecipeError.emptyResponse
        }

        return RecipeResult(
            text: trimmed,
            usedMeetings: context.used,
            truncated: context.truncated,
            promptText: promptText,
            contextText: context.text,
            usedLocalEngine: usedLocalEngine
        )
    }
}
