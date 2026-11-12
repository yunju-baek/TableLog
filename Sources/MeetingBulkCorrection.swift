import Foundation

struct MeetingBulkCorrection: Codable {
    struct Rule: Codable {
        let before: String
        let after: String
        // A trailing question mark in an unquoted source marks an uncertain transcription.
        let optionalQuestionMark: Bool
    }

    let transcript: Bool
    let minutes: Bool
    let title: String?
    let rules: [Rule]

    private static let rulesLabel = #/(?:^|[\s,:：])(?:일괄\s*교정|교정|치환|수정)\s*[:：]\s*/#
    private static let titleLabel = #/(?:^|[\s,:：])회의\s*(?:제목|명)\s*[:：]\s*([^\r\n]+)/#
    private static let transcriptLabel = #/전사록|녹취록|전사문|전사|녹취/#
    private static let scopeLabel = #/^(?:전사록|녹취록|전사문|전사|녹취|회의록)(?:\s*(?:및|과|와|,|·|\+|\/|랑)\s*(?:전사록|녹취록|전사문|전사|녹취|회의록))?\s*[:：]\s*/#
    private static let listSeparator = try! NSRegularExpression(pattern: #"[\r\n]+|(?:[,;]\s*|\s+)(?=\d{1,3}[.)]\s*[^\d\s])"#)
    private static let listMarker = #/^(?:\d{1,3}[.)]\s*|[-*•]\s+)/#
    private static let arrow = #/->|=>|→|⇒/#
    private static let heading = #/(?m)^# [^\r\n]+/#
    private static let minutesTitle = #/(?m)^([ \t]*(?:[-*][ \t]+)?(?:\*\*)?회의[ \t]*(?:제목|명)(?:\*\*)?[ \t]*[:：](?:\*\*)?[ \t]*)[^\r\n]+/#

    static func parse(_ request: String) -> Self? {
        let prefix: Substring
        let body: Substring
        if let label = request.firstMatch(of: rulesLabel) {
            prefix = request[..<label.range.lowerBound]
            body = request[label.range.upperBound...]
        } else if let label = request.prefixMatch(of: scopeLabel) {
            prefix = request[label.range]
            body = request[label.range.upperBound...]
        } else {
            return nil
        }
        let titleMatch = prefix.firstMatch(of: titleLabel)
        let scope = titleMatch.map { prefix[..<$0.range.lowerBound] } ?? prefix
        guard !scope.contains("회의자료"), !scope.contains("회의 자료") else { return nil }
        let targetsTranscript = scope.firstMatch(of: transcriptLabel) != nil
        let targetsMinutes = scope.contains("회의록")
        guard targetsTranscript || targetsMinutes else { return nil }

        let title = titleMatch.map { match in
            let value = unquote(match.1.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))).text
            return String(value.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160))
        }
        guard title != "" else { return nil }

        let bodyText = String(body)
        let source = bodyText as NSString
        let separators = listSeparator.matches(in: bodyText, range: NSRange(location: 0, length: source.length))
        var lines: [String] = [], start = 0
        for separator in separators {
            lines.append(source.substring(with: NSRange(location: start, length: separator.range.location - start)))
            start = NSMaxRange(separator.range)
        }
        lines.append(source.substring(from: start))

        var rules: [Rule] = [], seen = Set<String>()
        for line in lines {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { continue }
            let pair = value.replacing(listMarker, with: "", maxReplacements: 1)
            let arrows = pair.matches(of: arrow)
            guard arrows.count == 1, let split = arrows.first else { return nil }
            let from = unquote(pair[..<split.range.lowerBound].trimmingCharacters(in: .whitespaces))
            let to = unquote(pair[split.range.upperBound...].trimmingCharacters(in: .whitespaces))
            let uncertain = !from.quoted && from.text.hasSuffix("?")
            let before = uncertain ? String(from.text.dropLast()).trimmingCharacters(in: .whitespaces) : from.text
            guard !before.isEmpty, !to.text.isEmpty, before != to.text,
                  to.quoted || !to.text.hasSuffix("?"), seen.insert(before).inserted else { return nil }
            rules.append(Rule(before: before, after: to.text, optionalQuestionMark: uncertain))
        }
        guard !rules.isEmpty else { return nil }
        return Self(transcript: targetsTranscript, minutes: targetsMinutes, title: title, rules: rules)
    }

    private static func unquote(_ value: String) -> (text: String, quoted: Bool) {
        let closing: [Character: Character] = ["\"": "\"", "'": "'", "`": "`", "“": "”", "‘": "’"]
        if value.count >= 2, let first = value.first, closing[first] == value.last {
            return (String(value.dropFirst().dropLast()), true)
        }
        return (value, false)
    }

    func evaluate(in snapshot: EditingSnapshot) throws -> Evaluation {
        var variants: [String: Int] = [:]
        for (index, rule) in rules.enumerated() { variants[rule.before] = index }
        for (index, rule) in rules.enumerated() where rule.optionalQuestionMark {
            if variants[rule.before + "?"] == nil { variants[rule.before + "?"] = index }
            if variants[rule.before + " ?"] == nil { variants[rule.before + " ?"] = index }
        }
        let alternatives = variants.keys.sorted { $0.utf16.count > $1.utf16.count }
        let pattern = alternatives.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let matcher = try NSRegularExpression(pattern: pattern)
        let newTitle = title == snapshot.meetingTitle ? nil : title
        var preview = Preview(rules: rules.map { .init(rule: $0) }, transcript: transcript, minutes: minutes,
                              previousTitle: newTitle == nil ? nil : snapshot.meetingTitle, newTitle: newTitle)
        var changes: [EditingChange] = []
        for document in snapshot.documents {
            switch document.kind {
            case .transcript where transcript: preview.utterances += 1
            case .speaker where transcript && document.editableName == true: break
            case .minutes where minutes && !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                preview.hasMinutes = true
            default: continue
            }
            let source = document.text as NSString
            var after = "", cursor = 0
            for match in matcher.matches(in: document.text, range: NSRange(location: 0, length: source.length)) {
                let original = source.substring(with: match.range)
                guard let index = variants[original], original != rules[index].after else { continue }
                after += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                after += rules[index].after
                cursor = NSMaxRange(match.range)
                switch document.kind {
                case .transcript: preview.rules[index].transcript += 1
                case .speaker: preview.rules[index].speakers += 1
                case .minutes: preview.rules[index].minutes += 1
                case .material: break
                }
            }
            after += source.substring(from: cursor)
            if document.kind == .minutes, let title {
                after = Self.renameMinutes(after, to: title)
            }
            if after != document.text {
                changes.append(EditingChange(targetID: document.id, before: document.text, after: after, speaker: -1))
            }
        }
        return Evaluation(preview: preview, changes: changes)
    }

    private static func renameMinutes(_ text: String, to title: String) -> String {
        let escaped = title.replacingOccurrences(of: "|", with: "\\|")
        if let field = text.firstMatch(of: minutesTitle) {
            return text.replacingCharacters(in: field.range, with: String(field.1) + escaped)
        }
        if let heading = text.firstMatch(of: heading) {
            return text.replacingCharacters(in: heading.range, with: "# " + escaped)
        }
        return "# " + escaped + "\n\n" + text
    }

    struct Evaluation {
        let preview: Preview
        let changes: [EditingChange]
        var hasChanges: Bool { !changes.isEmpty || preview.newTitle != nil }
    }

    struct Preview: Codable {
        struct MatchCount: Codable {
            let rule: Rule
            var transcript = 0
            var speakers = 0
            var minutes = 0
        }
        var rules: [MatchCount]
        let transcript: Bool
        let minutes: Bool
        let previousTitle: String?
        let newTitle: String?
        var utterances = 0
        var hasMinutes = false

        var coverage: String {
            var parts: [String] = []
            if transcript { parts.append("전사록 전체 \(utterances)개 발언") }
            if minutes { parts.append(hasMinutes ? "현재 회의록 전체" : "회의록 생성 대기") }
            return parts.joined(separator: " · ")
        }
    }
}
