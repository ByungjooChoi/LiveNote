import Foundation

/// 라이브 회의 중 LS-EEND 화자 슬롯의 음성 샘플을 축적하여 성문 임베딩을 추출하고
/// 등록된 화자로 자동 승격시키는 액터
actor LiveVoicePromoter {

    private let sampleRate: Int = 16_000
    private let maxBufferSeconds: Double = 90.0

    private let capacity: Int
    private var buffer: [Float]
    private var totalSamplesIngested: Int = 0

    private var accumulatedSpeechSeconds: [Int: Double] = [:]
    private var accumulatedSegments: [Int: [(start: Double, end: Double)]] = [:]
    private var promotedSlots: Set<Int> = []
    private var loggedLackingAudioSlots: Set<Int> = []

    private var pendingPromotionQueue: [Int] = []
    private var queuedSlots: Set<Int> = []
    private var drainTask: Task<Void, Never>? = nil

    private let diarizer: OfflineDiarizer?
    private let embeddingProvider: (@Sendable ([Float]) async throws -> [Float])?

    var diarizerInstance: OfflineDiarizer? { diarizer }

    private(set) var generation: Int = 0

    var currentGeneration: Int { generation }

    /// 슬롯 승격 임베딩 추출 완료 콜백 (MainActor에서 VoiceprintStore.match 수행)
    var onEmbedding: (@Sendable (Int, [Float], Double, Int) -> Void)?

    init(
        diarizer: OfflineDiarizer? = nil,
        embeddingProvider: (@Sendable ([Float]) async throws -> [Float])? = nil,
        onEmbedding: (@Sendable (Int, [Float], Double, Int) -> Void)? = nil
    ) {
        self.diarizer = diarizer
        self.embeddingProvider = embeddingProvider
        self.onEmbedding = onEmbedding
        let cap = Int(90.0 * 16_000.0)
        self.capacity = cap
        self.buffer = [Float](repeating: 0, count: cap)
    }

    func setOnEmbedding(_ callback: (@Sendable (Int, [Float], Double, Int) -> Void)?) {
        self.onEmbedding = callback
    }

    /// 시스템 오디오(상대방 채널) 16kHz 모노 샘플을 고정 크기 링 버퍼에 O(chunk)로 기록 (최대 90초 유지)
    func append(samples: [Float]) {
        guard !samples.isEmpty else { return }

        let incoming: [Float]
        let startPos: Int
        let count: Int

        if samples.count > capacity {
            incoming = Array(samples.suffix(capacity))
            startPos = (totalSamplesIngested + samples.count - capacity) % capacity
            count = capacity
        } else {
            incoming = samples
            startPos = totalSamplesIngested % capacity
            count = incoming.count
        }

        totalSamplesIngested += samples.count

        if startPos + count <= capacity {
            buffer.replaceSubrange(startPos..<(startPos + count), with: incoming)
        } else {
            let firstPart = capacity - startPos
            buffer.replaceSubrange(startPos..<capacity, with: incoming[0..<firstPart])
            let secondPart = count - firstPart
            buffer.replaceSubrange(0..<secondPart, with: incoming[firstPart..<count])
        }
    }

    /// 확정된 화자 세그먼트를 슬롯별로 누적하고 30초 도달 시 승격 작업을 큐에 넣고 즉시 반환
    func noteSegments(slot: Int, segments: [(start: Double, end: Double)]) {
        guard !promotedSlots.contains(slot), !segments.isEmpty else { return }

        for seg in segments {
            let dur = max(0, seg.end - seg.start)
            guard dur > 0 else { continue }
            accumulatedSpeechSeconds[slot, default: 0] += dur
            accumulatedSegments[slot, default: []].append(seg)
        }

        let threshold: Double
        if let custom = UserDefaults.standard.object(forKey: "voicePromoteSeconds") as? Double, custom > 0 {
            threshold = custom
        } else {
            threshold = 30.0
        }

        let currentSpeech = accumulatedSpeechSeconds[slot, default: 0]
        if currentSpeech >= threshold && !promotedSlots.contains(slot) && !queuedSlots.contains(slot) {
            queuedSlots.insert(slot)
            pendingPromotionQueue.append(slot)
            ensureDrainTaskRunning(threshold: threshold)
        }
    }

    /// 단일 백그라운드 유틸리티 태스크로 승격 큐를 드레인
    private func ensureDrainTaskRunning(threshold: Double) {
        guard drainTask == nil else { return }
        let taskGen = self.generation
        drainTask = Task(priority: .utility) { [weak self, taskGen] in
            while !Task.isCancelled {
                guard let self else { break }
                guard let nextSlot = await self.dequeueNextSlot(for: taskGen) else {
                    break
                }
                await self.processPromotion(slot: nextSlot, threshold: threshold, taskGen: taskGen)
            }
            if let self {
                await self.clearDrainTask(for: taskGen)
            }
        }
    }

    private func dequeueNextSlot(for expectedGen: Int) -> Int? {
        guard generation == expectedGen, !pendingPromotionQueue.isEmpty else { return nil }
        let slot = pendingPromotionQueue.removeFirst()
        queuedSlots.remove(slot)
        return slot
    }

    private func clearDrainTask(for expectedGen: Int) {
        if generation == expectedGen {
            drainTask = nil
        }
    }

    private func processPromotion(slot: Int, threshold: Double, taskGen: Int) async {
        guard generation == taskGen, !promotedSlots.contains(slot) else { return }

        let segs = accumulatedSegments[slot, default: []]
        let (audioSamples, actualSecs) = extractSamples(for: segs, maxSeconds: threshold)

        guard actualSecs >= threshold else {
            pruneExpiredSegments(for: slot)
            if !loggedLackingAudioSlots.contains(slot) {
                loggedLackingAudioSlots.insert(slot)
                AppLog.write("voice", "Live promoter: Insufficient buffered audio for slot \(slot) (\(String(format: "%.1f", actualSecs))s < \(String(format: "%.1f", threshold))s), awaiting more speech")
            }
            return
        }

        promotedSlots.insert(slot)

        let provider = self.embeddingProvider
        let diarizer = self.diarizer
        let callback = self.onEmbedding

        do {
            let emb: [Float]
            if let provider {
                emb = try await provider(audioSamples)
            } else if let diarizer {
                emb = try await diarizer.embedding(samples: audioSamples)
            } else {
                throw NSError(
                    domain: "livenote2.promoter",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No embedding engine available"]
                )
            }
            guard !Task.isCancelled, self.generation == taskGen else {
                AppLog.write("voice", "Live promoter dropped result for slot \(slot): cancelled or generation mismatch")
                return
            }
            AppLog.write("voice", "Live promotion extracted embedding for slot \(slot): \(String(format: "%.1f", actualSecs))s")
            callback?(slot, emb, actualSecs, taskGen)
        } catch {
            if !Task.isCancelled {
                AppLog.write("voice", "Live promotion failed for slot \(slot): \(error.localizedDescription)")
            }
        }
    }

    /// 누적 세그먼트 구간의 오디오 슬라이스를 링 버퍼에서 추출하여 연결 (최대 maxSeconds)
    func extractSamples(
        for segments: [(start: Double, end: Double)],
        maxSeconds: Double = 30.0
    ) -> (samples: [Float], actualSeconds: Double) {
        var result: [Float] = []
        let maxSamples = Int(maxSeconds * Double(sampleRate))

        let validStart = max(0, totalSamplesIngested - capacity)
        let validEnd = totalSamplesIngested
        guard validEnd > validStart else {
            return ([], 0.0)
        }

        for seg in segments {
            let segStartSample = Int(seg.start * Double(sampleRate))
            let segEndSample = Int(seg.end * Double(sampleRate))
            guard segEndSample > segStartSample else { continue }

            let overlapStart = max(segStartSample, validStart)
            let overlapEnd = min(segEndSample, validEnd)
            guard overlapEnd > overlapStart else { continue }

            let needed = min(overlapEnd - overlapStart, maxSamples - result.count)
            guard needed > 0 else { break }

            let startIdx = overlapStart % capacity
            if startIdx + needed <= capacity {
                result.append(contentsOf: buffer[startIdx..<(startIdx + needed)])
            } else {
                let firstPart = capacity - startIdx
                result.append(contentsOf: buffer[startIdx..<capacity])
                let secondPart = needed - firstPart
                result.append(contentsOf: buffer[0..<secondPart])
            }

            if result.count >= maxSamples {
                break
            }
        }

        let actualSecs = Double(result.count) / Double(sampleRate)
        return (result, actualSecs)
    }

    /// 링 버퍼 윈도우(최근 90초) 밖으로 벗어난 세그먼트를 제거하고 누적 발화 시간 재계산
    private func pruneExpiredSegments(for slot: Int) {
        let validStartSample = max(0, totalSamplesIngested - capacity)
        let validStartTime = Double(validStartSample) / Double(sampleRate)

        guard let segs = accumulatedSegments[slot] else { return }
        var kept: [(start: Double, end: Double)] = []
        for seg in segs {
            if seg.end <= validStartTime {
                continue
            }
            let clampedStart = max(seg.start, validStartTime)
            if seg.end > clampedStart {
                kept.append((start: clampedStart, end: seg.end))
            }
        }
        accumulatedSegments[slot] = kept
        accumulatedSpeechSeconds[slot] = kept.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    /// 세션 시작 시 내부 버퍼 및 누적 상태 초기화 (세대 증가 및 진행 중인 드레인 태스크 취소)
    func reset() {
        generation += 1
        drainTask?.cancel()
        drainTask = nil
        pendingPromotionQueue.removeAll()
        queuedSlots.removeAll()
        buffer = [Float](repeating: 0, count: capacity)
        totalSamplesIngested = 0
        accumulatedSpeechSeconds.removeAll()
        accumulatedSegments.removeAll()
        promotedSlots.removeAll()
        loggedLackingAudioSlots.removeAll()
    }
}
