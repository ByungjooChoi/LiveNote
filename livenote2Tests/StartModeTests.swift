import XCTest

@testable import LiveNote

/// Phase 0.5: 대면 회의 모드의 오디오 라우팅 결정과 모델 직렬화.
final class StartModeTests: XCTestCase {

    func testOnlineModeSendsMicToMeChannel() {
        XCTAssertEqual(AppState.micIngestChannel(for: .online), .me)
    }

    func testInPersonModeSendsMicToThemChannel() {
        XCTAssertEqual(AppState.micIngestChannel(for: .inPerson), .them)
    }

    func testRawValues() {
        XCTAssertEqual(StartMode.online.rawValue, "online")
        XCTAssertEqual(StartMode.inPerson.rawValue, "inPerson")
        XCTAssertEqual(StartMode(rawValue: "inPerson"), .inPerson)
        XCTAssertNil(StartMode(rawValue: "hybrid"))
    }

    func testCodableRoundTrip() throws {
        for mode in [StartMode.online, .inPerson] {
            let data = try JSONEncoder().encode(mode)
            XCTAssertEqual(try JSONDecoder().decode(StartMode.self, from: data), mode)
        }
    }
}
