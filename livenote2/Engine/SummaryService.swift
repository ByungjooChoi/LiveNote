import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// 회의 요약 생성 — Qwen3.5-4B (4bit, MLX, 로컬).
/// 2026년 3월 출시된 Qwen3.5 소형 라인 — 4B급 현존 최신 세대 (Apache 2.0, 262K 컨텍스트).
///
/// 설계: 모델(~2.3GB)을 상주시키지 않고 요약 요청 때만 로드하고,
/// 생성이 끝나면 참조를 놓아 메모리를 반환합니다. 회의 중 상주 메모리를
/// 가볍게 유지하기 위한 온디맨드 방식입니다.
///
/// 최초 1회는 Hugging Face에서 모델을 다운로드합니다 (~2.3GB, 수 분).
/// 이후에는 디스크 캐시에서 로드합니다 (수 초).
actor SummaryService {

    static let modelID = "mlx-community/Qwen3.5-4B-4bit"

    /// 전사본(영어, 화자 라벨 포함)을 받아 한국어 회의 요약을 생성.
    func generateSummary(transcript: String) async throws -> String {
        // mlx-swift-lm 3.x: 다운로더/토크나이저가 별도 패키지로 분리됨.
        // MLXHuggingFace 매크로가 HF 다운로더 + 토크나이저를 묶어 제공하는 정식 경로.
        let configuration = ModelConfiguration(id: Self.modelID)
        let container = try await #huggingFaceLoadModelContainer(configuration: configuration)
        let session = ChatSession(container, instructions: Self.systemPrompt)

        let response = try await session.respond(to: Self.userPrompt(transcript: transcript))
        return Self.cleaned(response)
        // container/session은 여기서 스코프를 벗어나며 해제 → 모델 메모리 반환
    }

    // MARK: - 프롬프트

    static let systemPrompt = """
        당신은 숙련된 회의록(meeting minutes) 작성자입니다. 영어 회의 전사본을 받아
        한국어 회의록을 작성합니다. 회의록은 대화의 중계가 아니라, 논의를 주제별로
        재구성해 결론과 근거를 압축한 문서입니다.
        전사본은 자동 음성인식 결과라 오타나 어색한 문장이 있으니 문맥으로 보정해서 이해하세요.
        고유명사(사람·제품·회사명)와 수치는 원문 그대로 보존하세요.
        반드시 한국어로만 작성하세요 (고유명사와 기술 용어는 영문 유지).
        사고 과정, 분석 과정, 계획(Thinking Process 등)을 절대 출력하지 마세요.
        응답의 첫 줄은 반드시 "# "(마크다운 H1)로 시작해야 합니다.
        """

    // 주의: /no_think 소프트 스위치는 Qwen3 전용이라 Qwen3.5에서는 무시됨 (2026-08 확인).
    // enable_thinking=false 템플릿 kwarg도 mlx-swift-lm에서 전달되지 않는 이슈(#154)가 있어
    // 사고 억제는 시스템 프롬프트 지시 + cleaned()의 "## 개요" 앵커 절단으로 처리한다.
    static func userPrompt(transcript: String) -> String {
        // 컨텍스트 안전 상한: 뒤쪽(최신) 우선으로 자름
        let capped = String(transcript.suffix(60_000))
        return """
        다음 회의 전사본으로 "회의록(meeting minutes)"을 작성해 주세요.

        회의록의 정의 (가장 중요):
        - 대화를 시간 순서로 따라가며 "~라고 말했다 / ~를 물었다 / ~라고 답했다"를 나열하는 것은 회의록이 아닙니다. 절대 금지.
        - 같은 주제에 대해 흩어져 나온 발언들을 하나의 주제 아래로 모아, 결론부터 쓰고 근거·수치·맥락을 하위 불릿으로 압축하세요.
        - 독자는 회의에 없던 사람입니다. 회의를 안 들어도 논의 결과와 이유를 이해할 수 있어야 합니다.

        형식 규칙:
        - 주요 주제마다 "# 주제명" 섹션 (보통 3~7개). 섹션 제목은 내용을 요약하는 명사구.
        - 각 섹션: 핵심 결론·사실을 불릿(-)으로, 근거·수치·세부는 들여쓴 하위 불릿으로.
        - 수치와 고유명사는 원문 보존 (예: "디스크 50% 절감", "9.6 GA").
        - 특정인의 입장이 중요할 때만 이름을 붙인다 (예: "- Steve: 전원 한 달간 실험 권고").
        - 마지막 섹션은 "# Next Steps": "- **할 일** (담당자)" 형식.
        - 인사말·잡담·진행 멘트 제외. 응답 첫 줄은 반드시 "# "로 시작.

        --- 전사본 시작 ---
        \(capped)
        --- 전사본 끝 ---
        """
    }

    // 주의: cleaned()/systemPrompt/userPrompt는 GeminiSummarizer(클라우드 요약)와 공유됨.

    /// Qwen 계열 thinking 누출 등 출력 정리.
    /// ① <think>...</think> 태그 블록 제거.
    /// ② 태그 없이 평문으로 새는 사고 과정 제거: Qwen3.5가 /no_think를 무시하고
    ///    "Thinking Process:" 평문을 앞에 붙이는 사례를 실측(2026-08-06 세션).
    ///    출력 형식의 첫 헤더인 "## 개요"로 시작하는 줄을 앵커로 그 앞을 전부 절단.
    ///    사고 과정 안에서 형식을 인용할 때는 들여쓰기·불릿이 붙어 줄 시작이 아니므로 안전.
    static func cleaned(_ text: String) -> String {
        var result = text
        // <think>...</think> 블록 제거
        while let start = result.range(of: "<think>"),
              let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        // 첫 마크다운 헤더("# " 또는 구버전 "## 개요") 앞을 절단 (정상 출력이면 첫 줄이라 no-op)
        let lines = result.components(separatedBy: "\n")
        if let anchor = lines.firstIndex(where: { $0.hasPrefix("# ") || $0.hasPrefix("## 개요") }),
           anchor > 0 {
            result = lines[anchor...].joined(separator: "\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 클라우드 요약 (Gemini 3.7 Flash)

/// 클라우드 번역 모드일 때 요약도 Gemini로 (2026-08 GA, generateContent REST).
/// 로컬 Qwen 대비 품질 우위, 모델 로드(2.3GB) 없이 수 초 내 응답.
/// 실패 시 호출측(AppState.runSummary)이 로컬 Qwen으로 폴백.
enum GeminiSummarizer {

    static let model = "gemini-3.7-flash"

    static func generateSummary(transcript: String, apiKey: String) async throws -> String {
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        ) else {
            throw Self.error("잘못된 URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": SummaryService.systemPrompt]]],
            "contents": [[
                "role": "user",
                "parts": [["text": SummaryService.userPrompt(transcript: transcript)]],
            ]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        AppLog.write("summary", "Gemini 요약 요청 transcript=\(transcript.count)자")

        let data = try await GeminiREST.send(request, logCategory: "summary")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw Self.error("Gemini 응답 파싱 실패")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        let cleanedText = SummaryService.cleaned(text)
        guard !cleanedText.isEmpty else { throw Self.error("Gemini가 빈 요약을 반환") }
        return cleanedText
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "livenote2.geminisummary", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
