import Foundation

public struct MeetingPerson: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var organization: String
    public init(id: String, name: String, organization: String = "") {
        self.id = id; self.name = name; self.organization = organization
    }
}
public struct MeetingTemplate: Codable, Identifiable {
    public var id = UUID()
    public var name: String
    public var markdown: String
    public var similarTopics: [String]
    public var participantCandidates: [MeetingPerson]
    public init(name: String, markdown: String, similarTopics: [String] = [], participantCandidates: [MeetingPerson] = []) {
        self.name = name; self.markdown = markdown
        self.similarTopics = similarTopics; self.participantCandidates = participantCandidates
    }
    /// Preserve structural headings and table columns, clearing previous meeting facts.
    public static func fromMeetingMarkdown(_ source: String, name: String,
                                            similarTopics: [String], participantCandidates: [MeetingPerson]) -> Self {
        let sections: [String: String] = [
            "회의 개요": "- 일시: {{datetime}}\n- 참석자: {{participants}}\n- 목적: {{purpose}}",
            "핵심 요약": "{{summary}}",
            "결정 사항": "| 결정 | 근거 시각 |\n| -- | ----- |\n{{decisions}}",
            "할 일": "| 할 일 | 담당자 | 기한 | 근거 시각 |\n| --- | --- | -- | ----- |\n{{actions}}",
            "논의 내용": "{{discussion}}",
            "미해결 쟁점 및 확인 필요 사항": "{{open_issues}}"
        ]
        var result: [String] = [], seen = Set<String>()
        for line in source.components(separatedBy: .newlines) {
            guard line.hasPrefix("# ") else { continue }
            let title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if let content = sections[title], seen.insert(title).inserted {
                result += [line, "", content, ""]
            }
        }
        for title in ["회의 개요", "핵심 요약", "결정 사항", "할 일", "논의 내용", "미해결 쟁점 및 확인 필요 사항"] where !seen.contains(title) {
            result += ["# " + title, "", sections[title]!, ""]
        }
        result += ["전사문:", "", "{{transcript}}"]
        return Self(name: name, markdown: result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
                    similarTopics: similarTopics, participantCandidates: participantCandidates)
    }
}

public struct MeetingUtterance: Codable, Identifiable {
    public let id: Int
    public let speaker: Int
    public let start: Double
    public let end: Double
    public let text: String
    public init(id: Int, speaker: Int, start: Double, end: Double, text: String) {
        self.id = id; self.speaker = speaker; self.start = start; self.end = end; self.text = text
    }
}
public struct EvidencedItem: Codable {
    public var text: String
    public var evidenceIDs: [Int]
    public init(text: String, evidenceIDs: [Int]) { self.text = text; self.evidenceIDs = evidenceIDs }
}
public struct MeetingAction: Codable {
    public var text: String
    public var assignee: String?
    public var deadline: String?
    public var evidenceIDs: [Int]
    public init(text: String, assignee: String? = nil, deadline: String? = nil, evidenceIDs: [Int]) {
        self.text = text; self.assignee = assignee; self.deadline = deadline; self.evidenceIDs = evidenceIDs
    }
}
public struct MeetingDiscussion: Codable {
    public var title: String
    public var points: [EvidencedItem]
    public init(title: String, points: [EvidencedItem]) { self.title = title; self.points = points }
}
public struct MeetingMinutesFacts: Codable {
    var materialReviews: [MaterialReview]? = nil
    public var summary: [EvidencedItem] = []
    public var decisions: [EvidencedItem] = []
    public var actions: [MeetingAction] = []
    public var discussions: [MeetingDiscussion] = []
    public var openIssues: [EvidencedItem] = []
    public init() {}
}
public struct MeetingMinutesSnapshot {
    public let sessionID: UUID
    public let revision: Int
    public let date: String
    public let purpose: String
    public let confirmedParticipants: [MeetingPerson]
    public let speakerBindings: [Int: MeetingPerson]
    public let utterances: [MeetingUtterance]
    public let referenceAppendix: String
    public let facts: MeetingMinutesFacts
    public init(sessionID: UUID, revision: Int, date: String, purpose: String,
                confirmedParticipants: [MeetingPerson], speakerBindings: [Int: MeetingPerson],
                utterances: [MeetingUtterance], facts: MeetingMinutesFacts, referenceAppendix: String = "") {
        self.sessionID = sessionID; self.revision = revision; self.date = date; self.purpose = purpose
        self.confirmedParticipants = confirmedParticipants; self.speakerBindings = speakerBindings
        self.referenceAppendix=referenceAppendix
        self.utterances = utterances; self.facts = facts
    }
}
public enum MeetingMinutesError: Error { case invalidEvidence, outdatedRevision, invalidTranscript, unsupportedTemplate }

