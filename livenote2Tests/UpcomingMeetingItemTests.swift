import XCTest
import EventKit
@testable import LiveNote

final class UpcomingMeetingItemTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestLogSandbox.activate()
    }

    func testEventKeyAndDefaults() {
        let now = Date(timeIntervalSince1970: 1788220800)
        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "meeting-id-123@1788220800",
            title: "Quick Sync",
            start: now,
            end: now.addingTimeInterval(1800),
            webLink: URL(string: "https://zoom.us/j/123456"),
            deepLink: URL(string: "zoommtg://zoom.us/join?action=join&confno=123456")
        )

        XCTAssertEqual(item.eventKey, "meeting-id-123@1788220800")
        XCTAssertEqual(item.eventKey, item.id)
        XCTAssertEqual(item.attendees, [])
        XCTAssertNil(item.notes)
    }

    func testIsNow() {
        let now = Date(timeIntervalSince1970: 1788220800)
        let start = now.addingTimeInterval(300) // 5 minutes in the future (within 10m)
        let end = now.addingTimeInterval(2100)

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "item1",
            title: "Imminent Meeting",
            start: start,
            end: end,
            webLink: nil,
            deepLink: nil
        )

        // 5 minutes before start -> isNow true
        XCTAssertTrue(item.isNow(now))

        // 15 minutes before start -> isNow false
        XCTAssertFalse(item.isNow(now.addingTimeInterval(-600)))

        // During meeting -> isNow true
        XCTAssertTrue(item.isNow(start.addingTimeInterval(600)))

        // After meeting end -> isNow false
        XCTAssertFalse(item.isNow(end.addingTimeInterval(10)))
    }

    @MainActor
    func testOnTodayUpcomingChangedFiresOnlyOnChange() {
        let monitor = CalendarMonitor()
        var fireCount = 0
        var receivedItems: [UpcomingMeetingItem] = []

        monitor.onTodayUpcomingChanged = { items in
            fireCount += 1
            receivedItems = items
        }

        let item1 = CalendarMonitor.UpcomingMeetingItem(
            id: "event1",
            title: "Meeting 1",
            start: Date(),
            end: Date().addingTimeInterval(1800)
        )
        let item2 = CalendarMonitor.UpcomingMeetingItem(
            id: "event2",
            title: "Meeting 2",
            start: Date(),
            end: Date().addingTimeInterval(1800)
        )

        // 1. Initial change from [] to [item1] -> fires
        monitor.setTodayUpcomingForTesting([item1])
        XCTAssertEqual(fireCount, 1)
        XCTAssertEqual(receivedItems.count, 1)
        XCTAssertEqual(receivedItems.first?.id, "event1")

        // 2. Same item list -> does not fire
        monitor.setTodayUpcomingForTesting([item1])
        XCTAssertEqual(fireCount, 1)

        // 3. Changed item list -> fires
        monitor.setTodayUpcomingForTesting([item1, item2])
        XCTAssertEqual(fireCount, 2)
        XCTAssertEqual(receivedItems.count, 2)
    }

    @MainActor
    func testUpcomingItemsWithEightEventsNotCappedAtSix() {
        let now = Date(timeIntervalSince1970: 1788220800)
        let eventStore = EKEventStore()
        var events: [EKEvent] = []

        for i in 1...8 {
            let event = EKEvent(eventStore: eventStore)
            event.title = "Meeting \(i)"
            event.startDate = now.addingTimeInterval(Double(i) * 1800)
            event.endDate = now.addingTimeInterval(Double(i) * 1800 + 1200)
            event.notes = "Discussion topics for meeting \(i)"
            events.append(event)
        }

        let items = CalendarMonitor.upcomingItems(from: events, now: now)
        XCTAssertEqual(items.count, 8, "upcomingItems should not cap at 6 and must return all 8 events")

        let monitor = CalendarMonitor()
        monitor.setTodayUpcomingForTesting(items)
        XCTAssertEqual(monitor.todayUpcoming.count, 8, "todayUpcoming should store all 8 events")
        XCTAssertEqual(monitor.todayUpcoming[0].title, "Meeting 1")
        XCTAssertEqual(monitor.todayUpcoming[7].title, "Meeting 8")
    }

    @MainActor
    func testOnMeetingApproachingFiresForSeventhEventInTenMinuteWindow() {
        let now = Date(timeIntervalSince1970: 1788220800)
        let monitor = CalendarMonitor()

        var items: [UpcomingMeetingItem] = []
        for i in 1...8 {
            // Events 1..6 are far in the future (+30m, +60m, ...)
            // Event 7 is approaching: 5 minutes in the future (300 seconds)
            // Event 8 is in 4 hours (+14400s)
            let startOffset: Double
            if i == 7 {
                startOffset = 300 // 5 minutes away (0 < remaining <= 600)
            } else if i == 8 {
                startOffset = 14400
            } else {
                startOffset = Double(i) * 1800 // 30m, 60m, 90m, 120m, 150m, 180m
            }

            let start = now.addingTimeInterval(startOffset)
            let end = start.addingTimeInterval(1800)
            items.append(UpcomingMeetingItem(
                id: "event-\(i)@\(Int(start.timeIntervalSince1970))",
                title: "Event \(i)",
                start: start,
                end: end
            ))
        }

        monitor.setTodayUpcomingForTesting(items)
        XCTAssertEqual(monitor.todayUpcoming.count, 8)

        var notifiedItems: [UpcomingMeetingItem] = []
        monitor.onMeetingApproaching = { item in
            notifiedItems.append(item)
        }

        monitor.notifyMeetingApproaching(now: now)

        XCTAssertEqual(notifiedItems.count, 1)
        XCTAssertEqual(notifiedItems.first?.title, "Event 7")
        XCTAssertEqual(notifiedItems.first?.id, items[6].id)

        // Second notification call at same time does not re-fire (approachingNotifiedKeys deduplication)
        monitor.notifyMeetingApproaching(now: now)
        XCTAssertEqual(notifiedItems.count, 1)
    }

    // MARK: - S6: Session Attribution Tests (no AppState construction)

    func testResolveSessionItemExplicitWinsAndHeuristicNotInvoked() {
        let explicit = CalendarMonitor.UpcomingMeetingItem(
            id: "explicit-key@123",
            title: "Explicit Meeting",
            start: Date(),
            end: Date().addingTimeInterval(1800)
        )
        var heuristicInvoked = false
        let resolved = AppState.resolveSessionItem(explicit: explicit) {
            heuristicInvoked = true
            return CalendarMonitor.UpcomingMeetingItem(
                id: "heuristic-key@123",
                title: "Heuristic Meeting",
                start: Date(),
                end: Date().addingTimeInterval(1800)
            )
        }
        XCTAssertEqual(resolved?.id, "explicit-key@123")
        XCTAssertEqual(resolved?.title, "Explicit Meeting")
        XCTAssertFalse(heuristicInvoked, "Heuristic must not be invoked when explicit item is provided")
    }

    func testResolveSessionItemNilExplicitFallsBackToHeuristic() {
        var heuristicInvoked = false
        let heuristicItem = CalendarMonitor.UpcomingMeetingItem(
            id: "heuristic-key@456",
            title: "Heuristic Meeting",
            start: Date(),
            end: Date().addingTimeInterval(1800)
        )
        let resolved = AppState.resolveSessionItem(explicit: nil) {
            heuristicInvoked = true
            return heuristicItem
        }
        XCTAssertTrue(heuristicInvoked, "Heuristic must be invoked when explicit item is nil")
        XCTAssertEqual(resolved?.id, "heuristic-key@456")
        XCTAssertEqual(resolved?.title, "Heuristic Meeting")
    }

    func testResolveSessionItemBothNilReturnsNil() {
        var heuristicInvoked = false
        let resolved = AppState.resolveSessionItem(explicit: nil) {
            heuristicInvoked = true
            return nil
        }
        XCTAssertTrue(heuristicInvoked)
        XCTAssertNil(resolved)
    }

    func testSessionContextFromItemReturnsTitleAndAttendees() {
        let attendees = [
            Attendee(name: "Alice", email: "alice@example.com"),
            Attendee(name: "Bob", email: "bob@example.com")
        ]
        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "item-789",
            title: "Project Review",
            start: Date(),
            end: Date().addingTimeInterval(3600),
            attendees: attendees
        )
        let context = AppState.sessionContext(from: item)
        XCTAssertEqual(context.title, "Project Review")
        XCTAssertEqual(context.attendees, attendees)
    }

    @MainActor
    func testOnRecordRequestedReceivesItemMatchingAlertKey() throws {
        let monitor = CalendarMonitor()
        let webLink = try XCTUnwrap(URL(string: "https://zoom.us/j/999"))
        let alert = MeetingAlert(
            key: "alert-event-999@1788220800",
            title: "Sprint Retro",
            start: Date(),
            end: Date().addingTimeInterval(1800),
            webLink: webLink,
            deepLink: nil
        )

        var receivedItem: CalendarMonitor.UpcomingMeetingItem?
        monitor.onRecordRequested = { item in
            receivedItem = item
        }

        monitor.triggerRecordRequestedForTesting(candidate: alert)
        XCTAssertNotNil(receivedItem)
        XCTAssertEqual(receivedItem?.eventKey, alert.key)
        XCTAssertEqual(receivedItem?.title, "Sprint Retro")
    }

    @MainActor
    func testOnRecordRequestedCarriesTodayUpcomingMetadataWhenAvailable() throws {
        let monitor = CalendarMonitor()
        let now = Date()
        let attendees = [Attendee(name: "Charlie", email: "charlie@example.com")]
        let existingItem = CalendarMonitor.UpcomingMeetingItem(
            id: "alert-event-777@1788220800",
            title: "Rich Metadata Meeting",
            start: now,
            end: now.addingTimeInterval(1800),
            webLink: URL(string: "https://zoom.us/j/777"),
            deepLink: nil,
            attendees: attendees
        )
        monitor.setTodayUpcomingForTesting([existingItem])

        let webLink = try XCTUnwrap(URL(string: "https://zoom.us/j/777"))
        let alert = MeetingAlert(
            key: "alert-event-777@1788220800",
            title: "Fallback Title",
            start: now,
            end: now.addingTimeInterval(1800),
            webLink: webLink,
            deepLink: nil
        )

        var receivedItem: CalendarMonitor.UpcomingMeetingItem?
        monitor.onRecordRequested = { item in
            receivedItem = item
        }

        monitor.triggerRecordRequestedForTesting(candidate: alert)
        XCTAssertEqual(receivedItem?.eventKey, alert.key)
        XCTAssertEqual(receivedItem?.title, "Rich Metadata Meeting")
        XCTAssertEqual(receivedItem?.attendees, attendees)
    }
}
