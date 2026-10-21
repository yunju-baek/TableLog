import Foundation

struct VoiceNamePresentation {
    enum Kind: Equatable { case none, manual, suggested, automatic }
    let kind: Kind
    let name: String
    let detail: String
}

struct VoiceNameChange {
    let speaker: Int
    let suggestion: VoiceSuggestion
    let name: String?
    let action: String
}

/// Session-owned provisional names. Explicit edits keep authority over future matches.
struct VoiceNameAssignments {
    private(set) var automatic: [Int: VoiceSuggestion] = [:]
    private(set) var userControlled = Set<Int>()

    mutating func userEdited(_ speaker: Int) {
        userControlled.insert(speaker)
        automatic[speaker] = nil
    }

    mutating func reconcile(suggestions: [Int: VoiceSuggestion], mode: VoiceMappingMode,
                            speakers: Set<Int>, names: [Int: String], rejected: Set<Int>) -> [VoiceNameChange] {
        var changes: [VoiceNameChange] = []
        let eligible = suggestions.filter {
            mode == .automatic && $0.value.automaticEligible && speakers.contains($0.key)
            && !userControlled.contains($0.key) && !rejected.contains($0.key)
        }
        for speaker in automatic.keys.sorted() {
            guard let previous = automatic[speaker] else { continue }
            if names[speaker] != previous.name {
                automatic[speaker] = nil
                if names[speaker] != nil { userControlled.insert(speaker) }
                continue
            }
            if let next = eligible[speaker], next.profileID == previous.profileID {
                automatic[speaker] = next
                if next.name != previous.name {
                    changes.append(.init(speaker: speaker, suggestion: next, name: next.name, action: "automatic_name_updated"))
                }
            } else {
                automatic[speaker] = nil
                changes.append(.init(speaker: speaker, suggestion: previous, name: nil, action: "automatic_retracted"))
            }
        }
        for speaker in eligible.keys.sorted() {
            guard let next = eligible[speaker], automatic[speaker] == nil,
                  !userControlled.contains(speaker),
                  names[speaker] == nil || changes.contains(where: { $0.speaker == speaker && $0.name == nil }) else { continue }
            automatic[speaker] = next
            changes.append(.init(speaker: speaker, suggestion: next, name: next.name, action: "automatically_mapped"))
        }
        return changes
    }

    var export: VoiceNameAssignmentsExport {
        .init(automaticallyMapped: automatic, userControlledSpeakers: userControlled.sorted())
    }
}

struct VoiceNameAssignmentsExport: Encodable {
    let automaticallyMapped: [Int: VoiceSuggestion]
    let userControlledSpeakers: [Int]
}
