import Foundation
import Observation

/// 레시피 기본 실행 범위. 파일에는 한 줄 문자열로 저장된다
/// ("thisWeek" / "lastNDays:14" / "currentMeeting" / "manual").
enum RecipeScopeDefault: Equatable, Sendable, Codable {
    case thisWeek
    case lastDays(Int)
    case currentMeeting
    case manual

    private static let lastDaysPrefix = "lastNDays:"

    var rawString: String {
        switch self {
        case .thisWeek: return "thisWeek"
        case .lastDays(let days): return "\(Self.lastDaysPrefix)\(days)"
        case .currentMeeting: return "currentMeeting"
        case .manual: return "manual"
        }
    }

    /// 실행 시트 세그먼트 라벨 (UI 문자열은 영어).
    var label: String {
        switch self {
        case .thisWeek: return "This week"
        case .lastDays(let days): return "Last \(days) days"
        case .currentMeeting: return "This meeting"
        case .manual: return "Choose..."
        }
    }

    init?(rawString: String) {
        switch rawString {
        case "thisWeek": self = .thisWeek
        case "currentMeeting": self = .currentMeeting
        case "manual": self = .manual
        default:
            guard rawString.hasPrefix(Self.lastDaysPrefix) else { return nil }
            let value = String(rawString.dropFirst(Self.lastDaysPrefix.count))
            guard let days = Int(value), days > 0 else { return nil }
            self = .lastDays(days)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let scope = RecipeScopeDefault(rawString: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "알 수 없는 scopeDefault: \(raw)")
        }
        self = scope
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawString)
    }
}

/// 모델 라우팅 힌트. thinking이면 실행 시트가 Thinking 모델을 기본 선택한다.
enum RecipeModelHint: String, Codable, Sendable {
    case standard
    case thinking
}

/// 레시피 한 건: `~/Documents/LiveNote/recipes/<id>.json`
///
/// 구버전·수기 편집 파일과의 호환을 위해 icon / modelHint / builtin은 없어도 디코딩된다.
struct Recipe: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    /// SF Symbol 이름
    var icon: String
    var builtin: Bool
    var scopeDefault: RecipeScopeDefault
    var modelHint: RecipeModelHint
    var outputLanguage: String
    var system: String
    var prompt: String

    static let defaultIcon = "doc.text"

    init(
        id: String,
        title: String,
        icon: String = Recipe.defaultIcon,
        builtin: Bool = false,
        scopeDefault: RecipeScopeDefault,
        modelHint: RecipeModelHint = .standard,
        outputLanguage: String,
        system: String,
        prompt: String
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.builtin = builtin
        self.scopeDefault = scopeDefault
        self.modelHint = modelHint
        self.outputLanguage = outputLanguage
        self.system = system
        self.prompt = prompt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, icon, builtin, scopeDefault, modelHint, outputLanguage, system, prompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? Recipe.defaultIcon
        builtin = try container.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
        scopeDefault = try container.decode(RecipeScopeDefault.self, forKey: .scopeDefault)
        modelHint = try container.decodeIfPresent(RecipeModelHint.self, forKey: .modelHint) ?? .standard
        outputLanguage = try container.decode(String.self, forKey: .outputLanguage)
        system = try container.decode(String.self, forKey: .system)
        prompt = try container.decode(String.self, forKey: .prompt)
    }
}

/// 레시피 저장소 오류. UI는 errorDescription을 그대로 보여준다.
enum RecipeStoreError: LocalizedError, Equatable {
    case invalidID
    case writeFailed(String)
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidID:
            return "Invalid recipe id"
        case .writeFailed(let detail):
            return "Could not save the recipe: \(detail)"
        case .deleteFailed(let detail):
            return "Could not delete the recipe: \(detail)"
        }
    }
}

