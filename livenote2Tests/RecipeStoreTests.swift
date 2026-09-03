import XCTest

@testable import LiveNote

/// Phase 1.1: 레시피 저장소와 내장 레시피 5종.
@MainActor
final class RecipeStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveNoteRecipeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    // MARK: - 번들 내장 레시피

    func testBuiltinRecipesLoadFromBundle() throws {
        for id in RecipeStore.builtinIDs {
            let recipe = try XCTUnwrap(RecipeStore.loadBuiltin(id: id), "번들에 \(id).json 없음")
            XCTAssertEqual(recipe.id, id)
            XCTAssertTrue(recipe.builtin, "\(id) builtin 플래그")
            XCTAssertFalse(recipe.title.isEmpty)
            XCTAssertFalse(recipe.icon.isEmpty)
            XCTAssertTrue(recipe.prompt.contains("{{meetings}}"), "\(id) 프롬프트에 {{meetings}} 없음")
            XCTAssertFalse(recipe.system.isEmpty)
        }
    }

    func testBuiltinRecipeMetadataMatchesProductPlan() throws {
        let expected: [String: (RecipeScopeDefault, RecipeModelHint, String, String)] = [
            "weekly-update": (.thisWeek, .thinking, "Korean", "doc.text"),
            "follow-up-email": (.currentMeeting, .standard, "English", "envelope"),
            "open-commitments": (.lastDays(14), .thinking, "Korean", "checklist"),
            "customer-call-brief": (.currentMeeting, .standard, "English", "person.2"),
            "korean-digest": (.currentMeeting, .standard, "Korean", "text.alignleft"),
        ]
        for (id, want) in expected {
            let recipe = try XCTUnwrap(RecipeStore.loadBuiltin(id: id))
            XCTAssertEqual(recipe.scopeDefault, want.0, id)
            XCTAssertEqual(recipe.modelHint, want.1, id)
            XCTAssertEqual(recipe.outputLanguage, want.2, id)
            XCTAssertEqual(recipe.icon, want.3, id)
        }
        let brief = try XCTUnwrap(RecipeStore.loadBuiltin(id: "customer-call-brief"))
        XCTAssertEqual(brief.title, "Customer call brief (EN)")
    }

    // MARK: - RecipeScopeDefault

    func testScopeDefaultRawStringRoundTrip() {
        let cases: [RecipeScopeDefault] = [.thisWeek, .lastDays(14), .currentMeeting, .manual]
        for scope in cases {
            XCTAssertEqual(RecipeScopeDefault(rawString: scope.rawString), scope)
        }
        XCTAssertEqual(RecipeScopeDefault.lastDays(14).rawString, "lastNDays:14")
        XCTAssertEqual(RecipeScopeDefault.lastDays(7).label, "Last 7 days")
        XCTAssertEqual(RecipeScopeDefault.thisWeek.label, "This week")
        XCTAssertEqual(RecipeScopeDefault.currentMeeting.label, "This meeting")
        XCTAssertEqual(RecipeScopeDefault.manual.label, "Choose...")
    }

    func testScopeDefaultRejectsInvalidRawString() {
        XCTAssertNil(RecipeScopeDefault(rawString: "yesterday"))
        XCTAssertNil(RecipeScopeDefault(rawString: "lastNDays:"))
        XCTAssertNil(RecipeScopeDefault(rawString: "lastNDays:abc"))
        XCTAssertNil(RecipeScopeDefault(rawString: "lastNDays:0"))
    }

    // MARK: - Recipe 코딩

    func testRecipeJSONRoundTrip() throws {
        let recipe = Recipe(
            id: "round-trip", title: "Round trip", icon: "star", builtin: false,
            scopeDefault: .lastDays(30), modelHint: .thinking, outputLanguage: "English",
            system: "sys", prompt: "{{meetings}}")
        let data = try JSONEncoder().encode(recipe)
        XCTAssertEqual(try JSONDecoder().decode(Recipe.self, from: data), recipe)
    }

    func testRecipeDecodesMinimalJSON() throws {
        let json = """
            {"id":"min","title":"Minimal","scopeDefault":"manual",
             "outputLanguage":"Korean","system":"s","prompt":"{{meetings}}"}
            """
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
        XCTAssertEqual(recipe.icon, "doc.text")
        XCTAssertEqual(recipe.modelHint, .standard)
        XCTAssertFalse(recipe.builtin)
        XCTAssertEqual(recipe.scopeDefault, .manual)
    }

    // MARK: - 시딩

    func testSeedCopiesAllBuiltinsOnFirstRun() {
        let store = RecipeStore(rootURL: root)
        XCTAssertEqual(store.recipes.map(\.id).sorted(), RecipeStore.builtinIDs.sorted())
        for id in RecipeStore.builtinIDs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(id).path), id)
        }
    }

    func testSeedKeepsEditedBuiltinAndRestoresDeletedOne() throws {
        let store = RecipeStore(rootURL: root)
        var edited = try XCTUnwrap(store.recipes.first { $0.id == "weekly-update" })
        edited.title = "My weekly"
        store.upsert(edited)
        try FileManager.default.removeItem(at: fileURL("korean-digest"))

        store.seedBuiltinsIfNeeded()
        store.refresh()

        XCTAssertEqual(store.recipes.first { $0.id == "weekly-update" }?.title, "My weekly")
        XCTAssertNotNil(store.recipes.first { $0.id == "korean-digest" })
    }

    func testResetBuiltinsRestoresEditedBuiltinAndKeepsUserRecipe() throws {
        let store = RecipeStore(rootURL: root)
        var edited = try XCTUnwrap(store.recipes.first { $0.id == "weekly-update" })
        let original = edited.title
        edited.title = "My weekly"
        store.upsert(edited)
        store.upsert(makeUserRecipe())

        store.resetBuiltins()

        XCTAssertEqual(store.recipes.first { $0.id == "weekly-update" }?.title, original)
        XCTAssertNotNil(store.recipes.first { $0.id == "mine" })
    }

    // MARK: - 목록 조작

    func testUpsertDeleteAndRefresh() throws {
        let store = RecipeStore(rootURL: root)
        store.upsert(makeUserRecipe())
        XCTAssertNotNil(store.recipes.first { $0.id == "mine" })

        var updated = try XCTUnwrap(store.recipes.first { $0.id == "mine" })
        updated.prompt = "{{meetings}} updated"
        store.upsert(updated)
        store.refresh()
        XCTAssertEqual(store.recipes.first { $0.id == "mine" }?.prompt, "{{meetings}} updated")

        store.delete(id: "mine")
        XCTAssertNil(store.recipes.first { $0.id == "mine" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL("mine").path))
        store.refresh()
        XCTAssertNil(store.recipes.first { $0.id == "mine" })
    }

    func testSortPutsBuiltinsFirstThenTitleAscending() {
        let store = RecipeStore(rootURL: root)
        store.upsert(makeUserRecipe(id: "zeta", title: "Zeta"))
        store.upsert(makeUserRecipe(id: "alpha", title: "alpha"))

        let ids = store.recipes.map(\.id)
        let builtinCount = RecipeStore.builtinIDs.count
        XCTAssertEqual(Set(ids.prefix(builtinCount)), Set(RecipeStore.builtinIDs))
        XCTAssertEqual(Array(ids.suffix(2)), ["alpha", "zeta"])

        let builtinTitles = store.recipes.prefix(builtinCount).map(\.title)
        XCTAssertEqual(builtinTitles, builtinTitles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    func testBuiltinTemplateReturnsBundleOriginal() throws {
        let store = RecipeStore(rootURL: root)
        var edited = try XCTUnwrap(store.recipes.first { $0.id == "korean-digest" })
        edited.system = "changed"
        store.upsert(edited)

        let template = try XCTUnwrap(store.builtinTemplate(id: "korean-digest"))
        XCTAssertNotEqual(template.system, "changed")
        XCTAssertNil(store.builtinTemplate(id: "no-such-recipe"))
    }

    // MARK: - 식별자

    func testSlugFromTitle() {
        XCTAssertEqual(RecipeStore.slug(from: "Weekly Update"), "weekly-update")
        XCTAssertEqual(RecipeStore.slug(from: "  Customer call brief (EN) "), "customer-call-brief-en")
        XCTAssertEqual(RecipeStore.slug(from: "주간 보고"), "주간-보고")
        XCTAssertEqual(RecipeStore.slug(from: "!!!"), "recipe")
    }

    func testUniqueIDAvoidsExistingRecipes() {
        let store = RecipeStore(rootURL: root)
        XCTAssertEqual(store.uniqueID(for: "Korean digest"), "korean-digest-2")
        store.upsert(makeUserRecipe(id: "korean-digest-2", title: "Korean digest"))
        XCTAssertEqual(store.uniqueID(for: "Korean digest"), "korean-digest-3")
        XCTAssertEqual(store.uniqueID(for: "Brand new"), "brand-new")
    }

    // MARK: - helpers

    private func fileURL(_ id: String) -> URL {
        root.appendingPathComponent("\(id).json")
    }

    private func makeUserRecipe(id: String = "mine", title: String = "Mine") -> Recipe {
        Recipe(
            id: id, title: title, scopeDefault: .manual, outputLanguage: "English",
            system: "sys", prompt: "{{meetings}}")
    }
}
