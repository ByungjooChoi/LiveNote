import XCTest
@testable import LiveNote

@MainActor
final class FakeRecordingReminderProbe: RecordingReminderProbing {
    var meetingAppName: String? = "Zoom"
    var micInUse: Bool = true
    var liveNoteActive: Bool = false
    var probeCallCount = 0
    var onProbe: ((Int) -> Void)?

    func probe() -> RecordingReminderProbe {
        probeCallCount += 1
        onProbe?(probeCallCount)
        return RecordingReminderProbe(
            meetingAppName: meetingAppName,
            micInUse: micInUse,
            liveNoteActive: liveNoteActive
        )
    }
}

final class FakeRecordingReminderNotifier: RecordingReminderNotifying, @unchecked Sendable {
    var authGranted = true
    var requestAuthCallCount = 0
    var deliveredAppNames: [String] = []
    var deliveryError: (any Error)?
    var onStartAction: (@MainActor () -> Void)?
    var holdAuthorization = false
    var pendingAuthCompletions: [@MainActor (Bool) -> Void] = []

    func requestAuthorizationIfNeeded(_ completion: @escaping @MainActor (Bool) -> Void) {
        requestAuthCallCount += 1
        if holdAuthorization {
            pendingAuthCompletions.append(completion)
        } else {
            let granted = authGranted
            Task { @MainActor in
                completion(granted)
            }
        }
    }

    func releaseAuthorization(granted: Bool) {
        let completions = pendingAuthCompletions
        pendingAuthCompletions.removeAll()
        for completion in completions {
            Task { @MainActor in
                completion(granted)
            }
        }
    }

    func deliver(appName: String, completion: @escaping @MainActor (Error?) -> Void) {
        deliveredAppNames.append(appName)
        let err = deliveryError
        Task { @MainActor in
            completion(err)
        }
    }

    func simulateUserTappedStart() {
        Task { @MainActor in
            self.onStartAction?()
        }
    }
}

