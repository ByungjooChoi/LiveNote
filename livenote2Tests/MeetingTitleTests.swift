import XCTest

@testable import LiveNote

/// Phase 0.4: 요약에서 회의 제목 도출 + 폴더 rename.
@MainActor
final class MeetingTitleTests: XCTestCase {

    // MARK: - titleFromSummary

    func testTitleFromFirstH1() {
        XCTAssertEqual(
            MeetingStore.titleFromSummary("# Weekly sync\n\n- item one\n"),
            "Weekly sync"
        )
    }

    func testTitleFromH1LaterInDocument() {
        let summary = """
        Some preamble text.

        # Actual title
        # Second title
        """
        XCTAssertEqual(MeetingStore.titleFromSummary(summary), "Actual title")
    }

    func testTitleIgnoresH2() {
        XCTAssertNil(MeetingStore.titleFromSummary("## Not a title\n\ncontent"))
    }

    func testTitleNilWhenNoHeading() {
        XCTAssertNil(MeetingStore.titleFromSummary("plain summary without heading"))
        XCTAssertNil(MeetingStore.titleFromSummary(""))
    }

    func testTitleNilWhenHeadingIsEmpty() {
        XCTAssertNil(MeetingStore.titleFromSummary("#  \n\ncontent"))
    }

    func testTitleTruncatedTo60Characters() throws {
        let long = String(repeating: "a", count: 80)
        let title = try XCTUnwrap(MeetingStore.titleFromSummary("# \(long)"))
        XCTAssertEqual(title.count, 60)
    }

    // MARK: - rename

    func testRenameMovesFolderAndUpdatesSessionJSON() throws {
        let store = try MeetingStoreFixture.makeStore()
        defer { MeetingStoreFixture.cleanUp(store) }

        let original = try XCTUnwrap(saveUntitledMeeting(in: store, hour: 10))
        XCTAssertNil(store.load(original)?.title)

        let renamed = try XCTUnwrap(store.rename(at: original, title: "Weekly sync"))

        XCTAssertTrue(renamed.lastPathComponent.hasSuffix("Weekly sync"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(store.load(renamed)?.title, "Weekly sync")
        XCTAssertEqual(store.meetings.first?.title, "Weekly sync")
        // 목록의 URL은 디렉터리 열거에서 오므로 /private 접두사가 붙는다. 심볼릭 링크를 풀어 비교.
        XCTAssertEqual(
            store.meetings.first?.url.resolvingSymlinksInPath(),
            renamed.resolvingSymlinksInPath()
        )
        XCTAssertEqual(store.load(renamed)?.rows.count, 1)
    }

    func testRenameAvoidsCollisionWithSuffix() throws {
        let store = try MeetingStoreFixture.makeStore()
        defer { MeetingStoreFixture.cleanUp(store) }

        let original = try XCTUnwrap(saveUntitledMeeting(in: store, hour: 10))
        let taken = store.rootURL.appendingPathComponent(
            MeetingStore.folderBaseName(for: MeetingStoreFixture.date(hour: 10), title: "Weekly sync"),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)

        let renamed = try XCTUnwrap(store.rename(at: original, title: "Weekly sync"))

        XCTAssertTrue(renamed.lastPathComponent.hasSuffix("Weekly sync (2)"), renamed.lastPathComponent)
        XCTAssertEqual(store.load(renamed)?.title, "Weekly sync")
    }

    /// 이미 같은 제목이면 폴더를 옮기지 않는다 ((2) 접미사 방지).
    func testRenameToSameTitleKeepsFolder() throws {
        let store = try MeetingStoreFixture.makeStore()
        defer { MeetingStoreFixture.cleanUp(store) }

        let url = try XCTUnwrap(store.save(
            rows: [MeetingStoreFixture.row(text: "hello")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: MeetingStoreFixture.date(hour: 10),
            durationSeconds: 60,
            title: "Weekly sync",
            summary: nil,
            attendees: nil,
            existingURL: nil
        ))

        let renamed = try XCTUnwrap(store.rename(at: url, title: "Weekly sync"))
        XCTAssertEqual(renamed, url)
        XCTAssertEqual(store.meetings.count, 1)
    }

    func testRenameReturnsNilForUnknownFolder() throws {
        let store = try MeetingStoreFixture.makeStore()
        defer { MeetingStoreFixture.cleanUp(store) }

        let missing = store.rootURL.appendingPathComponent("nope", isDirectory: true)
        XCTAssertNil(store.rename(at: missing, title: "Whatever"))
    }

    private func saveUntitledMeeting(in store: MeetingStore, hour: Int) -> URL? {
        store.save(
            rows: [MeetingStoreFixture.row(text: "hello there")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: MeetingStoreFixture.date(hour: hour),
            durationSeconds: 60,
            title: nil,
            summary: nil,
            attendees: nil,
            existingURL: nil
        )
    }
}
