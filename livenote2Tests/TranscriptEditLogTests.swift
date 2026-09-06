import XCTest
@testable import LiveNote

final class TranscriptEditLogTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestLogSandbox.activate()
    }

    func testEncodeDecodeRoundTrip() throws {
        let rowID1 = UUID()
        let rowID2 = UUID()
        let batch1 = TranscriptEditBatch(
            kind: .inline,
            rowEdits: [RowEdit(rowID: rowID1, before: "hello", after: "Hello")]
        )
        let batch2 = TranscriptEditBatch(
            kind: .replaceAll,
            find: "world",
            replacement: "World",
            caseSensitive: true,
            wholeWord: true,
            rowEdits: [RowEdit(rowID: rowID2, before: "world", after: "World")],
            summaryBefore: "old summary",
            summaryAfter: "new summary"
        )
        let log = TranscriptEditLog(version: 1, editsAtLastSummary: 1, batches: [batch1, batch2])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(log)

        let loaded = try TranscriptEditLog.load(from: data)
        XCTAssertEqual(loaded.version, 1)
        XCTAssertEqual(loaded.editsAtLastSummary, 1)
        XCTAssertEqual(loaded.batches.count, 2)
        XCTAssertEqual(loaded.batches[0].kind, .inline)
        XCTAssertEqual(loaded.batches[0].rowEdits[0].before, "hello")
        XCTAssertEqual(loaded.batches[1].kind, .replaceAll)
        XCTAssertEqual(loaded.batches[1].find, "world")
        XCTAssertEqual(loaded.batches[1].summaryAfter, "new summary")
    }

    func testEditCountAndEditedRowIDs() {
        let rowID1 = UUID()
        let rowID2 = UUID()
        let rowID3 = UUID()

        let batch1 = TranscriptEditBatch(
            kind: .inline,
            rowEdits: [RowEdit(rowID: rowID1, before: "a", after: "b")]
        )
        let batch2 = TranscriptEditBatch(
            kind: .replaceAll,
            rowEdits: [
                RowEdit(rowID: rowID2, before: "c", after: "d"),
                RowEdit(rowID: rowID3, before: "e", after: "f")
            ]
        )
        let log = TranscriptEditLog(batches: [batch1, batch2])

        XCTAssertEqual(log.editCount, 3)
        XCTAssertEqual(log.editedRowIDs, Set([rowID1, rowID2, rowID3]))
    }

    func testSummaryOnlyBatchEditCount() {
        let batch = TranscriptEditBatch(
            kind: .replaceAll,
            find: "term",
            replacement: "replacement",
            caseSensitive: true,
            wholeWord: true,
            rowEdits: [],
            summaryBefore: "old summary",
            summaryAfter: "new summary"
        )
        let log = TranscriptEditLog(batches: [batch])
        XCTAssertEqual(log.editCount, 1)
        XCTAssertTrue(log.editedRowIDs.isEmpty)
    }

    func testOriginalTextPicksEarliestBefore() {
        let rowID = UUID()
        let batch1 = TranscriptEditBatch(
            kind: .inline,
            rowEdits: [RowEdit(rowID: rowID, before: "Initial text", after: "First edit")]
        )
        let batch2 = TranscriptEditBatch(
            kind: .inline,
            rowEdits: [RowEdit(rowID: rowID, before: "First edit", after: "Second edit")]
        )
        let log = TranscriptEditLog(batches: [batch1, batch2])

        XCTAssertEqual(log.originalText(for: rowID), "Initial text")
        XCTAssertNil(log.originalText(for: UUID()))
    }

    func testPendingEditsSinceSummary() {
        let rowID = UUID()
        var log = TranscriptEditLog()
        XCTAssertEqual(log.pendingEditsSinceSummary, 0)

        log.batches.append(TranscriptEditBatch(
            kind: .inline,
            rowEdits: [RowEdit(rowID: rowID, before: "a", after: "b")]
        ))
        XCTAssertEqual(log.pendingEditsSinceSummary, 1)

        log.editsAtLastSummary = 1
        XCTAssertEqual(log.pendingEditsSinceSummary, 0)

        log.batches.append(TranscriptEditBatch(
            kind: .inline,
            rowEdits: [RowEdit(rowID: rowID, before: "b", after: "c")]
        ))
        XCTAssertEqual(log.pendingEditsSinceSummary, 1)
    }

    func testLoadEmptyDataThrowsEditLogCorrupt() {
        XCTAssertThrowsError(try TranscriptEditLog.load(from: Data())) { error in
            guard case MeetingStoreError.editLogCorrupt(let message) = error else {
                XCTFail("Expected editLogCorrupt, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("empty file"))
        }
    }

    func testCorruptJSONThrowsEditLogCorrupt() {
        let corruptData = "{ corrupt json ".data(using: .utf8)!
        XCTAssertThrowsError(try TranscriptEditLog.load(from: corruptData)) { error in
            guard case MeetingStoreError.editLogCorrupt = error else {
                XCTFail("Expected editLogCorrupt error, got \(error)")
                return
            }
        }
    }

    func testVersion2TreatedAsCorrupt() {
        let v2JSON = """
        {
            "version": 2,
            "editsAtLastSummary": 0,
            "batches": []
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try TranscriptEditLog.load(from: v2JSON)) { error in
            guard case MeetingStoreError.editLogCorrupt(let message) = error else {
                XCTFail("Expected editLogCorrupt, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("Unsupported version 2"))
        }
    }

    // MARK: - U2: Revision and Backward Compatibility Tests

    func testLegacyJSONWithoutRevisionOffsetDecodesProperly() throws {
        let legacyJSON = """
        {
            "version": 1,
            "editsAtLastSummary": 2,
            "batches": []
        }
        """.data(using: .utf8)!

        let log = try TranscriptEditLog.load(from: legacyJSON)
        XCTAssertEqual(log.revisionOffset, 0)
        XCTAssertEqual(log.revision, 0)
        XCTAssertEqual(log.editsAtLastSummary, 2)
        XCTAssertEqual(log.pendingEditsSinceSummary, 0)
    }

    func testRoundTripEncodesRevisionOffset() throws {
        let log = TranscriptEditLog(version: 1, editsAtLastSummary: 2, batches: [], revisionOffset: 3)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(log)

        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("\"revisionOffset\":3"))

        let loaded = try TranscriptEditLog.load(from: data)
        XCTAssertEqual(loaded.revisionOffset, 3)
        XCTAssertEqual(loaded.revision, 3)
        XCTAssertEqual(loaded.pendingEditsSinceSummary, 1)
    }

    // MARK: - Fix Round 1 Tests (F1-1 & F1-2)

    func testRevisionOffsetOverflowFailsToDecode() {
        let json = """
        {
            "version": 1,
            "editsAtLastSummary": 0,
            "batches": [
                {
                    "id": "11111111-1111-1111-1111-111111111111",
                    "at": "2026-09-05T12:00:00Z",
                    "kind": "inline",
                    "rowEdits": [
                        {
                            "rowID": "22222222-2222-2222-2222-222222222222",
                            "before": "before",
                            "after": "after"
                        }
                    ]
                }
            ],
            "revisionOffset": 9223372036854775807
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try TranscriptEditLog.load(from: json)) { error in
            guard case MeetingStoreError.editLogCorrupt = error else {
                XCTFail("Expected editLogCorrupt, got \(error)")
                return
            }
        }
    }

    func testNegativeRevisionOffsetFailsToDecode() {
        let json = """
        {
            "version": 1,
            "editsAtLastSummary": 0,
            "batches": [],
            "revisionOffset": -1
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try TranscriptEditLog.load(from: json)) { error in
            guard case MeetingStoreError.editLogCorrupt = error else {
                XCTFail("Expected editLogCorrupt, got \(error)")
                return
            }
        }
    }

    func testNegativeEditsAtLastSummaryFailsToDecode() {
        let json = """
        {
            "version": 1,
            "editsAtLastSummary": -1,
            "batches": [],
            "revisionOffset": 0
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try TranscriptEditLog.load(from: json)) { error in
            guard case MeetingStoreError.editLogCorrupt = error else {
                XCTFail("Expected editLogCorrupt, got \(error)")
                return
            }
        }
    }

    func testMissingBatchesFailsToDecode() {
        let json = """
        {"version":1,"editsAtLastSummary":2}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try TranscriptEditLog.load(from: json)) { error in
            guard case MeetingStoreError.editLogCorrupt = error else {
                XCTFail("Expected editLogCorrupt, got \(error)")
                return
            }
        }
    }

    func testNullBatchesFailsToDecode() {
        let json = """
        {"version":1,"editsAtLastSummary":2,"batches":null}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try TranscriptEditLog.load(from: json)) { error in
            guard case MeetingStoreError.editLogCorrupt = error else {
                XCTFail("Expected editLogCorrupt, got \(error)")
                return
            }
        }
    }

    func testLegacyFileWithAllThreeFieldsAndNoRevisionOffsetDecodesWithOffsetZero() throws {
        let json = """
        {
            "version": 1,
            "editsAtLastSummary": 2,
            "batches": []
        }
        """.data(using: .utf8)!

        let log = try TranscriptEditLog.load(from: json)
        XCTAssertEqual(log.version, 1)
        XCTAssertEqual(log.editsAtLastSummary, 2)
        XCTAssertEqual(log.batches.count, 0)
        XCTAssertEqual(log.revisionOffset, 0)
    }

    // MARK: - Fix Round 2 Tests (F2-1)

    func testRevisionAfterAppending() throws {
        // Normal add returns the sum
        let log1 = TranscriptEditLog(version: 1, editsAtLastSummary: 0, batches: [], revisionOffset: 5)
        XCTAssertEqual(try log1.revisionAfterAppending(weight: 3), 8)
        XCTAssertEqual(try log1.revisionAfterAppending(weight: 0), 5)

        // Exact boundary reaches Int.max without overflow
        let logBoundary = TranscriptEditLog(version: 1, editsAtLastSummary: 0, batches: [], revisionOffset: Int.max - 2)
        XCTAssertEqual(try logBoundary.revisionAfterAppending(weight: 2), Int.max)

        // Overflow throws editLogCorrupt
        let logMax = TranscriptEditLog(version: 1, editsAtLastSummary: 0, batches: [], revisionOffset: Int.max)
        XCTAssertThrowsError(try logMax.revisionAfterAppending(weight: 1)) { error in
            guard case MeetingStoreError.editLogCorrupt(let message) = error else {
                XCTFail("Expected editLogCorrupt, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("revision counter overflow"))
        }

        let logNearMax = TranscriptEditLog(version: 1, editsAtLastSummary: 0, batches: [], revisionOffset: Int.max - 1)
        XCTAssertThrowsError(try logNearMax.revisionAfterAppending(weight: 2)) { error in
            guard case MeetingStoreError.editLogCorrupt(let message) = error else {
                XCTFail("Expected editLogCorrupt, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("revision counter overflow"))
        }

        // Negative weight throws
        XCTAssertThrowsError(try log1.revisionAfterAppending(weight: -1)) { error in
            guard case MeetingStoreError.editLogCorrupt = error else {
                XCTFail("Expected editLogCorrupt, got \(error)")
                return
            }
        }
    }
}
