import XCTest

@testable import LiveNote

final class RecipeOutputStoreTests: XCTestCase {

    private var root: URL!

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = 12
        return Calendar.current.date(from: comps)!
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveNoteRecipeOutputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    func testSafeTitleSanitizesForbiddenCharacters() {
        XCTAssertEqual(RecipeOutputStore.safeTitle("Weekly / Update : Brief?"), "Weekly Update Brief")
        XCTAssertEqual(RecipeOutputStore.safeTitle("   "), "Recipe")
        XCTAssertEqual(RecipeOutputStore.safeTitle("Follow-up email"), "Follow-up email")
    }

    func testFileNameFormat() {
        let fixedDate = date(2026, 9, 3)
        let name = RecipeOutputStore.fileName(title: "Weekly Update", date: fixedDate)
        XCTAssertEqual(name, "2026-09-03 Weekly Update.md")
    }

    func testWriteCreatesFileAndHandlesDuplicates() throws {
        let store = RecipeOutputStore(rootURL: root)
        let fixedDate = date(2026, 9, 3)

        let url1 = try store.write(text: "# Run 1", title: "Weekly Update", date: fixedDate)
        XCTAssertEqual(url1.lastPathComponent, "2026-09-03 Weekly Update.md")
        XCTAssertEqual(try String(contentsOf: url1, encoding: .utf8), "# Run 1")

        let url2 = try store.write(text: "# Run 2", title: "Weekly Update", date: fixedDate)
        XCTAssertEqual(url2.lastPathComponent, "2026-09-03 Weekly Update (2).md")
        XCTAssertEqual(try String(contentsOf: url2, encoding: .utf8), "# Run 2")

        let url3 = try store.write(text: "# Run 3", title: "Weekly Update", date: fixedDate)
        XCTAssertEqual(url3.lastPathComponent, "2026-09-03 Weekly Update (3).md")
        XCTAssertEqual(try String(contentsOf: url3, encoding: .utf8), "# Run 3")
    }
}
