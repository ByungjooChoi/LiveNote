import XCTest

@testable import LiveNote

final class RecipeScopeTests: XCTestCase {

    /// firstWeekday를 일요일(1)로 둬서 RecipeScope.weekStart가 Calendar.firstWeekday와
    /// 무관하게 항상 월요일을 기준으로 삼는지 증명한다.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        c.firstWeekday = 1
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = h
        comps.minute = mi
        comps.second = s
        return cal.date(from: comps)!
    }

    private func summary(
        url: URL,
        title: String = "M",
        startedAt: Date,
        attendees: [Attendee]? = nil
    ) -> MeetingSummary {
        MeetingSummary(
            url: url,
            title: title,
            dateLabel: "label",
            startedAt: startedAt,
            rowCount: 0,
            durationSeconds: 0,
            attendees: attendees
        )
    }

    // MARK: - weekStart

    func testWeekStartOnSunday() {
        let now = date(2026, 9, 6, 15, 0)
        let start = RecipeScope.weekStart(for: now, calendar: cal)
        XCTAssertEqual(start, date(2026, 8, 31, 0, 0))
    }

    func testWeekStartOnMonday() {
        let now = date(2026, 8, 31, 9, 0)
        let start = RecipeScope.weekStart(for: now, calendar: cal)
        XCTAssertEqual(start, date(2026, 8, 31, 0, 0))
    }

    func testWeekStartOnWednesday() {
        let now = date(2026, 9, 2, 12, 0)
        let start = RecipeScope.weekStart(for: now, calendar: cal)
        XCTAssertEqual(start, date(2026, 8, 31, 0, 0))
    }

    // MARK: - thisWeek

    func testThisWeekIncludesAndExcludes() {
        let now = date(2026, 9, 6, 15, 0)  // Sunday
        let inMonday = summary(url: URL(fileURLWithPath: "/tmp/m1"), startedAt: date(2026, 8, 31, 0, 30))
        let inFriday = summary(url: URL(fileURLWithPath: "/tmp/m2"), startedAt: date(2026, 9, 4, 10, 0))
        let outPrevSunday = summary(url: URL(fileURLWithPath: "/tmp/m3"), startedAt: date(2026, 8, 30, 23, 59))
        let outFuture = summary(url: URL(fileURLWithPath: "/tmp/m4"), startedAt: date(2026, 9, 6, 15, 1))

        let result = RecipeScope.thisWeek.resolve(
            meetings: [inMonday, inFriday, outPrevSunday, outFuture],
            now: now,
            calendar: cal
        )

        XCTAssertEqual(Set(result.map { $0.url }), Set([inMonday.url, inFriday.url]))
        XCTAssertEqual(result.map { $0.url }, [inFriday.url, inMonday.url])
    }

    /// 월요일 오전에 실행하면 그 주에는 월요일 기록만 남는다(직전 일요일 23:59는 제외).
    func testThisWeekOnMondayMorningKeepsOnlyThatDay() {
        let now = date(2026, 8, 31, 9, 0)  // Monday
        let mondayEarly = summary(url: URL(fileURLWithPath: "/tmp/m1"), startedAt: date(2026, 8, 31, 0, 0))
        let mondayJustBefore = summary(url: URL(fileURLWithPath: "/tmp/m2"), startedAt: date(2026, 8, 31, 8, 59))
        let previousSunday = summary(url: URL(fileURLWithPath: "/tmp/m3"), startedAt: date(2026, 8, 30, 23, 59))
        let laterToday = summary(url: URL(fileURLWithPath: "/tmp/m4"), startedAt: date(2026, 8, 31, 9, 1))

        let result = RecipeScope.thisWeek.resolve(
            meetings: [mondayEarly, mondayJustBefore, previousSunday, laterToday],
            now: now,
            calendar: cal
        )

        XCTAssertEqual(result.map { $0.url }, [mondayJustBefore.url, mondayEarly.url])
    }

    // MARK: - lastDays

    func testLastDaysBoundary() {
        let now = date(2026, 9, 6, 12, 0)
        let exactly14 = summary(url: URL(fileURLWithPath: "/tmp/a"), startedAt: date(2026, 8, 23, 12, 0))
        let exactly15 = summary(url: URL(fileURLWithPath: "/tmp/b"), startedAt: date(2026, 8, 22, 12, 0))

        let result = RecipeScope.lastDays(14).resolve(meetings: [exactly14, exactly15], now: now, calendar: cal)

        XCTAssertEqual(result.map { $0.url }, [exactly14.url])
    }

    // MARK: - currentMeeting / manual

    func testCurrentMeetingMatchesDespiteTrailingSlash() {
        let now = date(2026, 9, 6, 12, 0)
        let base = URL(fileURLWithPath: "/tmp/session-1")
        let withSlash = URL(fileURLWithPath: "/tmp/session-1/")
        let m = summary(url: base, startedAt: date(2026, 9, 1, 10, 0))
        let other = summary(url: URL(fileURLWithPath: "/tmp/session-2"), startedAt: date(2026, 9, 2, 10, 0))

        let result = RecipeScope.currentMeeting(withSlash).resolve(meetings: [m, other], now: now, calendar: cal)

        XCTAssertEqual(result.map { $0.url }, [m.url])
    }

    func testManualReturnsNewestFirstAndMatchesTrailingSlash() {
        let now = date(2026, 9, 6, 12, 0)
        let url1 = URL(fileURLWithPath: "/tmp/session-1")
        let url2Slash = URL(fileURLWithPath: "/tmp/session-2/")
        let url2NoSlash = URL(fileURLWithPath: "/tmp/session-2")
        let excluded = URL(fileURLWithPath: "/tmp/session-3")

        let older = summary(url: url1, startedAt: date(2026, 9, 1, 10, 0))
        let newer = summary(url: url2NoSlash, startedAt: date(2026, 9, 3, 10, 0))
        let excludedMeeting = summary(url: excluded, startedAt: date(2026, 9, 5, 10, 0))

        let result = RecipeScope.manual([url1, url2Slash]).resolve(
            meetings: [older, newer, excludedMeeting],
            now: now,
            calendar: cal
        )

        XCTAssertEqual(result.map { $0.url }, [newer.url, older.url])
    }

    // MARK: - label

    func testLabels() {
        XCTAssertEqual(RecipeScope.thisWeek.label, "This week")
        XCTAssertEqual(RecipeScope.lastDays(30).label, "Last 30 days")
        XCTAssertEqual(RecipeScope.currentMeeting(URL(fileURLWithPath: "/tmp/x")).label, "This meeting")
        XCTAssertEqual(RecipeScope.manual([URL(fileURLWithPath: "/tmp/x")]).label, "1 meeting")
        XCTAssertEqual(
            RecipeScope.manual([URL(fileURLWithPath: "/tmp/x"), URL(fileURLWithPath: "/tmp/y")]).label,
            "2 meetings"
        )
    }

    // MARK: - init(default:)

    func testInitFromScopeDefaultThisWeek() {
        XCTAssertEqual(RecipeScope(default: .thisWeek, currentMeeting: nil), .thisWeek)
    }

    func testInitFromScopeDefaultLastDays() {
        XCTAssertEqual(RecipeScope(default: .lastDays(7), currentMeeting: nil), .lastDays(7))
    }

    func testInitFromScopeDefaultCurrentMeeting() {
        let url = URL(fileURLWithPath: "/tmp/session-1")
        XCTAssertEqual(RecipeScope(default: .currentMeeting, currentMeeting: url), .currentMeeting(url))
    }

    func testInitFromScopeDefaultCurrentMeetingWithoutMeetingStartsEmptyManual() {
        XCTAssertEqual(RecipeScope(default: .currentMeeting, currentMeeting: nil), .manual([]))
    }

    func testInitFromScopeDefaultManualStartsEmpty() {
        let url = URL(fileURLWithPath: "/tmp/session-1")
        XCTAssertEqual(RecipeScope(default: .manual, currentMeeting: url), .manual([]))
    }

    func testEmptyManualResolvesToNoMeetings() {
        let now = date(2026, 9, 6, 12, 0)
        let m = summary(url: URL(fileURLWithPath: "/tmp/session-1"), startedAt: date(2026, 9, 1, 10, 0))
        XCTAssertTrue(RecipeScope.manual([]).resolve(meetings: [m], now: now, calendar: cal).isEmpty)
    }
}
