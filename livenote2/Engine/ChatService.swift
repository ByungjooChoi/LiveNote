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
            lines.append("\(turn.isUser ? "사용자" : "비서"): \(turn.text)")
        }
        lines.append("사용자: \(question)")
        lines.append("비서:")
        return lines.joined(separator: "\n")
    }
}

/// 로컬 채팅 — Qwen3.5-4B. 첫 질문 때 로드 후 상주 (채팅 응답성 우선, 약 +2.3GB).
/// 요약(SummaryService)과 달리 대화는 연속 사용이 잦아 온디맨드 해제를 하지 않음.
actor LocalChatEngine {

    private var container: ModelContainer?

    func respond(context: String, history: [(isUser: Bool, text: String)], question: String) async throws -> String {
        if container == nil {
            let configuration = ModelConfiguration(id: SummaryService.modelID)
            container = try await #huggingFaceLoadModelContainer(configuration: configuration)
        }
        guard let container else { throw NSError(domain: "livenote2.chat", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "로컬 모델 로드 실패"]) }
        let session = ChatSession(container, instructions: ChatPrompt.system)
        let answer = try await session.respond(
            to: ChatPrompt.composed(context: context, history: history, question: question))
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
        apiKey: String
    ) async throws -> String {
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(GeminiSummarizer.model):generateContent"
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
        request.timeoutInterval = 60
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": ChatPrompt.system]]],
            "contents": contents,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? "HTTP 오류"
            throw Self.error("Gemini 응답 실패 (\((response as? HTTPURLResponse)?.statusCode ?? -1)): \(detail)")
        }
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
