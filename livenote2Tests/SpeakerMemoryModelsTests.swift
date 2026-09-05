import XCTest
@testable import LiveNote

final class SpeakerMemoryModelsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppLog.directoryOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("livenote2-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let dir = AppLog.directoryOverride {
            try? FileManager.default.removeItem(at: dir)
            AppLog.directoryOverride = nil
        }
        super.tearDown()
    }

    // MARK: - TranscriptRow Codable Tests

    func testTranscriptRowRoundTripWithNewFields() throws {
        let row = TranscriptRow(
            id: UUID(),
            channel: .them,
            speakerSlot: 1,
            speakerName: "Alice",
            english: "Hello world",
            korean: "안녕하세요",
            startSeconds: 1.5,
            endSeconds: 5.0,
            nameSource: .voice,
            candidateNames: ["Alice", "Bob"],
            clusterID: "cluster_0"
        )

        let data = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(TranscriptRow.self, from: data)

        XCTAssertEqual(decoded.id, row.id)
        XCTAssertEqual(decoded.channel, .them)
        XCTAssertEqual(decoded.speakerSlot, 1)
        XCTAssertEqual(decoded.speakerName, "Alice")
        XCTAssertEqual(decoded.english, "Hello world")
        XCTAssertEqual(decoded.korean, "안녕하세요")
        XCTAssertEqual(decoded.startSeconds, 1.5)
        XCTAssertEqual(decoded.endSeconds, 5.0)
        XCTAssertEqual(decoded.nameSource, .voice)
        XCTAssertEqual(decoded.candidateNames, ["Alice", "Bob"])
        XCTAssertEqual(decoded.clusterID, "cluster_0")
    }

    func testTranscriptRowDecodesLegacyJSONWithoutNewFields() throws {
        let legacyJSON = """
        {
            "id": "12345678-1234-1234-1234-1234567890AB",
            "channel": "them",
            "speakerSlot": 0,
            "speakerName": null,
            "english": "Legacy transcript line",
            "korean": null,
            "startSeconds": 0.0,
            "endSeconds": 4.2
        }
        """

        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(TranscriptRow.self, from: data)

        XCTAssertEqual(decoded.id.uuidString, "12345678-1234-1234-1234-1234567890AB")
        XCTAssertEqual(decoded.channel, .them)
        XCTAssertEqual(decoded.speakerSlot, 0)
        XCTAssertNil(decoded.speakerName)
        XCTAssertEqual(decoded.english, "Legacy transcript line")
        XCTAssertNil(decoded.nameSource)
        XCTAssertNil(decoded.candidateNames)
        XCTAssertNil(decoded.clusterID)
    }

    // MARK: - VoiceprintDatabase & VoiceCentroid Tolerant Decode Tests

    func testVoiceprintDatabaseDecodesCentroidMissingConflicts() throws {
        let json = """
        {
            "version": 1,
            "people": [
                {
                    "id": "p1",
                    "name": "Craig",
                    "aliases": ["Craig F"],
                    "email": "craig@example.com",
                    "centroids": [
                        {
                            "v": [0.1, 0.2, 0.3],
                            "n": 5,
                            "quality": 0.85,
                            "updated": 1725500000.0
                        }
                    ],
                    "meetings": 2,
                    "sources": ["zoom"]
                }
            ]
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let db = try decoder.decode(VoiceprintDatabase.self, from: data)

        XCTAssertEqual(db.version, 1)
        XCTAssertEqual(db.people.count, 1)
        let person = db.people[0]
        XCTAssertEqual(person.id, "p1")
        XCTAssertEqual(person.name, "Craig")
        XCTAssertEqual(person.aliases, ["Craig F"])
        XCTAssertEqual(person.email, "craig@example.com")
        XCTAssertEqual(person.centroids.count, 1)
        XCTAssertEqual(person.centroids[0].v, [0.1, 0.2, 0.3])
        XCTAssertEqual(person.centroids[0].n, 5)
        XCTAssertEqual(person.centroids[0].quality, 0.85)
        XCTAssertEqual(person.centroids[0].conflicts, 0)
        XCTAssertEqual(person.totalSamples, 5)
    }

    // MARK: - OfflineDiarization Math Tests

    func testOfflineDiarizationClusterIDsOrdering() {
        let diarization = OfflineDiarization(
            segments: [
                SpeakerSegment(clusterID: "spk_1", start: 0, end: 5, embedding: [], quality: 0.9),
                SpeakerSegment(clusterID: "spk_2", start: 5, end: 17, embedding: [], quality: 0.8),
                SpeakerSegment(clusterID: "spk_3", start: 17, end: 25, embedding: [], quality: 0.7),
                SpeakerSegment(clusterID: "spk_1", start: 25, end: 27, embedding: [], quality: 0.9)
            ],
            processingSeconds: 1.2,
            audioSeconds: 27.0
        )

        // spk_2: 12s, spk_3: 8s, spk_1: 7s
        XCTAssertEqual(diarization.clusterIDs, ["spk_2", "spk_3", "spk_1"])
        XCTAssertEqual(diarization.seconds(for: "spk_1"), 7.0)
        XCTAssertEqual(diarization.seconds(for: "spk_2"), 12.0)
        XCTAssertEqual(diarization.seconds(for: "spk_3"), 8.0)
        XCTAssertEqual(diarization.seconds(for: "spk_unknown"), 0.0)
    }

    func testOfflineDiarizationDominantCluster() {
        let diarization = OfflineDiarization(
            segments: [
                SpeakerSegment(clusterID: "c_A", start: 0.0, end: 2.0, embedding: [], quality: 0.8),
                SpeakerSegment(clusterID: "c_B", start: 2.0, end: 6.0, embedding: [], quality: 0.8),
                SpeakerSegment(clusterID: "c_C", start: 6.0, end: 10.0, embedding: [], quality: 0.8)
            ],
            processingSeconds: 0.5,
            audioSeconds: 10.0
        )

        // Query interval [1.0, 5.0] (duration 4.0s).
        // c_A overlap: [1.0, 2.0] = 1.0s
        // c_B overlap: [2.0, 5.0] = 3.0s
        // minOverlap = max(0.3, 4.0 * 0.15) = 0.6s.
        // Best: c_B with 3.0s >= 0.6s -> "c_B"
        XCTAssertEqual(diarization.dominantCluster(from: 1.0, to: 5.0), "c_B")

        // Query interval [1.9, 2.1] (duration 0.2s).
        // c_A overlap = 0.1s, c_B overlap = 0.1s
        // minOverlap = max(0.3, 0.2 * 0.15) = 0.3s.
        // Neither meets 0.3s -> nil
        XCTAssertNil(diarization.dominantCluster(from: 1.9, to: 2.1))

        // Query outside any segment
        XCTAssertNil(diarization.dominantCluster(from: 20.0, to: 25.0))

        // Invalid query interval
        XCTAssertNil(diarization.dominantCluster(from: 5.0, to: 2.0))
    }

    func testOfflineDiarizationCentroidMath() {
        let seg1 = SpeakerSegment(clusterID: "c1", start: 0, end: 2, embedding: [1.0, 0.0], quality: 0.8)
        let seg2 = SpeakerSegment(clusterID: "c1", start: 2, end: 5, embedding: [0.0, 1.0], quality: 0.8)
        let diarization = OfflineDiarization(
            segments: [seg1, seg2],
            processingSeconds: 0.1,
            audioSeconds: 5.0
        )

        let centroid = diarization.centroid(for: "c1")
        XCTAssertNotNil(centroid)
        guard let c = centroid else { return }

        XCTAssertEqual(c.clusterID, "c1")
        XCTAssertEqual(c.seconds, 5.0, accuracy: 0.001)
        XCTAssertEqual(c.quality, 0.8, accuracy: 0.001)
        XCTAssertEqual(c.embedding.count, 2)

        // Equal quality weights -> sum = [0.8, 0.8] -> L2 normalized = [1/sqrt(2), 1/sqrt(2)]
        let expectedVal: Float = 1.0 / sqrt(2.0)
        XCTAssertEqual(c.embedding[0], expectedVal, accuracy: 0.0001)
        XCTAssertEqual(c.embedding[1], expectedVal, accuracy: 0.0001)

        // Check L2 norm is 1.0
        let norm = sqrt(c.embedding[0] * c.embedding[0] + c.embedding[1] * c.embedding[1])
        XCTAssertEqual(norm, 1.0, accuracy: 0.0001)

        // Non-existent cluster returns nil
        XCTAssertNil(diarization.centroid(for: "non_existent"))
    }

    // MARK: - VoiceprintThresholds Tests

    func testVoiceprintThresholdsLoadFallsBackOnGarbage() throws {
        let suiteName = "test.voiceprint.thresholds.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Set garbage data
        defaults.set(Data([0xDE, 0xAD, 0xBE, 0xEF]), forKey: VoiceprintThresholds.defaultsKey)

        let loaded = VoiceprintThresholds.load(defaults: defaults)
        XCTAssertEqual(loaded.matchThreshold, 0.65, accuracy: 0.001)
        XCTAssertEqual(loaded.margin, 0.08, accuracy: 0.001)
        XCTAssertEqual(loaded.mergeThreshold, 0.35, accuracy: 0.001)
        XCTAssertEqual(loaded.minEnrollSeconds, 20.0, accuracy: 0.001)
        XCTAssertEqual(loaded.minQuality, 0.6, accuracy: 0.001)
        XCTAssertEqual(loaded.maxCentroids, 5)
        XCTAssertEqual(loaded.conflictLimit, 3)

        // Test save and load roundtrip
        var custom = VoiceprintThresholds()
        custom.matchThreshold = 0.72
        custom.margin = 0.10
        try custom.save(defaults: defaults)

        let reloaded = VoiceprintThresholds.load(defaults: defaults)
        XCTAssertEqual(reloaded.matchThreshold, 0.72, accuracy: 0.001)
        XCTAssertEqual(reloaded.margin, 0.10, accuracy: 0.001)
    }

    // MARK: - SpeakerSummary Tests

    func testSpeakerSummaryOrdering() {
        let rows: [TranscriptRow] = [
            TranscriptRow(
                channel: .them,
                speakerName: "Alice",
                english: "Hello",
                startSeconds: 0.0,
                endSeconds: 10.0,
                nameSource: .zoom
            ),
            TranscriptRow(
                channel: .them,
                speakerName: "Bob",
                english: "Hi there",
                startSeconds: 10.0,
                endSeconds: 30.0,
                nameSource: .voice
            ),
            TranscriptRow(
                channel: .them,
                speakerName: "Alice",
                english: "How are you?",
                startSeconds: 30.0,
                endSeconds: 45.0,
                nameSource: .manual
            ),
            TranscriptRow(
                channel: .them,
                speakerName: "Charlie",
                english: "Great",
                startSeconds: 45.0,
                endSeconds: 50.0,
                nameSource: .slot
            )
        ]

        let stats = SpeakerSummary.speakerStats(rows: rows) { row in
            row.speakerName ?? "Unknown"
        }

        // Alice: 10 + 15 = 25s
        // Bob: 20s
        // Charlie: 5s
        XCTAssertEqual(stats.count, 3)
        XCTAssertEqual(stats[0].name, "Alice")
        XCTAssertEqual(stats[0].seconds, 25.0)
        XCTAssertEqual(stats[0].source, .zoom)

        XCTAssertEqual(stats[1].name, "Bob")
        XCTAssertEqual(stats[1].seconds, 20.0)
        XCTAssertEqual(stats[1].source, .voice)

        XCTAssertEqual(stats[2].name, "Charlie")
        XCTAssertEqual(stats[2].seconds, 5.0)
        XCTAssertEqual(stats[2].source, .slot)
    }
}
