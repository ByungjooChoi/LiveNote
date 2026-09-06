import XCTest
@testable import LiveNote

@MainActor
final class MeetingStoreEditTests: XCTestCase {

    private var store: MeetingStore!
    private var tempLogDir: URL!
    private var previousLogOverride: URL?

    override func setUp() {
        super.setUp()
        TestLogSandbox.activate()
        previousLogOverride = AppLog.directoryOverride
        tempLogDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLogTests-\(UUID().uuidString)", isDirectory: true)
        AppLog.directoryOverride = tempLogDir
        do {
            store = try MeetingStoreFixture.makeStore()
        } catch {
            XCTFail("Failed to create store fixture: \(error)")
        }
    }

    override func tearDown() {
        AppLog.flush()
        AppLog.directoryOverride = previousLogOverride
        if let store {
            MeetingStoreFixture.cleanUp(store)
        }
        if let tempLogDir {
            try? FileManager.default.removeItem(at: tempLogDir)
        }
        super.tearDown()
    }

    private func createTestMeeting(
        summaryText: String? = "Initial summary",
        koreanText: String? = nil
    ) throws -> (URL, [TranscriptRow]) {
        let row1 = MeetingStoreFixture.row(text: "First row about Apple", start: 0, end: 5)
        let row2 = MeetingStoreFixture.row(text: "Second row about Google", start: 5, end: 10)
        let row3: TranscriptRow
        if let koreanText {
            row3 = TranscriptRow(
                id: UUID(),
                channel: .them,
                speakerSlot: 0,
                speakerName: "Alice",
                english: "Third row about Apple products",
                korean: koreanText,
                startSeconds: 10,
                endSeconds: 15
            )
        } else {
            row3 = MeetingStoreFixture.row(text: "Third row about Apple products", start: 10, end: 15)
        }
        let rows = [row1, row2, row3]

        let url = try store.save(
            rows: rows,
            myName: "Philip",
            speakerNames: [0: "Alice"],
            startedAt: MeetingStoreFixture.date(hour: 10),
            durationSeconds: 15,
            title: "Test Meeting",
            summary: summaryText,
            attendees: nil,
            existingURL: nil
        )
        return (url, rows)
    }

    // MARK: - R1-3: AC11 on-disk text preservation in save(existingURL:)

    func testSavePreservesNewerOnDiskTextForExistingRowIDs() throws {
        let (url, rows) = try createTestMeeting()
        let row1ID = rows[0].id

        // 1. User edits row 1 on disk via updateRow
        _ = try store.updateRow(at: url, rowID: row1ID, english: "Row 1 edited by user")

        // 2. Caller (e.g. 2-pass or rename) calls save with stale original rows + 1 brand new row
        let newRow4 = MeetingStoreFixture.row(text: "New fourth row", start: 15, end: 20)
        var staleRowsWithNew = rows
        staleRowsWithNew.append(newRow4)

        try store.save(
            rows: staleRowsWithNew,
            myName: "Philip",
            speakerNames: [0: "Alice Renamed"],
            startedAt: MeetingStoreFixture.date(hour: 10),
            durationSeconds: 20,
            title: "Test Meeting",
            summary: "Updated summary",
            attendees: nil,
            existingURL: url
        )

        let loaded = store.load(url)!
        XCTAssertEqual(loaded.rows.count, 4)
        // Edited text survives
        XCTAssertEqual(loaded.rows[0].english, "Row 1 edited by user")
        // Stale unmodified text remains
        XCTAssertEqual(loaded.rows[1].english, "Second row about Google")
        // Brand new row is written as given
        XCTAssertEqual(loaded.rows[3].english, "New fourth row")
        // Caller's speaker rename is applied
        XCTAssertEqual(loaded.speakerNames[0], "Alice Renamed")
    }

    // MARK: - R1-4: Summary-only matches & replaceAll

