import Foundation

/// Presentation-only grouping preserves the original timed segments in exports and logs.
struct ConversationTurn: Identifiable {
    let id: String
    let speaker: Int
    var segments: [TranscriptSegment]
    var start: Double { segments.map(\.startTime).min() ?? 0 }
    var end: Double { segments.map(\.endTime).max() ?? 0 }

    static func grouped(_ segments: [TranscriptSegment], speaker: (TranscriptSegment) -> Int = { $0.speaker }, breakBefore: Set<Int> = []) -> [Self] {
        var turns: [Self] = []
        var occurrences: [Int: Int] = [:]
        for segment in segments {
            let label = speaker(segment)
            if label > 0, turns.last?.speaker == label, !breakBefore.contains(segment.id) {
                turns[turns.count - 1].segments.append(segment)
            } else {
                let occurrence = occurrences[label, default: 0]
                occurrences[label] = occurrence + 1
                turns.append(Self(id: "\(label):\(occurrence)", speaker: label, segments: [segment]))
            }
        }
        return turns
    }
}

/// Reads the existing sidecar format, including recordings made by older app versions.
struct RecognitionComparison: Decodable {
    struct Chunk: Decodable, Identifiable {
        let chunk_id: Int
        let start_time: Double
        let end_time: Double
        let received_at: String
        let request_seconds: Double
        let local_at_submission: String
        let local_at_response: String
        let final_local_text: String?
        let gemini_text: String
        var id: Int { chunk_id }
    }
    struct Failure: Decodable {
        let timestamp: String
        let message: String
    }
    let codex_corrections: [CodexCorrectionRecord]?
    let speaker_reviews: [SpeakerReviewRecord]?
    let session_id: String
    let chunks: [Chunk]
    let failures: [Failure]
    let local_update_count: Int
}
