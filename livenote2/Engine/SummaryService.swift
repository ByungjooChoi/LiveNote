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

    private static let systemPrompt = """
        당신은 회의록 요약 전문가입니다. 영어 회의 전사본을 받아 한국어로 요약합니다.
        전사본은 자동 음성인식 결과라 오타나 어색한 문장이 있을 수 있으니 문맥으로 보정해서 이해하세요.
        화자 라벨(이름)이 붙어 있으니 누가 말했는지 반영하세요.
        반드시 한국어로만 답하세요.
        사고 과정, 분석 과정, 계획(Thinking Process 등)을 절대 출력하지 마세요.
        응답의 첫 줄은 반드시 "## 개요"로 시작해야 합니다.
        """

    // 주의: /no_think 소프트 스위치는 Qwen3 전용이라 Qwen3.5에서는 무시됨 (2026-08 확인).
    // enable_thinking=false 템플릿 kwarg도 mlx-swift-lm에서 전달되지 않는 이슈(#154)가 있어
    // 사고 억제는 시스템 프롬프트 지시 + cleaned()의 "## 개요" 앵커 절단으로 처리한다.
    private static func userPrompt(transcript: String) -> String {
        // 컨텍스트 안전 상한: 뒤쪽(최신) 우선으로 자름
        let capped = String(transcript.suffix(60_000))
        return """
        다음 회의 전사본을 아래 형식으로 요약해 주세요:

        ## 개요
        (회의 전체를 2~3문장으로)

        ## 핵심 논의
        (주요 논의 사항을 항목별로, 화자 언급 포함)

        ## 결정 사항
        (합의되거나 결정된 것. 없으면 "없음")

        ## 액션 아이템
        (해야 할 일과 담당자. 없으면 "없음")

        --- 전사본 시작 ---
        \(capped)
        --- 전사본 끝 ---
        """
    }

    /// Qwen 계열 thinking 누출 등 출력 정리.
    /// ① <think>...</think> 태그 블록 제거.
    /// ② 태그 없이 평문으로 새는 사고 과정 제거: Qwen3.5가 /no_think를 무시하고
    ///    "Thinking Process:" 평문을 앞에 붙이는 사례를 실측(2026-08-06 세션).
    ///    출력 형식의 첫 헤더인 "## 개요"로 시작하는 줄을 앵커로 그 앞을 전부 절단.
    ///    사고 과정 안에서 형식을 인용할 때는 들여쓰기·불릿이 붙어 줄 시작이 아니므로 안전.
    private static func cleaned(_ text: String) -> String {
        var result = text
        // <think>...</think> 블록 제거
        while let start = result.range(of: "<think>"),
              let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        // 줄 시작이 "## 개요"인 첫 줄 앞을 절단 (정상 출력이면 첫 줄이라 no-op)
        let lines = result.components(separatedBy: "\n")
        if let anchor = lines.firstIndex(where: { $0.hasPrefix("## 개요") }), anchor > 0 {
            result = lines[anchor...].joined(separator: "\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
