import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// AI 채팅 시스템 프롬프트 (로컬/클라우드 공유).
enum ChatPrompt {
    static let system = """
        당신은 회의 기록에 정통한 비서입니다. 제공된 회의 기록(전사·요약)을 근거로 답하세요.
        기록에 없는 내용은 추측하지 말고 없다고 말하세요.
        질문이 한국어면 한국어로, 영어면 영어로 답하세요. 간결하되 구체적으로.
        사고 과정을 출력하지 말고 답만 하세요.
        """

    /// 대화 이력을 텍스트로 접어 단일 프롬프트 구성 (로컬 Qwen용).
    static func composed(context: String, history: [(isUser: Bool, text: String)], question: String) -> String {
        var lines: [String] = ["--- 회의 기록 ---", context, "--- 기록 끝 ---", ""]
        for turn in history {
            lines.append("\(turn.isUser ? "User" : "Assistant"): \(turn.text)")
        }
        lines.append("User: \(question)")
        lines.append("Assistant:")
        return lines.joined(separator: "\n")
    }
}

/// 로컬 채팅 — Qwen3.5-4B. 첫 질문 때 로드 후 상주 (채팅 응답성 우선, 약 +2.3GB).
/// 요약(SummaryService)과 달리 대화는 연속 사용이 잦아 온디맨드 해제를 하지 않음.
actor LocalChatEngine {

    private var container: ModelContainer?
    private var loadedModelID: String?

    func respond(context: String, history: [(isUser: Bool, text: String)], question: String) async throws -> String {
        let modelID = SummaryService.modelID
        if container == nil || loadedModelID != modelID {
            AppLog.write("chat", "로컬 모델 로드 시작 (\(modelID))")
            let loadStart = Date()
            container = nil   // 모델 교체 시 기존 컨테이너 해제
            let configuration = ModelConfiguration(id: modelID)
            container = try await #huggingFaceLoadModelContainer(configuration: configuration)
            loadedModelID = modelID
            AppLog.write("chat", "로컬 모델 로드 완료 \(String(format: "%.1f", Date().timeIntervalSince(loadStart)))s")
        }
        guard let container else { throw NSError(domain: "livenote2.chat", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Local model load failed"]) }
        let started = Date()
        let session = ChatSession(container, instructions: ChatPrompt.system)
        let answer = try await session.respond(
            to: ChatPrompt.composed(context: context, history: history, question: question))
        AppLog.write("chat", "로컬 응답 \(answer.count)자 \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        return Self.stripThinking(answer)
    }

    private static func stripThinking(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>"),
              let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 클라우드 채팅 — Gemini 3.7 Flash (generateContent, 멀티턴 contents).
enum GeminiChat {

    static func respond(
        context: String,
        history: [(isUser: Bool, text: String)],
        question: String,
        apiKey: String,
        model: String = GeminiSummarizer.model,
        thinkingLevel: String? = nil
    ) async throws -> String {
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        ) else { throw Self.error("잘못된 URL") }

        var contents: [[String: Any]] = [[
            "role": "user",
            "parts": [["text": "--- 회의 기록 ---\n\(context)\n--- 기록 끝 ---\n이후 질문에 이 기록을 근거로 답해 주세요."]],
        ], [
            "role": "model",
            "parts": [["text": "네, 회의 기록을 확인했습니다. 질문해 주세요."]],
        ]]
        for turn in history {
            contents.append([
                "role": turn.isUser ? "user" : "model",
                "parts": [["text": turn.text]],
            ])
        }
        contents.append(["role": "user", "parts": [["text": question]]])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 150
        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": ChatPrompt.system]]],
            "contents": contents,
        ]
        // Gemini 3.x thinking 제어 (thinkingLevel: high/medium — thinkingBudget은 레거시)
        if let thinkingLevel {
            body["generationConfig"] = ["thinkingConfig": ["thinkingLevel": thinkingLevel]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        AppLog.write("chat", "Gemini 요청 model=\(model) thinking=\(thinkingLevel ?? "-") ctx=\(context.count)자 hist=\(history.count)턴 body=\(request.httpBody?.count ?? 0)B")

        let data = try await GeminiREST.send(request, logCategory: "chat")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw Self.error("Gemini 응답 파싱 실패")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Self.error("빈 응답") }
        return text
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "livenote2.geminichat", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
