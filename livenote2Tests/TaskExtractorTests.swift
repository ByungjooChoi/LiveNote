import XCTest

@testable import LiveNote

@MainActor
final class TaskExtractorTests: XCTestCase {

    func testParseFencesAndTolerances() {
        let jsonWithFences = """
        ```json
        [
          {"title": "Prepare slides", "owner": "me", "due": "2026-09-10", "quote": "I'll prepare the slides"},
          {"title": "Review PR", "owner": "Craig", "due": "2026-09-12"}
        ]
        ```
        """
        let parseResult = TaskExtractor.parse(jsonWithFences)
        guard case .valid(let parsed) = parseResult else {
            XCTFail("Expected .valid, got \(parseResult)")
            return
        }
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].title, "Prepare slides")
        XCTAssertEqual(parsed[0].owner, "me")
        XCTAssertEqual(parsed[0].due, "2026-09-10")
        XCTAssertEqual(parsed[0].quote, "I'll prepare the slides")
        XCTAssertEqual(parsed[1].title, "Review PR")
        XCTAssertEqual(parsed[1].owner, "Craig")
        XCTAssertEqual(parsed[1].due, "2026-09-12")
        XCTAssertNil(parsed[1].quote)
    }

    func testParseAbsentAndMalformed() {
        XCTAssertEqual(TaskExtractor.parse(nil), .absent)
        XCTAssertEqual(TaskExtractor.parse(""), .malformed)
        XCTAssertEqual(TaskExtractor.parse("   \n\t  "), .malformed)
        XCTAssertEqual(TaskExtractor.parse("not valid json at all"), .malformed)
        XCTAssertEqual(TaskExtractor.parse("{\"title\": \"not an array\"}"), .malformed)
    }

    func testParseLiteralEmptyArrayReturnsValidEmpty() {
        XCTAssertEqual(TaskExtractor.parse("[]"), .valid([]))
        XCTAssertEqual(TaskExtractor.parse("  [  ]  "), .valid([]))
        XCTAssertEqual(TaskExtractor.parse("```json\n[]\n```"), .valid([]))
    }

    func testParseNonEmptyArrayWithNoUsableItemsReturnsNoUsableItems() {
        let noTitles = """
        [
          {"owner": "Craig"},
          {"due": "2026-09-10"}
        ]
        """
        XCTAssertEqual(TaskExtractor.parse(noTitles), .noUsableItems)

        let emptyTitlesOnly = """
        [
          {"title": ""},
          {"title": "   ", "owner": "Alice"}
        ]
        """
        XCTAssertEqual(TaskExtractor.parse(emptyTitlesOnly), .noUsableItems)
    }

    func testLossyDecodingSkipsBadElements() {
        // First element has no title (bad), second and third are good
        let json = """
        [
          {"owner": "Alice", "due": "2026-09-10"},
          {"title": "Good Task 1", "owner": "Bob"},
          {"title": "   "},
          {"title": "Good Task 2", "due": "2026-09-15"}
        ]
        """
        let parseResult = TaskExtractor.parse(json)
        guard case .valid(let parsed) = parseResult else {
            XCTFail("Expected .valid, got \(parseResult)")
            return
        }
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].title, "Good Task 1")
        XCTAssertEqual(parsed[0].owner, "Bob")
        XCTAssertEqual(parsed[1].title, "Good Task 2")
        XCTAssertEqual(parsed[1].due, "2026-09-15")
    }

    func testParseCapsAtEightAndDropsEmptyTitles() {
        var items: [[String: String]] = []
        items.append(["title": ""]) // should be dropped
        items.append(["title": "   "]) // should be dropped
        for i in 1...15 {
            items.append(["title": "Task \(i)"])
        }
        let data = try! JSONSerialization.data(withJSONObject: items)
        let json = String(data: data, encoding: .utf8)!

        let parseResult = TaskExtractor.parse(json)
        guard case .valid(let parsed) = parseResult else {
            XCTFail("Expected .valid, got \(parseResult)")
            return
        }
        XCTAssertEqual(parsed.count, 8)
        XCTAssertEqual(parsed[0].title, "Task 1")
        XCTAssertEqual(parsed[7].title, "Task 8")
    }

    func testParseDueValidationRejectsInvalidDates() {
        let json = """
        [
          {"title": "Valid due", "due": "2026-09-05"},
          {"title": "Invalid due 1", "due": "tomorrow"},
          {"title": "Invalid due 2", "due": "2026-9-5"},
          {"title": "Invalid due 3", "due": "2026/09/05"},
          {"title": "Invalid due 4", "due": "2026-99-99"},
          {"title": "Invalid due 5", "due": "2026-02-31"},
          {"title": "Null due", "due": null}
        ]
        """
        let parseResult = TaskExtractor.parse(json)
        guard case .valid(let parsed) = parseResult else {
            XCTFail("Expected .valid, got \(parseResult)")
            return
        }
        XCTAssertEqual(parsed.count, 7)
        XCTAssertEqual(parsed[0].due, "2026-09-05")
        XCTAssertNil(parsed[1].due)
        XCTAssertNil(parsed[2].due)
        XCTAssertNil(parsed[3].due)
        XCTAssertNil(parsed[4].due, "2026-99-99 must be rejected")
        XCTAssertNil(parsed[5].due, "2026-02-31 must be rejected")
        XCTAssertNil(parsed[6].due)
    }

    func testItemsAttribution() {
        let raw = [
            TaskExtractor.RawTask(title: "Follow up", owner: "me", due: "2026-09-08", quote: "I will follow up"),
            TaskExtractor.RawTask(title: "Check telemetry", owner: "craig", due: nil, quote: nil)
        ]
        let meetingURL = URL(fileURLWithPath: "/tmp/test-meeting")
        let meetingDate = Date(timeIntervalSince1970: 1700000000)
        let attendees = [Attendee(name: "Craig Angulo", email: "craig@apple.com")]
        let speakerNames = ["Speaker 1", "Alice"]
        let myName = "Byungjoo"
        let now = Date(timeIntervalSince1970: 1700000100)

        let items = TaskExtractor.items(
            from: raw,
            meetingURL: meetingURL,
            meetingTitle: "Team Sync",
            meetingDate: meetingDate,
            attendees: attendees,
            speakerNames: speakerNames,
            myName: myName,
            now: now
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].meetingURL, meetingURL)
        XCTAssertEqual(items[0].meetingTitle, "Team Sync")
        XCTAssertEqual(items[0].meetingDate, meetingDate)
        XCTAssertEqual(items[0].owner, "Byungjoo")
        XCTAssertEqual(items[0].createdAt, now)
        XCTAssertEqual(items[0].status, .open)

        XCTAssertEqual(items[1].owner, "Craig Angulo")
        XCTAssertEqual(items[1].title, "Check telemetry")
    }
}