    func testSummaryOnlyReplaceAllAndUndo() throws {
        let (url, _) = try createTestMeeting(summaryText: "Special summary mentioning Unicorn")

        // "Unicorn" exists only in the summary, not in transcript rows
        let result = try store.replaceAll(
            at: url,
            find: "Unicorn",
            replacement: "Pegasus",
            caseSensitive: true,
            wholeWord: true,
            includeSummary: true
        )

        XCTAssertEqual(result.changedRowCount, 0)
        XCTAssertEqual(result.meeting.summary, "Special summary mentioning Pegasus")
        XCTAssertEqual(result.log.editCount, 1)
        XCTAssertEqual(result.log.batches.count, 1)
        XCTAssertTrue(result.log.batches[0].rowEdits.isEmpty)
        XCTAssertEqual(result.log.batches[0].summaryBefore, "Special summary mentioning Unicorn")
        XCTAssertEqual(result.log.batches[0].summaryAfter, "Special summary mentioning Pegasus")

        // Check summary.md and edits.json on disk
        let summaryFile = url.appendingPathComponent("summary.md")
        let summaryContent = try String(contentsOf: summaryFile, encoding: .utf8)
        XCTAssertTrue(summaryContent.contains("Pegasus"))

        let editsFile = url.appendingPathComponent("edits.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: editsFile.path))

        // Undo restores summary
        let undoResult = try store.undoLastEdit(at: url)
        XCTAssertEqual(undoResult.meeting.summary, "Special summary mentioning Unicorn")
        XCTAssertEqual(undoResult.log.editCount, 0)
        XCTAssertTrue(undoResult.log.batches.isEmpty)

        let restoredSummaryContent = try String(contentsOf: summaryFile, encoding: .utf8)
        XCTAssertTrue(restoredSummaryContent.contains("Unicorn"))

        // Both rows and summary empty/no matches -> throws noMatches
        XCTAssertThrowsError(
            try store.replaceAll(
                at: url,
                find: "NonExistentAnywhere",
                replacement: "X",
                caseSensitive: false,
                wholeWord: false,
                includeSummary: true
            )
        ) { error in
            XCTAssertEqual(error as? MeetingStoreError, MeetingStoreError.noMatches)
        }
    }

    // MARK: - R1-5: Corrupt edits.json transactional recovery

    func testCorruptEditsJsonIsMovedTransactionalWithNewPattern() throws {
        let (url, rows) = try createTestMeeting()
        let editsFile = url.appendingPathComponent("edits.json")
        try "{ bad json ".write(to: editsFile, atomically: true, encoding: .utf8)

        let result = try store.updateRow(at: url, rowID: rows[0].id, english: "Clean edit after corruption")
        XCTAssertEqual(result.changedRowCount, 1)
        XCTAssertEqual(result.warning, "Edit history was unreadable and has been reset")

        // Verify backup file exists with new pattern edits.json.corrupt-<unix ts>-<uuid prefix 8>
        let files = try FileManager.default.contentsOfDirectory(atPath: url.path)
        let corruptBackups = files.filter { $0.hasPrefix("edits.json.corrupt-") }
        XCTAssertEqual(corruptBackups.count, 1)
        let pattern = "^edits\\.json\\.corrupt-\\d+-[0-9A-Fa-f]{8}$"
        let regex = try NSRegularExpression(pattern: pattern)
        let backupName = corruptBackups[0]
        let match = regex.firstMatch(in: backupName, range: NSRange(backupName.startIndex..., in: backupName))
        XCTAssertNotNil(match)

        // New clean edits.json exists
        let loadedLog = store.editLog(at: url)
        XCTAssertEqual(loadedLog.editCount, 1)
    }

    func testCorruptEditsJsonForcedStagingFailureDoesNotMoveCorruptFile() throws {
        let (url, rows) = try createTestMeeting()
        let editsFile = url.appendingPathComponent("edits.json")
        try "{ bad json content }".write(to: editsFile, atomically: true, encoding: .utf8)

        // Force staging failure with read-only folder
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        XCTAssertThrowsError(try store.updateRow(at: url, rowID: rows[0].id, english: "Failed edit")) { error in
            guard case MeetingStoreError.writeFailed = error else {
                XCTFail("Expected writeFailed, got \(error)")
                return
            }
        }

        // Restore permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        // Corrupt file is still in place, no backup file created
        let files = try FileManager.default.contentsOfDirectory(atPath: url.path)
        XCTAssertTrue(files.contains("edits.json"))
        let corruptContent = try String(contentsOf: editsFile, encoding: .utf8)
        XCTAssertEqual(corruptContent, "{ bad json content }")
        let backups = files.filter { $0.hasPrefix("edits.json.corrupt-") }
        XCTAssertTrue(backups.isEmpty)
    }

    func testCorruptEditsJsonUndoPerformsRecoveryCommitAndWarning() throws {
        let (url, _) = try createTestMeeting()
        let editsFile = url.appendingPathComponent("edits.json")
        try "{ bad json for undo }".write(to: editsFile, atomically: true, encoding: .utf8)

        let undoResult = try store.undoLastEdit(at: url)
        XCTAssertEqual(undoResult.changedRowCount, 0)
        XCTAssertEqual(undoResult.warning, "Edit history was unreadable and has been reset")
        XCTAssertEqual(undoResult.log.editCount, 0)

        // Corrupt file moved
        let files = try FileManager.default.contentsOfDirectory(atPath: url.path)
        let corruptBackups = files.filter { $0.hasPrefix("edits.json.corrupt-") }
        XCTAssertEqual(corruptBackups.count, 1)
    }

    func testUnreadableEditsJsonThrowsWriteFailed() throws {
        let (url, rows) = try createTestMeeting()
        let editsFile = url.appendingPathComponent("edits.json")
        try "{}".write(to: editsFile, atomically: true, encoding: .utf8)

        // Make edits.json unreadable (chmod 000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: editsFile.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: editsFile.path)
        }

        XCTAssertThrowsError(try store.updateRow(at: url, rowID: rows[0].id, english: "New text")) { error in
            guard case MeetingStoreError.writeFailed(let message) = error else {
                XCTFail("Expected writeFailed, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("read edits.json"))
        }
    }

    // MARK: - R1-6: updateSummary throws on write failure

    func testUpdateSummaryThrowsOnWriteFailure() throws {
        let (url, _) = try createTestMeeting(summaryText: "Old summary")
        let sessionFile = url.appendingPathComponent("session.json")
        let summaryFile = url.appendingPathComponent("summary.md")
        let sessionBefore = try Data(contentsOf: sessionFile)
        let summaryBefore = try Data(contentsOf: summaryFile)

        // Force failure by setting folder read-only
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        XCTAssertThrowsError(try store.updateSummary(at: url, summary: "New summary that fails")) { error in
            guard case MeetingStoreError.writeFailed = error else {
                XCTFail("Expected writeFailed, got \(error)")
                return
            }
        }

        // Restore permissions and verify files unchanged
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let sessionAfter = try Data(contentsOf: sessionFile)
        let summaryAfter = try Data(contentsOf: summaryFile)
        XCTAssertEqual(sessionBefore, sessionAfter)
        XCTAssertEqual(summaryBefore, summaryAfter)
    }

    // MARK: - R1-7: Stale derived files removal

    func testStaleDerivedFilesRemovalOnSave() throws {
        let (url, rows) = try createTestMeeting(summaryText: "Initial summary", koreanText: "한국어 번역")
        let koFile = url.appendingPathComponent("ko.md")
        let summaryFile = url.appendingPathComponent("summary.md")

        XCTAssertTrue(FileManager.default.fileExists(atPath: koFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryFile.path))

        // Save again without korean rows and with summary = nil
        let nonKoreanRows = rows.map { row in
            TranscriptRow(
                id: row.id,
                channel: row.channel,
                speakerSlot: row.speakerSlot,
                speakerName: row.speakerName,
                english: row.english,
                korean: nil,
                startSeconds: row.startSeconds,
                endSeconds: row.endSeconds
            )
        }

        try store.save(
            rows: nonKoreanRows,
            myName: "Philip",
            speakerNames: [0: "Alice"],
            startedAt: MeetingStoreFixture.date(hour: 10),
            durationSeconds: 15,
            title: "Test Meeting",
            summary: nil,
            attendees: nil,
            existingURL: url
        )

        // ko.md is deleted (no korean rows), while summary.md is preserved per R3-2 disk summary ownership
        XCTAssertFalse(FileManager.default.fileExists(atPath: koFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryFile.path))
        XCTAssertEqual(store.load(url)?.summary, "Initial summary")
    }

    // MARK: - R1-9: Leftover staging directory cleanup

    func testLeftoverStagingDirectoryIsCleanedUpByNextCommit() throws {
        let (url, rows) = try createTestMeeting()

        // Plant a stale staging folder
        let staleStaging = url.appendingPathComponent(".staging-old-abandoned", isDirectory: true)
        try FileManager.default.createDirectory(at: staleStaging, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleStaging.path))

        // Run a commit
        _ = try store.updateRow(at: url, rowID: rows[0].id, english: "New text triggers cleanup")

        // Stale staging is cleaned up and no staging folders remain
        let files = try FileManager.default.contentsOfDirectory(atPath: url.path)
        let stagingFolders = files.filter { $0.hasPrefix(".staging-") }
        XCTAssertTrue(stagingFolders.isEmpty)
    }

    // MARK: - Standard Edit & Undo Tests

    func testUpdateRowWritesFilesAndRecordsDiskBefore() throws {
        let (url, rows) = try createTestMeeting()
        let targetRowID = rows[0].id

        let result = try store.updateRow(at: url, rowID: targetRowID, english: "First row updated")

        XCTAssertEqual(result.changedRowCount, 1)
        XCTAssertNil(result.warning)
        XCTAssertEqual(result.meeting.rows[0].english, "First row updated")
        XCTAssertEqual(result.log.editCount, 1)
        XCTAssertEqual(result.log.batches.first?.rowEdits.first?.before, "First row about Apple")
        XCTAssertEqual(result.log.batches.first?.rowEdits.first?.after, "First row updated")

        // Verify files on disk
        let sessionFile = url.appendingPathComponent("session.json")
        let editsFile = url.appendingPathComponent("edits.json")
        let enFile = url.appendingPathComponent("en.md")
        let combinedFile = url.appendingPathComponent("combined.md")

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: editsFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: enFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: combinedFile.path))

