import Foundation
import FluidAudio

/// 2-pass 전사 정제: stop 시점에 세션 전체 오디오를 Parakeet으로 재디코딩.
///
/// 라이브 경로는 짧은 창을 잘라 디코딩하므로 경계 잘림·구두점 아티팩트가 생긴다.
/// 재디코딩은 전체 문맥을 한 번에 읽어(디스크 기반 청크 병합, FluidAudio) 더 정확한
/// 텍스트와 자연스러운 문장 경계를 얻는다. 화자·번역은 라이브 행에서 시간 겹침으로 승계.
/// 라이브 화면·실시간 채팅은 영향 없음 (저장본만 교체).
enum TranscriptRefiner {

    /// 문장 경계 판정 상수
    private static let gapBoundary: Double = 1.2      // 토큰 간 이 이상 침묵이면 문장 분리
    private static let maxSentenceSeconds: Double = 30

    /// 채널별 WAV를 재디코딩해 정제된 행 목록을 만든다. 실패하거나 결과가 빈약하면 nil.
    static func refine(
        files: [AudioChannel: URL],
        liveRows: [TranscriptRow],
        engine: TranscriptionEngine,
        diarization: OfflineDiarization? = nil
    ) async -> [TranscriptRow]? {
        var refined: [TranscriptRow] = []
        let started = Date()

        for (channel, url) in files {
            guard let result = await engine.finalPass(url: url) else { continue }
            let timings = result.tokenTimings ?? []
            guard !timings.isEmpty else { continue }
            let channelLive = liveRows.filter { $0.channel == channel }
            for sentence in split(timings) {
                let donor = bestOverlap(start: sentence.start, end: sentence.end, in: channelLive)
                let cluster = (channel == .them) ? (diarization?.dominantCluster(from: sentence.start, to: sentence.end) ?? donor?.clusterID) : donor?.clusterID
                refined.append(TranscriptRow(
                    id: UUID(),
                    channel: channel,
                    speakerSlot: donor?.speakerSlot,
                    speakerName: donor?.speakerName,
                    english: sentence.text,
                    korean: nil,
                    startSeconds: sentence.start,
                    endSeconds: sentence.end,
                    nameSource: donor?.nameSource,
                    candidateNames: donor?.candidateNames,
                    clusterID: cluster
                ))
            }
        }
        guard !refined.isEmpty else { return nil }

        // 품질 가드: 정제본이 라이브 대비 절반 미만이면 재디코딩 실패로 간주
        let liveLength = liveRows.reduce(0) { $0 + $1.english.count }
        let refinedLength = refined.reduce(0) { $0 + $1.english.count }
        guard refinedLength * 2 >= liveLength else {
            AppLog.write("app", "2-pass 품질 가드 발동 (live=\(liveLength)자 refined=\(refinedLength)자) - 라이브 전사 유지")
            return nil
        }

        // 번역 승계: 라이브 행의 한국어를 가장 많이 겹치는 정제 행에 붙임
        for live in liveRows {
            guard let korean = live.korean, !korean.isEmpty else { continue }
            guard let index = bestOverlapIndex(
                start: live.startSeconds, end: live.endSeconds,
                channel: live.channel, in: refined) else { continue }
            if let existing = refined[index].korean, !existing.isEmpty {
                refined[index].korean = existing + " " + korean
            } else {
                refined[index].korean = korean
            }
        }

        refined.sort { $0.startSeconds < $1.startSeconds }

        // 채널 간 에코 중복 제거 (마이크 WAV는 게이트 없이 재디코딩되므로 여기서 걸러야 함)
        // + 구두점만 남은 빈 행 제거
        let deduped = EchoDedup.removeEchoRows(refined)
        let finalRows = assignClusters(rows: deduped.rows, diarization: diarization)
        AppLog.write("app", "2-pass 재디코딩 \(String(format: "%.1f", Date().timeIntervalSince(started)))s - rows \(liveRows.count)→\(finalRows.count) (에코·빈행 \(deduped.removed)개 제거), \(liveLength)→\(refinedLength)자")
        return finalRows
    }

    /// them 채널 정제 행에 다이어라이제이션 클러스터 ID 할당
    static func assignClusters(rows: [TranscriptRow], diarization: OfflineDiarization?) -> [TranscriptRow] {
        guard let diarization else { return rows }
        return rows.map { row in
            var updated = row
            if row.channel == .them {
                updated.clusterID = diarization.dominantCluster(from: row.startSeconds, to: row.endSeconds)
            }
            return updated
        }
    }

    // MARK: - 문장 분리 (토큰 타임스탬프 기반)

    private struct Sentence {
        let text: String
        let start: Double
        let end: Double
    }

    private static func split(_ timings: [TokenTiming]) -> [Sentence] {
        var sentences: [Sentence] = []
        var currentTokens: [TokenTiming] = []

        func flush() {
            guard let first = currentTokens.first, let last = currentTokens.last else { return }
            let text = currentTokens.map(\.token).joined()
                .replacingOccurrences(of: "▁", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                sentences.append(Sentence(
                    text: text,
                    start: Double(first.startTime),
                    end: Double(last.endTime)))
            }
            currentTokens = []
        }

        for (index, timing) in timings.enumerated() {
            currentTokens.append(timing)
            let trimmed = timing.token.trimmingCharacters(in: .whitespaces)
            let terminal = trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!")
            let gap: Double
            if index + 1 < timings.count {
                gap = Double(timings[index + 1].startTime) - Double(timing.endTime)
            } else {
                gap = .infinity
            }
            let duration = Double(timing.endTime) - Double(currentTokens.first.map { Double($0.startTime) } ?? 0)
            if terminal || gap > gapBoundary || duration > maxSentenceSeconds {
                flush()
            }
        }
        flush()
        return sentences
    }

    // MARK: - 시간 겹침 매칭

    static func overlap(_ aStart: Double, _ aEnd: Double, _ bStart: Double, _ bEnd: Double) -> Double {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }

    static func bestOverlap(start: Double, end: Double, in rows: [TranscriptRow]) -> TranscriptRow? {
        rows.max { lhs, rhs in
            overlap(start, end, lhs.startSeconds, lhs.endSeconds)
                < overlap(start, end, rhs.startSeconds, rhs.endSeconds)
        }.flatMap { best in
            overlap(start, end, best.startSeconds, best.endSeconds) > 0 ? best : nil
        }
    }

    private static func bestOverlapIndex(
        start: Double, end: Double, channel: AudioChannel, in rows: [TranscriptRow]
    ) -> Int? {
        var bestIndex: Int?
        var bestValue: Double = 0
        for (index, row) in rows.enumerated() where row.channel == channel {
            let value = overlap(start, end, row.startSeconds, row.endSeconds)
            if value > bestValue {
                bestValue = value
                bestIndex = index
            }
        }
        return bestIndex
    }
}
