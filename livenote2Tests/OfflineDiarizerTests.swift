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

    // MARK: - R10-2 Streaming Me-Enrollment Tests (T4..T7 & X5)

    func testMeEnrollmentClipScansPastInitialSilence() async throws {
        // T4: 60s silence + 25s tone (0.3 amplitude) + 5s silence at 16 kHz
        let sr = 16_000
        let silence60s = [Float](repeating: 0.0, count: 60 * sr)
        let tone25s = (0..<(25 * sr)).map { _ in Float(0.3) }
        let silence5s = [Float](repeating: 0.0, count: 5 * sr)
        let totalSamples = silence60s + tone25s + silence5s

        let wavURL = try createWAVFile(samples: totalSamples, sampleRate: sr)

        let (clip, clipSecs) = try OfflineDiarizer.meEnrollmentClip(wavURL: wavURL, maxSeconds: 60.0)

        // Must scan past the first 60s of silence and collect the 25s of tone
        XCTAssertGreaterThanOrEqual(clipSecs, 24.5, "Must collect at least 24.5s of voiced audio")
        XCTAssertEqual(clipSecs, Double(clip.count) / Double(sr), accuracy: 0.01)
    }

    func testCollectVoicedSamplesStopsEarly() throws {
        // T5: 5-minute WAV of continuous tone (16 kHz, 300s total)
        // With 10s chunks, collecting 60s should stop after at most 7 pulls.
        let sr = 16_000
        let tone10s = [Float](repeating: 0.3, count: 10 * sr)
        var totalChunksAvailable = 30 // 30 * 10s = 300s
        var pullCount = 0

        let result = try OfflineDiarizer.collectVoicedSamples(
            next: {
                pullCount += 1
                if totalChunksAvailable > 0 {
                    totalChunksAvailable -= 1
                    return tone10s
                } else {
                    return nil
                }
            },
            sampleRate: sr,
            maxSeconds: 60.0
        )

        XCTAssertEqual(result.seconds, 60.0, accuracy: 0.01)
        XCTAssertEqual(result.samples.count, 60 * sr)
        XCTAssertLessThanOrEqual(pullCount, 7, "Must stop early without pulling all chunks (expected <= 7 pulls, got \(pullCount))")
    }

    func testMeEnrollmentClip48kHzResampled() async throws {
        // T6: 48 kHz WAV with speech (tone) only after 70s of silence (70s silence + 10s tone)
        let sr48k = 48_000
        let silence70s = [Float](repeating: 0.0, count: 70 * sr48k)
        let tone10s = [Float](repeating: 0.3, count: 10 * sr48k)
        let total48k = silence70s + tone10s
        let wavURL = try createWAVFile(samples: total48k, sampleRate: sr48k)

        let (clip, clipSecs) = try OfflineDiarizer.meEnrollmentClip(wavURL: wavURL, maxSeconds: 60.0)

        // Resampled output is at 16 kHz, should be ~10s of voiced audio
        XCTAssertEqual(clipSecs, 10.0, accuracy: 0.2)
        XCTAssertEqual(Double(clip.count) / 16_000.0, clipSecs, accuracy: 0.01)
    }

    func testWAVStreamReaderTruncatedDataChunk() throws {
        // T7: WAV whose data chunk declares 1,000,000 bytes but file only contains 1600 samples (3200 bytes)
        let sr = 16_000
        let actualSamples = [Float](repeating: 0.2, count: 1600)
        let fakeDataSize: UInt32 = 1_000_000
        let fileSize: UInt32 = 36 + fakeDataSize

        let fileURL = tempDir.appendingPathComponent("truncated_\(UUID().uuidString).wav")
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        var fileSizeLE = fileSize.littleEndian
        data.append(Data(bytes: &fileSizeLE, count: 4))
        data.append(contentsOf: "WAVEfmt ".utf8)
        var fmtSize: UInt32 = 16
        data.append(Data(bytes: &fmtSize, count: 4))
        var format: UInt16 = 1
        data.append(Data(bytes: &format, count: 2))
        var ch: UInt16 = 1
        data.append(Data(bytes: &ch, count: 2))
        var sRate: UInt32 = UInt32(sr)
        data.append(Data(bytes: &sRate, count: 4))
        var byteRate: UInt32 = UInt32(sr * 2)
        data.append(Data(bytes: &byteRate, count: 4))
        var blockAlign: UInt16 = 2
        data.append(Data(bytes: &blockAlign, count: 2))
        var bits: UInt16 = 16
        data.append(Data(bytes: &bits, count: 2))

        data.append(contentsOf: "data".utf8)
        var dSizeLE = fakeDataSize.littleEndian
        data.append(Data(bytes: &dSizeLE, count: 4))

        for sample in actualSamples {
            let int16Val = Int16(sample * 32767.0).littleEndian
            var val = int16Val
            data.append(Data(bytes: &val, count: 2))
        }

        try data.write(to: fileURL)

        var reader = try OfflineDiarizer.WAVStreamReader(url: fileURL)
        defer { reader.close() }

        let firstChunk = try reader.nextFrames(maxFrames: 1600)
        XCTAssertNotNil(firstChunk)
        XCTAssertEqual(firstChunk?.count, 1600)

        // Second chunk reaches EOF and returns nil gracefully without throwing
        let secondChunk = try reader.nextFrames(maxFrames: 1600)
        XCTAssertNil(secondChunk)
    }

    func testMeEnrollmentClipFiveMinuteContinuousTone() async throws {
        // X5 updated: 5-minute synthetic WAV at 16 kHz
        let sr = 16_000
        let fiveMinSamples = [Float](repeating: 0.25, count: 5 * 60 * sr)
        let wavURL = try createWAVFile(samples: fiveMinSamples, sampleRate: sr)

        let (clip, clipSecs) = try OfflineDiarizer.meEnrollmentClip(wavURL: wavURL, maxSeconds: 60.0)

        XCTAssertEqual(clip.count, 60 * sr)
        XCTAssertEqual(clipSecs, 60.0, accuracy: 0.01)
    }

    // MARK: - R11-1 Concurrency Isolation Tests (F1a & F1b)

    func testEmbeddingExtractorIndependentOfRunningDiarization_F1a() async throws {
        let enterGate = AsyncTestGate()
        let blockGate = AsyncTestGate()
        let diarizerA = OfflineDiarizer(engine: BlockingDiarizationEngine(enterGate: enterGate, blockGate: blockGate))
        let extractorB = OfflineDiarizer(engine: FixedEmbeddingEngine(fixedEmbedding: [Float](repeating: 0.42, count: 256)))

        // Small synthetic WAV with non-silent tone
        let sr = 16_000
        let toneSamples = [Float](repeating: 0.3, count: sr)
        let wavURL = try createWAVFile(samples: toneSamples, sampleRate: sr)

        let taskA = Task {
            try await diarizerA.diarize(wavURL: wavURL, skipSilence: false)
        }

        // Wait until diarizer A enters synchronous diarize
        await enterGate.wait()

        // Extractor B embedding must return within 1s while A is blocked
        let embStart = Date()
        let embedding = try await extractorB.embedding(samples: [0.1, 0.2, 0.3])
        let embDuration = Date().timeIntervalSince(embStart)
        XCTAssertLessThan(embDuration, 1.0, "Extractor B embedding must complete within 1s while Diarizer A is blocked")
        XCTAssertEqual(embedding.first, 0.42)

        // OfflineDiarizer.meEnrollmentClip must also complete within 1s
        let clipStart = Date()
        let (_, clipSecs) = try OfflineDiarizer.meEnrollmentClip(wavURL: wavURL, maxSeconds: 1.0)
        let clipDuration = Date().timeIntervalSince(clipStart)
        XCTAssertLessThan(clipDuration, 1.0, "meEnrollmentClip must complete within 1s while Diarizer A is blocked")
        XCTAssertGreaterThan(clipSecs, 0)

        // Finally open blockGate and await A
        await blockGate.open()
        let resultA = try await taskA.value
        XCTAssertEqual(resultA.segments.count, 0)
    }

    func testSingleDiarizerEmbeddingBlocksBehindDiarization_F1b() async throws {
        let enterGate = AsyncTestGate()
        let blockGate = AsyncTestGate()
        let diarizerA = OfflineDiarizer(engine: BlockingDiarizationEngine(enterGate: enterGate, blockGate: blockGate))

        let sr = 16_000
        let toneSamples = [Float](repeating: 0.3, count: sr)
        let wavURL = try createWAVFile(samples: toneSamples, sampleRate: sr)

        let taskA = Task {
            try await diarizerA.diarize(wavURL: wavURL, skipSilence: false)
        }

        // Wait until diarizer A enters synchronous diarize
        await enterGate.wait()

        // Calling embedding on instance A itself must NOT complete within 0.5s while gate is closed
        let didCompleteFlag = AtomicFlag()
        let embTask = Task {
            let res = try await diarizerA.embedding(samples: [0.1, 0.2, 0.3])
            didCompleteFlag.set(true)
            return res
        }

        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(didCompleteFlag.get(), "Calling embedding on blocked Diarizer A must not complete within 0.5s")

        // Open the gate and await tasks to prevent dangling tasks
        await blockGate.open()
        _ = try await taskA.value
        _ = try await embTask.value
        XCTAssertTrue(didCompleteFlag.get(), "Embedding must complete after unblocking Diarizer A")
    }
}

