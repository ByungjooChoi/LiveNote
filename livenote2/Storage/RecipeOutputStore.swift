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

        // 날짜 형식은 fileName(title:date:) 한 곳에만 둔다. 여기서는 중복 접미사만 붙인다.
        let base = Self.fileName(title: title, date: date)
        let stem = String(base.dropLast(3))  // ".md" 제거

        var fileURL = rootURL.appendingPathComponent(base)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            var index = 2
            while FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent("\(stem) (\(index)).md").path
            ) {
                index += 1
            }
            fileURL = rootURL.appendingPathComponent("\(stem) (\(index)).md")
        }
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
