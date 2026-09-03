import Foundation

/// 레시피 실행 산출물 저장소: ~/Documents/LiveNote/recipes-output/
///
/// 파일명 규칙: "yyyy-MM-dd <safe title>.md" (중복 시 " (2)", " (3)" 접미사).
struct RecipeOutputStore: Sendable {

    let rootURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        rootURL = documents.appendingPathComponent("LiveNote/recipes-output", isDirectory: true)
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// 파일명에 안전한 제목 생성.
    static func safeTitle(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = String(title.map { char -> Character in
            if let scalar = char.unicodeScalars.first, forbidden.contains(scalar) { return " " }
            return char
        })
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        return cleaned.isEmpty ? "Recipe" : cleaned
    }

    static func fileName(title: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let dateString = formatter.string(from: date)
        let safe = safeTitle(title)
        return "\(dateString) \(safe).md"
    }

    @discardableResult
    func write(text: String, title: String, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let base = Self.fileName(title: title, date: date)
        let stem = String(base.dropLast(3))  // ".md" 제거

        var fileURL = rootURL.appendingPathComponent(base)
        var index = 2
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = rootURL.appendingPathComponent("\(stem) (\(index)).md")
            index += 1
        }
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
