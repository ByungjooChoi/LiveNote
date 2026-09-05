import Foundation

/// 전사 텍스트 찾아바꾸기 순수 함수 모음.
enum TranscriptReplace {

    struct Options: Equatable, Sendable {
        var caseSensitive: Bool
        var wholeWord: Bool

        init(caseSensitive: Bool = false, wholeWord: Bool = false) {
            self.caseSensitive = caseSensitive
            self.wholeWord = wholeWord
        }
    }

    struct Match: Equatable, Sendable {
        let rowID: UUID
        let count: Int

        init(rowID: UUID, count: Int) {
            self.rowID = rowID
            self.count = count
        }
    }

    /// 행별 일치 건수 (0건 초과인 행만 행 순서대로 반환).
    static func matches(in rows: [TranscriptRow], find: String, options: Options) -> [Match] {
        guard !find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var result: [Match] = []
        for row in rows {
            let count = matchCount(in: row.english, find: find, options: options)
            if count > 0 {
                result.append(Match(rowID: row.id, count: count))
            }
        }
        return result
    }

    /// 단일 텍스트 내 일치 건수.
    static func matchCount(in text: String, find: String, options: Options) -> Int {
        guard !find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        guard let regex = makeRegex(find: find, options: options) else { return 0 }
        let range = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, range: range)
    }

    /// 단일 텍스트 내 일치 문자열 치환.
    static func replace(in text: String, find: String, replacement: String, options: Options) -> String {
        guard !find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        guard let regex = makeRegex(find: find, options: options) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func isWordCharacter(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "_"
    }

    private static func makeRegex(find: String, options: Options) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: find)
        let pattern: String
        if options.wholeWord {
            let firstWord = find.first.map(isWordCharacter) ?? false
            let lastWord = find.last.map(isWordCharacter) ?? false
            if firstWord && lastWord {
                pattern = "\\b\(escaped)\\b"
            } else {
                // "C++"처럼 단어 경계 문자가 아닌 기호로 시작/끝나는 경우 일반 부분문자열 일치로 완화
                pattern = escaped
            }
        } else {
            pattern = escaped
        }

        var regexOptions: NSRegularExpression.Options = []
        if !options.caseSensitive {
            regexOptions.insert(.caseInsensitive)
        }
        return try? NSRegularExpression(pattern: pattern, options: regexOptions)
    }
}

/// 찾아바꾸기 결과로부터 사내 전문용어(jargon) 등록 제안 여부 판정.
enum JargonSuggestion {

    /// 교체어가 사내 전문용어로 등록할 만한 단어인지 판정.
    /// (2글자 이상의 단일 토큰이며, 대문자로 시작하거나 전체가 대문자/숫자이고, 기존 목록에 없는 경우)
    static func shouldSuggest(replacement: String, existingJargon: String) -> Bool {
        let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        guard !trimmed.contains(where: \.isWhitespace), !trimmed.contains(where: \.isNewline) else { return false }

        let startsWithUpper = trimmed.first?.isUppercase == true
        let allUpperOrDigits = trimmed.allSatisfy { $0.isUppercase || $0.isNumber } && trimmed.contains(where: \.isLetter)
        guard startsWithUpper || allUpperOrDigits else { return false }

        let existingTerms = existingJargon.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard !existingTerms.contains(trimmed.lowercased()) else { return false }

        return true
    }

    /// 기존 전문용어 문자열에 새 단어 추가 (쉼표+공백 구분, 중복 없음).
    static func appending(_ term: String, to jargon: String) -> String {
        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerm.isEmpty else { return jargon }

        var items: [String] = []
        for part in jargon.split(separator: ",") {
            let s = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty && !items.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) {
                items.append(s)
            }
        }
        if !items.contains(where: { $0.caseInsensitiveCompare(trimmedTerm) == .orderedSame }) {
            items.append(trimmedTerm)
        }
        return items.joined(separator: ", ")
    }
}
