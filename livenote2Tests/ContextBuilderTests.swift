import XCTest

@testable import LiveNote

/// Phase 0.2: 아카이브 컨텍스트 빌더.
@MainActor
final class ContextBuilderTests: XCTestCase {

    private var store: MeetingStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try MeetingStoreFixture.makeStore()
    }

    override func tearDown() {
        MeetingStoreFixture.cleanUp(store)
        store = nil
        super.tearDown()
    }

    func testSummaryPreferredOverTranscript() throws {
        try saveMeeting(title: "Alpha", hour: 10, transcript: "TRANSCRIPT-BODY", summary: "SUMMARY-BODY")

        let result = ContextBuilder.build(
            meetings: store.meetings,
            store: store,
            budget: 60_000,
            perMeetingTranscriptCap: 1_500
        )

        XCTAssertTrue(result.text.contains("SUMMARY-BODY"))
        XCTAssertFalse(result.text.contains("TRANSCRIPT-BODY"))
        XCTAssertTrue(result.text.contains("## Alpha ("))
        XCTAssertEqual(result.used.count, 1)
        XCTAssertEqual(result.truncated, 0)
    }

    func testTranscriptFallbackIsCappedPerMeeting() throws {
        let long = String(repeating: "x", count: 500)
        try saveMeeting(title: "Beta", hour: 10, transcript: long, summary: nil)

        let result = ContextBuilder.build(
            meetings: store.meetings,
            store: store,
            budget: 60_000,
            perMeetingTranscriptCap: 40
        )

        let body = try XCTUnwrap(result.text.split(separator: "\n").last.map(String.init))
        XCTAssertEqual(body.count, 40)
        XCTAssertFalse(result.text.contains(long))
    }

    func testAttendeesLineAppearsOnlyWhenPresent() throws {
        try saveMeeting(
            title: "With people",
            hour: 11,
            transcript: "hi",
            summary: "S1",
            attendees: [Attendee(name: "Jane Doe", email: "jane@x.com"), Attendee(name: "Bob", email: nil)]
        )
        try saveMeeting(title: "No people", hour: 10, transcript: "hi", summary: "S2")

        let result = ContextBuilder.build(
            meetings: store.meetings,
            store: store,
            budget: 60_000,
            perMeetingTranscriptCap: 1_500
        )

        XCTAssertTrue(result.text.contains("Attendees: Jane Doe, Bob"))
        XCTAssertEqual(result.text.components(separatedBy: "Attendees: ").count - 1, 1)
        XCTAssertEqual(result.used.count, 2)
    }

    func testBudgetExhaustionCountsTruncatedMeetings() throws {
        try saveMeeting(title: "First", hour: 11, transcript: "t1", summary: String(repeating: "a", count: 1_800))
        try saveMeeting(title: "Second", hour: 10, transcript: "t2", summary: "S2")
        try saveMeeting(title: "Third", hour: 9, transcript: "t3", summary: "S3")

        let result = ContextBuilder.build(
            meetings: store.meetings,
            store: store,
            budget: 2_100,
            perMeetingTranscriptCap: 1_500
        )

        XCTAssertEqual(result.used.map(\.title), ["First"])
        XCTAssertEqual(result.truncated, 2)
        XCTAssertFalse(result.text.contains("Second"))
    }

    func testEmptyArchiveProducesEmptyText() {
        let result = ContextBuilder.build(
            meetings: [],
            store: store,
            budget: 60_000,
            perMeetingTranscriptCap: 1_500
        )
        XCTAssertTrue(result.text.isEmpty)
        XCTAssertTrue(result.used.isEmpty)
        XCTAssertEqual(result.truncated, 0)
    }

    // MARK: - helpers

    private func saveMeeting(
        title: String,
        hour: Int,
        transcript: String,
        summary: String?,
        attendees: [Attendee]? = nil
    ) throws {
        let saved = store.save(
            rows: [MeetingStoreFixture.row(text: transcript)],
            myName: "Philip",
            speakerNames: [0: "Craig"],
            startedAt: MeetingStoreFixture.date(hour: hour),
            durationSeconds: 60,
            title: title,
            summary: summary,
            attendees: attendees,
            existingURL: nil
        )
        XCTAssertNotNil(saved)
    }
}
