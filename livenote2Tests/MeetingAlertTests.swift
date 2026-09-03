import XCTest

@testable import LiveNote

/// Phase 0.3: 알림 팝업 분할 버튼의 플랫폼 이름 결정.
@MainActor
final class MeetingAlertTests: XCTestCase {

    private func name(_ link: String) -> String {
        MeetingAlertView.platformName(for: URL(string: link))
    }

    func testZoomHost() {
        XCTAssertEqual(name("https://zoom.us/j/123456789"), "Zoom")
    }

    func testZoomSubdomainHost() {
        XCTAssertEqual(name("https://elastic.zoom.us/j/123456789?pwd=abc"), "Zoom")
    }

    func testZoomUppercaseHostIsNormalized() {
        XCTAssertEqual(name("https://Company.Zoom.US/j/987"), "Zoom")
    }

    func testCompanySubdomainIsZoom() {
        XCTAssertEqual(name("https://company.zoom.us/j/123"), "Zoom")
    }

    func testTeamsHost() {
        XCTAssertEqual(name("https://teams.microsoft.com/l/meetup-join/19%3ameeting"), "Teams")
        XCTAssertEqual(name("https://teams.live.com/meet/9876543"), "Teams")
    }

    func testGoogleMeetHost() {
        XCTAssertEqual(name("https://meet.google.com/abc-defg-hij"), "Meet")
    }

    func testWebexHost() {
        XCTAssertEqual(name("https://elastic.webex.com/meet/philip"), "Webex")
    }

    func testUnknownHostFallsBackToMeeting() {
        XCTAssertEqual(name("https://example.com/room/42"), "meeting")
    }

    // MARK: - 호스트 오인식 방지 (부분 문자열이 아니라 도메인 일치)

    func testLookalikeZoomHostIsNotZoom() {
        XCTAssertEqual(name("https://notzoom.us/j/123"), "meeting")
        XCTAssertEqual(name("https://zoom.us.evil.example/j/123"), "meeting")
    }

    func testLookalikeTeamsHostIsNotTeams() {
        XCTAssertEqual(name("https://teams.evil.example/l/meetup-join/1"), "meeting")
        XCTAssertEqual(name("https://myteams.microsoft.com.evil.example/x"), "meeting")
    }

    func testLookalikeMeetHostIsNotMeet() {
        XCTAssertEqual(name("https://meet.google.com.evil.example/abc"), "meeting")
    }

    func testLookalikeWebexHostIsNotWebex() {
        XCTAssertEqual(name("https://notwebex.com/meet/philip"), "meeting")
    }

    func testNilURLFallsBackToMeeting() {
        XCTAssertEqual(MeetingAlertView.platformName(for: nil), "meeting")
    }

    /// 링크 감지(firstZoomLink)로 얻은 URL이 그대로 플랫폼 이름으로 이어지는지.
    func testPlatformNameMatchesDetectedLink() {
        let notes = "Join here: https://elastic.webex.com/meet/philip"
        let link = CalendarMonitor.firstZoomLink(in: [nil, nil, notes])
        XCTAssertEqual(MeetingAlertView.platformName(for: link), "Webex")
    }
}
