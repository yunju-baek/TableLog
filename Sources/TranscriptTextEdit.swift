import Foundation

struct TranscriptTextEdit: Codable, Identifiable {
    var id = UUID()
    let segmentID: Int
    let start: Double
    let end: Double
    let originalText: String
    let replacement: String
    let editedAt: Date
    func overlaps(_ segment: TranscriptSegment) -> Bool {
        if end-start<0.001 { return segment.id==segmentID && abs(segment.startTime-start)<0.02 }
        return segment.endTime > start && segment.startTime < end
    }
}

enum TranscriptTextProjection {
    static func render(segments: [TranscriptSegment], words: [TranscriptWord], edits: [TranscriptTextEdit],
                       base: (TranscriptSegment) -> String) -> [Int: String] {
        var result: [Int:String] = [:], emitted = Set<UUID>()
        let ordered = edits.sorted { $0.start < $1.start }
        var superseded=Set<UUID>()
        for (index,edit) in edits.enumerated() {
            if edits.dropFirst(index+1).contains(where: { $0.start<=edit.start && $0.end>=edit.start }) { superseded.insert(edit.id) }
        }
        for segment in segments {
            let matching = ordered.filter { $0.overlaps(segment) }
            guard !matching.isEmpty else { result[segment.id] = base(segment); continue }
            // Streaming may extend a captured utterance. Keep its new suffix, using source words
            // when the decoder revises the prefix or assigns new segment IDs.
            if matching.count == 1, let edit = matching.first,
               abs(segment.startTime-edit.start)<0.02, !edit.originalText.isEmpty, segment.text.hasPrefix(edit.originalText),
               segment.endTime >= edit.end, !emitted.contains(edit.id), !superseded.contains(edit.id) {
                let tail = String(segment.text.dropFirst(edit.originalText.count)).trimmingCharacters(in:.whitespacesAndNewlines)
                result[segment.id] = [edit.replacement,tail].filter {!$0.isEmpty}.joined(separator:" ")
                emitted.insert(edit.id);continue
            }
            var pieces: [(Double,String)] = []
            for edit in matching where !emitted.contains(edit.id) {
                if !edit.replacement.isEmpty && !superseded.contains(edit.id) { pieces.append((max(segment.startTime,edit.start),edit.replacement)) }
                emitted.insert(edit.id)
            }
            for word in words {
                let midpoint=(word.start+word.end)/2
                guard midpoint>=segment.startTime, midpoint<segment.endTime,
                      segment.speaker<=0 || word.speaker==segment.speaker,
                      !matching.contains(where:{midpoint >= $0.start && midpoint <= $0.end}) else { continue }
                pieces.append((midpoint,word.text))
            }
            result[segment.id] = pieces.sorted {$0.0<$1.0}.map(\.1).joined(separator:" ").trimmingCharacters(in:.whitespacesAndNewlines)
        }
        return result
    }
}
