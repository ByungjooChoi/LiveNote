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
}
