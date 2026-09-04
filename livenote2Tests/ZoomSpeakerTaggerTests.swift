import XCTest
@testable import LiveNote

final class ZoomSpeakerTaggerTests: XCTestCase {

    func testShortNameStripsSuffixesAndWhitespace() {
        XCTAssertEqual(
            ZoomSpeakerTagger.shortName("Philip Choi @ Elastic SA, Search Specialist"),
            "Philip Choi"
        )
        XCTAssertEqual(
            ZoomSpeakerTagger.shortName("Craig Angulo, 컴퓨터 오디오 음소거 해제됨"),
            "Craig Angulo"
        )
        XCTAssertEqual(
            ZoomSpeakerTagger.shortName("Steve Mayzak | VP Engineering"),
            "Steve Mayzak"
        )
        XCTAssertEqual(
            ZoomSpeakerTagger.shortName("   Simple Name   "),
            "Simple Name"
        )
    }

    func testNameMatchesUsingSubstringAndWordBootstrap() {
        XCTAssertTrue(
            ZoomSpeakerTagger.nameMatches(
                tile: "Philip Choi @ Elastic SA, Search Specialist",
                hint: "Byung joo Choi"
            )
        )
        XCTAssertTrue(
            ZoomSpeakerTagger.nameMatches(
                tile: "Byung joo Choi",
                hint: "byung joo choi"
            )
        )
        XCTAssertFalse(
            ZoomSpeakerTagger.nameMatches(
                tile: "Craig Angulo",
                hint: "Bo Li"
            )
        )
    }

    func testAccessibilitySettingsURLIsValidAndPointsToPrivacyAccessibility() {
        let url = ZoomSpeakerTagger.accessibilitySettingsURL
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertTrue(url.absoluteString.contains("Privacy_Accessibility"))
        XCTAssertEqual(url.query, "Privacy_Accessibility")
    }

    func testResolveMyNamePriority() {
        XCTAssertEqual(
            AppState.resolveMyName(persistedZoomName: "Philip Choi", accountName: "Byung joo Choi"),
            "Philip Choi"
        )
        XCTAssertEqual(
            AppState.resolveMyName(persistedZoomName: "  Philip Choi  ", accountName: "Byung joo Choi"),
            "Philip Choi"
        )

        XCTAssertEqual(
            AppState.resolveMyName(persistedZoomName: nil, accountName: "Byung joo Choi"),
            "Byung joo Choi"
        )
        XCTAssertEqual(
            AppState.resolveMyName(persistedZoomName: "", accountName: "Byung joo Choi"),
            "Byung joo Choi"
        )
        XCTAssertEqual(
            AppState.resolveMyName(persistedZoomName: "   ", accountName: "Byung joo Choi"),
            "Byung joo Choi"
        )

        XCTAssertEqual(
            AppState.resolveMyName(persistedZoomName: nil, accountName: ""),
            "Me"
        )
        XCTAssertEqual(
            AppState.resolveMyName(persistedZoomName: "   ", accountName: "   "),
            "Me"
        )
    }
}
