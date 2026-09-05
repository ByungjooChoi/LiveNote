import XCTest
@testable import LiveNote

@MainActor
final class BriefGeneratorTests: XCTestCase {

    private var rootURL: URL!
    private var logRoot: URL!
    private var store: MeetingStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveNoteGenTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        logRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveNoteGenLogs-\(UUID().uuidString)", isDirectory: true)
        AppLog.directoryOverride = logRoot
        store = MeetingStore(rootURL: rootURL)
    }

    override func tearDown() {
        AppLog.directoryOverride = nil
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        if let logRoot { try? FileManager.default.removeItem(at: logRoot) }
        store = nil
        rootURL = nil
        logRoot = nil
        super.tearDown()
    }

    func testScoringAndRanking() {
        let now = Date(timeIntervalSince1970: 1788220800) // 2026-09-01 00:00:00 UTC

        let event = CalendarMonitor.UpcomingMeetingItem(
            id: "event1",
            title: "Philip / Craig",
            start: now.addingTimeInterval(3600),
            end: now.addingTimeInterval(7200),
            webLink: nil,
            deepLink: nil,
            attendees: [Attendee(name: "Craig Angulo", email: "craig@example.com")],
            notes: "Discussion on roadmap"
        )

        // Meeting 1: 10 days ago (within 30d), attendee Craig (+3), title "Philip / Craig" (+2), recency (+1) = 6 points
        let m1 = MeetingSummary(
            url: rootURL.appendingPathComponent("m1"),
            title: "Philip / Craig",
            dateLabel: "8/22",
            startedAt: now.addingTimeInterval(-10 * 86400),
            rowCount: 20,
            durationSeconds: 1800,
            attendees: [Attendee(name: "Craig Angulo", email: "craig@example.com")]
        )

        // Meeting 2: 20 days ago (within 30d), attendee Craig (+3), title "Philip / Craig 1:1" (+2), recency (+1) = 6 points
        let m2 = MeetingSummary(
            url: rootURL.appendingPathComponent("m2"),
            title: "Philip / Craig 1:1",
            dateLabel: "8/12",
            startedAt: now.addingTimeInterval(-20 * 86400),
            rowCount: 20,
            durationSeconds: 1800,
            attendees: [Attendee(name: "Craig Angulo", email: "craig@example.com")]
        )

        // Meeting 3: 40 days ago (>30d, <=90d), attendee Craig (+3), title "Philip / Craig" (+2), recency (0) = 5 points
        let m3 = MeetingSummary(
            url: rootURL.appendingPathComponent("m3"),
            title: "Philip / Craig",
            dateLabel: "7/23",
            startedAt: now.addingTimeInterval(-40 * 86400),
            rowCount: 20,
            durationSeconds: 1800,
            attendees: [Attendee(name: "Craig Angulo", email: "craig@example.com")]
        )

        // Meeting 4: Unrelated meeting, attendee John, title "All Hands", 5 days ago = 0 points (excluded)
        let m4 = MeetingSummary(
            url: rootURL.appendingPathComponent("m4"),
            title: "All Hands",
            dateLabel: "8/27",
            startedAt: now.addingTimeInterval(-5 * 86400),
            rowCount: 20,
            durationSeconds: 1800,
            attendees: [Attendee(name: "John Doe", email: "john@example.com")]
        )

        let candidates = BriefGenerator.candidates(
            for: event,
            meetings: [m1, m2, m3, m4],
            now: now
        )

        XCTAssertNotNil(candidates)
        let list = candidates!
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].meeting.url, m1.url)
        XCTAssertEqual(list[0].score, 6)
        XCTAssertEqual(list[1].meeting.url, m2.url)
        XCTAssertEqual(list[1].score, 6)
        XCTAssertEqual(list[2].meeting.url, m3.url)
        XCTAssertEqual(list[2].score, 5)
    }

    func testNinetyDayCutoff() {
        let now = Date(timeIntervalSince1970: 1788220800)
        let event = CalendarMonitor.UpcomingMeetingItem(
            id: "event1",
            title: "Philip / Craig",
            start: now.addingTimeInterval(3600),
            end: now.addingTimeInterval(7200),
            webLink: nil,
            deepLink: nil,
            attendees: [Attendee(name: "Craig Angulo", email: "craig@example.com")]
        )

        let mOld = MeetingSummary(
            url: rootURL.appendingPathComponent("old"),
            title: "Philip / Craig",
            dateLabel: "5/1",
            startedAt: now.addingTimeInterval(-95 * 86400),
            rowCount: 10,
            durationSeconds: 600,
            attendees: [Attendee(name: "Craig Angulo", email: "craig@example.com")]
        )

        let candidates = BriefGenerator.candidates(for: event, meetings: [mOld], now: now)
        XCTAssertEqual(candidates?.count, 0)
    }

    func testSkipLargeMeetings() {
        let now = Date(timeIntervalSince1970: 1788220800)
        var attendees: [Attendee] = []
        for i in 1...8 {
            attendees.append(Attendee(name: "Person \(i)", email: "p\(i)@example.com"))
        }

        let largeEvent = CalendarMonitor.UpcomingMeetingItem(
            id: "large",
            title: "Large Meeting",
            start: now.addingTimeInterval(3600),
            end: now.addingTimeInterval(7200),
            webLink: nil,
            deepLink: nil,
            attendees: attendees
        )

        let resultSkipped = BriefGenerator.candidates(for: largeEvent, meetings: [], now: now, skipLarge: true)
        XCTAssertNil(resultSkipped)

        let resultNotSkipped = BriefGenerator.candidates(for: largeEvent, meetings: [], now: now, skipLarge: false)
        XCTAssertEqual(resultNotSkipped?.count, 0)
    }

    func testJaccardSimilarity() {
        XCTAssertEqual(BriefGenerator.jaccard("Philip / Craig", "Philip / Craig"), 1.0)
        XCTAssertEqual(BriefGenerator.jaccard("Philip / Craig 1:1", "Philip / Craig sync"), 1.0)
        XCTAssertGreaterThanOrEqual(BriefGenerator.jaccard("Philip / Craig", "Philip / Craig / Dan"), 0.5)
        XCTAssertEqual(BriefGenerator.jaccard("Completely Different", "Something Else"), 0.0)
    }

    func testUserPromptContainsNotesAndTasks() {
        let now = Date(timeIntervalSince1970: 1788220800)
        let event = CalendarMonitor.UpcomingMeetingItem(
            id: "e1",
            title: "Team Catchup",
            start: now,
            end: now.addingTimeInterval(3600),
            webLink: nil,
            deepLink: nil,
            attendees: [Attendee(name: "Craig", email: nil)],
            notes: "Important notes for today"
        )

        let task = TaskItem(
            id: UUID().uuidString,
            meetingURL: nil,
            meetingTitle: "Sprint Planning",
            meetingDate: nil,
            title: "Fix auth issue",
            owner: "Craig",
            due: "2026-09-05",
            quote: nil,
            status: .open,
            createdAt: now,
            completedAt: nil
        )

        let prompt = BriefGenerator.userPrompt(
            event: event,
            contextText: "Past context here",
            openTasks: [task],
            today: now
        )

        XCTAssertTrue(prompt.contains("Important notes for today"))
        XCTAssertTrue(prompt.contains("Past context here"))
        XCTAssertTrue(prompt.contains("Fix auth issue"))
        XCTAssertTrue(prompt.contains("(Craig)"))
        XCTAssertTrue(prompt.contains("[due 2026-09-05]"))
        XCTAssertTrue(prompt.contains("[Sprint Planning]"))
    }

    func testValidateMarkdown() {
        let valid = """
        # Last time
        - Decisions made

        # Open items
        - Task 1

        # Suggested agenda
        - Item 1
        - Item 2
        - Item 3
        """
        XCTAssertTrue(BriefGenerator.validate(markdown: valid).isEmpty)

        let twoBullets = """
        # Last time
        - Decisions made

        # Open items
        - Task 1

        # Suggested agenda
        - Item 1
        - Item 2
        """
        XCTAssertEqual(
            BriefGenerator.validate(markdown: twoBullets),
            ["Suggested agenda must have exactly 3 bullets (found 2)"]
        )

        let fourBullets = """
        # Last time
        - Decisions made

        # Open items
        - Task 1

        # Suggested agenda
        - Item 1
        - Item 2
        - Item 3
        - Item 4
        """
        XCTAssertEqual(
            BriefGenerator.validate(markdown: fourBullets),
            ["Suggested agenda must have exactly 3 bullets (found 4)"]
        )

        let missingLastTime = """
        # Open items
        - Task 1

        # Suggested agenda
        - Item 1
        - Item 2
        - Item 3
        """
        XCTAssertEqual(BriefGenerator.validate(markdown: missingLastTime), ["# Last time"])

        let missingAll = "Plain text without headers"
        XCTAssertEqual(BriefGenerator.validate(markdown: missingAll), ["# Last time", "# Open items", "# Suggested agenda"])
    }

    func testMalformedBriefThrows() async {
        let now = Date(timeIntervalSince1970: 1788220800)
        let event = CalendarMonitor.UpcomingMeetingItem(
            id: "e1",
            title: "Team Catchup",
            start: now,
            end: now.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: nil)]
        )

        let m1 = MeetingSummary(
            url: rootURL.appendingPathComponent("m1"),
            title: "Team Catchup",
            dateLabel: "8/22",
            startedAt: now.addingTimeInterval(-10 * 86400),
            rowCount: 20,
            durationSeconds: 1800,
            attendees: [Attendee(name: "Craig", email: nil)]
        )

        let backend = BriefGenerator.Backend(
            apiKey: { "test-key" },
            cloud: { _, _, _ in
                // Missing "# Suggested agenda"
                return "# Last time\n- Did stuff\n# Open items\n- Nothing"
            },
            local: { _, _ in "" }
        )

        do {
            _ = try await BriefGenerator.generate(
                event: event,
                candidates: [BriefGenerator.Candidate(meeting: m1, score: 5)],
                openTasks: [],
                store: store,
                language: "English",
                backend: backend,
                now: now
            )
            XCTFail("Expected malformed error to be thrown")
        } catch let error as BriefError {
            if case .malformed(let missing) = error {
                XCTAssertEqual(missing, ["# Suggested agenda"])
            } else {
                XCTFail("Expected malformed error, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSpeakerNamesInfluencesScoring() {
        let now = Date(timeIntervalSince1970: 1788220800)
        let event = CalendarMonitor.UpcomingMeetingItem(
            id: "e1",
            title: "Sync",
            start: now.addingTimeInterval(3600),
            end: now.addingTimeInterval(7200),
            attendees: [Attendee(name: "Alice Smith", email: nil)]
        )

        let meetingURL = rootURL.appendingPathComponent("m_speaker")
        let m = MeetingSummary(
            url: meetingURL,
            title: "Unrelated Title",
            dateLabel: "8/20",
            startedAt: now.addingTimeInterval(-10 * 86400),
            rowCount: 20,
            durationSeconds: 1800,
            attendees: [] // No attendee in summary
        )

        // Without speakerNames: score = 0 (no candidates)
        let candidatesBefore = BriefGenerator.candidates(
            for: event,
            meetings: [m],
            speakerNamesByMeeting: [:],
            now: now
        )
        XCTAssertEqual(candidatesBefore?.count, 0)

        // With speakerNames containing "Alice Smith": score = 3 (attendee match) + 1 (recent) = 4
        let candidatesAfter = BriefGenerator.candidates(
            for: event,
            meetings: [m],
            speakerNamesByMeeting: [meetingURL: ["Alice Smith", "Bob"]],
            now: now
        )
        XCTAssertEqual(candidatesAfter?.count, 1)
        XCTAssertEqual(candidatesAfter?.first?.score, 4)
    }

    func testAttendeeMatchingExactRules() {
        let now = Date(timeIntervalSince1970: 1788220800)

        // 1. "John Doe" vs "John Smith" -> 0 (single token overlap must not match)
        let eventJohnDoe = CalendarMonitor.UpcomingMeetingItem(
            id: "e_john_doe",
            title: "Discussion",
            start: now.addingTimeInterval(3600),
            end: now.addingTimeInterval(7200),
            attendees: [Attendee(name: "John Doe", email: nil)]
        )
        let mJohnSmith = MeetingSummary(
            url: rootURL.appendingPathComponent("m_john_smith"),
            title: "Past Meeting",
            dateLabel: "8/20",
            startedAt: now.addingTimeInterval(-10 * 86400),
            rowCount: 10,
            durationSeconds: 600,
            attendees: [Attendee(name: "John Smith", email: nil)]
        )
        let candidatesJohn = BriefGenerator.candidates(
            for: eventJohnDoe,
            meetings: [mJohnSmith],
            now: now
        )
        XCTAssertEqual(candidatesJohn?.count, 0)

        // 2. "Craig Angulo" vs "craig angulo" (case and whitespace) -> match (+3 + 1 recent = 4)
        let eventCraig = CalendarMonitor.UpcomingMeetingItem(
            id: "e_craig",
            title: "Sync",
            start: now.addingTimeInterval(3600),
            end: now.addingTimeInterval(7200),
            attendees: [Attendee(name: "Craig Angulo", email: nil)]
        )
        let mCraigLower = MeetingSummary(
            url: rootURL.appendingPathComponent("m_craig_lower"),
            title: "Other Title",
            dateLabel: "8/20",
            startedAt: now.addingTimeInterval(-10 * 86400),
            rowCount: 10,
            durationSeconds: 600,
            attendees: [Attendee(name: "  craig   angulo  ", email: nil)]
        )
        let candidatesCraig = BriefGenerator.candidates(
            for: eventCraig,
            meetings: [mCraigLower],
            now: now
        )
        XCTAssertEqual(candidatesCraig?.count, 1)
        XCTAssertEqual(candidatesCraig?.first?.score, 4)

        // 3. Email match without name match -> match (+3 + 1 recent = 4)
        let eventEmail = CalendarMonitor.UpcomingMeetingItem(
            id: "e_email",
            title: "Sync",
            start: now.addingTimeInterval(3600),
            end: now.addingTimeInterval(7200),
            attendees: [Attendee(name: "Anonymous User", email: "user@example.com")]
        )
        let mEmail = MeetingSummary(
            url: rootURL.appendingPathComponent("m_email"),
            title: "Other Title",
            dateLabel: "8/20",
            startedAt: now.addingTimeInterval(-10 * 86400),
            rowCount: 10,
            durationSeconds: 600,
            attendees: [Attendee(name: "Known Person", email: "USER@EXAMPLE.COM")]
        )
        let candidatesEmail = BriefGenerator.candidates(
            for: eventEmail,
            meetings: [mEmail],
            now: now
        )
        XCTAssertEqual(candidatesEmail?.count, 1)
        XCTAssertEqual(candidatesEmail?.first?.score, 4)

        // 4. Suffix stripping (" @ ...", ", ...") and diacritics
        XCTAssertEqual(
            BriefGenerator.normalizePersonName("Craig Angulo @ Elastic, SA"),
            "craig angulo"
        )
        XCTAssertEqual(
            BriefGenerator.normalizePersonName("Craig Angulo, VP Engineering"),
            "craig angulo"
        )
        XCTAssertEqual(
            BriefGenerator.normalizePersonName("René Descartes"),
            "rene descartes"
        )
        XCTAssertTrue(
            BriefGenerator.personMatches(
                eventName: "René Descartes @ Academie",
                eventEmail: nil,
                pastName: "Rene Descartes",
                pastEmail: nil
            )
        )
        XCTAssertTrue(
            BriefGenerator.speakerMatches(
                eventName: "Steve Mayzak @ Elastic",
                eventEmail: nil,
                speakerName: "steve mayzak"
            )
        )
    }
}