// MARK: - Concurrency Test Helpers

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool = false

    func set(_ val: Bool) {
        lock.lock()
        defer { lock.unlock() }
        value = val
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { cont in
            continuations.append(cont)
        }
    }

    func open() {
        isOpen = true
        for cont in continuations {
            cont.resume()
        }
        continuations.removeAll()
    }
}

private final class BlockingDiarizationEngine: OfflineDiarizationEngine, @unchecked Sendable {
    let enterGate: AsyncTestGate
    let blockGate: AsyncTestGate
    let fixedEmbedding: [Float]

    init(
        enterGate: AsyncTestGate,
        blockGate: AsyncTestGate,
        fixedEmbedding: [Float] = [Float](repeating: 0.1, count: 256)
    ) {
        self.enterGate = enterGate
        self.blockGate = blockGate
        self.fixedEmbedding = fixedEmbedding
    }

    func prepare() async throws {}

    func diarize(samples: [Float]) throws -> [SpeakerSegment] {
        Task {
            await enterGate.open()
        }
        let sema = DispatchSemaphore(value: 0)
        Task {
            await blockGate.wait()
            sema.signal()
        }
        sema.wait()
        return []
    }

    func embedding(for samples: [Float]) throws -> [Float] {
        return fixedEmbedding
    }
}

private final class FixedEmbeddingEngine: OfflineDiarizationEngine, @unchecked Sendable {
    let fixedEmbedding: [Float]

    init(fixedEmbedding: [Float] = [Float](repeating: 0.2, count: 256)) {
        self.fixedEmbedding = fixedEmbedding
    }

    func prepare() async throws {}
    func diarize(samples: [Float]) throws -> [SpeakerSegment] { [] }
    func embedding(for samples: [Float]) throws -> [Float] { fixedEmbedding }
}
