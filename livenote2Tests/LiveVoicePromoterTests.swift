import XCTest
@testable import LiveNote

final class LiveVoicePromoterTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveVoicePromoterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        AppLog.directoryOverride = tempDir.appendingPathComponent("logs")
    }

    override func tearDown() {
        AppLog.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testRingBufferSlicingAndCap() async {
        let promoter = LiveVoicePromoter()

        // 1초치 샘플 추가 (16,000개)
        let samples1 = (0..<16_000).map { Float($0) }
        await promoter.append(samples: samples1)

        // 0.25s ~ 0.75s 슬라이스 추출 (0.5초 = 8,000개)
        let (extracted, secs) = await promoter.extractSamples(for: [(start: 0.25, end: 0.75)])
        XCTAssertEqual(secs, 0.5, accuracy: 0.01)
        XCTAssertEqual(extracted.count, 8_000)
        XCTAssertEqual(extracted.first, Float(4_000))
    }

    func testRingBufferSlidingWindow90Seconds() async {
        let promoter = LiveVoicePromoter()

        // 100초치 샘플 주입 (100 * 16,000 = 1,600,000 샘플)
        // 90초 초과분(10초 = 160,000 샘플)은 앞부분에서 잘려나가야 함
        let chunk = [Float](repeating: 1.0, count: 160_000) // 10초 분량씩 10번
        for _ in 0..<10 {
            await promoter.append(samples: chunk)
        }

        // 0s ~ 5s (이미 버퍼 밖으로 밀려남) -> 추출 샘플 0
        let (oldSlices, oldSecs) = await promoter.extractSamples(for: [(start: 0.0, end: 5.0)])
        XCTAssertEqual(oldSecs, 0.0)
        XCTAssertEqual(oldSlices.count, 0)

        // 95s ~ 98s (버퍼 내부) -> 3초치 추출
        let (recentSlices, recentSecs) = await promoter.extractSamples(for: [(start: 95.0, end: 98.0)])
        XCTAssertEqual(recentSecs, 3.0, accuracy: 0.01)
        XCTAssertEqual(recentSlices.count, 48_000)
    }

    func testPromotionTriggerAt30Seconds() async {
        let expectation = expectation(description: "Promotion triggered on 30s speech")
        expectation.expectedFulfillmentCount = 1

        let fakeEngine: @Sendable ([Float]) async throws -> [Float] = { samples in
            return [Float](repeating: 0.42, count: 256)
        }

        let promoter = LiveVoicePromoter(embeddingProvider: fakeEngine)
        await promoter.setOnEmbedding { slot, embedding, seconds in
            XCTAssertEqual(slot, 1)
            XCTAssertEqual(embedding.count, 256)
            XCTAssertEqual(seconds, 30.0, accuracy: 0.1)
            expectation.fulfill()
        }

        // 40초치 샘플 버퍼에 추가
        let samples = [Float](repeating: 0.1, count: 40 * 16_000)
        await promoter.append(samples: samples)

        // 1. 20초 세그먼트 알림 -> 아직 30초 미만이므로 트리거되지 않음
        await promoter.noteSegments(slot: 1, segments: [(start: 0.0, end: 20.0)])

        // 2. 추가 10초 세그먼트 알림 -> 누적 30초 도달하여 트리거됨
        await promoter.noteSegments(slot: 1, segments: [(start: 20.0, end: 30.0)])

        // 3. 추가 세그먼트 알림 -> 이미 승격되었으므로 재트리거되지 않음 (expectedFulfillmentCount = 1)
        await promoter.noteSegments(slot: 1, segments: [(start: 30.0, end: 35.0)])

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testPromoterRingBufferWraparoundAndCorrectness() async {
        let promoter = LiveVoicePromoter()
        let sr = 16_000
        let chunkSize = 10 * sr // 10s per chunk

        // 2 hours = 720 chunks of 10s each
        for i in 0..<720 {
            let chunk = [Float](repeating: Float(i), count: chunkSize)
            await promoter.append(samples: chunk)
        }

        // Total ingested = 7200 seconds. Buffer holds last 90 seconds (7110s..7200s).
        // Extract 7150s..7160s (chunk 715)
        let (extracted, secs) = await promoter.extractSamples(for: [(start: 7150.0, end: 7160.0)], maxSeconds: 10.0)
        XCTAssertEqual(secs, 10.0, accuracy: 0.01)
        XCTAssertEqual(extracted.count, 10 * sr)
        XCTAssertEqual(extracted.first, Float(715))
        XCTAssertEqual(extracted.last, Float(715))

        // Old audio before 7110s is gone
        let (oldExtracted, oldSecs) = await promoter.extractSamples(for: [(start: 5000.0, end: 5010.0)])
        XCTAssertEqual(oldSecs, 0.0)
        XCTAssertEqual(oldExtracted.count, 0)
    }

    func testPromoterDoesNotMarkSlotPromotedIfAudioMissing() async {
        let counter = AtomicCounter()
        let fakeEngine: @Sendable ([Float]) async throws -> [Float] = { samples in
            return [Float](repeating: 0.1, count: 256)
        }

        let promoter = LiveVoicePromoter(embeddingProvider: fakeEngine)
        await promoter.setOnEmbedding { _, _, _ in
            counter.increment()
        }

        // Buffer has only 5s of audio (0..5s)
        await promoter.append(samples: [Float](repeating: 0.1, count: 5 * 16_000))

        // Segments are declared at 100..135s (35s speech, but not present in buffer)
        await promoter.noteSegments(slot: 2, segments: [(start: 100.0, end: 135.0)])

        // Should not have triggered
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(counter.get(), 0)

        // Now append audio covering 100..140s
        // Ingest up to 140s
        let chunk = [Float](repeating: 0.2, count: 135 * 16_000)
        await promoter.append(samples: chunk)

        // Retrying with new segment now succeeds
        await promoter.noteSegments(slot: 2, segments: [(start: 135.0, end: 136.0)])
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(counter.get(), 1)
    }

    @MainActor
    func testLivePromotionManualSlotProtection() {
        let row1 = TranscriptRow(
            channel: .them,
            speakerSlot: 1,
            speakerName: "Speaker 1",
            english: "Hello",
            startSeconds: 0.0,
            endSeconds: 5.0,
            nameSource: .slot
        )
        let row2 = TranscriptRow(
            channel: .them,
            speakerSlot: 2,
            speakerName: "Speaker 2",
            english: "Hi",
            startSeconds: 5.0,
            endSeconds: 10.0,
            nameSource: .slot
        )
        let row3 = TranscriptRow(
            channel: .them,
            speakerSlot: 2,
            speakerName: "Manually Named",
            english: "How are you",
            startSeconds: 10.0,
            endSeconds: 15.0,
            nameSource: .manual
        )

        let initialRows = [row1, row2, row3]

        // 1. Slot 1 without manual override -> renamed succeeds
        let (rowsA, renamedA) = AppState.applyLivePromotion(
            rows: initialRows,
            slot: 1,
            name: "Alice",
            manualSlots: []
        )
        XCTAssertTrue(renamedA)
        XCTAssertEqual(rowsA[0].speakerName, "Alice")
        XCTAssertEqual(rowsA[0].nameSource, .voice)

        // 2. Slot 1 when manualSlots contains 1 -> skipped
        let (rowsB, renamedB) = AppState.applyLivePromotion(
            rows: initialRows,
            slot: 1,
            name: "Alice",
            manualSlots: [1]
        )
        XCTAssertFalse(renamedB)
        XCTAssertEqual(rowsB[0].speakerName, "Speaker 1")
        XCTAssertEqual(rowsB[0].nameSource, .slot)

        // 3. Slot 2 has a row with .manual -> skipped
        let (rowsC, renamedC) = AppState.applyLivePromotion(
            rows: initialRows,
            slot: 2,
            name: "Bob",
            manualSlots: []
        )
        XCTAssertFalse(renamedC)
        XCTAssertEqual(rowsC[1].speakerName, "Speaker 2")
        XCTAssertEqual(rowsC[2].speakerName, "Manually Named")
    }

    func testTimeoutRaceNonCooperativeTaskTimesOutAndCleansUpAfterFinished() async {
        let race = TimeoutRace<String>()
        let gate = AsyncTestGate()
        let cleanupFlag = AtomicFlag()

        let nonCooperativeTask = Task.detached {
            // Wait on gate (ignores Task cancellation)
            await gate.wait()
            race.resolve(.finished("done"))
            return "done"
        }

        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
            race.resolve(.timedOut)
        }

        let start = Date()
        let outcome = await race.wait()
        let elapsed = Date().timeIntervalSince(start)
        watchdog.cancel()

        // 1) Verify timeout returned quickly (< 1.0s) while task is still blocked
        switch outcome {
        case .timedOut:
            break
        case .finished:
            XCTFail("Expected timedOut result")
        }
        XCTAssertLessThan(elapsed, 1.0)

        // Detached cleanup task that waits for non-cooperative task
        let cleanupTask = Task.detached {
            _ = await nonCooperativeTask.value
            cleanupFlag.set(true)
        }

        XCTAssertFalse(cleanupFlag.get(), "Cleanup should not have run before gate opens")

        // Open the gate so non-cooperative task can finish
        await gate.open()
        _ = await cleanupTask.value

        XCTAssertTrue(cleanupFlag.get(), "Cleanup should run after non-cooperative task finishes")
    }

    func testTimeoutRaceLateCompletionDeliversValueToContinuationConsumer() async {
        let race = TimeoutRace<Result<OfflineDiarization?, Error>>()
        let gate = AsyncTestGate()
        let lateResultReceived = AtomicFlag()

        let expectedDiarization = OfflineDiarization(
            segments: [
                SpeakerSegment(clusterID: "cluster_0", start: 0, end: 5, embedding: [1.0, 0.0], quality: 0.9)
            ],
            processingSeconds: 0.1,
            audioSeconds: 5.0
        )

        let diarizationTask = Task.detached(priority: .utility) { () -> OfflineDiarization? in
            await gate.wait()
            race.resolve(.finished(.success(expectedDiarization)))
            return expectedDiarization
        }

        let watchdog = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            race.resolve(.timedOut)
        }

        let outcome = await race.wait()
        watchdog.cancel()

        switch outcome {
        case .timedOut:
            break
        case .finished:
            XCTFail("Expected timedOut result")
        }

        let continuationTask = Task.detached(priority: .utility) {
            let lateResult = await diarizationTask.value
            if let lateResult, lateResult.clusterIDs == ["cluster_0"] {
                lateResultReceived.set(true)
            }
        }

        XCTAssertFalse(lateResultReceived.get(), "Continuation should not have completed before gate opens")

        await gate.open()
        _ = await continuationTask.value

        XCTAssertTrue(lateResultReceived.get(), "Continuation consumer must receive late diarization result after timeout")
    }

    func testCleanupCompositionWaitsForBothDiarizationAndMeEnrollment() async {
        let diarizationGate = AsyncTestGate()
        let meEnrollmentGate = AsyncTestGate()
        let cleanupFlag = AtomicFlag()

        let diarizationTask = Task.detached(priority: .utility) { () -> String in
            await diarizationGate.wait()
            return "diarizationDone"
        }

        let meEnrollmentTask: Task<Void, Never> = Task.detached(priority: .utility) {
            await meEnrollmentGate.wait()
        }

        let cleanupTask = Task.detached(priority: .utility) {
            _ = await diarizationTask.value
            _ = await meEnrollmentTask.value
            cleanupFlag.set(true)
        }

        // Neither completed -> cleanup not run
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(cleanupFlag.get())

        // Diarization completes first, meEnrollment still pending -> cleanup not run
        await diarizationGate.open()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(cleanupFlag.get())

        // Me enrollment completes -> cleanup runs
        await meEnrollmentGate.open()
        _ = await cleanupTask.value
        XCTAssertTrue(cleanupFlag.get())
    }

    func testAppendOversizedChunkAndExtractSlices() async {
        let promoter = LiveVoicePromoter()
        let capacity = 90 * 16_000 // 1,440,000 samples
        let n = 10 * 16_000 // 160,000 samples extra (total 100 seconds)
        let totalCount = capacity + n

        // Create samples where sample[i] = Float(i)
        var largeChunk = [Float](repeating: 0, count: totalCount)
        for i in 0..<totalCount {
            largeChunk[i] = Float(i)
        }

        // Single append of capacity + n samples (100 seconds)
        await promoter.append(samples: largeChunk)

        // The buffer retains the last 90 seconds (samples from second 10.0 to 100.0, i.e. index 160,000..<1,600,000)
        // Extract 5s slice from 20.0s to 25.0s (indices 320,000..<400,000)
        let (slice1, sec1) = await promoter.extractSamples(
            for: [(start: 20.0, end: 25.0)],
            maxSeconds: 10.0
        )
        XCTAssertEqual(sec1, 5.0, accuracy: 0.001)
        XCTAssertEqual(slice1.count, 5 * 16_000)
        XCTAssertEqual(slice1.first ?? -1, Float(20 * 16_000), accuracy: 0.001)
        XCTAssertEqual(slice1.last ?? -1, Float(25 * 16_000 - 1), accuracy: 0.001)

        // Extract 5s slice from 90.0s to 95.0s (indices 1,440,000..<1,520,000)
        let (slice2, sec2) = await promoter.extractSamples(
            for: [(start: 90.0, end: 95.0)],
            maxSeconds: 10.0
        )
        XCTAssertEqual(sec2, 5.0, accuracy: 0.001)
        XCTAssertEqual(slice2.count, 5 * 16_000)
        XCTAssertEqual(slice2.first ?? -1, Float(90 * 16_000), accuracy: 0.001)
        XCTAssertEqual(slice2.last ?? -1, Float(95 * 16_000 - 1), accuracy: 0.001)
    }

    func testShouldEnrollMeDecision() {
        // All conditions satisfied -> true
        XCTAssertTrue(AppState.shouldEnrollMe(
            didRefine: true,
            alreadyEnrolled: false,
            speechSeconds: 25.0,
            minSeconds: 20.0
        ))

        // Refine failed -> false
        XCTAssertFalse(AppState.shouldEnrollMe(
            didRefine: false,
            alreadyEnrolled: false,
            speechSeconds: 25.0,
            minSeconds: 20.0
        ))

        // Already enrolled -> false
        XCTAssertFalse(AppState.shouldEnrollMe(
            didRefine: true,
            alreadyEnrolled: true,
            speechSeconds: 25.0,
            minSeconds: 20.0
        ))

        // Too little speech audio (< minSeconds) -> false
        XCTAssertFalse(AppState.shouldEnrollMe(
            didRefine: true,
            alreadyEnrolled: false,
            speechSeconds: 15.0,
            minSeconds: 20.0
        ))
    }

    func testPromotionWaitsForSufficientBufferedAudio() async {
        let callbackCount = AtomicCounter()
        let promoter = LiveVoicePromoter(
            embeddingProvider: { samples in
                return [Float](repeating: 0.1, count: 256)
            },
            onEmbedding: { slot, emb, secs, gen in
                callbackCount.increment()
            }
        )

        // Session runs for 300 seconds total (buffer holds last 90s: [210.0, 300.0])
        let audio300s = [Float](repeating: 0.05, count: 300 * 16_000)
        await promoter.append(samples: audio300s)

        // Slot 1: 25s at t=10..35s (outside buffer) + 5s at t=295..300s (inside buffer) = 30s cumulative
        await promoter.noteSegments(slot: 1, segments: [
            (start: 10.0, end: 35.0),
            (start: 295.0, end: 300.0)
        ])

        // Allow any background extraction task to run
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Because only 5s was in the buffer (< 30s threshold), no promotion or callback
        XCTAssertEqual(callbackCount.get(), 0, "No promotion when buffered audio is only 5s despite 30s cumulative")

        // Ingest 30s of fresh audio from t=300..330s
        let audio30s = [Float](repeating: 0.05, count: 30 * 16_000)
        await promoter.append(samples: audio30s)

        // Slot 1 speaks for 30s of fresh speech at t=300..330s
        await promoter.noteSegments(slot: 1, segments: [
            (start: 300.0, end: 330.0)
        ])

        // Wait for background embedding task
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Exactly one promotion callback should fire
        XCTAssertEqual(callbackCount.get(), 1, "Exactly one callback when fresh 30s arrives in buffer")

        // Further speech should not trigger another callback (already promoted)
        await promoter.noteSegments(slot: 1, segments: [
            (start: 330.0, end: 340.0)
        ])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(callbackCount.get(), 1, "Slot remains promoted, no duplicate callback")
    }

    func testExtractionResetCancelsAndDropsCallback() async {
        let gate = AsyncTestGate()
        let callbackFired = AtomicFlag()

        let delayedEngine: @Sendable ([Float]) async throws -> [Float] = { samples in
            await gate.wait()
            return [Float](repeating: 0.5, count: 256)
        }

        let promoter = LiveVoicePromoter(embeddingProvider: delayedEngine)
        await promoter.setOnEmbedding { slot, embedding, seconds, generation in
            callbackFired.set(true)
        }

        // Feed 40s of audio
        let samples = [Float](repeating: 0.1, count: 40 * 16_000)
        await promoter.append(samples: samples)

        // Note 30s speech -> triggers extraction task which blocks on gate
        await promoter.noteSegments(slot: 1, segments: [(start: 0.0, end: 30.0)])

        // Reset while extraction is in flight (increments generation and cancels inFlightTasks)
        await promoter.reset()

        // Open gate so extraction task finishes
        await gate.open()

        // Wait a short moment
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(callbackFired.get(), "Callback must not fire for extraction started before reset")
    }

    func testRunGuardedCleanupWithHardLimitDeletesFolderOnTimeout() async {
        let testDir = tempDir.appendingPathComponent("guarded-cleanup-test")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        let sampleFile = testDir.appendingPathComponent("test.wav")
        let markerFile = testDir.appendingPathComponent("retained-until-restart")
        try? "dummy audio data".write(to: sampleFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sampleFile.path))

        let gate = AsyncTestGate()
        let hardLimitExceededFlag = AtomicFlag()
        let deleteCalledFlag = AtomicFlag()

        let success = await AppState.runGuardedCleanup(
            hardLimitSeconds: 0.2,
            work: {
                await gate.wait()
            },
            deleteFiles: {
                deleteCalledFlag.set(true)
                try? FileManager.default.removeItem(at: testDir)
            },
            markRetained: {
                FileManager.default.createFile(atPath: markerFile.path, contents: nil)
            },
            onHardLimitExceeded: {
                hardLimitExceededFlag.set(true)
            }
        )

        XCTAssertFalse(success, "Cleanup helper should report false on timeout")
        XCTAssertFalse(deleteCalledFlag.get(), "Delete closure must NOT be called on hard limit timeout")
        XCTAssertTrue(hardLimitExceededFlag.get(), "onHardLimitExceeded callback must fire")
        XCTAssertTrue(FileManager.default.fileExists(atPath: testDir.path), "Folder must still exist on hard limit timeout")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerFile.path), "retained-until-restart marker must be written on timeout")

        // Open gate to let normal background completion run
        await gate.open()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(deleteCalledFlag.get(), "Delete closure must be called when normal completion finishes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: testDir.path), "Folder must be deleted by normal completion")
    }

    func testNoteSegmentsReturnsImmediatelyBeforeExtractionStarts() async {
        let gate = AsyncTestGate()
        let extractionStarted = AtomicFlag()
        let callbackCount = AtomicCounter()

        let delayedEngine: @Sendable ([Float]) async throws -> [Float] = { samples in
            extractionStarted.set(true)
            await gate.wait()
            return [Float](repeating: 0.42, count: 256)
        }

        let promoter = LiveVoicePromoter(embeddingProvider: delayedEngine)
        await promoter.setOnEmbedding { slot, emb, secs, gen in
            callbackCount.increment()
        }

        // Buffer 40s of audio
        let samples = [Float](repeating: 0.1, count: 40 * 16_000)
        await promoter.append(samples: samples)

        // noteSegments should return immediately while gate is closed
        await promoter.noteSegments(slot: 1, segments: [(start: 0.0, end: 35.0)])

        // noteSegments has returned! At this point callback has NOT fired because gate is closed
        XCTAssertEqual(callbackCount.get(), 0, "Callback must not have fired yet while gate is closed")

        // Open gate
        await gate.open()

        // Wait for drain task to complete extraction and call callback
        for _ in 0..<50 {
            if callbackCount.get() == 1 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(callbackCount.get(), 1, "Result must still be delivered once after gate opens")
    }
}

// Async gate helper for testing in-flight task concurrency
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

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ initial: Bool = false) {
        self.value = initial
    }

    func set(_ v: Bool) {
        lock.lock()
        value = v
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func get() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

// LiveVoicePromoter actor extension for 3-argument callback compatibility in tests
extension LiveVoicePromoter {
    func setOnEmbedding(_ callback: @escaping @Sendable (Int, [Float], Double) -> Void) {
        self.onEmbedding = { slot, emb, secs, _ in
            callback(slot, emb, secs)
        }
    }
}
