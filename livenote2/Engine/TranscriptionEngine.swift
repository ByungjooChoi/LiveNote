import Foundation
import FluidAudio

/// 전사 엔진.
/// 채널별(나/상대방)로 에너지 기반 문장 분리를 하고,
/// 말하는 도중엔 잠정(volatile) 전사, 문장이 닫히면 확정 전사를 내보냅니다.
///
/// ASR: FluidAudio Parakeet TDT v2 (영어 전용, CoreML/ANE, ~460MB 최초 다운로드)
/// 문장 분리: RMS 에너지 게이트
///
/// 에코 게이트 (포락선 상관 기반):
/// 스피커로 나가는 소리의 디지털 원본(시스템 채널)을 참조 신호로 갖고 있으므로,
/// 마이크 신호의 에너지 포락선이 시스템 신호의 0~0.6초 전 포락선과 닮았는지(상관계수)로
/// 에코를 판정합니다. 에코는 원본의 시간 이동 복사본이라 상관이 높고, 실제 내 발화는
/// 무관한 패턴이라 낮습니다. 크기가 아닌 "모양" 비교라 스피커 볼륨과 무관하게 동작합니다.
actor TranscriptionEngine {

    // MARK: - 튜닝 상수 (16kHz 샘플 기준)

    private static let sampleRate = 16_000
    /// 이 RMS를 넘으면 "말하는 중"으로 판정
    private static let speechThreshold: Float = 0.008
    /// 말이 끊긴 뒤 이 시간이 지나면 문장 확정
    private static let hangoverSamples = Int(0.9 * Double(sampleRate))
    /// 문장 최대 길이 (넘으면 강제 확정 후 이어서 새 문장)
    private static let hardCapSamples = 12 * sampleRate
    /// 잠정 전사 주기
    private static let volatileIntervalSamples = Int(1.4 * Double(sampleRate))
    /// 이보다 짧은 조각은 버림
    private static let minSegmentSamples = Int(0.4 * Double(sampleRate))
    /// 문장 시작 직전 보존할 프리롤
    private static let preRollSamples = Int(0.3 * Double(sampleRate))
    /// 연속 발화가 이 길이를 넘으면 "내부 문장 경계"에서 조기 확정을 시도 (§5.1)
    private static let earlyCloseMinSamples = 7 * sampleRate
    /// 내부 경계로 인정하려면 경계 뒤에 최소 이만큼 토큰이 더 있어야 함 (발화가 이어지는 중)
    private static let earlyCloseMinTrailingTokens = 2
    /// 경계 시각 하한 (너무 짧은 파편 방지)
    private static let earlyCloseMinBoundarySeconds = 3.0

    // MARK: - 에코 게이트 상수

    /// 포락선 프레임 길이 (10ms @ 16kHz)
    private static let envelopeFrameSamples = 160
    /// 시스템 채널 포락선 보관 길이 (150 프레임 = 1.5초)
    private static let themEnvelopeCapacity = 150
    /// 상관 계산에 쓸 마이크 최근 프레임 수 (30 = 0.3초)
    private static let meEnvelopeFrames = 30
    /// 에코 지연 탐색 범위 (60 프레임 = 0~0.6초; 출력 지연 + 공기 전파 + 입력 지연)
    private static let maxEchoLagFrames = 60
    /// 이 상관계수 이상이면 에코로 판정
    private static let echoCorrelationThreshold: Float = 0.55
    /// 마이크가 시스템 피크의 이 배수보다 크면 근접 발화 우세로 즉시 통과
    private static let micDominanceRatio: Float = 1.5
    /// 시스템 채널이 이 RMS를 넘어야 "스피커에서 소리가 나는 중"
    private static let echoSystemActiveThreshold: Float = 0.008
    /// 세그먼트 내 에코 판정 청크 비율이 이걸 넘으면 세그먼트 폐기
    private static let segmentEchoDropFraction = 0.6

    // MARK: - 콜백 (AppState가 MainActor 전환을 책임짐)

    private let onVolatile: @Sendable (AudioChannel, String) -> Void
    private let onFinal: @Sendable (FinalSegment) -> Void
    private let onStatus: @Sendable (String) -> Void

    // MARK: - 상태

    private var asrManager: AsrManager?
    private var asrBusy = false

    /// 에코 게이트 on/off (UI 토글과 연동)
    private var echoFilterEnabled = true
    /// 마이크 뮤트. true면 .me 채널 오디오를 버림 (오디오 스레드가 아닌 actor에서 판정 — §7.4).
    private var micMuted = false
    /// 채널별 10ms 포락선 링과 프레임 조립용 잔여 샘플
    private var envelope: [AudioChannel: [Float]] = [.me: [], .them: []]
    private var envelopePending: [AudioChannel: [Float]] = [.me: [], .them: []]

    private struct ChannelTracker {
        var totalSamples = 0
        var active = false
        var buffer: [Float] = []
        var preRoll: [Float] = []
        var segmentStartSample = 0
        var lastSpeechSample = 0
        var lastVolatileSample = 0
        /// 열려 있는 세그먼트 동안의 에코 판정 통계 (me 채널 전용)
        var gateChunksTotal = 0
        var gateChunksEcho = 0
    }

    private var trackers: [AudioChannel: ChannelTracker] = [.me: .init(), .them: .init()]

    init(
        onVolatile: @escaping @Sendable (AudioChannel, String) -> Void,
        onFinal: @escaping @Sendable (FinalSegment) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) {
        self.onVolatile = onVolatile
        self.onFinal = onFinal
        self.onStatus = onStatus
    }

    // MARK: - 설정

    func setEchoFilter(_ enabled: Bool) {
        echoFilterEnabled = enabled
    }

    /// 마이크 뮤트 설정. 뮤트 시 열려 있던 "나" 문장은 즉시 확정.
    func setMicMuted(_ muted: Bool) async {
        micMuted = muted
        if muted {
            await flushChannel(.me)
        }
    }

    // MARK: - 준비

    /// Parakeet v2 모델 다운로드(최초 1회) 및 로드.
    func prepare() async throws {
        onStatus("Parakeet 영어 모델 준비 중… 첫 실행은 약 500MB를 다운로드합니다.")
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asrManager = manager
        onStatus("모델 준비 완료")
    }

    // MARK: - 오디오 유입

    func ingest(_ samples: [Float], channel: AudioChannel) async {
        // 뮤트 중엔 마이크 채널을 통째로 버림 (에코 유입 원천 차단)
        if channel == .me, micMuted { return }
        guard var tracker = trackers[channel], !samples.isEmpty else { return }

        // 포락선 갱신은 게이트 판정보다 먼저 (현재 청크 포함)
        updateEnvelope(samples, channel: channel)

        let rms = Self.rms(samples)
        let isEchoChunk = (channel == .me) ? micChunkIsEcho(rms) : false
        let isSpeech = rms > Self.speechThreshold && !isEchoChunk

        tracker.totalSamples += samples.count

        if tracker.active {
            tracker.buffer.append(contentsOf: samples)
            if channel == .me {
                tracker.gateChunksTotal += 1
                if isEchoChunk { tracker.gateChunksEcho += 1 }
            }
            if isSpeech {
                tracker.lastSpeechSample = tracker.totalSamples
            }

            let silenceGap = tracker.totalSamples - tracker.lastSpeechSample
            let reachedCap = tracker.buffer.count >= Self.hardCapSamples

            if silenceGap >= Self.hangoverSamples || reachedCap {
                // 문장 확정
                let segment = tracker
                trackers[channel] = Self.resetAfterClose(tracker, keepActive: reachedCap)
                await finalize(channel: channel, tracker: segment)
            } else if tracker.totalSamples - tracker.lastVolatileSample >= Self.volatileIntervalSamples,
                      tracker.buffer.count >= Self.minSegmentSamples {
                // 잠정 전사 (ASR가 바쁘면 이번 주기는 건너뜀)
                tracker.lastVolatileSample = tracker.totalSamples
                trackers[channel] = tracker
                await runVolatile(channel: channel, snapshot: tracker.buffer, segmentStart: tracker.segmentStartSample)
            } else {
                trackers[channel] = tracker
            }
        } else {
            // 대기 상태: 프리롤 유지하다가 말이 시작되면 문장 오픈
            tracker.preRoll.append(contentsOf: samples)
            if tracker.preRoll.count > Self.preRollSamples {
                tracker.preRoll.removeFirst(tracker.preRoll.count - Self.preRollSamples)
            }
            if isSpeech {
                tracker.active = true
                tracker.segmentStartSample = max(0, tracker.totalSamples - samples.count - tracker.preRoll.count)
                tracker.buffer = tracker.preRoll + samples
                tracker.preRoll = []
                tracker.lastSpeechSample = tracker.totalSamples
                tracker.lastVolatileSample = tracker.totalSamples
                tracker.gateChunksTotal = 1
                tracker.gateChunksEcho = 0
            }
            trackers[channel] = tracker
        }
    }

    /// 녹음 중지 시 열려 있는 문장을 모두 확정.
    func flushAll() async {
        for channel in [AudioChannel.me, .them] {
            await flushChannel(channel)
        }
    }

    /// 한 채널의 열린 문장을 강제 확정 (뮤트 시 .me 채널에도 사용).
    func flushChannel(_ channel: AudioChannel) async {
        guard let tracker = trackers[channel], tracker.active,
              tracker.buffer.count >= Self.minSegmentSamples else {
            trackers[channel]?.active = false
            trackers[channel]?.buffer = []
            trackers[channel]?.preRoll = []
            return
        }
        trackers[channel] = Self.resetAfterClose(tracker, keepActive: false)
        await finalize(channel: channel, tracker: tracker)
    }

    // MARK: - 에코 게이트 (포락선 상관)

    private func updateEnvelope(_ samples: [Float], channel: AudioChannel) {
        var pending = envelopePending[channel] ?? []
        var ring = envelope[channel] ?? []
        pending.append(contentsOf: samples)
        while pending.count >= Self.envelopeFrameSamples {
            let frame = Array(pending.prefix(Self.envelopeFrameSamples))
            pending.removeFirst(Self.envelopeFrameSamples)
            ring.append(Self.rms(frame))
        }
        let capacity = (channel == .them) ? Self.themEnvelopeCapacity : Self.meEnvelopeFrames + 10
        if ring.count > capacity {
            ring.removeFirst(ring.count - capacity)
        }
        envelopePending[channel] = pending
        envelope[channel] = ring
    }

    /// 현재 마이크 청크가 스피커 에코인지 판정.
    private func micChunkIsEcho(_ micRMS: Float) -> Bool {
        guard echoFilterEnabled else { return false }
        let themEnv = envelope[.them] ?? []
        guard themEnv.count >= Self.meEnvelopeFrames + 5 else { return false }

        // 스피커가 조용하면 에코일 수 없음
        let themPeak = themEnv.suffix(Self.meEnvelopeFrames + Self.maxEchoLagFrames).max() ?? 0
        guard themPeak > Self.echoSystemActiveThreshold else { return false }

        // 마이크가 시스템 레벨을 압도하면 근접 발화 (입 > 스피커)
        if micRMS > themPeak * Self.micDominanceRatio { return false }

        let meEnv = envelope[.me] ?? []
        guard meEnv.count >= Self.meEnvelopeFrames else { return false }

        // 로그 포락선 상관: 마이크 최근 0.3초 vs 시스템의 0~0.6초 전 구간들
        let a = Array(meEnv.suffix(Self.meEnvelopeFrames)).map { log($0 + 1e-5) }
        let b = themEnv.map { log($0 + 1e-5) }
        let n = Self.meEnvelopeFrames
        let maxLag = min(Self.maxEchoLagFrames, b.count - n)
        guard maxLag >= 0 else { return false }

        var bestCorrelation: Float = 0
        var lag = 0
        while lag <= maxLag {
            let start = b.count - n - lag
            let window = Array(b[start..<(start + n)])
            bestCorrelation = max(bestCorrelation, Self.pearson(a, window))
            lag += 2   // 20ms 간격 탐색이면 충분
        }
        return bestCorrelation >= Self.echoCorrelationThreshold
    }

    private static func pearson(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let n = Float(a.count)
        var meanA: Float = 0
        var meanB: Float = 0
        for i in 0..<a.count {
            meanA += a[i]
            meanB += b[i]
        }
        meanA /= n
        meanB /= n
        var numerator: Float = 0
        var varA: Float = 0
        var varB: Float = 0
        for i in 0..<a.count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            numerator += da * db
            varA += da * da
            varB += db * db
        }
        let denominator = (varA * varB).squareRoot()
        guard denominator > 1e-6 else { return 0 }
        return numerator / denominator
    }

    // MARK: - 전사 실행

    private func finalize(channel: AudioChannel, tracker: ChannelTracker) async {
        guard tracker.buffer.count >= Self.minSegmentSamples else {
            onVolatile(channel, "")
            return
        }
        // 세그먼트 대부분이 에코 판정이면 전사하지 않고 폐기 (마이크 채널만)
        if channel == .me, echoFilterEnabled, tracker.gateChunksTotal >= 4 {
            let echoFraction = Double(tracker.gateChunksEcho) / Double(tracker.gateChunksTotal)
            if echoFraction > Self.segmentEchoDropFraction {
                onVolatile(channel, "")
                return
            }
        }
        guard let text = await runTranscribe(tracker.buffer, channel: channel), Self.isMeaningful(text) else {
            onVolatile(channel, "")
            return
        }
        let start = Double(tracker.segmentStartSample) / Double(Self.sampleRate)
        let end = Double(tracker.totalSamples) / Double(Self.sampleRate)
        onVolatile(channel, "")
        onFinal(FinalSegment(channel: channel, text: text, startSeconds: start, endSeconds: end))
    }

    private func runVolatile(channel: AudioChannel, snapshot: [Float], segmentStart: Int) async {
        guard !asrBusy else { return }
        guard let result = await runTranscribeResult(snapshot, channel: channel) else { return }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isMeaningful(text) else { return }

        // 내부 문장 경계 조기 확정 (2026-08-21 재설계).
        // 이전 방식(끝이 종결부호면 승격)은 Parakeet이 잘린 오디오 끝에 붙이는 추정 마침표에
        // 속아 가짜 경계에서 잘랐다 → 어색한 문장의 원인. 새 방식:
        // "문장이 끝났고 그 뒤에 새 문장이 이미 진행 중"인 내부 경계에서만 자른다.
        // 토큰 타임스탬프로 오디오를 경계 시각에서 정확히 자르고, 경계 뒤 오디오는
        // 버퍼에 남겨 다음 확정에서 온전히 재전사한다 (단어 유실·중복 없음).
        if snapshot.count >= Self.earlyCloseMinSamples,
           let timings = result.tokenTimings, !timings.isEmpty,
           let boundary = Self.lastInternalSentenceBoundary(text: text, timings: timings),
           var tracker = trackers[channel],
           tracker.active,
           tracker.segmentStartSample == segmentStart,      // await 중 다른 확정이 없었는지
           tracker.buffer.count >= snapshot.count {
            let cutSample = min(snapshot.count, Int((boundary.time + 0.05) * Double(Self.sampleRate)))
            if cutSample > Self.minSegmentSamples, cutSample < tracker.buffer.count {
                let remainder = Array(tracker.buffer.suffix(tracker.buffer.count - cutSample))
                let start = Double(tracker.segmentStartSample) / Double(Self.sampleRate)
                let end = Double(tracker.segmentStartSample + cutSample) / Double(Self.sampleRate)
                tracker.segmentStartSample += cutSample
                tracker.buffer = remainder
                tracker.gateChunksTotal = 0
                tracker.gateChunksEcho = 0
                tracker.lastVolatileSample = tracker.totalSamples
                trackers[channel] = tracker
                onVolatile(channel, "")
                onFinal(FinalSegment(channel: channel, text: boundary.prefixText, startSeconds: start, endSeconds: end))
                return
            }
        }

        onVolatile(channel, text)
    }

    private static let sentenceTerminators: Set<Character> = [".", "?", "!", "…"]

    /// 텍스트의 "내부" 문장 경계 중 조건을 만족하는 마지막 것을 찾음.
    /// 조건: 경계 토큰 뒤에 토큰이 2개 이상 더 있고 (발화가 이어짐), 경계 시각 ≥ 3초 (파편 방지).
    /// 반환: 경계 시각(스냅샷 기준 초)과 경계까지의 텍스트. 토큰 순번과 텍스트 순번을 대응시켜 절단.
    private static func lastInternalSentenceBoundary(
        text: String, timings: [TokenTiming]
    ) -> (time: Double, prefixText: String)? {
        // 토큰 쪽: 종결부호로 끝나는 토큰들 중 조건 만족하는 마지막 것과 그 순번
        var ordinal = 0
        var best: (ordinal: Int, time: Double)?
        for (index, timing) in timings.enumerated() {
            guard let lastChar = timing.token.last, sentenceTerminators.contains(lastChar) else { continue }
            ordinal += 1
            let trailing = timings.count - 1 - index
            if trailing >= earlyCloseMinTrailingTokens, timing.endTime >= earlyCloseMinBoundarySeconds {
                best = (ordinal, timing.endTime)
            }
        }
        guard let best else { return nil }

        // 텍스트 쪽: 같은 순번의 종결부호(뒤가 공백 또는 끝) 위치에서 절단
        var count = 0
        var index = text.startIndex
        while index < text.endIndex {
            if sentenceTerminators.contains(text[index]) {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " {
                    count += 1
                    if count == best.ordinal {
                        let prefix = String(text[text.startIndex..<next])
                            .trimmingCharacters(in: .whitespaces)
                        return prefix.count >= 2 ? (best.time, prefix) : nil
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// ASR 호출 직렬화. Parakeet은 빨라서(실시간의 100배+) 대기가 거의 없음.
    /// FluidAudio v0.15.2 공개 API는 명시적 디코더 상태를 요구합니다.
    /// 매 호출이 독립된 버퍼의 배치 전사이므로 항상 새 상태로 시작합니다
    /// (기본 2 레이어 = v2 모델 구조와 일치).
    private func runTranscribe(_ samples: [Float], channel: AudioChannel) async -> String? {
        guard let result = await runTranscribeResult(samples, channel: channel) else { return nil }
        return result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    /// 전체 ASRResult 반환 (토큰 타임스탬프 포함 — 내부 경계 분할용).
    private func runTranscribeResult(_ samples: [Float], channel: AudioChannel) async -> ASRResult? {
        guard let asrManager else { return nil }
        while asrBusy {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        asrBusy = true
        defer { asrBusy = false }
        do {
            var decoderState = try TdtDecoderState()
            return try await asrManager.transcribe(samples, decoderState: &decoderState)
        } catch {
            return nil
        }
    }

    // MARK: - 헬퍼

    private static func resetAfterClose(_ tracker: ChannelTracker, keepActive: Bool) -> ChannelTracker {
        var next = tracker
        if keepActive {
            // 최대 길이 도달로 잘린 경우: 0.2초 꼬리를 물고 바로 다음 문장 시작
            let tail = Array(tracker.buffer.suffix(Int(0.2 * Double(sampleRate))))
            next.buffer = tail
            next.segmentStartSample = tracker.totalSamples - tail.count
            next.active = true
        } else {
            next.buffer = []
            next.active = false
        }
        next.preRoll = []
        next.lastVolatileSample = tracker.totalSamples
        next.gateChunksTotal = 0
        next.gateChunksEcho = 0
        return next
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    private static func isMeaningful(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2
    }
}