@MainActor
final class RecordingReminderTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tempLogDir: URL!

    override func setUp() {
        super.setUp()
        suiteName = "RecordingReminderTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        tempLogDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("livenote-reminder-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempLogDir, withIntermediateDirectories: true)
        AppLog.directoryOverride = tempLogDir
    }

    override func tearDown() {
        AppLog.directoryOverride = nil
        if let tempLogDir {
            try? FileManager.default.removeItem(at: tempLogDir)
        }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    // MARK: - Policy Tests

    func testPolicyTruthTable() {
        var policy = RecordingReminderPolicy()

        // 1. Initial tick with no meeting app running -> idle
        let noApp = RecordingReminderProbe(meetingAppName: nil, micInUse: true, liveNoteActive: false)
        XCTAssertEqual(policy.tick(noApp), .idle)
        XCTAssertEqual(policy.consecutiveHits, 0)
        XCTAssertFalse(policy.notified)

        // 2. Meeting app running + mic in use + LiveNote idle -> Hit 1: armed
        let hitProbe = RecordingReminderProbe(meetingAppName: "Zoom", micInUse: true, liveNoteActive: false)
        XCTAssertEqual(policy.tick(hitProbe), .armed)
        XCTAssertEqual(policy.consecutiveHits, 1)
        XCTAssertFalse(policy.notified)

        // 3. Hit 2: notify
        XCTAssertEqual(policy.tick(hitProbe), .notify(appName: "Zoom"))
        XCTAssertEqual(policy.consecutiveHits, 2)
        XCTAssertTrue(policy.notified)

        // 4. Hit 3+: suppressed while meeting continues
        XCTAssertEqual(policy.tick(hitProbe), .suppressed)
        XCTAssertEqual(policy.consecutiveHits, 3)
        XCTAssertTrue(policy.notified)

        // 5. Mic becomes idle while meeting app is still running -> consecutiveHits resets to 0, notified stays true
        let micIdleProbe = RecordingReminderProbe(meetingAppName: "Zoom", micInUse: false, liveNoteActive: false)
        XCTAssertEqual(policy.tick(micIdleProbe), .idle)
        XCTAssertEqual(policy.consecutiveHits, 0)
        XCTAssertTrue(policy.notified)

        // 6. Mic resumes while meeting app is still running -> suppressed (already notified for this session)
        XCTAssertEqual(policy.tick(hitProbe), .suppressed)
        XCTAssertEqual(policy.consecutiveHits, 1)
        XCTAssertTrue(policy.notified)

        // 7. LiveNote becomes active -> consecutiveHits resets to 0, notified stays true
        let activeProbe = RecordingReminderProbe(meetingAppName: "Zoom", micInUse: true, liveNoteActive: true)
        XCTAssertEqual(policy.tick(activeProbe), .idle)
        XCTAssertEqual(policy.consecutiveHits, 0)
        XCTAssertTrue(policy.notified)

        // 8. Meeting app quits (appName == nil) -> resets hits and notified, returns idle
        XCTAssertEqual(policy.tick(noApp), .idle)
        XCTAssertEqual(policy.consecutiveHits, 0)
        XCTAssertFalse(policy.notified)

        // 9. Next meeting app starts -> new cycle starts cleanly
        let teamsProbe = RecordingReminderProbe(meetingAppName: "Microsoft Teams", micInUse: true, liveNoteActive: false)
        XCTAssertEqual(policy.tick(teamsProbe), .armed)
        XCTAssertEqual(policy.consecutiveHits, 1)
        XCTAssertFalse(policy.notified)
        XCTAssertEqual(policy.tick(teamsProbe), .notify(appName: "Microsoft Teams"))
        XCTAssertEqual(policy.consecutiveHits, 2)
        XCTAssertTrue(policy.notified)

        // 10. Manual reset()
        policy.reset()
        XCTAssertEqual(policy.consecutiveHits, 0)
        XCTAssertFalse(policy.notified)
    }

    func testPolicyResetClearsNotifiedOnAppQuit() {
        var policy = RecordingReminderPolicy()
        let hitProbe = RecordingReminderProbe(meetingAppName: "Zoom", micInUse: true, liveNoteActive: false)

        _ = policy.tick(hitProbe) // hit 1: armed
        let decision = policy.tick(hitProbe) // hit 2: notify
        XCTAssertEqual(decision, .notify(appName: "Zoom"))
        XCTAssertTrue(policy.notified)

        // App quits (meetingAppName == nil)
        let appQuitProbe = RecordingReminderProbe(meetingAppName: nil, micInUse: true, liveNoteActive: false)
        let quitDecision = policy.tick(appQuitProbe)
        XCTAssertEqual(quitDecision, .idle)
        XCTAssertEqual(policy.consecutiveHits, 0)
        XCTAssertFalse(policy.notified, "Policy must clear notified flag when meeting app terminates")

        // New meeting starts -> should be able to arm and notify again
        _ = policy.tick(hitProbe)
        let secondNotify = policy.tick(hitProbe)
        XCTAssertEqual(secondNotify, .notify(appName: "Zoom"))
        XCTAssertTrue(policy.notified)
    }

    func testPolicyClearHitsPreservesNotified() {
        var policy = RecordingReminderPolicy()
        let hitProbe = RecordingReminderProbe(meetingAppName: "Zoom", micInUse: true, liveNoteActive: false)

        _ = policy.tick(hitProbe)
        _ = policy.tick(hitProbe)
        XCTAssertTrue(policy.notified)

        policy.clearHits()
        XCTAssertEqual(policy.consecutiveHits, 0)
        XCTAssertTrue(policy.notified, "clearHits must preserve notified state")

        // Next hit should be suppressed because notified remains true
        let decision = policy.tick(hitProbe)
        XCTAssertEqual(decision, .suppressed)
        XCTAssertTrue(policy.notified)
    }

    func testPolicyRearm() {
        var policy = RecordingReminderPolicy()
        let hitProbe = RecordingReminderProbe(meetingAppName: "Zoom", micInUse: true, liveNoteActive: false)

        _ = policy.tick(hitProbe)
        let decision1 = policy.tick(hitProbe)
        XCTAssertEqual(decision1, .notify(appName: "Zoom"))
        XCTAssertTrue(policy.notified)
        XCTAssertEqual(policy.consecutiveHits, 2)

        policy.rearm()
        XCTAssertFalse(policy.notified)
        XCTAssertEqual(policy.consecutiveHits, 0)

        // After rearm, two hits should trigger notify again
        let decision2 = policy.tick(hitProbe)
        XCTAssertEqual(decision2, .armed)
        let decision3 = policy.tick(hitProbe)
        XCTAssertEqual(decision3, .notify(appName: "Zoom"))
        XCTAssertTrue(policy.notified)
    }

    // MARK: - Async Test Helper

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if !condition() {
            XCTFail("Timed out waiting for condition after \(timeout)s", file: file, line: line)
        }
    }

    // MARK: - Controller Tests

    func testRecordingReminderNotifiesExactlyOnceAfterTwoHits() async {
        let fakeProbe = FakeRecordingReminderProbe()
        let fakeNotifier = FakeRecordingReminderNotifier()

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 60
        )

        // Hit 1: Armed (no delivery yet)
        reminder.tickNow()
        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0)
        XCTAssertNil(reminder.statusMessage)

        // Hit 2: Delivery triggered
        reminder.tickNow()
        await waitUntil { fakeNotifier.deliveredAppNames == ["Zoom"] }
        XCTAssertNil(reminder.statusMessage)

        // Hit 3: Suppressed (no further delivery)
        reminder.tickNow()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fakeNotifier.deliveredAppNames, ["Zoom"])
    }

    func testRecordingReminderDeliveryGatedOnAuthorizationGranted() async {
        let fakeProbe = FakeRecordingReminderProbe()
        let fakeNotifier = FakeRecordingReminderNotifier()
        fakeNotifier.holdAuthorization = true

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 60
        )

        // Two hits while authorization response is pending
        reminder.tickNow()
        reminder.tickNow()
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Gated: delivery must NOT have happened while authorization is held
        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0)
        XCTAssertNil(reminder.statusMessage)

        // Release authorization as granted
        fakeNotifier.releaseAuthorization(granted: true)
        await waitUntil { fakeNotifier.deliveredAppNames == ["Zoom"] }
        XCTAssertNil(reminder.statusMessage)
    }

    func testRecordingReminderDeliveryGatedOnAuthorizationDenied() async {
        let fakeProbe = FakeRecordingReminderProbe()
        let fakeNotifier = FakeRecordingReminderNotifier()
        fakeNotifier.holdAuthorization = true

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 60
        )

        // Two hits while authorization response is pending
        reminder.tickNow()
        reminder.tickNow()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0)

        // Release authorization as denied
        fakeNotifier.releaseAuthorization(granted: false)
        await waitUntil {
            reminder.statusMessage == "Notifications are off for LiveNote in System Settings > Notifications."
        }
        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0)
    }

    func testRecordingReminderNotifiesAgainAfterMeetingAppTerminated() async {
        let fakeProbe = FakeRecordingReminderProbe()
        let fakeNotifier = FakeRecordingReminderNotifier()

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 60
        )

        reminder.tickNow()
        reminder.tickNow()
        await waitUntil { fakeNotifier.deliveredAppNames == ["Zoom"] }

        // Meeting app terminates
        reminder.meetingAppTerminated()

        // Next meeting starts: 2 ticks needed
        reminder.tickNow()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 1)

        reminder.tickNow()
        await waitUntil { fakeNotifier.deliveredAppNames == ["Zoom", "Zoom"] }
    }

    func testRecordingReminderDoesNotNotifyWhenLiveNoteIsActive() async {
        let fakeProbe = FakeRecordingReminderProbe()
        fakeProbe.liveNoteActive = true
        let fakeNotifier = FakeRecordingReminderNotifier()

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 60
        )

        reminder.tickNow()
        reminder.tickNow()
        reminder.tickNow()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0)
    }

    func testRecordingReminderAuthorizationDenied() async {
        let fakeProbe = FakeRecordingReminderProbe()
        let fakeNotifier = FakeRecordingReminderNotifier()
        fakeNotifier.authGranted = false

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 60
        )

        reminder.tickNow()
        await Task.yield()

        reminder.tickNow()
        await waitUntil {
            reminder.statusMessage == "Notifications are off for LiveNote in System Settings > Notifications."
        }
        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0)
    }

    func testRealDeliveryFailureDoesNotRearm() async {
        struct SampleError: LocalizedError {
            var errorDescription: String? { "User notification service error" }
        }

        let fakeProbe = FakeRecordingReminderProbe()
        let fakeNotifier = FakeRecordingReminderNotifier()
        fakeNotifier.deliveryError = SampleError()

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 60
        )

        reminder.tickNow()
        reminder.tickNow()
        await waitUntil {
            reminder.statusMessage == "Notification delivery failed: User notification service error"
        }
        XCTAssertEqual(fakeNotifier.deliveredAppNames, ["Zoom"])

        // Two more ticks -> still 1 attempt (post-submit failure does not rearm)
        reminder.tickNow()
        reminder.tickNow()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fakeNotifier.deliveredAppNames, ["Zoom"])
    }

    func testRecordingReminderSetEnabledStopsAndClearsState() {
        let fakeProbe = FakeRecordingReminderProbe()
        let fakeNotifier = FakeRecordingReminderNotifier()

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 60
        )

        reminder.setEnabled(false)
        XCTAssertFalse(reminder.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: "recordingReminderEnabled"))

        reminder.tickNow()
        XCTAssertEqual(fakeProbe.probeCallCount, 0)

        reminder.setEnabled(true)
        XCTAssertTrue(reminder.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: "recordingReminderEnabled"))
        reminder.stop()
    }

    func testRecordingReminderToggleDuringMeetingKeepsNotifiedSuppression() async {
        let fakeProbe = FakeRecordingReminderProbe()
        let fakeNotifier = FakeRecordingReminderNotifier()

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 60
        )

        // 1. Two hits => 1 delivery
        reminder.tickNow()
        reminder.tickNow()
        await waitUntil { fakeNotifier.deliveredAppNames == ["Zoom"] }

        // 2. Toggle off and on during the same meeting
        reminder.setEnabled(false)
        reminder.setEnabled(true)

        // 3. Two hits with the same probe => still 1 delivery (suppressed)
        reminder.tickNow()
        reminder.tickNow()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fakeNotifier.deliveredAppNames, ["Zoom"])

        // 4. Meeting app terminates => resets state
        reminder.meetingAppTerminated()

        // 5. Two hits in new meeting => 2 deliveries
        reminder.tickNow()
        reminder.tickNow()
        await waitUntil { fakeNotifier.deliveredAppNames == ["Zoom", "Zoom"] }
    }

    func testRecordingReminderTimerTicksAndDoesNotDoubleTickOnStart() async {
        let fakeProbe = FakeRecordingReminderProbe()
        let fakeNotifier = FakeRecordingReminderNotifier()

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 0.05
        )

        reminder.start()
        reminder.start() // Idempotency check

        await waitUntil { fakeProbe.probeCallCount >= 2 }
        reminder.stop()
        let finalCount = fakeProbe.probeCallCount
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(fakeProbe.probeCallCount, finalCount, "Timer should not tick after stop")
    }

    func testRecordingReminderAuthorizationSingleFlightAcrossMeetings() async {
        let fakeProbe = FakeRecordingReminderProbe()
        let fakeNotifier = FakeRecordingReminderNotifier()
        fakeNotifier.holdAuthorization = true

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 60
        )

        // Two hits while auth is held
        reminder.tickNow()
        reminder.tickNow()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(fakeNotifier.requestAuthCallCount, 1)
        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0)

        // Release authorization granted -> 1 delivery
        fakeNotifier.releaseAuthorization(granted: true)
        await waitUntil { fakeNotifier.deliveredAppNames == ["Zoom"] }
        XCTAssertEqual(fakeNotifier.requestAuthCallCount, 1)

        // Meeting terminates
        reminder.meetingAppTerminated()

        // Two hits for next meeting -> auth call count remains 1 and second delivery occurs
        reminder.tickNow()
        reminder.tickNow()
        await waitUntil { fakeNotifier.deliveredAppNames == ["Zoom", "Zoom"] }
        XCTAssertEqual(fakeNotifier.requestAuthCallCount, 1)
    }

    func testRecordingReminderPendingAuthStaleOnSetEnabledFalse() async {
        let fakeProbe = FakeRecordingReminderProbe()
        let fakeNotifier = FakeRecordingReminderNotifier()
        fakeNotifier.holdAuthorization = true

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 60
        )

        reminder.tickNow()
        reminder.tickNow()
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Disable reminder while auth is held
        reminder.setEnabled(false)

        // Release auth as granted -> 0 deliveries (stale dropped)
        fakeNotifier.releaseAuthorization(granted: true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0)
    }

    func testRecordingReminderPendingAuthStaleOnMeetingAppTerminated() async {
        let fakeProbe = FakeRecordingReminderProbe()
        let fakeNotifier = FakeRecordingReminderNotifier()
        fakeNotifier.holdAuthorization = true

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 60
        )

        reminder.tickNow()
        reminder.tickNow()
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Meeting app terminated while auth is held
        reminder.meetingAppTerminated()

        // Release auth as granted -> 0 deliveries (stale dropped)
        fakeNotifier.releaseAuthorization(granted: true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0)

        // Next meeting can notify cleanly
        reminder.tickNow()
        reminder.tickNow()
        await waitUntil { fakeNotifier.deliveredAppNames == ["Zoom"] }
    }

    func testRecordingReminderPendingAuthStaleOnMeetingEndDetectedByTick() async {
        let fakeProbe = FakeRecordingReminderProbe()
        let fakeNotifier = FakeRecordingReminderNotifier()
        fakeNotifier.holdAuthorization = true

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 60
        )

        reminder.tickNow()
        reminder.tickNow()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0)

        // Meeting end detected by tick (meetingAppName becomes nil)
        fakeProbe.meetingAppName = nil
        reminder.tickNow()

        // Release authorization as granted
        fakeNotifier.releaseAuthorization(granted: true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0, "Delivery must be dropped when meeting ended on tick before auth was granted")
    }

    func testConditionDropWhileAwaitingAuthorizationCancelsIntentAndRearms() async {
        let fakeProbe = FakeRecordingReminderProbe()
        let fakeNotifier = FakeRecordingReminderNotifier()
        fakeNotifier.holdAuthorization = true

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 60
        )

        // Two hits while auth is held
        reminder.tickNow()
        reminder.tickNow()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0)

        // Mic becomes idle while auth is still pending -> cancels pendingDelivery and rearms policy
        fakeProbe.micInUse = false
        reminder.tickNow()

        // Release authorization as granted
        fakeNotifier.releaseAuthorization(granted: true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0, "No delivery should occur when condition dropped during auth")

        // Mic becomes active again -> 2 ticks needed to notify
        fakeProbe.micInUse = true
        reminder.tickNow()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0)

        reminder.tickNow()
        await waitUntil { fakeNotifier.deliveredAppNames == ["Zoom"] }
        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 1)
    }

    func testDeliverySkipRearmsPolicy() async {
        let fakeProbe = FakeRecordingReminderProbe()
        let fakeNotifier = FakeRecordingReminderNotifier()
        fakeNotifier.authGranted = true

        let reminder = RecordingReminder(
            probe: fakeProbe,
            notifier: fakeNotifier,
            defaults: defaults,
            tickInterval: 60
        )

        // Hit 1
        reminder.tickNow()
        XCTAssertEqual(fakeProbe.probeCallCount, 1)
        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0)
        await Task.yield()

        // After hit 2 decision, probe flips liveNoteActive = true for future probes right before deliver
        fakeProbe.onProbe = { count in
            if count > 2 {
                fakeProbe.liveNoteActive = true
            }
        }

        // Hit 2: triggers .notify decision, which immediately re-probes in deliver() -> skipped & rearmed
        reminder.tickNow()
        await waitUntil { fakeProbe.probeCallCount >= 3 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 0, "Delivery should be skipped when condition no longer holds right before deliver")

        // Reset liveNoteActive and remove onProbe override
        fakeProbe.onProbe = nil
        fakeProbe.liveNoteActive = false

        // Two more ticks should re-trigger delivery
        reminder.tickNow()
        reminder.tickNow()
        await waitUntil { fakeNotifier.deliveredAppNames == ["Zoom"] }
        XCTAssertEqual(fakeNotifier.deliveredAppNames.count, 1)
    }
}
