import XCTest
@testable import LiveNote

@MainActor
final class BriefStoreTests: XCTestCase {

    private var rootURL: URL!
    private var logRoot: URL!
    private var previousLogOverride: URL?
    private var store: BriefStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TestLogSandbox.activate()
        previousLogOverride = AppLog.directoryOverride
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveNoteBriefTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        logRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveNoteBriefLogs-\(UUID().uuidString)", isDirectory: true)
        AppLog.directoryOverride = logRoot
        store = BriefStore(rootURL: rootURL)
    }

    override func tearDown() {
        AppLog.flush()
        AppLog.directoryOverride = previousLogOverride
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        if let logRoot { try? FileManager.default.removeItem(at: logRoot) }
        store = nil
        rootURL = nil
        logRoot = nil
        super.tearDown()
    }

    func testRoundTripHeaderParse() throws {
        let date = Date(timeIntervalSince1970: 1788220800) // 2026-09-01 00:00:00 UTC
        let markdown = """
        # Last time
        - Decisions were made on 2026-08-25.

        # Open items
        - Complete task 1 (Craig) [Project sync]

        # Suggested agenda
        - Discuss roadmap for Q4
        - Review action items
        - Q&A
        """
        let brief = Brief(
            eventKey: "meeting123@1788220800",
            markdown: markdown,
            generatedAt: date,
            basedOn: ["Project sync", "Design review"],
            suggestedAgendaFirstLine: "Discuss roadmap for Q4"
        )

        try store.save(brief)

        let loaded = try XCTUnwrap(try store.load(eventKey: "meeting123@1788220800"))
        XCTAssertEqual(loaded.eventKey, brief.eventKey)
        XCTAssertEqual(loaded.markdown, brief.markdown)
        XCTAssertEqual(Int(loaded.generatedAt.timeIntervalSince1970), Int(brief.generatedAt.timeIntervalSince1970))
        XCTAssertEqual(loaded.basedOn, ["Project sync", "Design review"])
        XCTAssertEqual(loaded.suggestedAgendaFirstLine, "Discuss roadmap for Q4")
    }

    func testLoadNonExistentReturnsNil() throws {
        XCTAssertNil(try store.load(eventKey: "doesNotExist@123"))
    }

    func testLoadCorruptMissingHeaderThrowsCorruptError() throws {
        let briefsDir = rootURL.appendingPathComponent("briefs", isDirectory: true)
        try FileManager.default.createDirectory(at: briefsDir, withIntermediateDirectories: true)
        let corruptFile = briefsDir.appendingPathComponent("\(BriefStore.safeFileName("corrupt@123")).md")
        let corruptContent = "# Last time\n- No header comments here\n# Open items\n# Suggested agenda\n- A\n- B\n- C"
        try corruptContent.write(to: corruptFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.load(eventKey: "corrupt@123")) { error in
            guard let storeError = error as? BriefStoreError else {
                XCTFail("Expected BriefStoreError, got \(error)")
                return
            }
            if case .corrupt(let path) = storeError {
                XCTAssertEqual(path, corruptFile.path)
            } else {
                XCTFail("Expected .corrupt, got \(storeError)")
            }
        }
    }

    func testSafeFileName() {
        let name1 = BriefStore.safeFileName("event:123/456?title*foo|bar<baz>qux\"")
        XCTAssertTrue(name1.hasPrefix("event_123_456_title_foo_bar_baz_qux__"))
        let name2 = BriefStore.safeFileName("simpleKey@12345")
        XCTAssertTrue(name2.hasPrefix("simpleKey@12345_"))
        let name3 = BriefStore.safeFileName("")
        XCTAssertTrue(name3.hasPrefix("unknown_"))
    }

    func testSafeFileNameDistinctForPunctuation() {
        let f1 = BriefStore.safeFileName("team:sync?date=2026-09-01")
        let f2 = BriefStore.safeFileName("team/sync*date=2026-09-01")
        XCTAssertNotEqual(f1, f2, "Keys differing only in punctuation must generate distinct file names")
    }

    func testFirstAgendaLine() {
        let markdown = """
        # Last time
        - Point 1
        - Point 2

        # Suggested agenda
        - First important agenda item
        - Second agenda item
        """
        XCTAssertEqual(BriefStore.firstAgendaLine(in: markdown), "First important agenda item")

        let asteriskMarkdown = """
        ## Suggested agenda
        * Bullet with asterisk
        * Another bullet
        """
        XCTAssertEqual(BriefStore.firstAgendaLine(in: asteriskMarkdown), "Bullet with asterisk")

        let noAgenda = """
        # Last time
        - Only last time
        """
        XCTAssertNil(BriefStore.firstAgendaLine(in: noAgenda))
    }

    func testCopyBrief() throws {
        let date = Date(timeIntervalSince1970: 1788220800)
        let brief = Brief(
            eventKey: "copyTest@123",
            markdown: "# Last time\n- Summary",
            generatedAt: date,
            basedOn: ["Meeting 1"],
            suggestedAgendaFirstLine: nil
        )
        try store.save(brief)

        let meetingFolder = rootURL.appendingPathComponent("2026-09-01 1000 Meeting", isDirectory: true)
        try store.copyBrief(eventKey: "copyTest@123", toMeetingFolder: meetingFolder)

        let targetFile = meetingFolder.appendingPathComponent("brief.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetFile.path))

        let content = try String(contentsOf: targetFile, encoding: .utf8)
        XCTAssertTrue(content.contains("<!-- generated:"))
        XCTAssertTrue(content.contains("<!-- based-on: Meeting 1 -->"))
        XCTAssertTrue(content.contains("# Last time\n- Summary"))
    }

    func testInvalidate() throws {
        let brief = Brief(
            eventKey: "invKey",
            markdown: "Markdown",
            generatedAt: Date(),
            basedOn: [],
            suggestedAgendaFirstLine: nil
        )
        try store.save(brief)
        XCTAssertNotNil(try store.load(eventKey: "invKey"))

        try store.invalidate(eventKey: "invKey")
        XCTAssertNil(try store.load(eventKey: "invKey"))
    }
}
