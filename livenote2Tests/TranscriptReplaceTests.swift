import XCTest
@testable import LiveNote

final class TranscriptReplaceTests: XCTestCase {

    func testCaseSensitivity() {
        let text = "Apple and apple and APPLE"
        let insensitiveOptions = TranscriptReplace.Options(caseSensitive: false, wholeWord: false)
        let sensitiveOptions = TranscriptReplace.Options(caseSensitive: true, wholeWord: false)

        XCTAssertEqual(TranscriptReplace.matchCount(in: text, find: "apple", options: insensitiveOptions), 3)
        XCTAssertEqual(TranscriptReplace.matchCount(in: text, find: "apple", options: sensitiveOptions), 1)

        let replaced = TranscriptReplace.replace(in: text, find: "apple", replacement: "Orange", options: insensitiveOptions)
        XCTAssertEqual(replaced, "Orange and Orange and Orange")
    }

    func testWholeWordMatching() {
        let text = "Craig went to Craigslist with Craig."
        let wholeWordOptions = TranscriptReplace.Options(caseSensitive: false, wholeWord: true)
        let partialOptions = TranscriptReplace.Options(caseSensitive: false, wholeWord: false)

        XCTAssertEqual(TranscriptReplace.matchCount(in: text, find: "Craig", options: wholeWordOptions), 2)
        XCTAssertEqual(TranscriptReplace.matchCount(in: text, find: "Craig", options: partialOptions), 3)

        let replaced = TranscriptReplace.replace(in: text, find: "Craig", replacement: "John", options: wholeWordOptions)
        XCTAssertEqual(replaced, "John went to Craigslist with John.")
    }

    func testNonWordSymbolFallback() {
        let text = "We write C++ code and C++20 standard."
        let options = TranscriptReplace.Options(caseSensitive: false, wholeWord: true)

        // C++ ends in '+' which is non-word, so whole word degrades to plain substring matching
        XCTAssertEqual(TranscriptReplace.matchCount(in: text, find: "C++", options: options), 2)
        let replaced = TranscriptReplace.replace(in: text, find: "C++", replacement: "Swift", options: options)
        XCTAssertEqual(replaced, "We write Swift code and Swift20 standard.")
    }

    func testLiteralReplacementWithTemplateSymbols() {
        let text = "The price is USD 100."
        let options = TranscriptReplace.Options(caseSensitive: false, wholeWord: false)

        // $1 should be treated literally, not as regex capture group
        let replaced = TranscriptReplace.replace(in: text, find: "USD 100", replacement: "$100 ($1 bill)", options: options)
        XCTAssertEqual(replaced, "The price is $100 ($1 bill).")
    }

    func testEmptyFindYieldsZeroMatches() {
        let text = "Some sample text"
        let options = TranscriptReplace.Options(caseSensitive: false, wholeWord: false)

        XCTAssertEqual(TranscriptReplace.matchCount(in: text, find: "", options: options), 0)
        XCTAssertEqual(TranscriptReplace.matchCount(in: text, find: "   ", options: options), 0)
        XCTAssertEqual(TranscriptReplace.replace(in: text, find: "", replacement: "abc", options: options), text)
    }

    func testMatchesInRows() {
        let row1 = TranscriptRow(
            id: UUID(),
            channel: .me,
            english: "Hello world",
            korean: "안녕하세요 세계",
            startSeconds: 0,
            endSeconds: 2
        )
        let row2 = TranscriptRow(
            id: UUID(),
            channel: .them,
            english: "Another sentence without the term",
            korean: nil,
            startSeconds: 2,
            endSeconds: 5
        )
        let row3 = TranscriptRow(
            id: UUID(),
            channel: .them,
            english: "World of wonders world",
            korean: "경이로운 세계",
            startSeconds: 5,
            endSeconds: 8
        )

        let options = TranscriptReplace.Options(caseSensitive: false, wholeWord: true)
        let matches = TranscriptReplace.matches(in: [row1, row2, row3], find: "world", options: options)

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].rowID, row1.id)
        XCTAssertEqual(matches[0].count, 1)
        XCTAssertEqual(matches[1].rowID, row3.id)
        XCTAssertEqual(matches[1].count, 2)
    }

    // MARK: - JargonSuggestion Tests

    func testJargonSuggestionTruthTable() {
        let existing = "Swift, Kotlin, LiveNote"

        // Harvinder: uppercase first, not in existing -> true
        XCTAssertTrue(JargonSuggestion.shouldSuggest(replacement: "Harvinder", existingJargon: existing))

        // API: all uppercase/digits with at least one letter -> true
        XCTAssertTrue(JargonSuggestion.shouldSuggest(replacement: "API", existingJargon: existing))

        // Q2: starts with upper and has digit -> true
        XCTAssertTrue(JargonSuggestion.shouldSuggest(replacement: "Q2", existingJargon: existing))

        // 2026: digit-only token -> false
        XCTAssertFalse(JargonSuggestion.shouldSuggest(replacement: "2026", existingJargon: existing))

        // Q2Revenue: starts with upper -> true
        XCTAssertTrue(JargonSuggestion.shouldSuggest(replacement: "Q2Revenue", existingJargon: existing))

        // craig: starts with lowercase, not all uppercase -> false
        XCTAssertFalse(JargonSuggestion.shouldSuggest(replacement: "craig", existingJargon: existing))

        // two words: whitespace -> false
        XCTAssertFalse(JargonSuggestion.shouldSuggest(replacement: "two words", existingJargon: existing))

        // A: single character (< 2) -> false
        XCTAssertFalse(JargonSuggestion.shouldSuggest(replacement: "A", existingJargon: existing))

        // swift: case-insensitive match with existing -> false
        XCTAssertFalse(JargonSuggestion.shouldSuggest(replacement: "swift", existingJargon: existing))
        XCTAssertFalse(JargonSuggestion.shouldSuggest(replacement: "Swift", existingJargon: existing))
    }

    func testJargonAppending() {
        let existing = "Apple, Banana"

        let updated = JargonSuggestion.appending("Cherry", to: existing)
        XCTAssertEqual(updated, "Apple, Banana, Cherry")

        // Duplicate term should not be added
        let dup = JargonSuggestion.appending("banana", to: updated)
        XCTAssertEqual(dup, "Apple, Banana, Cherry")

        // Empty existing
        let fromEmpty = JargonSuggestion.appending("LiveNote", to: "")
        XCTAssertEqual(fromEmpty, "LiveNote")
    }
}
