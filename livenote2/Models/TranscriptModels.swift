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

/// AI 채팅 모델 선택 (상단 백엔드와 독립).
enum ChatModelChoice: String, Sendable, CaseIterable {
    case cloudGemini
    case localQwen

    var displayName: String {
        switch self {
        case .cloudGemini: return "Gemini 3.7 Flash"
        case .localQwen: return "Qwen (local)"
        }
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
