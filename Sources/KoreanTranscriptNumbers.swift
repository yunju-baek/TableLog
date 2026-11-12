import Foundation

enum KoreanTranscriptNumbers {
    private static let digits: [Character: Int] = [
        "영": 0, "공": 0, "일": 1, "이": 2, "삼": 3, "사": 4, "오": 5, "육": 6, "칠": 7, "팔": 8, "구": 9
    ]
    private static let smallUnits: [Character: Int] = ["십": 10, "백": 100, "천": 1_000]
    private static let largeUnits: [(Character, Int)] = [("조", 1_000_000_000_000), ("억", 100_000_000), ("만", 10_000)]
    private static let integerFormat = IntegerFormatStyle<Int>(locale: Locale(identifier: "ko_KR"))

    private static let nativeOnes = [
        "하나": 1, "한": 1, "둘": 2, "두": 2, "셋": 3, "세": 3, "넷": 4, "네": 4,
        "다섯": 5, "여섯": 6, "일곱": 7, "여덟": 8, "아홉": 9
    ]
    private static let nativeTens = [
        "열": 10, "스물": 20, "스무": 20, "서른": 30, "마흔": 40, "쉰": 50,
        "예순": 60, "일흔": 70, "여든": 80, "아흔": 90
    ]
    private static let digit = "[영공일이삼사오육칠팔구]"
    private static let counter = "(?:킬로미터|킬로그램|퍼센트|프로|개월|시간|분기|달러|유로|년|월|일|시|분|초|원|명|개|건|회|번|곳|대|쪽|장|층|호|배|점|권)"
    private static let ending = TranscriptNotation.particles + "?" + TranscriptNotation.wordEnd
    private static let smallGroup: String = {
        let coefficient = "(?:" + digit + #"\h*)?"#
        let thousands = coefficient + "천", hundreds = coefficient + "백", tens = coefficient + "십"
        return "(?:" + thousands + "(?:\\h*" + hundreds + ")?(?:\\h*" + tens + ")?|"
            + hundreds + "(?:\\h*" + tens + ")?|" + tens + ")"
    }()
    // A spaced final digit needs a counting unit. This keeps a following
    // demonstrative, as in "삼십 이 사업", outside the number.
    private static let finalDigit = "(?:" + digit + "|\\h+" + digit + "(?=\\h*" + counter + ending + "))?"
    private static let integer: String = {
        let major = "[조억만]"
        let coefficient = "(?:" + smallGroup + "(?:\\h*" + digit + ")?|" + digit + ")"
        let large = "(?:" + coefficient + "\\h*)?" + major
        let tail = "(?:\\h*" + smallGroup + finalDigit + "|" + finalDigit + ")"
        return large + "(?:\\h*" + large + ")*" + tail + "|" + smallGroup + finalDigit + "|" + digit
    }()
    private static let integers = try! NSRegularExpression(
        pattern: TranscriptNotation.wordStart + "(" + integer + ")(?:(?=\\h*(" + counter + ")" + ending + ")|(?=" + ending + "))"
    )
    private static let decimals = try! NSRegularExpression(
        pattern: TranscriptNotation.wordStart + "(" + smallGroup + "(?:\\h*" + digit + ")?|" + digit + "|[0-9]+)\\h*점\\h*("
            + digit + "(?:\\h*" + digit + ")*)"
            + "(?:(?=\\h*" + counter + ending + ")|(?=" + ending + "))"
    )
    private static let nativeCounts = try! NSRegularExpression(
        pattern: TranscriptNotation.wordStart + "(?:(" + nativeTens.keys.sorted().joined(separator: "|") + ")"
            + "(?:\\h*(" + nativeOnes.keys.sorted().joined(separator: "|") + "))?|("
            + nativeOnes.keys.sorted().joined(separator: "|") + "))(?=\\h*(?:명|개|건|번|곳|대|시간|살|잔|권|장|마리)" + ending + ")"
    )
    private static let ambiguousWords: Set<String> = ["일시", "일대", "사장", "사원", "영원", "십분"]
    private static let ambiguousLargeNumbers: Set<String> = ["구조", "사조", "일조", "이만", "일만", "오만", "천만"]

    static func normalize(_ text: String) -> String {
        let decimalText = TranscriptNotation.replacing(in: text, matches: decimals) { source, match in
            let whole = source.substring(with: match.range(at: 1))
            guard let value = Int(whole) ?? parse(whole) else { return nil }
            let fraction = source.substring(with: match.range(at: 2)).compactMap { digits[$0] }.map(String.init).joined()
            return String(value) + "." + fraction
        }
        let integerText = TranscriptNotation.replacing(in: decimalText, matches: integers) { source, match in
            let spelling = source.substring(with: match.range(at: 1))
            let unit = match.range(at: 2)
            let hasUnit = unit.location != NSNotFound
            let unitText = hasUnit ? source.substring(with: unit) : ""
            if spelling.count == 1 {
                guard hasUnit, spelling != "이", spelling != "공" else { return nil }
                if unit.location == NSMaxRange(match.range), ambiguousWords.contains(spelling + unitText) { return nil }
            }
            if ambiguousLargeNumbers.contains(spelling), !hasUnit || unitText == "이" { return nil }
            // A subject particle can immediately follow a large counting unit.
            if !hasUnit, spelling.last == "이", let preceding = spelling.dropLast().last,
               largeUnits.contains(where: { $0.0 == preceding }), let value = parse(String(spelling.dropLast())) {
                return formatted(value) + "이"
            }
            guard let value = parse(spelling) else { return nil }
            if unitText == "년", (1000...9999).contains(value) { return String(value) }
            return formatted(value)
        }
        return TranscriptNotation.replacing(in: integerText, matches: nativeCounts) { source, match in
            let tens = match.range(at: 1)
            let ones = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
            let whole = tens.location == NSNotFound ? 0 : nativeTens[source.substring(with: tens), default: 0]
            let digit = ones.location == NSNotFound ? 0 : nativeOnes[source.substring(with: ones), default: 0]
            return String(whole + digit)
        }
    }

    private static func parse(_ text: String) -> Int? {
        var total = 0, group = 0
        var digit: Int?
        var lastSmall = 10_000, lastLarge = Int.max
        for character in text where !character.isWhitespace {
            if let value = digits[character] {
                guard digit == nil else { return nil }
                digit = value
            } else if let unit = smallUnits[character] {
                guard unit < lastSmall, digit != 0 else { return nil }
                group += (digit ?? 1) * unit
                digit = nil
                lastSmall = unit
            } else if let unit = largeUnits.first(where: { $0.0 == character })?.1 {
                let value = group + (digit ?? 0)
                guard unit < lastLarge, value > 0 || total == 0 && digit == nil else { return nil }
                total += max(1, value) * unit
                group = 0
                digit = nil
                lastSmall = 10_000
                lastLarge = unit
            } else { return nil }
        }
        return total + group + (digit ?? 0)
    }

    private static func formatted(_ value: Int) -> String {
        var parts: [String] = []
        var remaining = value
        for (name, unit) in largeUnits where remaining >= unit {
            parts.append((remaining / unit).formatted(integerFormat) + String(name))
            remaining %= unit
        }
        if remaining > 0 || parts.isEmpty { parts.append(remaining.formatted(integerFormat)) }
        return parts.joined(separator: " ")
    }
}
