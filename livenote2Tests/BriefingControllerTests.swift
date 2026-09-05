import XCTest
@testable import LiveNote

private final class AtomicBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }
}

@MainActor
final class BriefingControllerTests: XCTestCase {

    private var rootURL: URL!
    private var logRoot: URL!
    private var briefStore: BriefStore!
    private var meetingStore: MeetingStore!
    private var userDefaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "BriefingControllerTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)

        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveNoteControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        logRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveNoteControllerLogs-\(UUID().uuidString)", isDirectory: true)
        AppLog.directoryOverride = logRoot

        briefStore = BriefStore(rootURL: rootURL)
        meetingStore = MeetingStore(rootURL: rootURL)
    }

    override func tearDown() {
        AppLog.directoryOverride = nil
        userDefaults?.removePersistentDomain(forName: suiteName)
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        if let logRoot { try? FileManager.default.removeItem(at: logRoot) }
        briefStore = nil
        meetingStore = nil
        userDefaults = nil
        super.tearDown()
    }

    func testCachedBriefNoSecondCallAndForceRegenerates() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)

        // Save a past meeting into meetingStore
        _ = try? meetingStore.save(
            rows: [MeetingStoreFixture.row(text: "Discussed project status")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: fixedNow.addingTimeInterval(-7 * 86400),
            durationSeconds: 1200,
            title: "Project Sync",
            summary: "# Summary\nAll good.",
            attendees: [Attendee(name: "Craig", email: "craig@example.com")],
            existingURL: nil
        )
        meetingStore.refresh()

        let callCount = AtomicBox(0)
        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "fake-key" },
            cloud: { _, _, _ in
                callCount.value += 1
                return "# Last time\n- Update\n# Open items\n- Item\n# Suggested agenda\n- Agenda item \(callCount.value)\n- Topic B\n- Topic C"
            },
            local: { _, _ in
                callCount.value += 1
                return "# Last time\n- Update\n# Open items\n- Item\n# Suggested agenda\n- Local agenda\n- Topic B\n- Topic C"
            }
        )

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "sync@12345",
            title: "Project Sync",
            start: fixedNow.addingTimeInterval(1800),
            end: fixedNow.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        XCTAssertEqual(controller.status(for: item), .notStarted)

        // 1st call: generates
        await controller.ensureBrief(for: item)
        XCTAssertEqual(callCount.value, 1)
        if case .ready(let b) = controller.status(for: item) {
            XCTAssertEqual(b.suggestedAgendaFirstLine, "Agenda item 1")
        } else {
            XCTFail("Expected ready status")
        }

        // 2nd call: cached, no backend call
        await controller.ensureBrief(for: item)
        XCTAssertEqual(callCount.value, 1)

        // Force call: regenerates
        await controller.ensureBrief(for: item, force: true)
        XCTAssertEqual(callCount.value, 2)
        if case .ready(let b) = controller.status(for: item) {
            XCTAssertEqual(b.suggestedAgendaFirstLine, "Agenda item 2")
        } else {
            XCTFail("Expected ready status after force")
        }
    }

    func testDisabledSkipsGeneration() async {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        let called = AtomicBox(false)
        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "key" },
            cloud: { _, _, _ in
                called.value = true
                return "text"
            },
            local: { _, _ in
                called.value = true
                return "text"
            }
        )

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )
        controller.settings.enabled = false

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "e1",
            title: "Meeting",
            start: fixedNow,
            end: fixedNow.addingTimeInterval(3600)
        )

        XCTAssertEqual(controller.status(for: item), .disabled)
        await controller.ensureBrief(for: item)
        XCTAssertFalse(called.value)
    }

    func testNoHistoryRemembered() async {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        let called = AtomicBox(false)
        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "key" },
            cloud: { _, _, _ in
                called.value = true
                return "text"
            },
            local: { _, _ in
                called.value = true
                return "text"
            }
        )

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        // No meetings in meetingStore -> candidates will be empty
        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "nohistory1",
            title: "Brand New Meeting",
            start: fixedNow,
            end: fixedNow.addingTimeInterval(3600),
            attendees: [Attendee(name: "New Person", email: "new@example.com")]
        )

        XCTAssertEqual(controller.status(for: item), .notStarted)
        await controller.ensureBrief(for: item)
        XCTAssertFalse(called.value)
        XCTAssertEqual(controller.status(for: item), .noHistory)

        // Subsequent call without force stays noHistory and does not call backend
        await controller.ensureBrief(for: item)
        XCTAssertFalse(called.value)
        XCTAssertEqual(controller.status(for: item), .noHistory)
    }

    func testNextBatchDateCalculation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 1
        components.hour = 5
        components.minute = 30
        let morning530 = calendar.date(from: components)!

        // At 05:30, next 7:00 batch is today at 07:00
        let nextToday = BriefingController.nextBatchDate(after: morning530, hour: 7, calendar: calendar)
        let hourToday = calendar.component(.hour, from: nextToday)
        let dayToday = calendar.component(.day, from: nextToday)
        XCTAssertEqual(hourToday, 7)
        XCTAssertEqual(dayToday, 1)

        components.hour = 8
        components.minute = 0
        let morning800 = calendar.date(from: components)!

        // At 08:00, next 7:00 batch is tomorrow at 07:00
        let nextTomorrow = BriefingController.nextBatchDate(after: morning800, hour: 7, calendar: calendar)
        let hourTomorrow = calendar.component(.hour, from: nextTomorrow)
        let dayTomorrow = calendar.component(.day, from: nextTomorrow)
        XCTAssertEqual(hourTomorrow, 7)
        XCTAssertEqual(dayTomorrow, 2)
    }

    func testForceRefreshFailureKeepsOldCachedBrief() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        _ = try? meetingStore.save(
            rows: [MeetingStoreFixture.row(text: "Past discussion")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: fixedNow.addingTimeInterval(-7 * 86400),
            durationSeconds: 1200,
            title: "Project Sync",
            summary: "# Summary\nAll good.",
            attendees: [Attendee(name: "Craig", email: "craig@example.com")],
            existingURL: nil
        )
        meetingStore.refresh()

        let shouldFail = AtomicBox(false)
        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "fake-key" },
            cloud: { _, _, _ in
                if shouldFail.value {
                    throw BriefError.emptyResponse
                }
                return "# Last time\n- Update\n# Open items\n- Item\n# Suggested agenda\n- Agenda item 1\n- Item 2\n- Item 3"
            },
            local: { _, _ in
                if shouldFail.value {
                    throw BriefError.emptyResponse
                }
                return "# Last time\n- Update\n# Open items\n- Item\n# Suggested agenda\n- Agenda item 1\n- Item 2\n- Item 3"
            }
        )

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "sync@12345",
            title: "Project Sync",
            start: fixedNow.addingTimeInterval(1800),
            end: fixedNow.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        // 1. Initial success
        await controller.ensureBrief(for: item)
        XCTAssertNotNil(controller.brief(for: item.eventKey))
        XCTAssertNil(controller.lastError)

        // 2. Failed force refresh
        shouldFail.value = true
        await controller.ensureBrief(for: item, force: true)

        // Error is recorded
        XCTAssertNotNil(controller.lastError)
        // BUT old cached brief is preserved in memory and on disk
        let preserved = controller.brief(for: item.eventKey)
        XCTAssertNotNil(preserved)
        XCTAssertEqual(preserved?.suggestedAgendaFirstLine, "Agenda item 1")
        XCTAssertNotNil(try briefStore.load(eventKey: item.eventKey))
    }

    func testConcurrentEnsureBriefGeneratesOnce() async {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        _ = try? meetingStore.save(
            rows: [MeetingStoreFixture.row(text: "Past discussion")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: fixedNow.addingTimeInterval(-7 * 86400),
            durationSeconds: 1200,
            title: "Project Sync",
            summary: "# Summary\nAll good.",
            attendees: [Attendee(name: "Craig", email: "craig@example.com")],
            existingURL: nil
        )
        meetingStore.refresh()

        let callCount = AtomicBox(0)
        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "fake-key" },
            cloud: { _, _, _ in
                callCount.value += 1
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
                return "# Last time\n- Update\n# Open items\n- Item\n# Suggested agenda\n- Agenda item 1\n- Item 2\n- Item 3"
            },
            local: { _, _ in
                callCount.value += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
                return "# Last time\n- Update\n# Open items\n- Item\n# Suggested agenda\n- Agenda item 1\n- Item 2\n- Item 3"
            }
        )

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "sync@12345",
            title: "Project Sync",
            start: fixedNow.addingTimeInterval(1800),
            end: fixedNow.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        // Launch two concurrent ensureBrief calls
        async let first: Void = controller.ensureBrief(for: item)
        async let second: Void = controller.ensureBrief(for: item)
        _ = await (first, second)

        XCTAssertEqual(callCount.value, 1)
        XCTAssertNotNil(controller.brief(for: item.eventKey))
    }

    func testWakeAndTimerOnSameDayRunBatchOnce() async {
        var testCalendar = Calendar(identifier: .gregorian)
        testCalendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 1
        comps.hour = 8
        comps.minute = 0
        comps.second = 0
        let date8AM = testCalendar.date(from: comps)!

        let currentDate = AtomicBox(date8AM)

        _ = try? meetingStore.save(
            rows: [MeetingStoreFixture.row(text: "Past discussion")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: currentDate.value.addingTimeInterval(-7 * 86400),
            durationSeconds: 1200,
            title: "Project Sync",
            summary: "# Summary\nAll good.",
            attendees: [Attendee(name: "Craig", email: "craig@example.com")],
            existingURL: nil
        )
        meetingStore.refresh()

        let callCount = AtomicBox(0)
        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "fake-key" },
            cloud: { _, _, _ in
                callCount.value += 1
                return "# Last time\n- Update\n# Open items\n- Item\n# Suggested agenda\n- Agenda item 1\n- Item 2\n- Item 3"
            },
            local: { _, _ in
                callCount.value += 1
                return "# Last time\n- Update\n# Open items\n- Item\n# Suggested agenda\n- Agenda item 1\n- Item 2\n- Item 3"
            }
        )

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { currentDate.value },
            calendar: testCalendar
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "sync@12345",
            title: "Project Sync",
            start: currentDate.value.addingTimeInterval(1800),
            end: currentDate.value.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        // Wake event at 08:00
        await controller.runMorningBatchIfNeeded(items: [item], reason: "wake")
        XCTAssertEqual(callCount.value, 1)

        // Timer event at 08:30 on same day -> deduplicated!
        await controller.runMorningBatchIfNeeded(items: [item], reason: "timer")
        XCTAssertEqual(callCount.value, 1)

        // Advance to tomorrow 08:00
        currentDate.value = currentDate.value.addingTimeInterval(86400)
        let tomorrowItem = CalendarMonitor.UpcomingMeetingItem(
            id: "sync@tomorrow",
            title: "Project Sync",
            start: currentDate.value.addingTimeInterval(1800),
            end: currentDate.value.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )
        await controller.runMorningBatchIfNeeded(items: [tomorrowItem], reason: "timer")
        XCTAssertEqual(callCount.value, 2)
    }

    func testScheduleMorningBatchCalledTwiceRegistersOneObserver() async {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        _ = try? meetingStore.save(
            rows: [MeetingStoreFixture.row(text: "Past discussion")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: fixedNow.addingTimeInterval(-7 * 86400),
            durationSeconds: 1200,
            title: "Project Sync",
            summary: "# Summary\nAll good.",
            attendees: [Attendee(name: "Craig", email: "craig@example.com")],
            existingURL: nil
        )
        meetingStore.refresh()

        let callCount = AtomicBox(0)
        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "k" },
            cloud: { _, _, _ in
                callCount.value += 1
                return "# Last time\n- Update\n# Open items\n- Item\n# Suggested agenda\n- Item 1\n- Item 2\n- Item 3"
            },
            local: { _, _ in
                callCount.value += 1
                return "# Last time\n- Update\n# Open items\n- Item\n# Suggested agenda\n- Item 1\n- Item 2\n- Item 3"
            }
        )
        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "sync@12345",
            title: "Project Sync",
            start: fixedNow.addingTimeInterval(1800),
            end: fixedNow.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        controller.scheduleMorningBatch(itemsProvider: { [item] })
        XCTAssertTrue(controller.observerRegistered)
        XCTAssertTrue(controller.batchTaskActive)

        // Calling a second time should not duplicate the observer and should maintain an active task
        controller.scheduleMorningBatch(itemsProvider: { [item] })
        XCTAssertTrue(controller.observerRegistered)
        XCTAssertTrue(controller.batchTaskActive)

        // Post didWakeNotification twice
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(nanoseconds: 50_000_000)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.wakeHandleCount, 2)
        XCTAssertEqual(callCount.value, 1)

        controller.cancelBatch()
    }

    func testMalformedBriefNotCachedAndLastErrorSet() async {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        _ = try? meetingStore.save(
            rows: [MeetingStoreFixture.row(text: "Past discussion")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: fixedNow.addingTimeInterval(-7 * 86400),
            durationSeconds: 1200,
            title: "Project Sync",
            summary: "# Summary\nAll good.",
            attendees: [Attendee(name: "Craig", email: "craig@example.com")],
            existingURL: nil
        )
        meetingStore.refresh()

        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "fake-key" },
            cloud: { _, _, _ in
                // Malformed: missing "# Suggested agenda"
                return "# Last time\n- Update\n# Open items\n- Item"
            },
            local: { _, _ in
                return "# Last time\n- Update\n# Open items\n- Item"
            }
        )

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "sync@12345",
            title: "Project Sync",
            start: fixedNow.addingTimeInterval(1800),
            end: fixedNow.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        await controller.ensureBrief(for: item)
        XCTAssertNotNil(controller.lastError)
        XCTAssertNotNil(controller.errors[item.eventKey])
        if case .failed = controller.status(for: item) {
            // expected
        } else {
            XCTFail("Expected status to be failed, got: \(controller.status(for: item))")
        }
        XCTAssertNil(controller.brief(for: item.eventKey))
        XCTAssertNil(try briefStore.load(eventKey: item.eventKey))
    }

    func testAgendaBulletCountNotThreeRejectedAndNotCached() async {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        _ = try? meetingStore.save(
            rows: [MeetingStoreFixture.row(text: "Past discussion")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: fixedNow.addingTimeInterval(-7 * 86400),
            durationSeconds: 1200,
            title: "Project Sync",
            summary: "# Summary\nAll good.",
            attendees: [Attendee(name: "Craig", email: "craig@example.com")],
            existingURL: nil
        )
        meetingStore.refresh()

        let bulletCount = AtomicBox(2)
        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "fake-key" },
            cloud: { _, _, _ in
                if bulletCount.value == 2 {
                    return "# Last time\n- Update\n# Open items\n- Item\n# Suggested agenda\n- Bullet 1\n- Bullet 2"
                } else {
                    return "# Last time\n- Update\n# Open items\n- Item\n# Suggested agenda\n- Bullet 1\n- Bullet 2\n- Bullet 3\n- Bullet 4"
                }
            },
            local: { _, _ in "" }
        )

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "sync@12345",
            title: "Project Sync",
            start: fixedNow.addingTimeInterval(1800),
            end: fixedNow.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        // 1. Test 2 bullets rejected
        bulletCount.value = 2
        await controller.ensureBrief(for: item)
        XCTAssertNotNil(controller.errors[item.eventKey])
        XCTAssertTrue(controller.errors[item.eventKey]?.contains("Suggested agenda must have exactly 3 bullets (found 2)") ?? false)
        XCTAssertNil(controller.brief(for: item.eventKey))
        XCTAssertNil(try briefStore.load(eventKey: item.eventKey))
        if case .failed = controller.status(for: item) {
            // expected
        } else {
            XCTFail("Expected .failed status for 2 bullets")
        }

        // 2. Test 4 bullets rejected
        bulletCount.value = 4
        await controller.ensureBrief(for: item, force: true)
        XCTAssertNotNil(controller.errors[item.eventKey])
        XCTAssertTrue(controller.errors[item.eventKey]?.contains("Suggested agenda must have exactly 3 bullets (found 4)") ?? false)
        XCTAssertNil(controller.brief(for: item.eventKey))
        XCTAssertNil(try briefStore.load(eventKey: item.eventKey))
        if case .failed = controller.status(for: item) {
            // expected
        } else {
            XCTFail("Expected .failed status for 4 bullets")
        }
    }

    func testOpenTasksProviderThrowsSetsErrorAndDoesNotGenerate() async {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        _ = try? meetingStore.save(
            rows: [MeetingStoreFixture.row(text: "Past discussion")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: fixedNow.addingTimeInterval(-7 * 86400),
            durationSeconds: 1200,
            title: "Project Sync",
            summary: "# Summary\nAll good.",
            attendees: [Attendee(name: "Craig", email: "craig@example.com")],
            existingURL: nil
        )
        meetingStore.refresh()

        let backendCalls = AtomicBox(0)
        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "k" },
            cloud: { _, _, _ in backendCalls.value += 1; return "" },
            local: { _, _ in backendCalls.value += 1; return "" }
        )

        enum TestError: LocalizedError {
            case simulatedFailure
            var errorDescription: String? { "Store query failed" }
        }

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in throw TestError.simulatedFailure },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "sync@12345",
            title: "Project Sync",
            start: fixedNow.addingTimeInterval(1800),
            end: fixedNow.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        await controller.ensureBrief(for: item)

        // Backend must NOT be called
        XCTAssertEqual(backendCalls.value, 0)
        XCTAssertEqual(controller.errors[item.eventKey], "Tasks unavailable: Store query failed")
        if case .failed(let msg) = controller.status(for: item) {
            XCTAssertEqual(msg, "Tasks unavailable: Store query failed")
        } else {
            XCTFail("Expected status to be .failed")
        }
        XCTAssertNil(controller.brief(for: item.eventKey))
    }

    func testPreloadCachedPopulatesFromDiskWithoutGenerating() throws {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        let brief = Brief(
            eventKey: "preloadKey@123",
            markdown: "# Last time\n- Past\n# Open items\n- Item\n# Suggested agenda\n- Agenda\n- Item 2\n- Item 3",
            generatedAt: fixedNow,
            basedOn: ["Past Meeting"],
            suggestedAgendaFirstLine: "Agenda"
        )
        try briefStore.save(brief)

        let backendCalls = AtomicBox(0)
        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "key" },
            cloud: { _, _, _ in backendCalls.value += 1; return "" },
            local: { _, _ in backendCalls.value += 1; return "" }
        )

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "preloadKey@123",
            title: "Preload Meeting",
            start: fixedNow,
            end: fixedNow.addingTimeInterval(3600)
        )

        // Before preload: pure in-memory read returns nil
        XCTAssertNil(controller.brief(for: item.eventKey))

        // Preload
        controller.preloadCached(for: [item])

        // After preload: in-memory read returns brief without backend call
        let loaded = controller.brief(for: item.eventKey)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.suggestedAgendaFirstLine, "Agenda")
        XCTAssertEqual(controller.status(for: item), .ready(brief))
        XCTAssertEqual(backendCalls.value, 0)
    }

    func testBeginSessionAndCopyBriefIfAvailable() throws {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        let brief = Brief(
            eventKey: "sessionKey@123",
            markdown: "# Last time\n- Past\n# Open items\n- Item\n# Suggested agenda\n- Agenda\n- Item 2\n- Item 3",
            generatedAt: fixedNow,
            basedOn: ["Past Meeting"],
            suggestedAgendaFirstLine: "Agenda"
        )
        try briefStore.save(brief)

        let fakeBackend = BriefGenerator.Backend(apiKey: { "key" }, cloud: { _, _, _ in "" }, local: { _, _ in "" })
        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "sessionKey@123",
            title: "Live Session Meeting",
            start: fixedNow,
            end: fixedNow.addingTimeInterval(3600)
        )

        // Begin session sets sessionEventKey and currentBrief
        controller.beginSession(item: item)
        XCTAssertEqual(controller.sessionEventKey, "sessionKey@123")
        XCTAssertNotNil(controller.currentBrief)

        let meetingFolder = rootURL.appendingPathComponent("LiveMeetingFolder", isDirectory: true)
        controller.copyBriefIfAvailable(toMeetingFolder: meetingFolder)

        let briefFile = meetingFolder.appendingPathComponent("brief.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: briefFile.path))

        // End session clears currentBrief but preserves sessionEventKey
        controller.endSession()
        XCTAssertEqual(controller.sessionEventKey, "sessionKey@123")
        XCTAssertNil(controller.currentBrief)
    }

    func testBeginSessionEndSessionCopyBriefIfAvailableStillWritesBrief() throws {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        let brief = Brief(
            eventKey: "sessionOrderKey@123",
            markdown: "# Last time\n- Past\n# Open items\n- Item\n# Suggested agenda\n- Bullet 1\n- Bullet 2\n- Bullet 3",
            generatedAt: fixedNow,
            basedOn: ["Past Meeting"],
            suggestedAgendaFirstLine: "Bullet 1"
        )
        try briefStore.save(brief)

        let fakeBackend = BriefGenerator.Backend(apiKey: { "k" }, cloud: { _, _, _ in "" }, local: { _, _ in "" })
        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "sessionOrderKey@123",
            title: "Live Session",
            start: fixedNow,
            end: fixedNow.addingTimeInterval(3600)
        )

        controller.beginSession(item: item)
        controller.endSession()

        XCTAssertNil(controller.currentBrief)
        XCTAssertEqual(controller.sessionEventKey, "sessionOrderKey@123")

        let meetingFolder = rootURL.appendingPathComponent("PostSessionFolder", isDirectory: true)
        controller.copyBriefIfAvailable(toMeetingFolder: meetingFolder)

        let briefFile = meetingFolder.appendingPathComponent("brief.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: briefFile.path))
    }

    func testSessionKeyIsolationManualMeetingClearsSessionEventKey() throws {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        let brief = Brief(
            eventKey: "sessionA@123",
            markdown: "# Last time\n- Past\n# Open items\n- Item\n# Suggested agenda\n- Bullet 1\n- Bullet 2\n- Bullet 3",
            generatedAt: fixedNow,
            basedOn: ["Past Meeting"],
            suggestedAgendaFirstLine: "Bullet 1"
        )
        try briefStore.save(brief)

        let fakeBackend = BriefGenerator.Backend(apiKey: { "k" }, cloud: { _, _, _ in "" }, local: { _, _ in "" })
        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let itemA = CalendarMonitor.UpcomingMeetingItem(
            id: "sessionA@123",
            title: "Calendar Meeting A",
            start: fixedNow,
            end: fixedNow.addingTimeInterval(3600)
        )

        // Session A: Calendar meeting
        controller.beginSession(item: itemA)
        XCTAssertEqual(controller.sessionEventKey, "sessionA@123")
        XCTAssertNotNil(controller.currentBrief)
        controller.endSession()
        XCTAssertEqual(controller.sessionEventKey, "sessionA@123")
        XCTAssertNil(controller.currentBrief)

        // Session B: Manual meeting (nil item)
        controller.beginSession(item: nil)
        XCTAssertNil(controller.sessionEventKey)
        XCTAssertNil(controller.currentBrief)
        controller.endSession()
        XCTAssertNil(controller.sessionEventKey)
        XCTAssertNil(controller.currentBrief)

        // Copy for Session B must write nothing
        let meetingBFolder = rootURL.appendingPathComponent("ManualMeetingBFolder", isDirectory: true)
        controller.copyBriefIfAvailable(toMeetingFolder: meetingBFolder)
        let briefFile = meetingBFolder.appendingPathComponent("brief.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: briefFile.path))
    }

    func testMorningBatchEmptyItemsDoesNotRecordBatchRunDate() async {
        var testCalendar = Calendar(identifier: .gregorian)
        testCalendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 1
        comps.hour = 8
        comps.minute = 40
        comps.second = 0
        let fixedNow = testCalendar.date(from: comps)!

        var generateCount = 0
        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "k" },
            cloud: { _, _, _ in
                generateCount += 1
                return "# Last time\n- P\n# Open items\n- O\n# Suggested agenda\n- A\n- B\n- C"
            },
            local: { _, _ in "" }
        )

        _ = try? meetingStore.save(
            rows: [MeetingStoreFixture.row(text: "Past discussion")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: fixedNow.addingTimeInterval(-7 * 86400),
            durationSeconds: 1200,
            title: "Project Sync",
            summary: "# Summary\nAll good.",
            attendees: [Attendee(name: "Craig", email: "craig@example.com")],
            existingURL: nil
        )
        meetingStore.refresh()

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow },
            calendar: testCalendar
        )

        // 1. Batch with [] does not record briefsLastBatchRun
        await controller.runMorningBatchIfNeeded(items: [], reason: "test")
        XCTAssertNil(userDefaults.object(forKey: "briefsLastBatchRun"))

        let item1 = CalendarMonitor.UpcomingMeetingItem(
            id: "event1",
            title: "Project Sync",
            start: fixedNow.addingTimeInterval(1800),
            end: fixedNow.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        // 2. Later items -> batch runs once and records
        await controller.runMorningBatchIfNeeded(items: [item1], reason: "test")
        XCTAssertNotNil(userDefaults.object(forKey: "briefsLastBatchRun"))
        XCTAssertEqual(generateCount, 1)

        let item2 = CalendarMonitor.UpcomingMeetingItem(
            id: "event2",
            title: "Project Sync 2",
            start: fixedNow.addingTimeInterval(5400),
            end: fixedNow.addingTimeInterval(7200),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        // 3. A second update the same day does not run again
        await controller.runMorningBatchIfNeeded(items: [item2], reason: "second-update")
        XCTAssertEqual(generateCount, 1) // Did not increase
    }

    func testCalendarItemsUpdatedPreloadsAndRunsMorningBatch() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1788252000)
        let savedBrief = Brief(
            eventKey: "savedKey@123",
            markdown: "# Last time\n- P\n# Open items\n- O\n# Suggested agenda\n- A\n- B\n- C",
            generatedAt: fixedNow,
            basedOn: ["M"],
            suggestedAgendaFirstLine: "A"
        )
        try briefStore.save(savedBrief)

        let fakeBackend = BriefGenerator.Backend(apiKey: { "k" }, cloud: { _, _, _ in "" }, local: { _, _ in "" })
        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "savedKey@123",
            title: "Saved Meeting",
            start: fixedNow.addingTimeInterval(3600),
            end: fixedNow.addingTimeInterval(7200)
        )

        XCTAssertNil(controller.brief(for: item.eventKey))
        controller.calendarItemsUpdated([item])
        // Synchronously preloaded
        XCTAssertNotNil(controller.brief(for: item.eventKey))
    }

    func testCopyBriefFailureInvokesOnUserNotice() throws {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        let brief = Brief(
            eventKey: "sessionKey@notice",
            markdown: "# Last time\n- Past\n# Open items\n- Item\n# Suggested agenda\n- Bullet 1\n- Bullet 2\n- Bullet 3",
            generatedAt: fixedNow,
            basedOn: ["Past Meeting"],
            suggestedAgendaFirstLine: "Bullet 1"
        )
        try briefStore.save(brief)

        let fakeBackend = BriefGenerator.Backend(apiKey: { "k" }, cloud: { _, _, _ in "" }, local: { _, _ in "" })
        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        var noticeMessage: String?
        controller.onUserNotice = { msg in
            noticeMessage = msg
        }

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "sessionKey@notice",
            title: "Notice Session",
            start: fixedNow,
            end: fixedNow.addingTimeInterval(3600)
        )
        controller.beginSession(item: item)

        // Read-only destination folder to force copyBrief to fail
        let readOnlyFolder = rootURL.appendingPathComponent("ReadOnlyNoticeFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyFolder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyFolder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyFolder.path)
        }

        controller.copyBriefIfAvailable(toMeetingFolder: readOnlyFolder)

        XCTAssertNotNil(noticeMessage)
        XCTAssertTrue(noticeMessage!.hasPrefix("Could not copy the pre-meeting brief into the meeting folder:"))
    }

    func testCancelBatchCancelsStartupTaskAndBatchTask() {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        let fakeBackend = BriefGenerator.Backend(apiKey: { "k" }, cloud: { _, _, _ in "" }, local: { _, _ in "" })
        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        controller.scheduleMorningBatch(itemsProvider: { [] })
        XCTAssertTrue(controller.observerRegistered)

        controller.cancelBatch()
        XCTAssertFalse(controller.observerRegistered)
        XCTAssertFalse(controller.batchTaskActive)
    }

    func testBriefStoreSaveFailureSetsErrorsAndFailedStatus() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        _ = try? meetingStore.save(
            rows: [MeetingStoreFixture.row(text: "Past discussion")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: fixedNow.addingTimeInterval(-7 * 86400),
            durationSeconds: 1200,
            title: "Project Sync",
            summary: "# Summary\nAll good.",
            attendees: [Attendee(name: "Craig", email: "craig@example.com")],
            existingURL: nil
        )
        meetingStore.refresh()

        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "k" },
            cloud: { _, _, _ in
                return "# Last time\n- Update\n# Open items\n- Item\n# Suggested agenda\n- Item 1\n- Item 2\n- Item 3"
            },
            local: { _, _ in "" }
        )

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "sync@readonly",
            title: "Project Sync",
            start: fixedNow.addingTimeInterval(1800),
            end: fixedNow.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        // Make briefs directory read-only
        let briefsDir = rootURL.appendingPathComponent("briefs", isDirectory: true)
        try FileManager.default.createDirectory(at: briefsDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: briefsDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: briefsDir.path)
        }

        await controller.ensureBrief(for: item)

        XCTAssertNotNil(controller.errors[item.eventKey])
        XCTAssertNil(controller.brief(for: item.eventKey))
        XCTAssertNil(try briefStore.load(eventKey: item.eventKey))
        if case .failed = controller.status(for: item) {
            // expected
        } else {
            XCTFail("Expected .failed status when store.save fails")
        }
    }

    func testEnsureBriefLoadsExistingFromDiskWithoutGenerating() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)

        // Save a past meeting into meetingStore
        _ = try? meetingStore.save(
            rows: [MeetingStoreFixture.row(text: "Discussed roadmap")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: fixedNow.addingTimeInterval(-5 * 86400),
            durationSeconds: 1200,
            title: "Roadmap Sync",
            summary: "# Summary\nDiscussed roadmap.",
            attendees: [Attendee(name: "Craig", email: "craig@example.com")],
            existingURL: nil
        )
        meetingStore.refresh()

        let backendCallsA = AtomicBox(0)
        let fakeBackendA = BriefGenerator.Backend(
            apiKey: { "k" },
            cloud: { _, _, _ in
                backendCallsA.value += 1
                return "# Last time\n- Update\n# Open items\n- Item\n# Suggested agenda\n- Agenda 1\n- Agenda 2\n- Agenda 3"
            },
            local: { _, _ in "" }
        )

        let controllerA = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackendA,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "roadmap@fresh",
            title: "Roadmap Sync",
            start: fixedNow.addingTimeInterval(1800),
            end: fixedNow.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        // Controller A generates and saves to disk
        await controllerA.ensureBrief(for: item)
        XCTAssertEqual(backendCallsA.value, 1)
        if case .ready(let briefA) = controllerA.status(for: item) {
            XCTAssertEqual(briefA.suggestedAgendaFirstLine, "Agenda 1")
        } else {
            XCTFail("Expected controllerA status to be .ready")
        }
        XCTAssertNotNil(try briefStore.load(eventKey: item.eventKey))

        // Controller B: fresh instance with same store and a new fake backend
        let backendCallsB = AtomicBox(0)
        let fakeBackendB = BriefGenerator.Backend(
            apiKey: { "k" },
            cloud: { _, _, _ in
                backendCallsB.value += 1
                return "# Last time\n- Fresh\n# Open items\n- Item\n# Suggested agenda\n- Fresh 1\n- Fresh 2\n- Fresh 3"
            },
            local: { _, _ in "" }
        )

        let controllerB = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackendB,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        // Before ensureBrief on controller B, memory dictionary is empty
        XCTAssertNil(controllerB.brief(for: item.eventKey))

        // ensureBrief on controller B should load from store and not call backend
        await controllerB.ensureBrief(for: item)
        XCTAssertEqual(backendCallsB.value, 0)
        if case .ready(let briefB) = controllerB.status(for: item) {
            XCTAssertEqual(briefB.suggestedAgendaFirstLine, "Agenda 1")
        } else {
            XCTFail("Expected controllerB status to be .ready")
        }
        XCTAssertEqual(controllerB.brief(for: item.eventKey)?.suggestedAgendaFirstLine, "Agenda 1")
    }

    func testRunMorningBatchProcessesAllEightEvents() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BriefingControllerTests_EightEvents_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let userDefaults = UserDefaults(suiteName: "BriefingControllerTests_EightEvents_\(UUID().uuidString)")!
        defer { userDefaults.removePersistentDomain(forName: userDefaults.description) }

        let briefStore = BriefStore(rootURL: tempDir.appendingPathComponent("Briefs"))
        let meetingStore = MeetingStore(rootURL: tempDir.appendingPathComponent("Meetings"))

        var testCalendar = Calendar(identifier: .gregorian)
        testCalendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 1
        comps.hour = 7
        comps.minute = 0
        comps.second = 0
        let fixedNow = testCalendar.date(from: comps)!

        let backendCalls = AtomicBox(0)
        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "k" },
            cloud: { _, _, _ in
                backendCalls.value += 1
                return "# Last time\n- Discussed previous work\n# Open items\n- Next steps\n# Suggested agenda\n- Bullet 1\n- Bullet 2\n- Bullet 3"
            },
            local: { _, _ in "" }
        )

        // Seed a past meeting so candidates exist
        _ = try? meetingStore.save(
            rows: [MeetingStoreFixture.row(text: "Kickoff discussion")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: fixedNow.addingTimeInterval(-2 * 86400),
            durationSeconds: 1800,
            title: "Sprint Planning",
            summary: "# Summary\nPrior work notes.",
            attendees: [Attendee(name: "Craig Angulo", email: "craig@example.com")],
            existingURL: nil as URL?
        )
        meetingStore.refresh()

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow },
            calendar: testCalendar
        )

        var eightItems: [UpcomingMeetingItem] = []
        for i in 1...8 {
            let start = fixedNow.addingTimeInterval(Double(i) * 3600)
            let end = start.addingTimeInterval(1800)
            eightItems.append(UpcomingMeetingItem(
                id: "batch-event-\(i)@\(Int(start.timeIntervalSince1970))",
                title: "Planning Session \(i)",
                start: start,
                end: end,
                attendees: [Attendee(name: "Craig Angulo", email: "craig@example.com")]
            ))
        }

        await controller.runMorningBatchIfNeeded(items: eightItems, reason: "test-eight-events")

        XCTAssertEqual(backendCalls.value, 8, "runMorningBatchIfNeeded should process and generate briefs for all 8 items")
        for item in eightItems {
            XCTAssertNotNil(controller.brief(for: item.eventKey), "Brief should be cached in controller for \(item.eventKey)")
            if case .ready(let brief) = controller.status(for: item) {
                XCTAssertEqual(brief.suggestedAgendaFirstLine, "Bullet 1")
            } else {
                XCTFail("Status should be ready for \(item.eventKey)")
            }
        }
    }

    func testCorruptCachedBriefNonForceFailsWithoutCallingBackendAndLeavesFileUnchanged() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        _ = try? meetingStore.save(
            rows: [MeetingStoreFixture.row(text: "Past discussion")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: fixedNow.addingTimeInterval(-7 * 86400),
            durationSeconds: 1200,
            title: "Project Sync",
            summary: "# Summary\nAll good.",
            attendees: [Attendee(name: "Craig", email: "craig@example.com")],
            existingURL: nil
        )
        meetingStore.refresh()

        let backendCalls = AtomicBox(0)
        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "k" },
            cloud: { _, _, _ in
                backendCalls.value += 1
                return "# Last time\n- Discussed\n# Open items\n- Item\n# Suggested agenda\n- Bullet 1\n- Bullet 2\n- Bullet 3"
            },
            local: { _, _ in "" }
        )

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "corruptItem@123",
            title: "Project Sync",
            start: fixedNow.addingTimeInterval(1800),
            end: fixedNow.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        // Write corrupt brief file (missing header metadata)
        let briefsDir = rootURL.appendingPathComponent("briefs", isDirectory: true)
        try FileManager.default.createDirectory(at: briefsDir, withIntermediateDirectories: true)
        let corruptFile = briefsDir.appendingPathComponent("\(BriefStore.safeFileName(item.eventKey)).md")
        let corruptContent = "# Last time\n- Corrupt content without header\n# Open items\n# Suggested agenda\n- A\n- B\n- C"
        try corruptContent.write(to: corruptFile, atomically: true, encoding: .utf8)

        // 1. Test preloadCached records error
        controller.preloadCached(for: [item])
        XCTAssertNotNil(controller.errors[item.eventKey])
        XCTAssertTrue(controller.errors[item.eventKey]?.contains("Cached brief unreadable") ?? false)
        if case .failed = controller.status(for: item) {
            // expected
        } else {
            XCTFail("Expected .failed status after preloadCached on corrupt file")
        }

        // 2. Test ensureBrief (force: false) fails without calling backend and leaves file unchanged
        await controller.ensureBrief(for: item, force: false)
        XCTAssertEqual(backendCalls.value, 0, "Backend should not be called when cached brief is unreadable")
        if case .failed(let err) = controller.status(for: item) {
            XCTAssertTrue(err.contains("Cached brief unreadable"))
        } else {
            XCTFail("Expected .failed status")
        }
        let contentAfter = try String(contentsOf: corruptFile, encoding: .utf8)
        XCTAssertEqual(contentAfter, corruptContent, "Corrupt file on disk should remain unchanged")
    }

    func testCorruptCachedBriefForceRegeneratesAndOverwrites() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        _ = try? meetingStore.save(
            rows: [MeetingStoreFixture.row(text: "Past discussion")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: fixedNow.addingTimeInterval(-7 * 86400),
            durationSeconds: 1200,
            title: "Project Sync",
            summary: "# Summary\nAll good.",
            attendees: [Attendee(name: "Craig", email: "craig@example.com")],
            existingURL: nil
        )
        meetingStore.refresh()

        let backendCalls = AtomicBox(0)
        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "k" },
            cloud: { _, _, _ in
                backendCalls.value += 1
                return "# Last time\n- Generated fresh\n# Open items\n- Fresh item\n# Suggested agenda\n- Bullet 1\n- Bullet 2\n- Bullet 3"
            },
            local: { _, _ in "" }
        )

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "corruptForceItem@123",
            title: "Project Sync",
            start: fixedNow.addingTimeInterval(1800),
            end: fixedNow.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        // Write corrupt brief file
        let briefsDir = rootURL.appendingPathComponent("briefs", isDirectory: true)
        try FileManager.default.createDirectory(at: briefsDir, withIntermediateDirectories: true)
        let corruptFile = briefsDir.appendingPathComponent("\(BriefStore.safeFileName(item.eventKey)).md")
        let corruptContent = "Corrupted data without headers"
        try corruptContent.write(to: corruptFile, atomically: true, encoding: .utf8)

        // Force ensureBrief should regenerate and overwrite
        await controller.ensureBrief(for: item, force: true)
        XCTAssertEqual(backendCalls.value, 1)
        XCTAssertNil(controller.errors[item.eventKey])
        if case .ready(let brief) = controller.status(for: item) {
            XCTAssertEqual(brief.suggestedAgendaFirstLine, "Bullet 1")
        } else {
            XCTFail("Expected .ready status after force regeneration")
        }

        let loaded = try XCTUnwrap(try briefStore.load(eventKey: item.eventKey))
        XCTAssertEqual(loaded.suggestedAgendaFirstLine, "Bullet 1")
    }

    func testCopyBriefWithCorruptCachedBriefSetsLastErrorAndFiresNotice() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1788220800)
        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: BriefGenerator.Backend(apiKey: { "k" }, cloud: { _, _, _ in "" }, local: { _, _ in "" }),
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { fixedNow }
        )

        let item = CalendarMonitor.UpcomingMeetingItem(
            id: "corruptCopyItem@123",
            title: "Project Sync",
            start: fixedNow.addingTimeInterval(1800),
            end: fixedNow.addingTimeInterval(3600),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        // Write corrupt brief file
        let briefsDir = rootURL.appendingPathComponent("briefs", isDirectory: true)
        try FileManager.default.createDirectory(at: briefsDir, withIntermediateDirectories: true)
        let corruptFile = briefsDir.appendingPathComponent("\(BriefStore.safeFileName(item.eventKey)).md")
        try "corrupt content".write(to: corruptFile, atomically: true, encoding: .utf8)

        controller.beginSession(item: item)

        let noticeFired = AtomicBox(false)
        controller.onUserNotice = { text in
            noticeFired.value = true
            XCTAssertTrue(text.contains("Could not copy the pre-meeting brief into the meeting folder"))
        }

        let targetFolder = rootURL.appendingPathComponent("2026-09-01 1000 Sync", isDirectory: true)
        controller.copyBriefIfAvailable(toMeetingFolder: targetFolder)

        XCTAssertTrue(noticeFired.value)
        XCTAssertNotNil(controller.lastError)
    }

    func testMorningBatchChangingBatchHourAfterRunDoesNotRerunSameDayAndRunsNextDay() async {
        let testCalendar = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 1
        comps.hour = 8
        comps.minute = 0
        comps.second = 0
        let date8AM = testCalendar.date(from: comps)!
        let currentDate = AtomicBox(date8AM)

        _ = try? meetingStore.save(
            rows: [MeetingStoreFixture.row(text: "Past discussion")],
            myName: "Philip",
            speakerNames: [:],
            startedAt: date8AM.addingTimeInterval(-7 * 86400),
            durationSeconds: 1200,
            title: "Project Sync",
            summary: "# Summary\nAll good.",
            attendees: [Attendee(name: "Craig", email: "craig@example.com")],
            existingURL: nil
        )
        meetingStore.refresh()

        let backendCalls = AtomicBox(0)
        let fakeBackend = BriefGenerator.Backend(
            apiKey: { "k" },
            cloud: { _, _, _ in
                backendCalls.value += 1
                return "# Last time\n- Discussed\n# Open items\n- Item\n# Suggested agenda\n- Bullet 1\n- Bullet 2\n- Bullet 3"
            },
            local: { _, _ in "" }
        )

        let controller = BriefingController(
            store: briefStore,
            meetingStore: meetingStore,
            defaults: userDefaults,
            backend: fakeBackend,
            openTasksProvider: { _ in [] },
            language: { "English" },
            now: { currentDate.value },
            calendar: testCalendar
        )

        // Set batch hour to 7
        controller.settings.batchHour = 7

        let item1 = CalendarMonitor.UpcomingMeetingItem(
            id: "sync@day1",
            title: "Project Sync",
            start: date8AM.addingTimeInterval(3600),
            end: date8AM.addingTimeInterval(5400),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )

        // 1. Run at 08:00 with hour 7 -> runs batch
        await controller.runMorningBatchIfNeeded(items: [item1], reason: "morning-8am")
        XCTAssertEqual(backendCalls.value, 1)

        // 2. Set hour to 9, call at 09:05 -> no second run!
        controller.settings.batchHour = 9
        currentDate.value = date8AM.addingTimeInterval(65 * 60) // 09:05
        await controller.runMorningBatchIfNeeded(items: [item1], reason: "morning-905am")
        XCTAssertEqual(backendCalls.value, 1, "Changing batch hour after run should not rerun on the same day")

        // 3. Next day at 09:05 -> runs batch!
        currentDate.value = date8AM.addingTimeInterval(86400 + 65 * 60) // Next day 09:05
        let item2 = CalendarMonitor.UpcomingMeetingItem(
            id: "sync@day2",
            title: "Project Sync",
            start: currentDate.value.addingTimeInterval(3600),
            end: currentDate.value.addingTimeInterval(5400),
            attendees: [Attendee(name: "Craig", email: "craig@example.com")]
        )
        await controller.runMorningBatchIfNeeded(items: [item2], reason: "next-day-905am")
        XCTAssertEqual(backendCalls.value, 2, "Batch should run on the next day")
    }
}
