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
    /// Existing templates keep their identity and preferences while adopting a minutes-only layout.
    public var minutesOnly: Self {
        guard markdown.contains("{{transcript}}") || markdown.contains("근거 시각") || markdown.contains("근거 발언") else { return self }
        var value = Self.fromMeetingMarkdown(markdown, name: name, similarTopics: similarTopics, participantCandidates: participantCandidates)
        value.id = id
        return value
    }
    public static func fromMeetingMarkdown(_ source: String, name: String,
                                            similarTopics: [String], participantCandidates: [MeetingPerson]) -> Self {
        let markdown = """
        # {{title}}

        ## 회의 개요

        {{overview}}

        ## 핵심 요약

        {{summary}}

        ## 안건별 논의

        {{discussion}}

        ## 결정 사항

        {{decisions}}

        ## 후속 조치

        | 조치 내용 | 담당 | 기한 |
        | --- | --- | --- |
        {{actions}}

        ## 확인할 사항

        {{open_issues}}
        """
        return Self(name: name, markdown: markdown + "\n", similarTopics: similarTopics, participantCandidates: participantCandidates)
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
    public let title: String
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
                utterances: [MeetingUtterance], facts: MeetingMinutesFacts, referenceAppendix: String = "", title: String = "") {
        self.sessionID = sessionID; self.revision = revision; self.date = date; self.purpose = purpose
        self.confirmedParticipants = confirmedParticipants; self.speakerBindings = speakerBindings
        self.title = title
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
        func validateEvidence(_ ids: [Int]) throws {
            guard !ids.isEmpty, ids.allSatisfy({ index[$0] != nil }) else { throw MeetingMinutesError.invalidEvidence }
        }
        func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
        func item(_ value: EvidencedItem) throws -> String {
            try validateEvidence(value.evidenceIDs)
            return cell(value.text)
        }
        func bullets(_ items: [EvidencedItem], empty: String) throws -> String {
            if items.isEmpty { return "- " + empty }
            return try items.map { "- " + (try item($0)) }.joined(separator: "\n")
        }
        let facts = snapshot.facts
        let actions = try facts.actions.map { action -> String in
            try validateEvidence(action.evidenceIDs)
            return "| \(cell(action.text)) | \(cell(action.assignee ?? "확인 필요")) | \(cell(action.deadline ?? "확인 필요")) |"
        }.joined(separator: "\n")
        let discussion = try facts.discussions.map { group in
            "### " + cell(group.title) + "\n\n" + (try group.points.map(item)).joined(separator: "\n\n")
        }.joined(separator: "\n\n")
        let date = snapshot.date.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression).map { String(snapshot.date[$0]) } ?? snapshot.date
        var seen = Set<String>()
        let people = snapshot.confirmedParticipants.map(\.name).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ", ")
        let overview = [("일자", date), ("참석자", people), ("목적", snapshot.purpose)]
            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "- " + $0.0 + ": " + cell($0.1) }.joined(separator: "\n")
        let fields: [String: String] = [
            "title": cell(snapshot.title.isEmpty ? template.name : snapshot.title), "overview": overview,
            "datetime": date, "participants": people, "purpose": snapshot.purpose,
            "summary": try bullets(facts.summary, empty: "요약할 내용 확인 필요"),
            "decisions": try bullets(facts.decisions, empty: "확정된 결정 사항 확인 필요"),
            "actions": actions.isEmpty ? "| 후속 조치 확인 필요 | — | — |" : actions,
            "discussion": discussion.isEmpty ? "논의 내용 정리 대기" : discussion,
            "open_issues": try bullets(facts.openIssues, empty: "추가 확인 사항 없음")]
        let markdown = template.minutesOnly.markdown
        // Single pass prevents utterances containing placeholder syntax from expanding.
        let regex = try NSRegularExpression(pattern: #"\{\{([a-z_]+)\}\}"#)
        let source = markdown as NSString
        var result = "", cursor = 0
        for match in regex.matches(in: markdown, range: NSRange(location: 0, length: source.length)) {
            let key = source.substring(with: match.range(at: 1))
            guard let replacement = fields[key] else { throw MeetingMinutesError.unsupportedTemplate }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + replacement
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        // Evidence, source transcripts and assistant histories stay in the app records.
        return result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
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
