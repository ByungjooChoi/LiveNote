import XCTest
@testable import LiveNote

/// 레시피 대화 첫 턴 표시 문구 (AppState.recipeUserLabel).
@MainActor
final class RecipeLabelTests: XCTestCase {

    func testPluralMeetings() {
        XCTAssertEqual(
            AppState.recipeUserLabel(title: "Weekly Update", scopeLabel: "This week", count: 5),
            "Recipe: Weekly Update (This week, 5 meetings)")
    }

    func testSingularMeeting() {
        XCTAssertEqual(
            AppState.recipeUserLabel(title: "Korean digest", scopeLabel: "This meeting", count: 1),
            "Recipe: Korean digest (This meeting, 1 meeting)")
    }

    func testTruncatedSuffix() {
        XCTAssertEqual(
            AppState.recipeUserLabel(title: "Open commitments", scopeLabel: "Last 14 days", count: 12, truncated: 3),
            "Recipe: Open commitments (Last 14 days, 12 meetings, 3 truncated)")
    }

    func testManualScopeDoesNotRepeatMeetingCount() {
        XCTAssertEqual(
            AppState.recipeUserLabel(title: "Korean digest", scopeLabel: RecipeScope.manual([URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]).label, count: 2),
            "Recipe: Korean digest (2 meetings)")
    }
}
