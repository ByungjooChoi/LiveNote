import Foundation

/// 채널 간 에코 중복 판정 (v1.3.1).
///
/// 스피커 사용 시 상대방 목소리가 마이크로 재유입되면 같은 문장이 them(시스템 오디오)과
/// me(마이크) 양쪽에 전사된다. 라이브 경로의 에너지 게이트가 놓치거나, 2-pass 재디코딩이
/// 마이크 WAV를 게이트 없이 다시 읽으면 저장본에 중복이 남는다. 텍스트 유사도 + 시간 근접으로
/// 마이크 쪽 사본을 제거한다 (에코는 항상 스피커→마이크 방향이므로 them이 원본).
enum EchoDedup {

    /// 유사도 임계 (작은 쪽 토큰 집합 기준 포함률)
    static let similarityThreshold = 0.6
    /// 시간 근접 허용 (초): 구간이 겹치거나 이 이내로 떨어져 있으면 같은 발화로 간주
    static let proximitySeconds = 3.0
    /// 판정 최소 토큰 수 (너무 짧은 문장은 우연 일치가 잦음)
    static let minTokens = 3

    static func normalizedTokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// 두 토큰 집합의 포함률 (작은 쪽 기준). 0.0~1.0
    static func similarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let setA = Set(a)
        let setB = Set(b)
        let common = setA.intersection(setB).count
        return Double(common) / Double(min(setA.count, setB.count))
    }

    static func isNear(_ aStart: Double, _ aEnd: Double, _ bStart: Double, _ bEnd: Double) -> Bool {
        max(aStart, bStart) - min(aEnd, bEnd) <= proximitySeconds
    }

    /// 두 발화가 채널 간 에코 관계인지
    static func isEcho(textA: String, startA: Double, endA: Double,
                       textB: String, startB: Double, endB: Double) -> Bool {
        guard isNear(startA, endA, startB, endB) else { return false }
        let tokensA = normalizedTokens(textA)
        let tokensB = normalizedTokens(textB)
        guard tokensA.count >= minTokens, tokensB.count >= minTokens else { return false }
        return similarity(tokensA, tokensB) >= similarityThreshold
    }

    /// 텍스트로서 의미가 있는 행인지 (구두점·공백만 남은 "." 같은 행 제거용)
    static func hasContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// 행 목록에서 me 채널의 에코 사본을 제거하고, 내용 없는 행도 제거한다.
    static func removeEchoRows(_ rows: [TranscriptRow]) -> (rows: [TranscriptRow], removed: Int) {
        let themRows = rows.filter { $0.channel == .them }
        var removed = 0
        let kept = rows.filter { row in
            guard hasContent(row.english) else { removed += 1; return false }
            guard row.channel == .me else { return true }
            let echo = themRows.contains { them in
                isEcho(textA: row.english, startA: row.startSeconds, endA: row.endSeconds,
                       textB: them.english, startB: them.startSeconds, endB: them.endSeconds)
            }
            if echo { removed += 1 }
            return !echo
        }
        return (kept, removed)
    }
}
