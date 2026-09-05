import XCTest

@testable import LiveNote

/// Phase 0.1: 참석자 데이터 모델과 mailto 파싱.
@MainActor
final class AttendeeTests: XCTestCase {

    // MARK: - mailto 파싱

    func testEmailFromMailtoURL() {
        let url = URL(string: "mailto:john@example.com")
        XCTAssertEqual(CalendarMonitor.email(fromParticipantURL: url), "john@example.com")
    }

    func testEmailFromMailtoURLWithQuery() {
        let url = URL(string: "mailto:jane.doe@example.com?subject=Sync")
        XCTAssertEqual(CalendarMonitor.email(fromParticipantURL: url), "jane.doe@example.com")
    }

    func testEmailFromNonMailtoURLIsNil() {
        XCTAssertNil(CalendarMonitor.email(fromParticipantURL: URL(string: "https://example.com/u/1")))
    }

    func testEmailFromNilURLIsNil() {
        XCTAssertNil(CalendarMonitor.email(fromParticipantURL: nil))
    }

    func testEmailFromEmptyMailtoIsNil() {
        XCTAssertNil(CalendarMonitor.email(fromParticipantURL: URL(string: "mailto:")))
    }

    // MARK: - 참석자 정규화 (한 일정에서 뽑은 원본 → 저장용 Attendee)

    func testNormalizedAttendeesKeepsSameNameWithDifferentEmails() {
        let result = CalendarMonitor.normalizedAttendees(from: [
            (name: "Jane Doe", email: "jane@a.com"),
            (name: "Jane Doe", email: "jane@b.com"),
        ])
        XCTAssertEqual(result, [
            Attendee(name: "Jane Doe", email: "jane@a.com"),
            Attendee(name: "Jane Doe", email: "jane@b.com"),
        ])
    }

    func testNormalizedAttendeesDedupesByEmailIgnoringCase() {
        let result = CalendarMonitor.normalizedAttendees(from: [
            (name: "Jane Doe", email: "Jane@A.com"),
            (name: "J. Doe", email: "jane@a.com"),
        ])
        XCTAssertEqual(result, [Attendee(name: "Jane Doe", email: "Jane@A.com")])
    }

    func testNormalizedAttendeesDedupesByNameWhenEmailMissing() {
        let result = CalendarMonitor.normalizedAttendees(from: [
            (name: "Bob", email: nil),
            (name: "bob", email: nil),
        ])
        XCTAssertEqual(result, [Attendee(name: "Bob", email: nil)])
    }

    func testNormalizedAttendeesKeepsEmailOnlyParticipant() {
        let result = CalendarMonitor.normalizedAttendees(from: [
            (name: nil, email: "jane.doe@example.com"),
            (name: "  ", email: "bob_smith@example.com"),
        ])
        XCTAssertEqual(result, [
            Attendee(name: "Jane Doe", email: "jane.doe@example.com"),
            Attendee(name: "Bob Smith", email: "bob_smith@example.com"),
        ])
    }

    func testNormalizedAttendeesDropsFullyEmptyParticipant() {
        XCTAssertTrue(CalendarMonitor.normalizedAttendees(from: [(name: nil, email: nil)]).isEmpty)
        XCTAssertTrue(CalendarMonitor.normalizedAttendees(from: [(name: " ", email: " ")]).isEmpty)
    }

    func testNormalizedAttendeesRespectsLimit() {
        let raw = (1...12).map { (name: "Person \($0)", email: Optional("p\($0)@x.com")) }
        XCTAssertEqual(CalendarMonitor.normalizedAttendees(from: raw).count, 10)
        XCTAssertEqual(CalendarMonitor.normalizedAttendees(from: raw, limit: 3).count, 3)
    }

    // MARK: - Attendee Codable

    func testAttendeeJSONRoundTrip() throws {
        let original = [
            Attendee(name: "Jane Doe", email: "jane@example.com"),
            Attendee(name: "Bob", email: nil),
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([Attendee].self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded[1].email)
    }

    // MARK: - SavedMeeting 하위 호환

    /// v1.3.1 이전 session.json에는 attendees 키가 없다. 그래도 디코드되어야 한다.
    func testSavedMeetingDecodesWithoutAttendeesKey() throws {
        let json = """
        {
          "startedAt": "2026-09-01T10:00:00Z",
          "durationSeconds": 120,
          "title": "Old meeting",
          "myName": "Philip",
          "speakerNames": { "0": "Craig" },
          "rows": []
        }
        """
        let meeting = try Self.decoder.decode(SavedMeeting.self, from: Data(json.utf8))
        XCTAssertNil(meeting.attendees)
        XCTAssertEqual(meeting.title, "Old meeting")
        XCTAssertEqual(meeting.myName, "Philip")
        XCTAssertEqual(meeting.speakerNames[0], "Craig")
    }

    func testSavedMeetingDecodesWithAttendeesKey() throws {
        let json = """
        {
          "startedAt": "2026-09-01T10:00:00Z",
          "durationSeconds": 120,
          "myName": "Philip",
          "speakerNames": {},
          "rows": [],
          "attendees": [
            { "name": "Jane Doe", "email": "jane@example.com" },
            { "name": "Bob" }
          ]
        }
        """
        let meeting = try Self.decoder.decode(SavedMeeting.self, from: Data(json.utf8))
        XCTAssertEqual(meeting.attendees?.count, 2)
        XCTAssertEqual(meeting.attendees?.first, Attendee(name: "Jane Doe", email: "jane@example.com"))
        XCTAssertNil(meeting.attendees?.last?.email)
    }

    /// 저장 → 불러오기에서 참석자가 보존되고, 목록(MeetingSummary)에도 실린다.
    func testSaveAndLoadPreservesAttendees() throws {
        let store = try MeetingStoreFixture.makeStore()
        defer { MeetingStoreFixture.cleanUp(store) }

        let attendees = [Attendee(name: "Jane Doe", email: "jane@example.com")]
        let url = try store.save(
            rows: [MeetingStoreFixture.row(text: "hello")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: MeetingStoreFixture.date(hour: 10),
            durationSeconds: 60,
            title: "Sync",
            summary: nil,
            attendees: attendees,
            existingURL: nil
        )

        XCTAssertEqual(store.load(url)?.attendees, attendees)
        XCTAssertEqual(store.meetings.first?.attendees, attendees)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
