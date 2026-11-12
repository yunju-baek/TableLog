import NaturalLanguage

enum TranscriptParagraphs {
    private static let targetLength = 120
    private static let unpunctuatedLimit = 220

    static func format(_ text: String) -> String {
        guard text.count > targetLength else { return text }

        let tokenizer = NLTokenizer(unit: .sentence)
        var result = ""
        var remaining = text[...]
        while let lineEnd = remaining.firstIndex(where: \.isNewline) {
            appendLine(remaining[..<lineEnd], tokenizer: tokenizer, to: &result)
            result.append(remaining[lineEnd])
            remaining = remaining[remaining.index(after: lineEnd)...]
        }
        appendLine(remaining, tokenizer: tokenizer, to: &result)
        return result
    }

    private static func appendLine(_ text: Substring, tokenizer: NLTokenizer, to result: inout String) {
        guard text.count > targetLength else {
            result.append(contentsOf: text)
            return
        }

        let line = String(text)
        tokenizer.string = line
        var paragraphStart = line.startIndex
        var previousEnd = line.startIndex
        for sentence in tokenizer.tokens(for: line.startIndex..<line.endIndex) {
            let nextStart = sentence.lowerBound
            let length = line.distance(from: paragraphStart, to: nextStart)
            let nextLength = line.distance(from: nextStart, to: sentence.upperBound)
            let reachesTarget = length >= targetLength
                || (length >= targetLength / 2 && length + nextLength > unpunctuatedLimit)
            if previousEnd > paragraphStart, reachesTarget,
               line[previousEnd..<nextStart].allSatisfy(\.isWhitespace) {
                appendLongParagraph(line[paragraphStart..<previousEnd], to: &result)
                result.append("\n\n")
                paragraphStart = nextStart
            }
            if let last = line[sentence].lastIndex(where: { !$0.isWhitespace }) {
                previousEnd = line.index(after: last)
            }
        }
        appendLongParagraph(line[paragraphStart...], to: &result)
    }

    // Speech recognition can produce long passages without sentence punctuation.
    private static func appendLongParagraph(_ paragraph: Substring, to result: inout String) {
        var start = paragraph.startIndex
        while let limit = paragraph.index(start, offsetBy: unpunctuatedLimit, limitedBy: paragraph.endIndex),
              limit < paragraph.endIndex {
            let target = paragraph.index(start, offsetBy: targetLength)
            guard let space = paragraph[target...limit].lastIndex(where: \.isWhitespace)
                    ?? paragraph[limit...].firstIndex(where: \.isWhitespace),
                  let lastWordEnd = paragraph[start..<space].lastIndex(where: { !$0.isWhitespace }),
                  let nextWord = paragraph[space...].firstIndex(where: { !$0.isWhitespace }) else { break }
            result.append(contentsOf: paragraph[start...lastWordEnd])
            result.append("\n\n")
            start = nextWord
        }
        result.append(contentsOf: paragraph[start...])
    }
}
