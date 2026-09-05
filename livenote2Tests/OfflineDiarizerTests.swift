import XCTest
@testable import LiveNote

final class OfflineDiarizerTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineDiarizerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        AppLog.directoryOverride = tempDir.appendingPathComponent("logs")
    }

    override func tearDown() {
        AppLog.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - WAV 생성 헬퍼

    private func createWAVFile(
        samples: [Float],
        sampleRate: Int = 16_000,
        channels: Int = 1
    ) throws -> URL {
        let fileURL = tempDir.appendingPathComponent("test_\(UUID().uuidString).wav")
        let totalInt16Samples = samples.count * channels
        let dataSize = UInt32(totalInt16Samples * 2)
        let fileSize = 36 + dataSize

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        var fileSizeLE = fileSize.littleEndian
        data.append(Data(bytes: &fileSizeLE, count: 4))
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        var fmtSize: UInt32 = 16
        data.append(Data(bytes: &fmtSize, count: 4))
        var format: UInt16 = 1 // PCM
        data.append(Data(bytes: &format, count: 2))
        var ch = UInt16(channels)
        data.append(Data(bytes: &ch, count: 2))
        var sr = UInt32(sampleRate)
        data.append(Data(bytes: &sr, count: 4))
        var byteRate = UInt32(sampleRate * channels * 2)
        data.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = UInt16(channels * 2)
        data.append(Data(bytes: &blockAlign, count: 2))
        var bitsPerSample: UInt16 = 16
        data.append(Data(bytes: &bitsPerSample, count: 2))

        // data chunk
        data.append(contentsOf: "data".utf8)
        var dSize = dataSize.littleEndian
        data.append(Data(bytes: &dSize, count: 4))

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Val = Int16(clamped * 32767.0)
            var int16LE = int16Val.littleEndian
            for _ in 0..<channels {
                data.append(Data(bytes: &int16LE, count: 2))
            }
        }

        try data.write(to: fileURL)
        return fileURL
    }

    // MARK: - 테스트 케이스

    func testLoadValidMonoWAV() throws {
        let originalSamples: [Float] = [0.0, 0.5, -0.5, 0.9, -0.9, 0.0]
        let url = try createWAVFile(samples: originalSamples, sampleRate: 16_000, channels: 1)

        let (loadedSamples, sampleRate) = try OfflineDiarizer.loadWAV(url: url)
        XCTAssertEqual(sampleRate, 16_000)
        XCTAssertEqual(loadedSamples.count, originalSamples.count)

        for (orig, loaded) in zip(originalSamples, loadedSamples) {
            XCTAssertEqual(orig, loaded, accuracy: 0.001)
        }
    }

    func testLoadValidStereoWAVDownmix() throws {
        let originalSamples: [Float] = [0.2, -0.4, 0.8]
        let url = try createWAVFile(samples: originalSamples, sampleRate: 16_000, channels: 2)

        let (loadedSamples, sampleRate) = try OfflineDiarizer.loadWAV(url: url)
        XCTAssertEqual(sampleRate, 16_000)
        XCTAssertEqual(loadedSamples.count, originalSamples.count)

        for (orig, loaded) in zip(originalSamples, loadedSamples) {
            XCTAssertEqual(orig, loaded, accuracy: 0.001)
        }
    }

    func testLoadCorruptedOrInvalidWAV() throws {
        // 너무 짧은 데이터
        let shortData = Data([0x01, 0x02, 0x03])
        XCTAssertThrowsError(try OfflineDiarizer.parseWAVData(shortData))

        // 잘못된 헤더
        let badHeader = Data("NOT_A_WAVE_FILE_1234567890123456789012345678901234".utf8)
        XCTAssertThrowsError(try OfflineDiarizer.parseWAVData(badHeader))
    }

    func testFilterSilence() {
        // 100ms 프레임(1600 샘플) 침묵 + 100ms 유음성 신호
        let silence = [Float](repeating: 0.0001, count: 1600)
        let signal = (0..<1600).map { sin(Float($0) * 0.1) * 0.5 }
        let mixed = silence + signal + silence

        let filtered = OfflineDiarizer.filterSilence(samples: mixed, sampleRate: 16_000, frameSize: 1600, rmsThreshold: 0.01)
        XCTAssertEqual(filtered.count, 1600)
    }

    func testOfflineDiarizerWithMockEngine() async throws {
        final class MockEngine: OfflineDiarizationEngine, @unchecked Sendable {
            var didPrepare = false
            func prepare() async throws {
                didPrepare = true
            }
            func diarize(samples: [Float]) throws -> [SpeakerSegment] {
                [
                    SpeakerSegment(clusterID: "spk1", start: 0.0, end: 1.0, embedding: [Float](repeating: 0.1, count: 256), quality: 0.9),
                    SpeakerSegment(clusterID: "spk2", start: 1.0, end: 2.5, embedding: [Float](repeating: 0.2, count: 256), quality: 0.85)
                ]
            }
            func embedding(for samples: [Float]) throws -> [Float] {
                [Float](repeating: 0.5, count: 256)
            }
        }

        let mock = MockEngine()
        let diarizer = OfflineDiarizer(engine: mock)

        // 3초 분량의 오디오 샘플 생성
        let samples = [Float](repeating: 0.1, count: 48_000)
        let wavURL = try createWAVFile(samples: samples, sampleRate: 16_000)

        let diarization = try await diarizer.diarize(wavURL: wavURL)
        XCTAssertTrue(mock.didPrepare)
        XCTAssertEqual(diarization.segments.count, 2)
        // spk2 (1.5s) > spk1 (1.0s) 내림차순 정렬
        XCTAssertEqual(diarization.clusterIDs, ["spk2", "spk1"])
        XCTAssertEqual(diarization.audioSeconds, 3.0, accuracy: 0.01)
        XCTAssertEqual(diarization.dominantCluster(from: 0.2, to: 0.8), "spk1")
        XCTAssertEqual(diarization.dominantCluster(from: 1.1, to: 2.0), "spk2")

        let emb = try await diarizer.embedding(samples: [0.1, 0.2])
        XCTAssertEqual(emb.count, 256)
    }

    func testRemapTimeline() {
        let sr = 16_000
        // 3s speech + 5s silence + 3s speech = 11s total
        let speech1 = (0..<(3 * sr)).map { sin(Float($0) * 0.1) * 0.5 }
        let silence = [Float](repeating: 0.0, count: 5 * sr)
        let speech2 = (0..<(3 * sr)).map { sin(Float($0) * 0.1) * 0.5 }
        let totalSamples = speech1 + silence + speech2

        let (compacted, keptRanges) = OfflineDiarizer.filterSilenceWithRanges(
            samples: totalSamples,
            sampleRate: sr,
            frameSize: 1600,
            rmsThreshold: 0.01
        )

        // Compacted is 6s (3s + 3s)
        XCTAssertEqual(compacted.count, 6 * sr)
        XCTAssertEqual(keptRanges.count, 2)
        XCTAssertEqual(keptRanges[0], 0..<(3 * sr))
        XCTAssertEqual(keptRanges[1], (8 * sr)..<(11 * sr))

        // Raw segments on compacted audio (0..3s and 3..6s)
        let rawSegments = [
            SpeakerSegment(clusterID: "spk1", start: 0.0, end: 3.0, embedding: [], quality: 0.9),
            SpeakerSegment(clusterID: "spk2", start: 3.0, end: 6.0, embedding: [], quality: 0.9)
        ]

        let remapped = OfflineDiarizer.remapToOriginal(segments: rawSegments, keptRanges: keptRanges, sampleRate: sr)
        XCTAssertEqual(remapped.count, 2)
        XCTAssertEqual(remapped[0].start, 0.0, accuracy: 0.01)
        XCTAssertEqual(remapped[0].end, 3.0, accuracy: 0.01)
        // Second segment must map to 8..11s
        XCTAssertEqual(remapped[1].start, 8.0, accuracy: 0.01)
        XCTAssertEqual(remapped[1].end, 11.0, accuracy: 0.01)
    }

    func testRemapTimelineCrossingBoundarySplitsSegment() {
        let sr = 1
        // kept 0...3 and 8...11, compacted 2.5...3.5 -> segments 2.5...3.0 and 8.0...8.5
        let keptRanges = [0..<3, 8..<11]
        let dummyEmb: [Float] = [0.1, 0.2, 0.3]
        let rawSegment = SpeakerSegment(
            clusterID: "spk1",
            start: 2.5,
            end: 3.5,
            embedding: dummyEmb,
            quality: 0.95
        )

        let remapped = OfflineDiarizer.remapToOriginal(
            segments: [rawSegment],
            keptRanges: keptRanges,
            sampleRate: sr
        )

        XCTAssertEqual(remapped.count, 2)

        // Segment 1: 2.5...3.0
        XCTAssertEqual(remapped[0].clusterID, "spk1")
        XCTAssertEqual(remapped[0].start, 2.5, accuracy: 0.001)
        XCTAssertEqual(remapped[0].end, 3.0, accuracy: 0.001)
        XCTAssertEqual(remapped[0].duration, 0.5, accuracy: 0.001)
        XCTAssertEqual(remapped[0].embedding, dummyEmb)
        XCTAssertEqual(remapped[0].quality, 0.95, accuracy: 0.001)

        // Segment 2: 8.0...8.5
        XCTAssertEqual(remapped[1].clusterID, "spk1")
        XCTAssertEqual(remapped[1].start, 8.0, accuracy: 0.001)
        XCTAssertEqual(remapped[1].end, 8.5, accuracy: 0.001)
        XCTAssertEqual(remapped[1].duration, 0.5, accuracy: 0.001)
        XCTAssertEqual(remapped[1].embedding, dummyEmb)
        XCTAssertEqual(remapped[1].quality, 0.95, accuracy: 0.001)

        // Durations sum to real speech time (1.0s)
        let totalDuration = remapped.reduce(0.0) { $0 + $1.duration }
        XCTAssertEqual(totalDuration, 1.0, accuracy: 0.001)
    }

    func testWAVTruncationAndMalformedChunks() throws {
        // 1. Truncated fmt chunk (size declared 16, but only 8 bytes present)
        var badFmtData = Data("RIFF".utf8)
        var fSize: UInt32 = 24
        badFmtData.append(Data(bytes: &fSize, count: 4))
        badFmtData.append(contentsOf: "WAVEfmt ".utf8)
        var fmtChunkSize: UInt32 = 16
        badFmtData.append(Data(bytes: &fmtChunkSize, count: 4))
        // Only 8 bytes of fmt data provided instead of 16
        badFmtData.append(Data([0x01, 0x00, 0x01, 0x00, 0x80, 0x3E, 0x00, 0x00]))
        XCTAssertThrowsError(try OfflineDiarizer.parseWAVData(badFmtData))

        // 2. Data chunk declared size exceeds file length
        var overdeclaredData = Data("RIFF".utf8)
        var fSize2: UInt32 = 44
        overdeclaredData.append(Data(bytes: &fSize2, count: 4))
        overdeclaredData.append(contentsOf: "WAVEfmt ".utf8)
        var fmt16: UInt32 = 16
        overdeclaredData.append(Data(bytes: &fmt16, count: 4))
        var format: UInt16 = 1
        var ch: UInt16 = 1
        var sr: UInt32 = 16000
        var br: UInt32 = 32000
        var ba: UInt16 = 2
        var bps: UInt16 = 16
        overdeclaredData.append(Data(bytes: &format, count: 2))
        overdeclaredData.append(Data(bytes: &ch, count: 2))
        overdeclaredData.append(Data(bytes: &sr, count: 4))
        overdeclaredData.append(Data(bytes: &br, count: 4))
        overdeclaredData.append(Data(bytes: &ba, count: 2))
        overdeclaredData.append(Data(bytes: &bps, count: 2))
        overdeclaredData.append(contentsOf: "data".utf8)
        var declaredDataSize: UInt32 = 1000 // Only 4 bytes follow
        overdeclaredData.append(Data(bytes: &declaredDataSize, count: 4))
        overdeclaredData.append(Data([0x00, 0x10, 0x00, 0x20]))
        XCTAssertThrowsError(try OfflineDiarizer.parseWAVData(overdeclaredData))

        // 3. Odd byte count handled gracefully
        var oddByteData = Data("RIFF".utf8)
        var fSize3: UInt32 = 41
        oddByteData.append(Data(bytes: &fSize3, count: 4))
        oddByteData.append(contentsOf: "WAVEfmt ".utf8)
        oddByteData.append(Data(bytes: &fmt16, count: 4))
        oddByteData.append(Data(bytes: &format, count: 2))
        oddByteData.append(Data(bytes: &ch, count: 2))
        oddByteData.append(Data(bytes: &sr, count: 4))
        oddByteData.append(Data(bytes: &br, count: 4))
        oddByteData.append(Data(bytes: &ba, count: 2))
        oddByteData.append(Data(bytes: &bps, count: 2))
        oddByteData.append(contentsOf: "data".utf8)
        var oddDataSize: UInt32 = 5 // 5 bytes (2 full Int16 samples + 1 trailing byte)
        oddByteData.append(Data(bytes: &oddDataSize, count: 4))
        oddByteData.append(Data([0x00, 0x10, 0x00, 0x20, 0xFF]))

        let (samples, loadedSR) = try OfflineDiarizer.parseWAVData(oddByteData)
        XCTAssertEqual(loadedSR, 16000)
        XCTAssertEqual(samples.count, 2)
    }

    func testResampleTo16kAndDiarize48kHzTone() async throws {
        // 48 kHz synthetic tone of 1.0s (48,000 samples)
        let samples48k = (0..<48_000).map { sin(Float($0) * 0.05) * 0.5 }
        let resampled = OfflineDiarizer.resampleTo16k(samples48k, from: 48_000)

        // Verify length ratio 1/3
        XCTAssertEqual(resampled.count, 16_000)
        XCTAssertEqual(Double(resampled.count) / Double(samples48k.count), 1.0 / 3.0, accuracy: 0.001)

        final class RecordingMockEngine: OfflineDiarizationEngine, @unchecked Sendable {
            var recordedSamplesCount: Int = 0
            func prepare() async throws {}
            func diarize(samples: [Float]) throws -> [SpeakerSegment] {
                recordedSamplesCount = samples.count
                return [
                    SpeakerSegment(clusterID: "spk1", start: 0.0, end: 1.0, embedding: [Float](repeating: 0.1, count: 256), quality: 0.9)
                ]
            }
            func embedding(for samples: [Float]) throws -> [Float] {
                [Float](repeating: 0.1, count: 256)
            }
        }

        let engine = RecordingMockEngine()
        let diarizer = OfflineDiarizer(engine: engine)

        let wav48kURL = try createWAVFile(samples: samples48k, sampleRate: 48_000)
        let diarization = try await diarizer.diarize(wavURL: wav48kURL)

        // Verify fake engine receives 16 kHz-length input
        XCTAssertEqual(engine.recordedSamplesCount, 16_000)
        XCTAssertEqual(diarization.audioSeconds, 1.0, accuracy: 0.01)
    }

    func testLoadWAVCappedMaxSeconds() throws {
        // 5-minute synthetic WAV at 16 kHz (5 * 60 * 16,000 = 4,800,000 samples)
        let sr = 16_000
        let fiveMinSamples = [Float](repeating: 0.25, count: 5 * 60 * sr)
        let wavURL = try createWAVFile(samples: fiveMinSamples, sampleRate: sr)

        // Read capped at 60s
        let (cappedSamples, loadedSR) = try OfflineDiarizer.loadWAV(url: wavURL, maxSeconds: 60.0)
        XCTAssertEqual(loadedSR, sr)
        // Must return exactly 60 seconds worth of samples (60 * 16,000 = 960,000)
        XCTAssertEqual(cappedSamples.count, 60 * sr)
        XCTAssertEqual(Double(cappedSamples.count) / Double(loadedSR), 60.0, accuracy: 0.01)
    }

    func testMeEnrollmentClip() async throws {
        let sr = 16_000
        // 90s audio: 80s speech + 10s silence
        let speech = [Float](repeating: 0.4, count: 80 * sr)
        let silence = [Float](repeating: 0.0, count: 10 * sr)
        let totalSamples = speech + silence
        let wavURL = try createWAVFile(samples: totalSamples, sampleRate: sr)

        final class DummyEngine: OfflineDiarizationEngine, @unchecked Sendable {
            func prepare() async throws {}
            func diarize(samples: [Float]) throws -> [SpeakerSegment] { [] }
            func embedding(for samples: [Float]) throws -> [Float] { [0.1] }
        }

        let diarizer = OfflineDiarizer(engine: DummyEngine())
        let (clip, clipSecs) = try await diarizer.meEnrollmentClip(wavURL: wavURL, maxSeconds: 60.0)

        // Clipped to maxSeconds (60s)
        XCTAssertEqual(clip.count, 60 * sr)
        XCTAssertEqual(clipSecs, 60.0, accuracy: 0.01)
    }
}
