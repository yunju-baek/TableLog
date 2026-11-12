import Foundation

enum TranscriptPresentation {
    static func format(_ text: String) -> String {
        TranscriptParagraphs.format(TranscriptNotation.normalize(text))
    }
}

enum TranscriptNotation {
    static let wordStart = #"(?<![\p{L}\p{N}])"#
    static let wordEnd = #"(?=$|[^\p{L}\p{N}])"#
    static let particles = "(?:입니다|이라고|이라는|으로|에서|에게|까지|부터|처럼|이라|은|는|이|가|을|를|도|에|의|와|과)"

    private static let alphabet: [String: String] = [
        "에이": "A", "비": "B", "씨": "C", "시": "C", "디": "D", "이": "E", "에프": "F",
        "지": "G", "에이치": "H", "아이": "I", "제이": "J", "케이": "K", "엘": "L",
        "엠": "M", "엔": "N", "오": "O", "피": "P", "큐": "Q", "알": "R", "에스": "S",
        "티": "T", "유": "U", "브이": "V", "더블유": "W", "엑스": "X", "와이": "Y", "제트": "Z", "지드": "Z"
    ]
    private static let letter = "(?:" + alphabet.keys.sorted { ($0.count, $0) > ($1.count, $1) }.joined(separator: "|") + ")"
    private static let letterToken = try! NSRegularExpression(pattern: letter)
    private static let letterRun = try! NSRegularExpression(
        pattern: wordStart + letter + "(?:\\h*" + letter + ")+(?=" + particles + "?" + wordEnd + ")"
    )
    // Compact or short spellings can also be ordinary Korean. Familiar initialisms
    // support forms such as 피디에프 while spaced, explicit letter sequences stay open-ended.
    private static let compactInitialisms: Set<String> = [
        "AI", "API", "AR", "ASR", "AWS", "BI", "CEO", "CFO", "CLI", "CPU", "CRM", "CSV",
        "CTO", "DB", "ERP", "FAQ", "GIS", "GPT", "GPU", "GUI", "HR", "HTTP", "HTTPS", "ICT",
        "ID", "IDE", "IOT", "IP", "IR", "IT", "JWT", "KPI", "LLM", "MCP", "ML", "NLP",
        "OCR", "OKR", "OS", "PC", "PDF", "PR", "QA", "RAG", "ROI", "SaaS", "SDK", "SLA",
        "SQL", "STT", "TTS", "UI", "URL", "USB", "UX", "VAD", "VPN", "VR", "XML"
    ]
    private static let longestInitialism = compactInitialisms.map(\.count).max() ?? 0

    static func normalize(_ text: String) -> String {
        let abbreviations = replacing(in: text, matches: letterRun) { source, match in
            let tokens = letterToken.matches(in: source as String, range: match.range)
            let letters = tokens.map { source.substring(with: $0.range) }
            let latin = letters.compactMap { alphabet[$0] }
            let initialism = latin.joined()
            if compactInitialisms.contains(initialism) { return initialism }

            let gaps = zip(tokens, tokens.dropFirst()).map { NSMaxRange($0.range) < $1.range.location }
            let rewritten = NSMutableString(string: source.substring(with: match.range))
            var start = 0
            var matches: [(NSRange, String)] = []
            while start < tokens.count {
                let limit = min(start + longestInitialism, tokens.count)
                if let end = (start + 1...limit).reversed().first(where: { end in
                    let boundary = end == tokens.count || gaps[end - 1]
                        || (end == tokens.count - 1 && letters[end] == "이")
                    return boundary && compactInitialisms.contains(latin[start..<end].joined())
                }) {
                    let lower = tokens[start].range.location
                    let upper = NSMaxRange(tokens[end - 1].range)
                    matches.append((NSRange(location: lower - match.range.location, length: upper - lower),
                                    latin[start..<end].joined()))
                    start = end
                } else {
                    repeat { start += 1 } while start < tokens.count && !gaps[start - 1]
                }
            }
            for (range, value) in matches.reversed() { rewritten.replaceCharacters(in: range, with: value) }
            if !matches.isEmpty { return rewritten as String }

            let explicit = letters.filter { $0.count > 1 && $0 != "아이" }.count
            guard gaps.allSatisfy({ $0 }), explicit >= (letters.count > 2 ? 1 : 2),
                  !letters.contains("이"), !letters.contains("오") else { return nil }
            return initialism
        }
        return KoreanTranscriptNumbers.normalize(abbreviations)
    }

    static func replacing(in text: String, matches pattern: NSRegularExpression,
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
}
