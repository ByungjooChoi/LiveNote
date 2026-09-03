import Foundation

enum RecipeError: LocalizedError, Equatable {
    case noMeetings
    case noAPIKey
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noMeetings:
            return "No meetings in range"
        case .noAPIKey:
            return "Gemini API key not found in Keychain"
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
    var usedLocalEngine: Bool
}

@MainActor
enum RecipeRunner {

    static let contextBudget = 120_000
    static let perMeetingTranscriptCap = 6_000

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
        localEngine: LocalChatEngine
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

        let promptText = renderPrompt(
            template: recipe.prompt,
            meetingsText: context.text,
            language: language
        )

        let questionForModel = renderPrompt(
            template: recipe.prompt,
            meetingsText: "(the meeting records above)",
            language: language
        )

        var responseText: String
        var usedLocalEngine = false

        if model == .localQwen {
            usedLocalEngine = true
            responseText = try await localEngine.respond(
                context: context.text,
                history: [],
                question: questionForModel,
                systemPrompt: recipe.system
            )
        } else {
            guard let key = GeminiKeychain.load(), let apiModel = model.apiModel else {
                throw RecipeError.noAPIKey
            }
            responseText = try await GeminiChat.respond(
                context: context.text,
                history: [],
                question: questionForModel,
                apiKey: key,
                model: apiModel,
                thinkingLevel: model.thinkingLevel,
                systemPrompt: recipe.system
            )
        }

        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RecipeError.emptyResponse
        }

        return RecipeResult(
            text: trimmed,
            usedMeetings: context.used,
            truncated: context.truncated,
            promptText: promptText,
            usedLocalEngine: usedLocalEngine
        )
    }
}
