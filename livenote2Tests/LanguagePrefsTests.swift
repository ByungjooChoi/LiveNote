import XCTest
@testable import LiveNote

final class LanguagePrefsTests: XCTestCase {

    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.byungjoo.livenote2.test.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultEnglishOnEmptySuite() {
        XCTAssertEqual(LanguagePrefs.summaryLanguage(defaults: testDefaults), "English")
    }

    func testStoredKoreanWithoutFlagMigratesToEnglishAndSetsFlag() {
        testDefaults.set("Korean", forKey: "summaryLanguage")
        XCTAssertFalse(testDefaults.bool(forKey: "summaryLanguageResetToEnglish.v1"))

        LanguagePrefs.migrateSummaryLanguageDefault(defaults: testDefaults)

        XCTAssertEqual(LanguagePrefs.summaryLanguage(defaults: testDefaults), "English")
        XCTAssertTrue(testDefaults.bool(forKey: "summaryLanguageResetToEnglish.v1"))
    }

    func testStoredKoreanWithFlagAlreadySetStaysKorean() {
        testDefaults.set(true, forKey: "summaryLanguageResetToEnglish.v1")
        testDefaults.set("Korean", forKey: "summaryLanguage")

        LanguagePrefs.migrateSummaryLanguageDefault(defaults: testDefaults)

        XCTAssertEqual(LanguagePrefs.summaryLanguage(defaults: testDefaults), "Korean")
    }

    func testMigrateTwiceIsIdempotent() {
        testDefaults.set("Korean", forKey: "summaryLanguage")

        LanguagePrefs.migrateSummaryLanguageDefault(defaults: testDefaults)
        XCTAssertEqual(LanguagePrefs.summaryLanguage(defaults: testDefaults), "English")

        // User explicitly sets Korean after migration
        testDefaults.set("Korean", forKey: "summaryLanguage")

        // Second migration invocation should not reset
        LanguagePrefs.migrateSummaryLanguageDefault(defaults: testDefaults)
        XCTAssertEqual(LanguagePrefs.summaryLanguage(defaults: testDefaults), "Korean")
    }

    func testTranslationLanguageDefaultKoreanUnchanged() {
        XCTAssertEqual(LanguagePrefs.translationLanguage(defaults: testDefaults), "Korean")
        XCTAssertEqual(LanguagePrefs.translationCode(defaults: testDefaults), "ko")
    }
}