/// 레시피 저장소: `~/Documents/LiveNote/recipes/` 한 폴더만 읽고 쓴다.
///
/// 내장 레시피는 앱 번들(Resources/Recipes/*.json)에 있고 첫 실행 시 폴더로 복사된다.
/// 사용자가 내장 레시피를 편집하면 그대로 유지되고, 파일을 지우면 다음 실행에 원본이 복원된다.
/// 로그(`recipe` 카테고리)에는 개수·상태·오류만 남기고 프롬프트 내용은 남기지 않는다.
@MainActor
@Observable
final class RecipeStore {

    /// 내장 레시피 첫 노출 순서 기준 목록.
    static let builtinIDs = [
        "weekly-update",
        "follow-up-email",
        "open-commitments",
        "customer-call-brief",
        "korean-digest",
    ]

    /// 내장 우선, 그다음 제목 오름차순(대소문자 무시).
    private(set) var recipes: [Recipe] = []

    let rootURL: URL

    private let bundle: Bundle

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        rootURL = documents.appendingPathComponent("LiveNote/recipes", isDirectory: true)
        bundle = .main
        prepare()
    }

    /// 테스트용: 임시 폴더를 레시피 폴더로 쓰는 저장소.
    init(rootURL: URL, bundle: Bundle = .main) {
        self.rootURL = rootURL
        self.bundle = bundle
        prepare()
    }

    private func prepare() {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        seedBuiltinsIfNeeded()
        refresh()
    }

    // MARK: - 목록

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        var found: [Recipe] = []
        var seenIDs = Set<String>()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            let recipe: Recipe
            do {
                recipe = try JSONDecoder().decode(Recipe.self, from: data)
            } catch {
                AppLog.write("recipe", "레시피 디코딩 실패 \(file.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            // 파일 이름이 곧 id다. 어긋나거나 형식에 맞지 않으면 무시한다
            // (경로 조작 방지, 로그에는 파일 이름만 남긴다).
            let basename = file.deletingPathExtension().lastPathComponent
            guard Self.isValidID(recipe.id), recipe.id == basename else {
                AppLog.write("recipe", "recipe id 불일치 무시 \(file.lastPathComponent)")
                continue
            }
            guard seenIDs.insert(recipe.id).inserted else {
                AppLog.write("recipe", "recipe id 중복 무시 \(file.lastPathComponent)")
                continue
            }
            found.append(recipe)
        }
        recipes = Self.sorted(found)
    }

    private static func sorted(_ list: [Recipe]) -> [Recipe] {
        list.sorted { left, right in
            if left.builtin != right.builtin { return left.builtin }
            let order = left.title.localizedCaseInsensitiveCompare(right.title)
            if order != .orderedSame { return order == .orderedAscending }
            return left.id < right.id
        }
    }

    // MARK: - 쓰기

    /// 파일에 먼저 쓰고, 성공했을 때만 메모리 목록을 갱신한다.
    func upsert(_ recipe: Recipe) throws {
        guard Self.isValidID(recipe.id) else { throw RecipeStoreError.invalidID }
        try write(recipe)
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes[index] = recipe
        } else {
            recipes.append(recipe)
        }
        recipes = Self.sorted(recipes)
    }

    func delete(id: String) throws {
        guard Self.isValidID(id) else { throw RecipeStoreError.invalidID }
        let url = try targetURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw RecipeStoreError.deleteFailed(error.localizedDescription)
            }
        }
        recipes.removeAll { $0.id == id }
    }

    /// 내장 레시피를 번들 원본으로 되돌린다. 사용자 레시피는 건드리지 않는다.
    /// 일부가 실패해도 남은 항목을 계속 복원하고, 첫 실패를 끝에서 던진다.
    func resetBuiltins() throws {
        var restored = 0
        var firstFailure: Error?
        for id in Self.builtinIDs {
            guard let recipe = Self.loadBuiltin(id: id, bundle: bundle) else {
                AppLog.write("recipe", "번들 내장 레시피 없음: \(id)")
                if firstFailure == nil { firstFailure = RecipeStoreError.writeFailed("bundled recipe \(id) is missing") }
                continue
            }
            do {
                try write(recipe)
                restored += 1
            } catch {
                AppLog.write("recipe", "내장 레시피 복원 실패 \(id): \(error.localizedDescription)")
                if firstFailure == nil { firstFailure = error }
            }
        }
        AppLog.write("recipe", "내장 레시피 초기화 \(restored)/\(Self.builtinIDs.count)")
        refresh()
        if let firstFailure { throw firstFailure }
    }

    /// 폴더에 없는 내장 레시피만 복사한다(사용자가 편집한 파일은 유지).
    /// 첫 실행 경로라서 던지지 않고 실패만 기록한다.
    func seedBuiltinsIfNeeded() {
        var seeded = 0
        for id in Self.builtinIDs {
            guard let url = try? targetURL(for: id) else { continue }
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let recipe = Self.loadBuiltin(id: id, bundle: bundle) else {
                AppLog.write("recipe", "번들 내장 레시피 없음: \(id)")
                continue
            }
            do {
                try write(recipe)
                seeded += 1
            } catch {
                AppLog.write("recipe", "내장 레시피 복사 실패 \(id): \(error.localizedDescription)")
            }
        }
        if seeded > 0 {
            AppLog.write("recipe", "내장 레시피 복사 \(seeded)/\(Self.builtinIDs.count)")
        }
    }

    // MARK: - 번들 원본

    static func loadBuiltin(id: String, bundle: Bundle = .main) -> Recipe? {
        let url = bundle.url(forResource: id, withExtension: "json")
            ?? bundle.url(forResource: id, withExtension: "json", subdirectory: "Recipes")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Recipe.self, from: data)
    }

    /// 이 저장소의 번들에서 읽은 원본. 폴더의 편집본과 비교할 때 쓴다.
    func builtinTemplate(id: String) -> Recipe? {
        Self.loadBuiltin(id: id, bundle: bundle)
    }

    // MARK: - 식별자

    /// 제목에서 파일 이름용 슬러그를 만든다. 영숫자·한글은 유지하고 나머지는 '-'로 접는다.
    static func slug(from title: String) -> String {
        var pieces: [String] = []
        var current = ""
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        let slug = pieces.joined(separator: "-")
        return slug.isEmpty ? "recipe" : slug
    }

    /// 파일 이름으로 쓸 수 있는 id인지 검사한다. 소문자 영숫자와 '-'만 허용하고
    /// 첫 글자는 영숫자여야 한다(경로 구분자·상위 경로 표기 차단).
    static func isValidID(_ id: String) -> Bool {
        id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil
    }

    /// 이미 쓰이는 슬러그면 -2, -3 순으로 붙인다.
    /// 슬러그가 id 규칙에 맞지 않으면(한글 제목 등) "recipe"로 대체한다.
    func uniqueID(for title: String) -> String {
        let slug = String(Self.slug(from: title).prefix(60))
        let base = Self.isValidID(slug) ? slug : "recipe"
        if !isTaken(base) { return base }
        var suffix = 2
        while isTaken("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    private func isTaken(_ id: String) -> Bool {
        if recipes.contains(where: { $0.id == id }) { return true }
        guard let url = try? targetURL(for: id) else { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - 파일

    private func write(_ recipe: Recipe) throws {
        guard Self.isValidID(recipe.id) else { throw RecipeStoreError.invalidID }
        let url = try targetURL(for: recipe.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try encoder.encode(recipe).write(to: url, options: .atomic)
        } catch {
            AppLog.write("recipe", "레시피 저장 실패 \(recipe.id): \(error.localizedDescription)")
            throw RecipeStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// 검증된 id로만 만들고, 표준화한 경로가 rootURL 아래인지 한 번 더 확인한다.
    private func targetURL(for id: String) throws -> URL {
        guard Self.isValidID(id) else { throw RecipeStoreError.invalidID }
        let url = rootURL.appendingPathComponent("\(id).json").standardizedFileURL
        var rootPath = rootURL.standardizedFileURL.path
        if !rootPath.hasSuffix("/") { rootPath += "/" }
        guard url.path.hasPrefix(rootPath) else { throw RecipeStoreError.invalidID }
        return url
    }
}
