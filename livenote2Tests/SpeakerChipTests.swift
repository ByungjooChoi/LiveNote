import XCTest
@testable import LiveNote

final class SpeakerChipTests: XCTestCase {
    func testIconMapping() {
        XCTAssertEqual(SpeakerChipLabel.icon(for: .zoom), "video")
        XCTAssertEqual(SpeakerChipLabel.icon(for: .voice), "waveform")
        XCTAssertEqual(SpeakerChipLabel.icon(for: .manual), "pencil")
        XCTAssertNil(SpeakerChipLabel.icon(for: .slot))
        XCTAssertNil(SpeakerChipLabel.icon(for: nil))
    }
}
