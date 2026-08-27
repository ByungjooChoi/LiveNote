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

/// 번역 제공자. 끔(영어 전용) / 로컬(Apple Translation, 기본) / 클라우드(Gemini Live Translate).
/// 클라우드 모드에서는 회의 오디오가 Google로 전송됨 — UI에 명시.
/// 끔은 한국어가 필요 없는 사용자(팀원 배포)용 — 언어팩 다운로드 요청도 뜨지 않음.
enum TranslationMode: String, Sendable {
    case off
    case local
    case cloud
}

/// 클라우드 번역 연결 상태 (헤더 표시등용).
enum CloudStatus: Sendable {
    case connecting
    case connected
    case reconnecting
}
