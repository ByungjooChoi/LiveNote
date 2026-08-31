import Foundation

/// 오디오가 어느 채널에서 왔는지.
/// 마이크 = 나(이름 편집 가능, 기본 "Philip"). 시스템 오디오 = 회의 상대방.
/// 상대방은 LS-EEND 화자구분으로 개별 슬롯(상대방 1/2/3…)으로 나뉩니다.
enum AudioChannel: String, Sendable, Codable {
    case me
    case them
}

/// 화면에 표시되는 확정 전사 한 줄. 회의 저장(session.json)에도 그대로 쓰입니다.
struct TranscriptRow: Identifiable, Sendable, Codable {
    let id: UUID
    let channel: AudioChannel
    /// 화자구분 슬롯 (them 채널 전용). nil이면 "상대방"으로 표시.
    var speakerSlot: Int?
    /// Zoom 태그 등에서 자동 인식된 화자 이름 (있으면 슬롯보다 우선, 편집 불가)
    var speakerName: String?
    let english: String
    var korean: String?          // 번역 도착 전 nil
    let startSeconds: Double     // 세션 시작 기준 초
    let endSeconds: Double

    var timeLabel: String {
        let total = Int(startSeconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 엔진 → UI로 전달되는 확정 세그먼트.
struct FinalSegment: Sendable {
    let channel: AudioChannel
    let text: String
    let startSeconds: Double
    let endSeconds: Double
}

/// 처리 백엔드. 번역·요약·(채팅 기본값)의 제공자를 결정.
/// 로컬 = Apple Translation + Qwen (오디오가 Mac 밖으로 안 나감)
/// 클라우드 = Gemini Live Translate + Gemini 3.7 Flash (품질 우위, 오디오 전송)
enum ProcessingBackend: String, Sendable {
    case local
    case cloud
}

/// AI 채팅 모델 선택 (번역 백엔드와 독립, Granola식 Standard/Thinking 구분).
/// 전체 채팅·회의 중 채팅이 하나의 선택을 공유하고 영속됨.
enum ChatModelChoice: String, Sendable, CaseIterable {
    case gemini37Flash            // 기본
    case gemini35FlashLite
    case gemini37FlashThinkingHigh
    case gemini37FlashThinkingMedium
    case gemini31Pro
    case localQwen

    var displayName: String {
        switch self {
        case .gemini37Flash: return "Gemini 3.7 Flash"
        case .gemini35FlashLite: return "Gemini 3.5 Flash-Lite"
        case .gemini37FlashThinkingHigh: return "3.7 Flash Thinking (high)"
        case .gemini37FlashThinkingMedium: return "3.7 Flash Thinking (medium)"
        case .gemini31Pro: return "Gemini 3.1 Pro"
        case .localQwen: return "Qwen (local)"
        }
    }

    /// generateContent 모델 ID (로컬이면 nil)
    var apiModel: String? {
        switch self {
        case .gemini37Flash, .gemini37FlashThinkingHigh, .gemini37FlashThinkingMedium:
            return "gemini-3.7-flash"
        case .gemini35FlashLite: return "gemini-3.5-flash-lite"
        case .gemini31Pro: return "gemini-3.1-pro"
        case .localQwen: return nil
        }
    }

    /// generationConfig.thinkingConfig.thinkingLevel (해당 시)
    var thinkingLevel: String? {
        switch self {
        case .gemini37FlashThinkingHigh: return "high"
        case .gemini37FlashThinkingMedium: return "medium"
        default: return nil
        }
    }

    static let standardChoices: [ChatModelChoice] = [.gemini37Flash, .gemini35FlashLite]
    static let thinkingChoices: [ChatModelChoice] = [
        .gemini37FlashThinkingHigh, .gemini37FlashThinkingMedium, .gemini31Pro,
    ]
}

/// 언어 설정 (Settings > Language). UserDefaults 직접 읽기 — 엔진(actor)에서도 접근.
enum LanguagePrefs {
    static let translationOptions = ["Korean", "Japanese", "Chinese", "Spanish", "French", "German"]
    static let summaryOptions = ["English", "Korean"]
    private static let codes: [String: String] = [
        "Korean": "ko", "Japanese": "ja", "Chinese": "zh",
        "Spanish": "es", "French": "fr", "German": "de",
    ]

    static var translationLanguage: String {
        UserDefaults.standard.string(forKey: "translationLanguage") ?? "Korean"
    }
    /// BCP-47 코드 (Apple Translation·Gemini translationConfig 공용)
    static var translationCode: String { codes[translationLanguage] ?? "ko" }

    static var summaryLanguage: String {
        UserDefaults.standard.string(forKey: "summaryLanguage") ?? "English"
    }
}

/// AI 채팅 말풍선.
struct ChatMessage: Identifiable, Sendable {
    enum Role: Sendable { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

/// 클라우드 번역 연결 상태 (헤더 표시등용).
enum CloudStatus: Sendable {
    case connecting
    case connected
    case reconnecting
}
