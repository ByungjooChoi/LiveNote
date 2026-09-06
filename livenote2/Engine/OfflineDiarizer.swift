import Foundation
import Accelerate
import FluidAudio

/// 비동기 타임아웃 레이스 결과
public enum TimeoutRaceResult<T: Sendable>: Sendable {
    case finished(T)
    case timedOut
}

/// 비동기 작업과 타이머 간의 단발성(OneShot) 레이스 헬퍼
public final class TimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TimeoutRaceResult<T>, Never>?
    private var resolvedResult: TimeoutRaceResult<T>?

    public init() {}

    public func resolve(_ result: TimeoutRaceResult<T>) {
        lock.lock()
        if resolvedResult != nil {
            lock.unlock()
            return
        }
        resolvedResult = result
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: result)
    }

    public func wait() async -> TimeoutRaceResult<T> {
        await withCheckedContinuation { cont in
            lock.lock()
            if let result = resolvedResult {
                lock.unlock()
                cont.resume(returning: result)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }
}

/// 오프라인 다이어라이제이션 엔진 프로토콜 (테스트 시 가짜 엔진 주입 가능)
protocol OfflineDiarizationEngine: Sendable {
    func prepare() async throws
    func diarize(samples: [Float]) throws -> [SpeakerSegment]
    func embedding(for samples: [Float]) throws -> [Float]
}

/// FluidAudio DiarizerManager 기반 실제 오프라인 다이어라이제이션 엔진
final class FluidOfflineEngine: OfflineDiarizationEngine, @unchecked Sendable {

    private var manager: DiarizerManager?
    private let lock = NSLock()

    func prepare() async throws {
        let models = try await DiarizerModels.downloadIfNeeded()
        lock.withLock {
            if manager == nil {
                let mgr = DiarizerManager(config: .default)
                mgr.initialize(models: models)
                self.manager = mgr
            }
        }
    }

    func diarize(samples: [Float]) throws -> [SpeakerSegment] {
        let mgr = lock.withLock { manager }

        guard let mgr else {
            throw NSError(
                domain: "livenote2.diarizer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "DiarizerManager not initialized"]
            )
        }

        let result = try mgr.performCompleteDiarization(samples, sampleRate: 16_000)
        return result.segments.map { seg in
            SpeakerSegment(
                clusterID: seg.speakerId,
                start: Double(seg.startTimeSeconds),
                end: Double(seg.endTimeSeconds),
                embedding: seg.embedding,
                quality: seg.qualityScore
            )
        }
    }

    func embedding(for samples: [Float]) throws -> [Float] {
        let mgr = lock.withLock { manager }

        guard let mgr else {
            throw NSError(
                domain: "livenote2.diarizer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "DiarizerManager not initialized"]
            )
        }

        return try mgr.extractSpeakerEmbedding(from: samples)
    }
}

/// 2-pass 오프라인 화자 분리 및 성문 임베딩 추출 액터
/// `diarize` and `embedding` hold the actor for the whole synchronous engine call. Three consumers therefore use three instances: the session diarizer (`AppState.offlineDiarizer`), the live promoter (`AppState.liveEmbeddingExtractor`), and a temporary instance created inside the me-enrollment task.
actor OfflineDiarizer {

    private let engine: OfflineDiarizationEngine
    private var isPrepared = false

    init(engine: OfflineDiarizationEngine = FluidOfflineEngine()) {
        self.engine = engine
    }

    /// 엔진 초기화 및 모델 다운로드
    func prepare() async throws {
        guard !isPrepared else { return }
        try await engine.prepare()
        isPrepared = true
    }

    /// 16kHz 모노 16-bit WAV 파일을 읽어 오프라인 다이어라이제이션 수행 (필요 시 16kHz로 리샘플링)
    func diarize(wavURL: URL, skipSilence: Bool? = nil) async throws -> OfflineDiarization {
        try await prepare()

        let (rawSamples, rawSampleRate) = try Self.loadWAV(url: wavURL)
        guard !rawSamples.isEmpty else {
            return OfflineDiarization(segments: [], processingSeconds: 0, audioSeconds: 0)
        }

        let samples: [Float]
        let sampleRate: Int = 16_000
        if rawSampleRate != 16_000 {
            samples = Self.resampleTo16k(rawSamples, from: rawSampleRate)
        } else {
            samples = rawSamples
        }

        guard !samples.isEmpty else {
            return OfflineDiarization(segments: [], processingSeconds: 0, audioSeconds: 0)
        }

        let shouldSkipSilence = skipSilence ?? UserDefaults.standard.bool(forKey: "voiceSkipSilence")
        let targetSamples: [Float]
        let keptRanges: [Range<Int>]
        if shouldSkipSilence {
            let filtered = Self.filterSilenceWithRanges(samples: samples, sampleRate: sampleRate)
            targetSamples = filtered.compacted
            keptRanges = filtered.keptRanges
        } else {
            targetSamples = samples
            keptRanges = [0..<samples.count]
        }

        guard !targetSamples.isEmpty else {
            return OfflineDiarization(segments: [], processingSeconds: 0, audioSeconds: Double(samples.count) / Double(sampleRate))
        }

        let started = Date()
        let rawSegments = try engine.diarize(samples: targetSamples)
        let segments = Self.remapToOriginal(segments: rawSegments, keptRanges: keptRanges, sampleRate: sampleRate)
        let processingSeconds = Date().timeIntervalSince(started)
        let audioSeconds = Double(samples.count) / Double(sampleRate)

        let result = OfflineDiarization(
            segments: segments,
            processingSeconds: processingSeconds,
            audioSeconds: audioSeconds
        )

        AppLog.write("voice", "Offline diarization finished: audio=\(String(format: "%.1f", audioSeconds))s processing=\(String(format: "%.2f", processingSeconds))s clusters=\(result.clusterIDs.count)")

        // 1시간 오디오 기준 60초 초과 시 경고 로그
        if audioSeconds > 0 && processingSeconds > (audioSeconds / 3600.0) * 60.0 {
            AppLog.write("voice", "Warning: Diarization processing time (\(String(format: "%.1f", processingSeconds))s) exceeded budget (>60s/hr for \(String(format: "%.1f", audioSeconds))s audio)")
        }

        return result
    }

    /// 단일 화자 음성 샘플에서 256차원 L2 정규화 임베딩 추출
    func embedding(samples: [Float]) async throws -> [Float] {
        try await prepare()
        return try engine.embedding(for: samples)
    }

    /// 본인(Me) 음성 등록용 오디오 클립 추출 (마이크 전체 WAV를 스트리밍 스캔하여 최대 maxSeconds 음성 수집, 침묵 제거, 16kHz 리샘플링)
    nonisolated static func meEnrollmentClip(wavURL: URL, maxSeconds: Double = 60.0) throws -> (samples: [Float], seconds: Double) {
        var reader = try WAVStreamReader(url: wavURL, truncation: .tolerate)
        defer { reader.close() }
        if reader.wasTruncated {
            AppLog.write("voice", "Me 음성 등록 WAV 데이터 청크가 헤더보다 짧음 (잘림 허용됨)")
        }
        let chunkFrames = reader.sampleRate * 10
        return try collectVoicedSamples(
            next: { try reader.nextFrames(maxFrames: chunkFrames) },
            sampleRate: reader.sampleRate,
            maxSeconds: maxSeconds
        )
    }

    /// 스트리밍 방식으로 오디오 청크를 당겨와 RMS 무음 게이트를 통과한 음성 샘플을 최대 maxSeconds(16kHz 기준)까지 수집
    static func collectVoicedSamples(
        next: () throws -> [Float]?,
        sampleRate: Int,
        maxSeconds: Double,
        frameSize: Int = 1_600,
        rmsThreshold: Float = 0.005
    ) throws -> (samples: [Float], seconds: Double) {
        guard maxSeconds > 0 else { return ([], 0) }
        let targetCount = Int(ceil(maxSeconds * 16_000))
        var collected: [Float] = []
        collected.reserveCapacity(targetCount)
        var remainder: [Float] = []

        while collected.count < targetCount {
            guard let rawChunk = try next(), !rawChunk.isEmpty else {
                break
            }

            let chunk16k: [Float]
            if sampleRate != 16_000 {
                chunk16k = resampleTo16k(rawChunk, from: sampleRate)
            } else {
                chunk16k = rawChunk
            }

            let inputSamples = remainder + chunk16k
            var offset = 0

            while offset + frameSize <= inputSamples.count {
                let frame = Array(inputSamples[offset..<(offset + frameSize)])
                var sumSquares: Float = 0
                vDSP_svesq(frame, 1, &sumSquares, vDSP_Length(frameSize))
                let rms = sqrt(sumSquares / Float(frameSize))

                if rms >= rmsThreshold {
                    let needed = targetCount - collected.count
                    if needed <= frameSize {
                        collected.append(contentsOf: frame.prefix(needed))
                        break
                    } else {
                        collected.append(contentsOf: frame)
                    }
                }
                offset += frameSize
                if collected.count >= targetCount { break }
            }

            if collected.count >= targetCount {
                remainder = []
                break
            }

            remainder = Array(inputSamples[offset..<inputSamples.count])
        }

        if collected.count < targetCount && !remainder.isEmpty {
            var sumSquares: Float = 0
            vDSP_svesq(remainder, 1, &sumSquares, vDSP_Length(remainder.count))
            let rms = sqrt(sumSquares / Float(remainder.count))
            if rms >= rmsThreshold {
                let needed = targetCount - collected.count
                collected.append(contentsOf: remainder.prefix(needed))
            }
        }

        let seconds = Double(collected.count) / 16_000.0
        return (collected, seconds)
    }

    // MARK: - 샘플레이트 리샘플링 (순수 함수)

    /// 샘플레이트가 16kHz가 아닌 오디오를 16kHz로 선형 보간 리샘플링
    static func resampleTo16k(_ samples: [Float], from rate: Int) -> [Float] {
        guard rate != 16_000, rate > 0, !samples.isEmpty else {
            return samples
        }
        let targetRate: Double = 16_000
        let sourceRate = Double(rate)
        let ratio = targetRate / sourceRate
        let targetCount = Int(Double(samples.count) * ratio)
        guard targetCount > 0 else { return [] }

        var resampled = [Float](repeating: 0, count: targetCount)
        let step = sourceRate / targetRate

        for i in 0..<targetCount {
            let srcPos = Double(i) * step
            let srcIdx = Int(srcPos)
            let frac = Float(srcPos - Double(srcIdx))

            if srcIdx + 1 < samples.count {
                resampled[i] = samples[srcIdx] * (1.0 - frac) + samples[srcIdx + 1] * frac
            } else if srcIdx < samples.count {
                resampled[i] = samples[srcIdx]
            }
        }
        return resampled
    }

    // MARK: - 타임라인 리매핑 (순수 함수)

    /// 압축된 오디오 시간(초)을 원본 타임라인 시간(초)으로 변환
    static func mapCompactedSecondsToOriginal(
        compactedSec: Double,
        keptRanges: [Range<Int>],
        sampleRate: Int,
        isEnd: Bool = false
    ) -> Double {
        guard !keptRanges.isEmpty, sampleRate > 0 else { return compactedSec }
        let compactedSample = max(0, compactedSec * Double(sampleRate))
        var cumSamples: Double = 0

        for (i, range) in keptRanges.enumerated() {
            let rangeLen = Double(range.count)
            let matches = isEnd ? (compactedSample <= cumSamples + rangeLen) : (compactedSample < cumSamples + rangeLen)
            if matches || i == keptRanges.count - 1 {
                let offset = max(0, compactedSample - cumSamples)
                let clampedOffset = min(offset, rangeLen)
                let origSample = Double(range.lowerBound) + clampedOffset
                return origSample / Double(sampleRate)
            }
            cumSamples += rangeLen
        }

        guard let last = keptRanges.last else { return compactedSec }
        return Double(last.upperBound) / Double(sampleRate)
    }

    /// 침묵 제거로 압축된 오디오 세그먼트의 start/end를 원본 타임라인으로 복원 (구간 경계 시 분할)
    static func remapToOriginal(
        segments: [SpeakerSegment],
        keptRanges: [Range<Int>],
        sampleRate: Int
    ) -> [SpeakerSegment] {
        guard !keptRanges.isEmpty, sampleRate > 0 else { return segments }
        var result: [SpeakerSegment] = []

        for seg in segments {
            guard seg.end > seg.start else { continue }
            var cumCompactedSec: Double = 0

            for range in keptRanges {
                let rangeLenSec = Double(range.count) / Double(sampleRate)
                let rangeCompactedStart = cumCompactedSec
                let rangeCompactedEnd = cumCompactedSec + rangeLenSec

                let overlapStart = max(seg.start, rangeCompactedStart)
                let overlapEnd = min(seg.end, rangeCompactedEnd)

                if overlapEnd > overlapStart {
                    let offsetStart = overlapStart - rangeCompactedStart
                    let offsetEnd = overlapEnd - rangeCompactedStart
                    let origStart = Double(range.lowerBound) / Double(sampleRate) + offsetStart
                    let origEnd = Double(range.lowerBound) / Double(sampleRate) + offsetEnd

                    result.append(SpeakerSegment(
                        clusterID: seg.clusterID,
                        start: origStart,
                        end: origEnd,
                        embedding: seg.embedding,
                        quality: seg.quality
                    ))
                }
                cumCompactedSec += rangeLenSec
            }
        }
        return result
    }

    // MARK: - WAV 로더 및 스트리밍 리더 (순수 함수 및 구조체)

    /// 16-bit PCM WAV 파일을 읽어 Float 배열([-1.0, 1.0]) 및 샘플레이트 반환
    static func loadWAV(url: URL) throws -> (samples: [Float], sampleRate: Int) {
        let data = try Data(contentsOf: url)
        return try parseWAVData(data)
    }

    enum TruncationPolicy: Sendable {
        case reject
        case tolerate
    }

    enum WAVStreamError: LocalizedError, Equatable {
        case truncatedData(expectedBytes: Int, availableBytes: Int)

        var errorDescription: String? {
            switch self {
            case .truncatedData(let expectedBytes, let availableBytes):
                return "WAV data chunk shorter than header: expected \(expectedBytes) bytes, found \(availableBytes)"
            }
        }
    }

    /// 스트리밍 방식으로 16-bit PCM WAV 파일에서 오디오 프레임을 청크 단위로 읽는 리더
    struct WAVStreamReader {
        typealias TruncationPolicy = OfflineDiarizer.TruncationPolicy
        typealias WAVStreamError = OfflineDiarizer.WAVStreamError

        private let handle: FileHandle
        let channels: Int
        let sampleRate: Int
        let bitsPerSample: Int
        let dataOffset: Int
        let dataSize: Int
        let wasTruncated: Bool
        private var bytesReadFromData: Int = 0

        init(url: URL, truncation: TruncationPolicy = .reject) throws {
            let handle = try FileHandle(forReadingFrom: url)
            self.handle = handle

            guard let headerData = try handle.read(upToCount: 4096), headerData.count >= 12 else {
                try? handle.close()
                throw NSError(
                    domain: "livenote2.wav",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "WAV file too short for header"]
                )
            }

            let (ch, sr, bits, offset, size) = try Self.parseHeader(headerData)
            self.channels = ch
            self.sampleRate = sr
            self.bitsPerSample = bits
            self.dataOffset = offset

            let fileSize: Int
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let num = attrs[.size] as? NSNumber {
                fileSize = num.intValue
            } else {
                fileSize = Int(try handle.seekToEnd())
            }

            let availableBytes = max(0, fileSize - offset)
            if fileSize < offset + size {
                switch truncation {
                case .reject:
                    try? handle.close()
                    throw WAVStreamError.truncatedData(expectedBytes: size, availableBytes: availableBytes)
                case .tolerate:
                    self.dataSize = availableBytes
                    self.wasTruncated = true
                }
            } else {
                self.dataSize = size
                self.wasTruncated = false
            }

            try handle.seek(toOffset: UInt64(offset))
        }

        func close() {
            try? handle.close()
        }

        mutating func nextFrames(maxFrames: Int) throws -> [Float]? {
            guard maxFrames > 0, bytesReadFromData < dataSize else { return nil }

            let bytesPerFrame = channels * (bitsPerSample / 8)
            guard bytesPerFrame > 0 else { return nil }

            let bytesWanted = maxFrames * bytesPerFrame
            let bytesAvailable = dataSize - bytesReadFromData
            let bytesToRead = min(bytesWanted, bytesAvailable)

            guard bytesToRead >= bytesPerFrame else { return nil }

            guard let chunkData = try handle.read(upToCount: bytesToRead), !chunkData.isEmpty else {
                return nil
            }

            bytesReadFromData += chunkData.count

            let validByteCount = chunkData.count - (chunkData.count % bytesPerFrame)
            guard validByteCount >= bytesPerFrame else {
                return nil
            }

            let totalFrames = validByteCount / bytesPerFrame
            var floatSamples = [Float](repeating: 0, count: totalFrames)

            if channels == 1 {
                chunkData.withUnsafeBytes { rawBuffer in
                    for i in 0..<totalFrames {
                        let raw = rawBuffer.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                        let val = Int16(littleEndian: raw)
                        floatSamples[i] = Float(val) / 32768.0
                    }
                }
            } else {
                chunkData.withUnsafeBytes { rawBuffer in
                    for frame in 0..<totalFrames {
                        var sum: Float = 0
                        for c in 0..<channels {
                            let byteOffset = (frame * channels + c) * 2
                            let raw = rawBuffer.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self)
                            let val = Int16(littleEndian: raw)
                            sum += Float(val) / 32768.0
                        }
                        floatSamples[frame] = sum / Float(channels)
                    }
                }
            }

            return floatSamples
        }

        private static func parseHeader(_ data: Data) throws -> (channels: Int, sampleRate: Int, bitsPerSample: Int, dataOffset: Int, dataSize: Int) {
            guard data.count >= 12 else {
                throw NSError(
                    domain: "livenote2.wav",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "WAV file too short (\(data.count) bytes)"]
                )
            }

            let riff = data.subdata(in: 0..<4)
            guard riff == Data("RIFF".utf8) else {
                throw NSError(
                    domain: "livenote2.wav",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Missing RIFF header"]
                )
            }

            let wave = data.subdata(in: 8..<12)
            guard wave == Data("WAVE".utf8) else {
                throw NSError(
                    domain: "livenote2.wav",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Missing WAVE header"]
                )
            }

            var offset = 12
            var channels: Int?
            var sampleRate: Int?
            var bitsPerSample: Int?
            var audioFormat: Int?
            var dataChunkOffset: Int?
            var dataChunkSize: Int?

            while offset + 8 <= data.count {
                let chunkID = String(decoding: data.subdata(in: offset..<(offset + 4)), as: UTF8.self)
                let chunkSize = Int(
                    UInt32(data[offset + 4]) |
                    (UInt32(data[offset + 5]) << 8) |
                    (UInt32(data[offset + 6]) << 16) |
                    (UInt32(data[offset + 7]) << 24)
                )
                let chunkDataStart = offset + 8
                let chunkDataEnd = chunkDataStart + chunkSize

                if chunkID == "fmt " {
                    guard chunkSize >= 16, chunkDataStart + 16 <= data.count else {
                        throw NSError(
                            domain: "livenote2.wav",
                            code: -4,
                            userInfo: [NSLocalizedDescriptionKey: "Truncated or invalid fmt chunk"]
                        )
                    }

                    let format = UInt16(data[chunkDataStart]) | (UInt16(data[chunkDataStart + 1]) << 8)
                    let numChannels = UInt16(data[chunkDataStart + 2]) | (UInt16(data[chunkDataStart + 3]) << 8)
                    let sRate = UInt32(data[chunkDataStart + 4]) |
                        (UInt32(data[chunkDataStart + 5]) << 8) |
                        (UInt32(data[chunkDataStart + 6]) << 16) |
                        (UInt32(data[chunkDataStart + 7]) << 24)
                    let bits = UInt16(data[chunkDataStart + 14]) | (UInt16(data[chunkDataStart + 15]) << 8)

                    audioFormat = Int(format)
                    channels = Int(numChannels)
                    sampleRate = Int(sRate)
                    bitsPerSample = Int(bits)
                } else if chunkID == "data" {
                    dataChunkOffset = chunkDataStart
                    dataChunkSize = chunkSize
                    break
                }

                offset = min(chunkDataEnd, data.count)
                if chunkSize % 2 != 0 && offset < data.count {
                    offset += 1
                }
            }

            guard let fmt = audioFormat, fmt == 1 else {
                throw NSError(
                    domain: "livenote2.wav",
                    code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format, only PCM (1) supported"]
                )
            }

            guard let ch = channels, ch >= 1, let sr = sampleRate, let bits = bitsPerSample, bits == 16,
                  let dOffset = dataChunkOffset, let dSize = dataChunkSize else {
                throw NSError(
                    domain: "livenote2.wav",
                    code: -7,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported format or missing chunks in header"]
                )
            }

            return (ch, sr, bits, dOffset, dSize)
        }
    }

    /// WAV 바이너리 데이터 파싱 (엄격한 범위 검증 및 프레임 상한 지원)
    static func parseWAVData(
        _ data: Data,
        allowTruncatedDataChunk: Bool = false,
        maxFrames: Int? = nil
    ) throws -> (samples: [Float], sampleRate: Int) {
        guard data.count >= 12 else {
            throw NSError(
                domain: "livenote2.wav",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "WAV file too short (\(data.count) bytes)"]
            )
        }

        // RIFF 헤더 검증
        let riff = data.subdata(in: 0..<4)
        guard riff == Data("RIFF".utf8) else {
            throw NSError(
                domain: "livenote2.wav",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Missing RIFF header"]
            )
        }

        let wave = data.subdata(in: 8..<12)
        guard wave == Data("WAVE".utf8) else {
            throw NSError(
                domain: "livenote2.wav",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Missing WAVE header"]
            )
        }

        var offset = 12
        var channels: Int?
        var sampleRate: Int?
        var bitsPerSample: Int?
        var audioFormat: Int?
        var dataRange: Range<Int>?

        while offset + 8 <= data.count {
            let chunkID = String(decoding: data.subdata(in: offset..<(offset + 4)), as: UTF8.self)
            let chunkSize = Int(
                UInt32(data[offset + 4]) |
                (UInt32(data[offset + 5]) << 8) |
                (UInt32(data[offset + 6]) << 16) |
                (UInt32(data[offset + 7]) << 24)
            )
            let chunkDataStart = offset + 8
            let chunkDataEnd = chunkDataStart + chunkSize

            if chunkID == "fmt " {
                guard chunkSize >= 16, chunkDataStart + 16 <= data.count else {
                    throw NSError(
                        domain: "livenote2.wav",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "Truncated or invalid fmt chunk (size=\(chunkSize), available=\(data.count - chunkDataStart))"]
                    )
                }

                let format = UInt16(data[chunkDataStart]) | (UInt16(data[chunkDataStart + 1]) << 8)
                let numChannels = UInt16(data[chunkDataStart + 2]) | (UInt16(data[chunkDataStart + 3]) << 8)
                let sRate = UInt32(data[chunkDataStart + 4]) |
                    (UInt32(data[chunkDataStart + 5]) << 8) |
                    (UInt32(data[chunkDataStart + 6]) << 16) |
                    (UInt32(data[chunkDataStart + 7]) << 24)
                let bits = UInt16(data[chunkDataStart + 14]) | (UInt16(data[chunkDataStart + 15]) << 8)

                audioFormat = Int(format)
                channels = Int(numChannels)
                sampleRate = Int(sRate)
                bitsPerSample = Int(bits)
            } else if chunkID == "data" {
                if !allowTruncatedDataChunk && chunkDataEnd > data.count {
                    throw NSError(
                        domain: "livenote2.wav",
                        code: -5,
                        userInfo: [NSLocalizedDescriptionKey: "data chunk declared size (\(chunkSize)) exceeds file length (\(data.count - chunkDataStart))"]
                    )
                }
                let actualEnd = min(chunkDataEnd, data.count)
                dataRange = chunkDataStart..<actualEnd
            }

            offset = min(chunkDataEnd, data.count)
            if chunkSize % 2 != 0 && offset < data.count {
                offset += 1 // 패딩 바이트
            }
        }

        guard let fmt = audioFormat, fmt == 1 else {
            throw NSError(
                domain: "livenote2.wav",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format (\(String(describing: audioFormat))), only PCM (1) supported"]
            )
        }

        guard let ch = channels, ch >= 1, let sr = sampleRate, let bits = bitsPerSample, bits == 16 else {
            throw NSError(
                domain: "livenote2.wav",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported format: channels=\(String(describing: channels)), sampleRate=\(String(describing: sampleRate)), bits=\(String(describing: bitsPerSample))"]
            )
        }

        guard let range = dataRange, range.count >= 2 else {
            return ([], sr)
        }

        let validByteCount = range.count - (range.count % 2)
        let totalInt16Samples = validByteCount / 2
        var totalFrames = totalInt16Samples / ch
        if let maxFrames, maxFrames < totalFrames {
            totalFrames = maxFrames
        }

        var floatSamples = [Float](repeating: 0, count: totalFrames)

        if ch == 1 {
            for i in 0..<totalFrames {
                let byteOffset = range.lowerBound + i * 2
                let b0 = UInt16(data[byteOffset])
                let b1 = UInt16(data[byteOffset + 1])
                let int16Val = Int16(bitPattern: b0 | (b1 << 8))
                floatSamples[i] = Float(int16Val) / 32768.0
            }
        } else {
            for frame in 0..<totalFrames {
                var sum: Float = 0
                for c in 0..<ch {
                    let byteOffset = range.lowerBound + (frame * ch + c) * 2
                    let b0 = UInt16(data[byteOffset])
                    let b1 = UInt16(data[byteOffset + 1])
                    let int16Val = Int16(bitPattern: b0 | (b1 << 8))
                    sum += Float(int16Val) / 32768.0
                }
                floatSamples[frame] = sum / Float(ch)
            }
        }

        return (floatSamples, sr)
    }

    // MARK: - 에너지 게이트 (침묵 프레임 필터링)

    /// RMS 에너지가 임계값 미만인 프레임을 제거하고 유지된 구간 범위를 반환
    static func filterSilenceWithRanges(
        samples: [Float],
        sampleRate: Int = 16_000,
        frameSize: Int = 1_600, // 100ms
        rmsThreshold: Float = 0.005
    ) -> (compacted: [Float], keptRanges: [Range<Int>]) {
        guard frameSize > 0, !samples.isEmpty else {
            return (samples, [0..<samples.count])
        }

        var compacted: [Float] = []
        compacted.reserveCapacity(samples.count)
        var keptRanges: [Range<Int>] = []

        var offset = 0
        while offset < samples.count {
            let end = min(offset + frameSize, samples.count)
            let frame = Array(samples[offset..<end])

            var sumSquares: Float = 0
            vDSP_svesq(frame, 1, &sumSquares, vDSP_Length(frame.count))
            let rms = sqrt(sumSquares / Float(frame.count))

            if rms >= rmsThreshold {
                compacted.append(contentsOf: frame)
                if let last = keptRanges.last, last.upperBound == offset {
                    keptRanges[keptRanges.count - 1] = last.lowerBound..<end
                } else {
                    keptRanges.append(offset..<end)
                }
            }
            offset = end
        }

        return (compacted, keptRanges)
    }

    /// RMS 에너지가 임계값 미만인 프레임을 제거 (하위 호환 래퍼)
    static func filterSilence(
        samples: [Float],
        sampleRate: Int = 16_000,
        frameSize: Int = 1_600,
        rmsThreshold: Float = 0.005
    ) -> [Float] {
        filterSilenceWithRanges(
            samples: samples,
            sampleRate: sampleRate,
            frameSize: frameSize,
            rmsThreshold: rmsThreshold
        ).compacted
    }
}
