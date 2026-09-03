import XCTest

// 앱 타깃의 PRODUCT_NAME이 LiveNote이므로 Swift 모듈 이름도 LiveNote다.
// (타깃 이름 livenote2와 다르니 import 시 주의)
@testable import LiveNote

/// 테스트 타깃 배선이 살아 있는지 확인하는 최소 스모크 테스트.
/// 앱 모듈 타입(TranscriptRow)을 건드려 @testable import가 동작함을 증명한다.
final class SmokeTests: XCTestCase {

    func testTranscriptRowTimeLabelFormatsMinutesAndSeconds() {
        let row = TranscriptRow(
            id: UUID(),
            channel: .me,
            speakerSlot: nil,
            speakerName: nil,
            english: "hello",
            korean: nil,
            startSeconds: 125,
            endSeconds: 130
        )

        XCTAssertEqual(row.timeLabel, "02:05")
        XCTAssertEqual(row.channel, .me)
    }
}