public enum MeetingMinutesRenderer {
    public static func time(_ value: Double) -> String {
        let n = Int(max(0, value))
        return n >= 3600 ? String(format: "%02d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) : String(format: "%02d:%02d", n / 60, n % 60)
    }
    public static func render(_ snapshot: MeetingMinutesSnapshot, template: MeetingTemplate) throws -> String {
        let segments = snapshot.utterances
        guard Set(segments.map(\.id)).count == segments.count,
              segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) else { throw MeetingMinutesError.invalidTranscript }
        let index = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        func evidence(_ ids: [Int]) throws -> String {
            guard !ids.isEmpty, ids.allSatisfy({ index[$0] != nil }) else { throw MeetingMinutesError.invalidEvidence }
            return Set(ids).sorted { index[$0]!.start < index[$1]!.start }.map { id in
                let s = index[id]!
                return "\(time(s.start))–\(time(s.end))"
            }.joined(separator: ", ")
        }
        func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        func bullets(_ items: [EvidencedItem]) throws -> String {
            if items.isEmpty { return "- 확인된 내용 없음" }
            return try items.map { "- \(cell($0.text)) (\(try evidence($0.evidenceIDs)))" }.joined(separator: "\n")
        }
        let facts = snapshot.facts
        let decisions = try facts.decisions.map { "| \(cell($0.text)) | \(try evidence($0.evidenceIDs)) |" }.joined(separator: "\n")
        let actions = try facts.actions.map { "| \(cell($0.text)) | \(cell($0.assignee ?? "확인 필요")) | \(cell($0.deadline ?? "확인 필요")) | \(try evidence($0.evidenceIDs)) |" }.joined(separator: "\n")
        let discussion = try facts.discussions.map { "## \(cell($0.title))\n\n\(try bullets($0.points))" }.joined(separator: "\n\n")
        let transcript = segments.map { s in
            let name = snapshot.speakerBindings[s.speaker]?.name ?? "화자 \(s.speaker)"
            return "[\(time(s.start))–\(time(s.end))] \(cell(name)): \(cell(s.text))"
        }.joined(separator: "\n\n")
        let fields: [String: String] = [
            "datetime": snapshot.date, "participants": snapshot.confirmedParticipants.map(\.name).joined(separator: ", "),
            "purpose": snapshot.purpose, "summary": try bullets(facts.summary),
            "decisions": decisions.isEmpty ? "| 확인된 결정 없음 | — |" : decisions,
            "actions": actions.isEmpty ? "| 확인된 할 일 없음 | — | — | — |" : actions,
            "discussion": discussion.isEmpty ? "## 안건 1\n\n- 확인된 내용 없음" : discussion,
            "open_issues": try bullets(facts.openIssues), "transcript": transcript]
        // Single pass prevents utterances containing placeholder syntax from expanding.
        let regex = try NSRegularExpression(pattern: #"\{\{([a-z_]+)\}\}"#)
        let source = template.markdown as NSString
        var result = "", cursor = 0
        for match in regex.matches(in: template.markdown, range: NSRange(location: 0, length: source.length)) {
            let key = source.substring(with: match.range(at: 1))
            guard let replacement = fields[key] else { throw MeetingMinutesError.unsupportedTemplate }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + replacement
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result + snapshot.referenceAppendix
    }
}

public actor MeetingFileStore {
    private let directory: URL
    private var revisions: [UUID: Int] = [:]
    public init(directory: URL) { self.directory = directory }
    public func save(_ snapshot: MeetingMinutesSnapshot, template: MeetingTemplate) throws -> URL {
        guard snapshot.revision >= revisions[snapshot.sessionID, default: -1] else { throw MeetingMinutesError.outdatedRevision }
        let markdown = try MeetingMinutesRenderer.render(snapshot, template: template)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(snapshot.sessionID.uuidString + ".md")
        try Data(markdown.utf8).write(to: target, options: .atomic)
        revisions[snapshot.sessionID] = snapshot.revision
        return target
    }
    public func saveTemplate(_ template: MeetingTemplate) throws -> URL {
        let folder = directory.appendingPathComponent("Templates")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(template.id.uuidString + ".json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(template).write(to: target, options: .atomic)
        return target
    }
    public func templates() throws -> [MeetingTemplate] {
        let folder = directory.appendingPathComponent("Templates")
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(MeetingTemplate.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
