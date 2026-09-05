import XCTest
@testable import LiveNote

final class TranscriptRefinerClusterTests: XCTestCase {

    func testAssignClustersWithDiarization() {
        let segments = [
            SpeakerSegment(clusterID: "spk_1", start: 0.0, end: 5.0, embedding: [], quality: 0.9),
            SpeakerSegment(clusterID: "spk_2", start: 5.0, end: 10.0, embedding: [], quality: 0.9)
        ]
        let diarization = OfflineDiarization(segments: segments, processingSeconds: 0.5, audioSeconds: 10.0)

        let rows = [
            TranscriptRow(
                id: UUID(),
                channel: .them,
                speakerSlot: 0,
                speakerName: nil,
                english: "Hello from speaker 1",
                korean: "안녕하세요 1",
                startSeconds: 0.5,
                endSeconds: 4.5
            ),
            TranscriptRow(
                id: UUID(),
                channel: .them,
                speakerSlot: 1,
                speakerName: nil,
                english: "Hello from speaker 2",
                korean: "안녕하세요 2",
                startSeconds: 5.5,
                endSeconds: 9.5
            ),
            TranscriptRow(
                id: UUID(),
                channel: .me,
                speakerSlot: nil,
                speakerName: "Me",
                english: "My speech here",
                korean: nil,
                startSeconds: 2.0,
                endSeconds: 3.0
            )
        ]

        let updated = TranscriptRefiner.assignClusters(rows: rows, diarization: diarization)
        XCTAssertEqual(updated.count, 3)

        // Them 채널 1: spk_1 할당
        XCTAssertEqual(updated[0].clusterID, "spk_1")
        XCTAssertEqual(updated[0].english, "Hello from speaker 1")

        // Them 채널 2: spk_2 할당
        XCTAssertEqual(updated[1].clusterID, "spk_2")
        XCTAssertEqual(updated[1].english, "Hello from speaker 2")

        // Me 채널: clusterID는 nil 유지
        XCTAssertNil(updated[2].clusterID)
    }

    func testAssignClustersNilDiarization() {
        let rows = [
            TranscriptRow(
                id: UUID(),
                channel: .them,
                speakerSlot: 0,
                speakerName: nil,
                english: "Hello",
                korean: nil,
                startSeconds: 1.0,
                endSeconds: 2.0,
                clusterID: nil
            )
        ]

        let updated = TranscriptRefiner.assignClusters(rows: rows, diarization: nil)
        XCTAssertEqual(updated.count, 1)
        XCTAssertNil(updated[0].clusterID)
    }

    @MainActor
    func testDonorManualInheritanceAndAssignNamesUntouched() {
        let donor = TranscriptRow(
            id: UUID(),
            channel: .them,
            speakerSlot: 1,
            speakerName: "Alice (Manual)",
            english: "Live spoken words",
            korean: nil,
            startSeconds: 0.0,
            endSeconds: 5.0,
            nameSource: .manual,
            candidateNames: ["Alice (Manual)"],
            clusterID: "cluster_1"
        )

        // 1. bestOverlap finds the donor
        let matchedDonor = TranscriptRefiner.bestOverlap(start: 0.5, end: 4.5, in: [donor])
        XCTAssertNotNil(matchedDonor)
        XCTAssertEqual(matchedDonor?.nameSource, .manual)

        // 2. Refined row construction inherits all three fields from donor
        let refinedRow = TranscriptRow(
            id: UUID(),
            channel: .them,
            speakerSlot: matchedDonor?.speakerSlot,
            speakerName: matchedDonor?.speakerName,
            english: "Refined accurate sentence.",
            korean: nil,
            startSeconds: 0.5,
            endSeconds: 4.5,
            nameSource: matchedDonor?.nameSource,
            candidateNames: matchedDonor?.candidateNames,
            clusterID: matchedDonor?.clusterID
        )

        XCTAssertEqual(refinedRow.nameSource, .manual)
        XCTAssertEqual(refinedRow.speakerName, "Alice (Manual)")
        XCTAssertEqual(refinedRow.candidateNames, ["Alice (Manual)"])
        XCTAssertEqual(refinedRow.clusterID, "cluster_1")

        // 3. SpeakerMemory.assignNames leaves manual row untouched
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VoiceprintStore(rootURL: tempDir)
        let memory = SpeakerMemory(store: store)

        let diarization = OfflineDiarization(
            segments: [
                SpeakerSegment(clusterID: "cluster_1", start: 0.0, end: 5.0, embedding: [Float](repeating: 0.1, count: 256), quality: 0.9)
            ],
            processingSeconds: 0.1,
            audioSeconds: 5.0
        )

        let (assignedRows, _, _) = memory.assignNames(
            rows: [refinedRow],
            diarization: diarization,
            zoomName: { _ in "Bob via Zoom" },
            fallbackName: "Fallback Person",
            existingSlotNames: [1: "Slot Speaker"]
        )

        XCTAssertEqual(assignedRows.count, 1)
        XCTAssertEqual(assignedRows[0].nameSource, .manual)
        XCTAssertEqual(assignedRows[0].speakerName, "Alice (Manual)")
        try? FileManager.default.removeItem(at: tempDir)
    }
}
