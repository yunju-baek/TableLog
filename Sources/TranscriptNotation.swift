import Foundation

enum TranscriptPresentation {
    static func format(_ text: String) -> String {
        TranscriptParagraphs.format(TranscriptNotation.normalize(text))
    }
}

enum TranscriptNotation {
    private static let wordEnd = #"(?=$|[^\p{L}\p{N}])"#
    private static let particles = "(?:입니다|이라고|이라는|으로|에서|에게|까지|부터|처럼|이라|은|는|이|가|을|를|도|에|의|와|과)"
    private static let counters = "(?:킬로그램|퍼센트|개월|시간|분기|달러|유로|년|월|일|시|분|초|원|명|개|건|회|번|대|쪽|장|층|호|배|점|권)"
    private static let abbreviationPatterns: [(String, String)] = [
        (#"에이\h*피\h*아이"#, "API"),
        (#"에이\h*아이"#, "AI"),
        (#"엘\h*엘\h*엠"#, "LLM"),
        (#"지\h*피\h*유"#, "GPU"),
        (#"(?:씨|시)\h*피\h*유"#, "CPU")
    ]
    private static let abbreviations = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(?:"# + abbreviationPatterns.map { "(" + $0.0 + ")" }.joined(separator: "|")
            + ")(?=" + particles + "?" + wordEnd + ")"
    )
    private static let numbers = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])([영공일이삼사오육칠팔구십백천만억조]+)"#
            + "(?:(?=\\h*(" + counters + ")" + particles + "?" + wordEnd + ")|(?=" + particles + "?" + wordEnd + "))"
    )
    private static let digits: [Character: Int] = ["영": 0, "공": 0, "일": 1, "이": 2, "삼": 3, "사": 4, "오": 5, "육": 6, "칠": 7, "팔": 8, "구": 9]
    private static let smallUnits: [Character: Int] = ["십": 10, "백": 100, "천": 1_000]
    private static let largeUnits: [(Character, Int)] = [("조", 1_000_000_000_000), ("억", 100_000_000), ("만", 10_000)]
    private static let integerFormat = IntegerFormatStyle<Int>(locale: Locale(identifier: "ko_KR"))

    static func normalize(_ text: String) -> String {
        let expanded = replacing(in: text, matches: abbreviations) { _, match in
            abbreviationPatterns.indices.first { match.range(at: $0 + 1).location != NSNotFound }
                .map { abbreviationPatterns[$0].1 }
        }
        return replacing(in: expanded, matches: numbers) { source, match in
            let spelling = source.substring(with: match.range(at: 1))
            let counter = match.range(at: 2)
            if spelling.count == 1 {
                guard counter.location == NSMaxRange(match.range), spelling != "이", spelling != "일" else { return nil }
            }
            // A subject particle can immediately follow a large counting unit.
            if counter.location == NSNotFound, spelling.last == "이",
               let preceding = spelling.dropLast().last, largeUnits.contains(where: { $0.0 == preceding }),
               let value = parse(spelling.dropLast()) {
                return formatted(value) + "이"
            }
            guard let value = parse(spelling[...]) else { return nil }
            if counter.location != NSNotFound, source.substring(with: counter) == "년", (1000...9999).contains(value) {
                return String(value)
            }
            return formatted(value)
        }
    }

    private static func replacing(in text: String, matches pattern: NSRegularExpression,
                                  replacement: (NSString, NSTextCheckingResult) -> String?) -> String {
        let source = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        let output = NSMutableString(string: text)
        for match in matches.reversed() {
            if let value = replacement(source, match) { output.replaceCharacters(in: match.range, with: value) }
        }
        return output as String
    }

    private static func parse(_ text: Substring) -> Int? {
        var total = 0, group = 0
        var digit: Int?
        var lastSmall = 10_000, lastLarge = Int.max
        for character in text {
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
            }
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