        let enContent = try String(contentsOf: enFile, encoding: .utf8)
        XCTAssertTrue(enContent.contains("First row updated"))
    }

    func testNoOpEditWritesNothing() throws {
        let (url, rows) = try createTestMeeting()
        let targetRowID = rows[0].id

        let sessionFile = url.appendingPathComponent("session.json")
        let initialData = try Data(contentsOf: sessionFile)

        let result = try store.updateRow(at: url, rowID: targetRowID, english: "First row about Apple")
        XCTAssertEqual(result.changedRowCount, 0)
        XCTAssertEqual(result.log.editCount, 0)

        let afterData = try Data(contentsOf: sessionFile)
        XCTAssertEqual(initialData, afterData)
    }

    func testEmptyTextThrowsEmptyText() throws {
        let (url, rows) = try createTestMeeting()
        XCTAssertThrowsError(try store.updateRow(at: url, rowID: rows[0].id, english: "   \n\t")) { error in
            XCTAssertEqual(error as? MeetingStoreError, MeetingStoreError.emptyText)
        }
    }

    func testUnknownRowThrowsRowNotFound() throws {
        let (url, _) = try createTestMeeting()
        let unknownID = UUID()
        let sessionFile = url.appendingPathComponent("session.json")
        let initialData = try Data(contentsOf: sessionFile)

        XCTAssertThrowsError(try store.updateRow(at: url, rowID: unknownID, english: "Some text")) { error in
            XCTAssertEqual(error as? MeetingStoreError, MeetingStoreError.rowNotFound(unknownID))
        }

        let afterData = try Data(contentsOf: sessionFile)
        XCTAssertEqual(initialData, afterData)
    }

    func testReplaceAllAcrossMultipleRowsAndSummary() throws {
        let (url, _) = try createTestMeeting(summaryText: "Initial summary mentioning Apple")

        let result = try store.replaceAll(
            at: url,
            find: "Apple",
            replacement: "Fruit",
            caseSensitive: true,
            wholeWord: true,
            includeSummary: true
        )

        XCTAssertEqual(result.changedRowCount, 2)
        XCTAssertEqual(result.meeting.rows[0].english, "First row about Fruit")
        XCTAssertEqual(result.meeting.rows[2].english, "Third row about Fruit products")
        XCTAssertEqual(result.meeting.summary, "Initial summary mentioning Fruit")

        XCTAssertEqual(result.log.batches.count, 1)
        let batch = result.log.batches[0]
        XCTAssertEqual(batch.kind, .replaceAll)
        XCTAssertEqual(batch.rowEdits.count, 2)
        XCTAssertEqual(batch.summaryBefore, "Initial summary mentioning Apple")
        XCTAssertEqual(batch.summaryAfter, "Initial summary mentioning Fruit")

        let summaryFile = url.appendingPathComponent("summary.md")
        let summaryContent = try String(contentsOf: summaryFile, encoding: .utf8)
        XCTAssertTrue(summaryContent.contains("Fruit"))

        // No matches throws noMatches
        XCTAssertThrowsError(
            try store.replaceAll(at: url, find: "NonExistent", replacement: "X", caseSensitive: false, wholeWord: false, includeSummary: true)
        ) { error in
            XCTAssertEqual(error as? MeetingStoreError, MeetingStoreError.noMatches)
        }
    }

    func testUndoLastEdit() throws {
        let (url, _) = try createTestMeeting(summaryText: "Initial summary with Apple")

        // 1. replaceAll
        let replaceResult = try store.replaceAll(
            at: url,
            find: "Apple",
            replacement: "Fruit",
            caseSensitive: true,
            wholeWord: true,
            includeSummary: true
        )
        XCTAssertEqual(replaceResult.meeting.rows[0].english, "First row about Fruit")
        XCTAssertEqual(replaceResult.meeting.summary, "Initial summary with Fruit")

        // 2. Undo
        let undoResult = try store.undoLastEdit(at: url)
        XCTAssertEqual(undoResult.meeting.rows[0].english, "First row about Apple")
        XCTAssertEqual(undoResult.meeting.rows[2].english, "Third row about Apple products")
        XCTAssertEqual(undoResult.meeting.summary, "Initial summary with Apple")
        XCTAssertEqual(undoResult.log.editCount, 0)
        XCTAssertTrue(undoResult.log.batches.isEmpty)

        // 3. Undo on empty throws nothingToUndo
        XCTAssertThrowsError(try store.undoLastEdit(at: url)) { error in
            XCTAssertEqual(error as? MeetingStoreError, MeetingStoreError.nothingToUndo)
        }
    }

    func testUndoConflictWhenRowChangedConcurrently() throws {
        let (url, rows) = try createTestMeeting()
        _ = try store.updateRow(at: url, rowID: rows[0].id, english: "Version 2")
        _ = try store.updateRow(at: url, rowID: rows[0].id, english: "Version 3")

        // Directly modify session.json to simulate an external change
        var meeting = store.load(url)!
        meeting.rows[0].english = "Externally modified"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meeting).write(to: url.appendingPathComponent("session.json"))

        XCTAssertThrowsError(try store.undoLastEdit(at: url)) { error in
            guard case MeetingStoreError.undoConflict(let id) = error else {
                XCTFail("Expected undoConflict, got \(error)")
                return
            }
            XCTAssertEqual(id, rows[0].id)
        }
    }

    func testUndoSummaryConflictWhenSummaryChanged() throws {
        let (url, _) = try createTestMeeting(summaryText: "Initial summary with Apple")

        // 1. replaceAll with includeSummary: true
        _ = try store.replaceAll(
            at: url,
            find: "Apple",
            replacement: "Fruit",
            caseSensitive: true,
            wholeWord: true,
            includeSummary: true
        )

        // 2. Update summary with a different text
        try store.updateSummary(at: url, summary: "Summary edited manually after replace")

        let sessionFile = url.appendingPathComponent("session.json")
        let summaryFile = url.appendingPathComponent("summary.md")
        let editsFile = url.appendingPathComponent("edits.json")

        let sessionBefore = try Data(contentsOf: sessionFile)
        let summaryBefore = try Data(contentsOf: summaryFile)
        let editsBefore = try Data(contentsOf: editsFile)

        // 3. undoLastEdit should throw undoSummaryConflict
        XCTAssertThrowsError(try store.undoLastEdit(at: url)) { error in
            XCTAssertEqual(error as? MeetingStoreError, MeetingStoreError.undoSummaryConflict)
        }

        // 4. Files remain byte-identical
        let sessionAfter = try Data(contentsOf: sessionFile)
        let summaryAfter = try Data(contentsOf: summaryFile)
        let editsAfter = try Data(contentsOf: editsFile)

        XCTAssertEqual(sessionBefore, sessionAfter)
        XCTAssertEqual(summaryBefore, summaryAfter)
        XCTAssertEqual(editsBefore, editsAfter)
    }

    func testStagingFailureLeavesOriginalsIntactAndCleansStagingFolder() throws {
        let (url, rows) = try createTestMeeting()
        let sessionFile = url.appendingPathComponent("session.json")
        let initialData = try Data(contentsOf: sessionFile)

        // Make folder read-only to force staging failure
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        XCTAssertThrowsError(try store.updateRow(at: url, rowID: rows[0].id, english: "Failing edit")) { error in
            guard case MeetingStoreError.writeFailed = error else {
                XCTFail("Expected writeFailed, got \(error)")
                return
            }
        }

        // Restore permissions to check contents
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let afterData = try Data(contentsOf: sessionFile)
        XCTAssertEqual(initialData, afterData)

        // Verify no .staging folder left behind
        let files = try FileManager.default.contentsOfDirectory(atPath: url.path)
        let stagingFolders = files.filter { $0.hasPrefix(".staging-") }
        XCTAssertTrue(stagingFolders.isEmpty)
    }

    func testUpdateSummarySetsEditsAtLastSummary() throws {
        let (url, rows) = try createTestMeeting()
        _ = try store.updateRow(at: url, rowID: rows[0].id, english: "Edit 1")
        _ = try store.updateRow(at: url, rowID: rows[1].id, english: "Edit 2")

        var log = store.editLog(at: url)
        XCTAssertEqual(log.editCount, 2)
        XCTAssertEqual(log.pendingEditsSinceSummary, 2)

        try store.updateSummary(at: url, summary: "Newly regenerated summary")

        log = store.editLog(at: url)
        XCTAssertEqual(log.editsAtLastSummary, 2)
        XCTAssertEqual(log.pendingEditsSinceSummary, 0)
    }

    // MARK: - U2: Revision Consistency Tests

    func testUndoAfterSummaryIncrementsRevisionAndSetsPendingToOne() throws {
        let (url, rows) = try createTestMeeting()
        _ = try store.updateRow(at: url, rowID: rows[0].id, english: "Row 0 Edit 1")
        _ = try store.updateRow(at: url, rowID: rows[1].id, english: "Row 1 Edit 1")

        var log = store.editLog(at: url)
        XCTAssertEqual(log.editCount, 2)
        XCTAssertEqual(log.revision, 2)

        try store.updateSummary(at: url, summary: "Regenerated summary")
        log = store.editLog(at: url)
        XCTAssertEqual(log.editsAtLastSummary, 2)
        XCTAssertEqual(log.pendingEditsSinceSummary, 0)

        let result = try store.undoLastEdit(at: url)
        let undoLog = result.log
        XCTAssertEqual(undoLog.pendingEditsSinceSummary, 1)
        XCTAssertEqual(undoLog.editCount, 1)
        XCTAssertEqual(undoLog.revision, 3)
    }

    func testUndoThenFourEditsReachesBannerThresholdOfFive() throws {
        let (url, rows) = try createTestMeeting()
        _ = try store.updateRow(at: url, rowID: rows[0].id, english: "Row 0 Edit 1")
        _ = try store.updateRow(at: url, rowID: rows[1].id, english: "Row 1 Edit 1")

        try store.updateSummary(at: url, summary: "Regenerated summary")
        _ = try store.undoLastEdit(at: url)

        _ = try store.updateRow(at: url, rowID: rows[1].id, english: "Row 1 Edit 2")
        _ = try store.updateRow(at: url, rowID: rows[2].id, english: "Row 2 Edit 1")
        _ = try store.updateRow(at: url, rowID: rows[0].id, english: "Row 0 Edit 2")
        _ = try store.updateRow(at: url, rowID: rows[1].id, english: "Row 1 Edit 3")

        let log = store.editLog(at: url)
        XCTAssertEqual(log.pendingEditsSinceSummary, 5)
    }

    func testReplaceAllThreeRowsPlusSummaryBatchUndoIncreasesRevisionByOne() throws {
        let (url, _) = try createTestMeeting(summaryText: "Initial summary with Apple")

        // 1. Summary-changing batch (only summary matched)
        _ = try store.replaceAll(at: url, find: "Initial", replacement: "Updated", caseSensitive: true, wholeWord: true, includeSummary: true)

        // 2. ReplaceAll batch affecting 3 rows (all 3 rows contain "about")
        let replaceResult = try store.replaceAll(at: url, find: "about", replacement: "regarding", caseSensitive: true, wholeWord: true, includeSummary: false)
        XCTAssertEqual(replaceResult.changedRowCount, 3)

        // 3. Mark summary regenerated
        try store.markSummaryRegenerated(at: url)
        let beforeUndoLog = store.editLog(at: url)
        XCTAssertEqual(beforeUndoLog.revision, 4)
        XCTAssertEqual(beforeUndoLog.editsAtLastSummary, 4)
        XCTAssertEqual(beforeUndoLog.pendingEditsSinceSummary, 0)

        // 4. Undo the 3-row batch
        let undoResult = try store.undoLastEdit(at: url)
        XCTAssertEqual(undoResult.log.editCount, 1)
        XCTAssertEqual(undoResult.log.revision, 5, "Revision must increase by exactly 1")
        XCTAssertEqual(undoResult.log.pendingEditsSinceSummary, 1)
    }

    func testTwoSequentialReplaceAllAndTwoUndosRestoreOriginal() throws {
        let (url, rows) = try createTestMeeting(summaryText: "Apple and Banana")
        let originalText0 = rows[0].english
        let originalText1 = rows[1].english
        let originalText2 = rows[2].english

        // 1. First replace
        _ = try store.replaceAll(at: url, find: "Apple", replacement: "Orange", caseSensitive: true, wholeWord: true, includeSummary: true)

        // 2. Second replace
        _ = try store.replaceAll(at: url, find: "Google", replacement: "Alphabet", caseSensitive: true, wholeWord: true, includeSummary: true)

        let meetingAfter2 = store.load(url)!
        XCTAssertEqual(meetingAfter2.rows[0].english, "First row about Orange")
        XCTAssertEqual(meetingAfter2.rows[1].english, "Second row about Alphabet")

        // 3. First undo (undoes Alphabet -> Google)
        let undo1 = try store.undoLastEdit(at: url)
        XCTAssertEqual(undo1.meeting.rows[1].english, originalText1)
        XCTAssertEqual(undo1.meeting.rows[0].english, "First row about Orange")

        // 4. Second undo (undoes Orange -> Apple)
        let undo2 = try store.undoLastEdit(at: url)
        XCTAssertEqual(undo2.meeting.rows[0].english, originalText0)
        XCTAssertEqual(undo2.meeting.rows[1].english, originalText1)
        XCTAssertEqual(undo2.meeting.rows[2].english, originalText2)
        XCTAssertEqual(undo2.meeting.summary, "Apple and Banana")
        XCTAssertEqual(undo2.log.editCount, 0)
    }

    // MARK: - Fix Round 3: Duplicate IDs, ExistingURL guards, UpdateRows disk merge, 0-byte edits.json

    func testSaveDuplicateRowIDThrowsDuplicateRowIDAndLeavesFilesIntact() throws {
        let (url, rows) = try createTestMeeting()
        let sessionFile = url.appendingPathComponent("session.json")
        let sharedID = UUID()
        let duplicateRow1 = TranscriptRow(
            id: sharedID,
            channel: .them,
            speakerSlot: 0,
            speakerName: "Alice",
            english: "Row A with shared ID",
            korean: nil,
            startSeconds: 0,
            endSeconds: 5
        )
        let duplicateRow2 = TranscriptRow(
            id: sharedID,
            channel: .them,
            speakerSlot: 1,
            speakerName: "Bob",
            english: "Row B with shared ID",
            korean: nil,
            startSeconds: 5,
            endSeconds: 10
        )
        var corruptMeeting = store.load(url)!
        corruptMeeting.rows = [duplicateRow1, duplicateRow2]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let corruptData = try encoder.encode(corruptMeeting)
        try corruptData.write(to: sessionFile)

        XCTAssertThrowsError(
            try store.save(
                rows: rows,
                myName: "Philip",
                speakerNames: [0: "Alice"],
                startedAt: MeetingStoreFixture.date(hour: 10),
                durationSeconds: 15,
                title: "Test Meeting",
                summary: "Summary",
                attendees: nil,
                existingURL: url
            )
        ) { error in
            guard case MeetingStoreError.duplicateRowID(let id) = error else {
                XCTFail("Expected duplicateRowID, got \(error)")
                return
            }
            XCTAssertEqual(id, sharedID)
        }

        // Files remain byte-identical to the corrupt data
        let afterData = try Data(contentsOf: sessionFile)
        XCTAssertEqual(corruptData, afterData)
    }

    func testSaveExistingURLThrowsMeetingNotFoundWhenSessionJsonMissingOrCorrupt() throws {
        let (url, rows) = try createTestMeeting()
        let sessionFile = url.appendingPathComponent("session.json")

        // 1. Invalid JSON in existing session.json
        let badData = "{ invalid json content ".data(using: .utf8)!
        try badData.write(to: sessionFile)

        XCTAssertThrowsError(
            try store.save(
                rows: rows,
                myName: "Philip",
                speakerNames: [0: "Alice"],
                startedAt: MeetingStoreFixture.date(hour: 10),
                durationSeconds: 15,
                title: "Test Meeting",
                summary: "Summary",
                attendees: nil,
                existingURL: url
            )
        ) { error in
            XCTAssertEqual(error as? MeetingStoreError, MeetingStoreError.meetingNotFound)
        }

        // Bytes unchanged
        let afterBadData = try Data(contentsOf: sessionFile)
        XCTAssertEqual(badData, afterBadData)

        // 2. Missing session.json
        try FileManager.default.removeItem(at: sessionFile)
        XCTAssertThrowsError(
            try store.save(
                rows: rows,
                myName: "Philip",
                speakerNames: [0: "Alice"],
                startedAt: MeetingStoreFixture.date(hour: 10),
                durationSeconds: 15,
                title: "Test Meeting",
                summary: "Summary",
                attendees: nil,
                existingURL: url
            )
        ) { error in
            XCTAssertEqual(error as? MeetingStoreError, MeetingStoreError.meetingNotFound)
        }
    }

    func testUpdateRowsPreservesNewerOnDiskText() throws {
        let (url, rows) = try createTestMeeting()
        let row0ID = rows[0].id

        // 1. User edits row 0
        _ = try store.updateRow(at: url, rowID: row0ID, english: "Row 0 edited on disk")

        // 2. Diarization finishes and calls updateRows with stale original text but new speaker info
        var diarizedRows = rows
        diarizedRows[0] = TranscriptRow(
            id: row0ID,
            channel: .them,
            speakerSlot: 1,
            speakerName: "Bob",
            english: "First row about Apple", // stale text
            korean: nil,
            startSeconds: 0,
            endSeconds: 5,
            clusterID: "cluster-101"
        )

        try store.updateRows(at: url, rows: diarizedRows, speakerNames: [1: "Bob"])

        let loaded = store.load(url)!
        // Edited text is preserved
        XCTAssertEqual(loaded.rows[0].english, "Row 0 edited on disk")
        // Diarization speaker metadata is updated
        XCTAssertEqual(loaded.rows[0].speakerName, "Bob")
        XCTAssertEqual(loaded.rows[0].speakerSlot, 1)
        XCTAssertEqual(loaded.rows[0].clusterID, "cluster-101")
        XCTAssertEqual(loaded.speakerNames[1], "Bob")
    }

    func testZeroByteEditsJsonTriggersCorruptRecovery() throws {
        let (url, rows) = try createTestMeeting()
        let editsFile = url.appendingPathComponent("edits.json")
        try Data().write(to: editsFile)

        let result = try store.updateRow(at: url, rowID: rows[0].id, english: "Edit after 0-byte edits.json")
        XCTAssertEqual(result.changedRowCount, 1)
        XCTAssertEqual(result.warning, "Edit history was unreadable and has been reset")

        // Verify corrupt backup was created
        let files = try FileManager.default.contentsOfDirectory(atPath: url.path)
        let corruptBackups = files.filter { $0.hasPrefix("edits.json.corrupt-") }
        XCTAssertEqual(corruptBackups.count, 1)

        // New valid edits.json exists with 1 batch
        let loadedLog = store.editLog(at: url)
        XCTAssertEqual(loadedLog.editCount, 1)
    }

    // MARK: - Fix Round 4: R3-3, R3-5, R3-2, R3-4, R3-6

    func testNewSaveWithDuplicateRowIDsThrowsDuplicateRowIDAndCreatesNoFolder() throws {
        let sharedID = UUID()
        let row1 = TranscriptRow(
            id: sharedID,
            channel: .them,
            speakerSlot: 0,
            speakerName: "Alice",
            english: "First duplicate row",
            korean: nil,
            startSeconds: 0,
            endSeconds: 5
        )
        let row2 = TranscriptRow(
            id: sharedID,
            channel: .them,
            speakerSlot: 1,
            speakerName: "Bob",
            english: "Second duplicate row",
            korean: nil,
            startSeconds: 5,
            endSeconds: 10
        )

        let initialFolders = (try? FileManager.default.contentsOfDirectory(atPath: store.rootURL.path)) ?? []

        XCTAssertThrowsError(
            try store.save(
                rows: [row1, row2],
                myName: "Philip",
                speakerNames: [0: "Alice", 1: "Bob"],
                startedAt: MeetingStoreFixture.date(hour: 10),
                durationSeconds: 10,
                title: "Duplicate New Meeting",
                summary: nil,
                attendees: nil,
                existingURL: nil
            )
        ) { error in
            guard case MeetingStoreError.duplicateRowID(let id) = error else {
                XCTFail("Expected duplicateRowID, got \(error)")
                return
            }
            XCTAssertEqual(id, sharedID)
        }

        let currentFolders = (try? FileManager.default.contentsOfDirectory(atPath: store.rootURL.path)) ?? []
        XCTAssertEqual(initialFolders, currentFolders)
    }

    func testReplaceAllWithDuplicateIDsInSessionJsonThrowsDuplicateRowIDAndLeavesFilesIntact() throws {
        let (url, _) = try createTestMeeting()
        let sessionFile = url.appendingPathComponent("session.json")
        let sharedID = UUID()
        let dupRow1 = TranscriptRow(
            id: sharedID,
            channel: .them,
            speakerSlot: 0,
            speakerName: "Alice",
            english: "Row A with Apple",
            korean: nil,
            startSeconds: 0,
            endSeconds: 5
        )
        let dupRow2 = TranscriptRow(
            id: sharedID,
            channel: .them,
            speakerSlot: 1,
            speakerName: "Bob",
            english: "Row B with Apple",
            korean: nil,
            startSeconds: 5,
            endSeconds: 10
        )
        var corruptMeeting = store.load(url)!
        corruptMeeting.rows = [dupRow1, dupRow2]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let corruptData = try encoder.encode(corruptMeeting)
        try corruptData.write(to: sessionFile)

        XCTAssertThrowsError(
            try store.replaceAll(
                at: url,
                find: "Apple",
                replacement: "Orange",
                caseSensitive: true,
                wholeWord: true,
                includeSummary: false
            )
        ) { error in
            guard case MeetingStoreError.duplicateRowID(let id) = error else {
                XCTFail("Expected duplicateRowID, got \(error)")
                return
            }
            XCTAssertEqual(id, sharedID)
        }

        // session.json is byte-identical
        let afterData = try Data(contentsOf: sessionFile)
        XCTAssertEqual(corruptData, afterData)
    }

    func testUpdateRowsWithEmptyRowsThrowsEmptyRowsAndLeavesFilesIntact() throws {
        let (url, _) = try createTestMeeting()
        _ = try store.updateRow(at: url, rowID: store.load(url)!.rows[0].id, english: "Initial edit")

        let sessionFile = url.appendingPathComponent("session.json")
        let enFile = url.appendingPathComponent("en.md")
        let editsFile = url.appendingPathComponent("edits.json")

        let sessionBefore = try Data(contentsOf: sessionFile)
        let enBefore = try Data(contentsOf: enFile)
        let editsBefore = try Data(contentsOf: editsFile)

        XCTAssertThrowsError(try store.updateRows(at: url, rows: [], speakerNames: [:])) { error in
            XCTAssertEqual(error as? MeetingStoreError, MeetingStoreError.emptyRows)
        }

        let sessionAfter = try Data(contentsOf: sessionFile)
        let enAfter = try Data(contentsOf: enFile)
        let editsAfter = try Data(contentsOf: editsFile)

        XCTAssertEqual(sessionBefore, sessionAfter)
        XCTAssertEqual(enBefore, enAfter)
        XCTAssertEqual(editsBefore, editsAfter)
    }

    func testSaveExistingURLPreservesDiskSummaryTitleAndAttendees() throws {
        let (url, rows) = try createTestMeeting(summaryText: "Old Summary")
        let originalTitle = store.load(url)!.title

        // 1. replaceAll with includeSummary: true changes summary Old Summary -> New Summary
        _ = try store.replaceAll(
            at: url,
            find: "Old",
            replacement: "New",
            caseSensitive: true,
            wholeWord: true,
            includeSummary: true
        )
        XCTAssertEqual(store.load(url)!.summary, "New Summary")

        // 2. Caller calls save(existingURL:) with stale summary "Old Summary", title: nil, attendees: nil
        try store.save(
            rows: rows,
            myName: "Philip",
            speakerNames: [0: "Alice"],
            startedAt: MeetingStoreFixture.date(hour: 10),
            durationSeconds: 15,
            title: nil,
            summary: "Old Summary",
            attendees: nil,
            existingURL: url
        )

        let loaded = store.load(url)!
        // Disk summary remains New Summary
        XCTAssertEqual(loaded.summary, "New Summary")
        // Title remains unchanged
        XCTAssertEqual(loaded.title, originalTitle)

        // 3. undoLastEdit succeeds without .undoSummaryConflict
        let undoResult = try store.undoLastEdit(at: url)
        XCTAssertEqual(undoResult.meeting.summary, "Old Summary")
        XCTAssertEqual(undoResult.log.editCount, 0)
    }

    func testCorruptEditsJsonUpdateSummaryCreatesBackupAndReturnsWarning() throws {
        let (url, _) = try createTestMeeting()
        let editsFile = url.appendingPathComponent("edits.json")
        try "{ bad json for summary update }".write(to: editsFile, atomically: true, encoding: .utf8)

        let warning = try store.updateSummary(at: url, summary: "Newly updated summary")
        XCTAssertEqual(warning, "Edit history was unreadable and has been reset")

        // Verify backup was created
        let files = try FileManager.default.contentsOfDirectory(atPath: url.path)
        let corruptBackups = files.filter { $0.hasPrefix("edits.json.corrupt-") }
        XCTAssertEqual(corruptBackups.count, 1)

        let log = store.editLog(at: url)
        XCTAssertEqual(log.editsAtLastSummary, 0)
        XCTAssertEqual(log.editCount, 0)
    }

    func testCorruptEditsJsonMarkSummaryRegeneratedCreatesBackupAndReturnsWarning() throws {
        let (url, _) = try createTestMeeting()
        let editsFile = url.appendingPathComponent("edits.json")
        try "{ bad json for summary mark }".write(to: editsFile, atomically: true, encoding: .utf8)

        let warning = try store.markSummaryRegenerated(at: url)
        XCTAssertEqual(warning, "Edit history was unreadable and has been reset")

        // Verify backup was created
        let files = try FileManager.default.contentsOfDirectory(atPath: url.path)
        let corruptBackups = files.filter { $0.hasPrefix("edits.json.corrupt-") }
        XCTAssertEqual(corruptBackups.count, 1)

        let log = store.editLog(at: url)
        XCTAssertEqual(log.editsAtLastSummary, 0)
        XCTAssertEqual(log.editCount, 0)
    }

    func testReplaceAllWithIdenticalReplacementThrowsNoChanges() throws {
        let (url, _) = try createTestMeeting(summaryText: "Initial summary with Apple")
        let editsFile = url.appendingPathComponent("edits.json")
        let sessionFile = url.appendingPathComponent("session.json")

        let sessionBefore = try Data(contentsOf: sessionFile)

        // Case 1: exact string replace foo -> foo
        XCTAssertThrowsError(
            try store.replaceAll(
                at: url,
                find: "Apple",
                replacement: "Apple",
                caseSensitive: true,
                wholeWord: true,
                includeSummary: true
            )
        ) { error in
            XCTAssertEqual(error as? MeetingStoreError, MeetingStoreError.noChanges)
        }

        // Case 2: case-insensitive replace Apple -> Apple on text that already reads Apple
        XCTAssertThrowsError(
            try store.replaceAll(
                at: url,
                find: "apple",
                replacement: "Apple",
                caseSensitive: false,
                wholeWord: true,
                includeSummary: true
            )
        ) { error in
            XCTAssertEqual(error as? MeetingStoreError, MeetingStoreError.noChanges)
        }

        // Verify no files written, editCount unchanged
        let sessionAfter = try Data(contentsOf: sessionFile)
        XCTAssertEqual(sessionBefore, sessionAfter)
        XCTAssertFalse(FileManager.default.fileExists(atPath: editsFile.path))
        XCTAssertEqual(store.editLog(at: url).editCount, 0)
    }
}
