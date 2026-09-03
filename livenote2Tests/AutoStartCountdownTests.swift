import XCTest

@testable import LiveNote

/// Phase 0.6: 자동 시작 카운트다운 결정과 설정 기본값.
final class AutoStartCountdownTests: XCTestCase {

    // MARK: - 지연 결정

    func testCountdownEnabledDelaysFiveSeconds() {
        XCTAssertEqual(AppState.autoStartDelay(countdownEnabled: true), 5)
        XCTAssertEqual(AppState.autoStartDelay(countdownEnabled: true),
                       AppState.autoStartCountdownSeconds)
    }

    func testCountdownDisabledStartsImmediately() {
        XCTAssertEqual(AppState.autoStartDelay(countdownEnabled: false), 0)
    }

    // MARK: - 설정 기본값 복원

    private func makeDefaults() throws -> UserDefaults {
        let name = "LiveNoteTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testAutoStartAtCalendarTimeDefaultsOff() throws {
        let defaults = try makeDefaults()
        XCTAssertFalse(AppState.restoredBool(
            defaults, key: "autoStartAtCalendarTime", default: false))
    }

    func testAutoStartCountdownDefaultsOn() throws {
        let defaults = try makeDefaults()
        XCTAssertTrue(AppState.restoredBool(defaults, key: "autoStartCountdown", default: true))
    }

    func testStoredFalseOverridesDefaultOn() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: "autoStartCountdown")
        XCTAssertFalse(AppState.restoredBool(defaults, key: "autoStartCountdown", default: true))
    }

    func testStoredTrueOverridesDefaultOff() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: "autoStartAtCalendarTime")
        XCTAssertTrue(AppState.restoredBool(
            defaults, key: "autoStartAtCalendarTime", default: false))
    }

    // MARK: - 시작 통지 키 정리 (끝난 회의는 버린다)

    @MainActor
    func testPrunedNotifiedKeysDropsEndedMeetings() {
        let now = Date()
        let keys = [
            "past": now.addingTimeInterval(-60),
            "ongoing": now.addingTimeInterval(600),
        ]
        let pruned = CalendarMonitor.prunedNotifiedKeys(keys, now: now)
        XCTAssertEqual(Array(pruned.keys), ["ongoing"])
    }

    @MainActor
    func testPrunedNotifiedKeysKeepsMeetingEndingNow() {
        let now = Date()
        let pruned = CalendarMonitor.prunedNotifiedKeys(["edge": now], now: now)
        XCTAssertEqual(pruned.count, 1)
    }

    // MARK: - 패널 남은 초 표기

    func testRemainingSecondsRoundsUp() {
        let now = Date()
        XCTAssertEqual(
            CountdownView.remainingSeconds(deadline: now.addingTimeInterval(4.2), now: now), 5)
        XCTAssertEqual(
            CountdownView.remainingSeconds(deadline: now.addingTimeInterval(0.1), now: now), 1)
    }

    func testRemainingSecondsNeverNegative() {
        let now = Date()
        XCTAssertEqual(
            CountdownView.remainingSeconds(deadline: now.addingTimeInterval(-3), now: now), 0)
    }
}
