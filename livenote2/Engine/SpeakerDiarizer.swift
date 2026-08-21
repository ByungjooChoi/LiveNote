import Foundation
import FluidAudio

/// 시스템 오디오 채널("상대방")의 발화자 구분 — FluidAudio LS-EEND 스트리밍 diarizer 래퍼.
///
/// FluidAudio diarizer API를 호출하는 곳은 프로젝트에서 이 파일 하나뿐입니다.
/// 라이브러리 시그니처가 버전에 따라 다르면 컴파일 에러가 여기에만 모입니다.
///
/// 시간축: 여기 들어오는 샘플은 시스템 오디오 캡처 시작 기준의 연속 스트림이고,
/// TranscriptionEngine의 .them 채널과 같은 샘플 소스이므로 초 단위 시계가 일치합니다.
actor SpeakerDiarizer {

    private var diarizer: LSEENDDiarizer?
    private var failed = false

    /// LS-EEND 모델 다운로드(최초 1회) 및 로드.
    func prepare() async throws {
        diarizer = try await LSEENDDiarizer(variant: .dihard3)
    }

    var isReady: Bool {
        diarizer != nil && !failed
    }

    /// 시스템 오디오 16kHz 모노 샘플 유입. 내부적으로 타임라인이 누적됩니다.
    func ingest(_ samples: [Float]) async {
        guard let diarizer, !failed else { return }
        do {
            _ = try diarizer.process(samples: samples, sourceSampleRate: 16_000)
        } catch {
            // 화자구분만 포기하고 전사는 계속 (라벨이 "상대방"으로 남을 뿐)
            failed = true
        }
    }

    /// [from, to] 구간에서 가장 오래 말한 화자 슬롯. 신뢰할 근거가 없으면 nil.
    func dominantSlot(from: Double, to: Double) async -> Int? {
        guard let diarizer, !failed, to > from else { return nil }

        let timeline = diarizer.timeline
        var bestSlot: Int?
        var bestOverlap: Double = 0

        for (slot, speaker) in timeline.speakers {
            var overlap: Double = 0
            let segments = speaker.finalizedSegments + speaker.tentativeSegments
            for segment in segments {
                let start = max(from, Double(segment.startTime))
                let end = min(to, Double(segment.endTime))
                if end > start {
                    overlap += end - start
                }
            }
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSlot = slot
            }
        }

        // 구간의 15% 이상 또는 0.3초 이상 겹칠 때만 라벨을 신뢰
        let minimumOverlap = max(0.3, (to - from) * 0.15)
        return bestOverlap >= minimumOverlap ? bestSlot : nil
    }

    /// 녹음 종료 시 잔여 프레임 확정.
    func finish() async {
        guard let diarizer, !failed else { return }
        _ = try? diarizer.finalizeSession()
    }
}
