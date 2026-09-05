import XCTest

@testable import LiveNote

@MainActor
final class TaskOwnerNormalizerTests: XCTestCase {

    func testNormalizeSelfTokens() {
        let attendees = [Attendee(name: "Craig Angulo", email: "craig@apple.com")]
        let speakerNames = ["Alice", "Bob"]
        let myName = "Byungjoo Choi"

        XCTAssertEqual(TaskOwnerNormalizer.normalize("me", attendees: attendees, speakerNames: speakerNames, myName: myName), "Byungjoo Choi")
        XCTAssertEqual(TaskOwnerNormalizer.normalize("I", attendees: attendees, speakerNames: speakerNames, myName: myName), "Byungjoo Choi")
        XCTAssertEqual(TaskOwnerNormalizer.normalize("나", attendees: attendees, speakerNames: speakerNames, myName: myName), "Byungjoo Choi")
        XCTAssertEqual(TaskOwnerNormalizer.normalize("myself", attendees: attendees, speakerNames: speakerNames, myName: myName), "Byungjoo Choi")
        XCTAssertEqual(TaskOwnerNormalizer.normalize("  ME  ", attendees: attendees, speakerNames: speakerNames, myName: myName), "Byungjoo Choi")
    }

    func testNormalizeViaAttendeeNameAndEmail() {
        let attendees = [
            Attendee(name: "Craig Angulo", email: "craig.angulo@apple.com"),
            Attendee(name: "Herminder Singh", email: "singh_h@company.com")
        ]
        let speakerNames = ["Speaker 1"]
        let myName = "Byungjoo"

        // Token match on attendee name
        XCTAssertEqual(TaskOwnerNormalizer.normalize("craig", attendees: attendees, speakerNames: speakerNames, myName: myName), "Craig Angulo")
        XCTAssertEqual(TaskOwnerNormalizer.normalize("Craig", attendees: attendees, speakerNames: speakerNames, myName: myName), "Craig Angulo")
        XCTAssertEqual(TaskOwnerNormalizer.normalize("Angulo", attendees: attendees, speakerNames: speakerNames, myName: myName), "Craig Angulo")

        // Email local-part token match
        XCTAssertEqual(TaskOwnerNormalizer.normalize("singh", attendees: attendees, speakerNames: speakerNames, myName: myName), "Herminder Singh")
    }

    func testNormalizeViaSpeakerNamesAndMyName() {
        let attendees: [Attendee] = []
        let speakerNames = ["Alice Johnson", "Speaker 2"]
        let myName = "Byungjoo"

        XCTAssertEqual(TaskOwnerNormalizer.normalize("alice", attendees: attendees, speakerNames: speakerNames, myName: myName), "Alice Johnson")
        XCTAssertEqual(TaskOwnerNormalizer.normalize("byungjoo", attendees: attendees, speakerNames: speakerNames, myName: myName), "Byungjoo")
    }

    func testNormalizeUnknownStaysRaw() {
        let attendees = [Attendee(name: "Craig Angulo", email: nil)]
        let speakerNames = ["Alice"]
        let myName = "Byungjoo"

        XCTAssertEqual(TaskOwnerNormalizer.normalize("David", attendees: attendees, speakerNames: speakerNames, myName: myName), "David")
        XCTAssertEqual(TaskOwnerNormalizer.normalize("  Custom Partner  ", attendees: attendees, speakerNames: speakerNames, myName: myName), "Custom Partner")
        XCTAssertNil(TaskOwnerNormalizer.normalize(nil, attendees: attendees, speakerNames: speakerNames, myName: myName))
        XCTAssertNil(TaskOwnerNormalizer.normalize("   ", attendees: attendees, speakerNames: speakerNames, myName: myName))
    }

    func testTokens() {
        let tokens1 = TaskOwnerNormalizer.tokens("Craig.Angulo@apple.com")
        XCTAssertEqual(tokens1, ["craig", "angulo", "apple", "com"])

        let tokens2 = TaskOwnerNormalizer.tokens("Alice  Smith-Jones")
        XCTAssertEqual(tokens2, ["alice", "smith", "jones"])
    }
}
