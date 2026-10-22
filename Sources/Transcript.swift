import Foundation

enum AppPhase { case loading, ready, recording, paused, finishing, completed, failed }

enum RecognitionProvider: String, CaseIterable, Codable {
    case local, gemini
    var title: String { self == .gemini ? "Gemini 3.5 Transcribe" : "NVIDIA 로컬" }
}

struct SpeakerActivity: Codable {
    let speaker: Int
    let start: Double
    let end: Double
}

struct TranscriptSegment: Identifiable, Codable, Equatable {
    let id: Int
    let speaker: Int
    let startTime: Double
    let endTime: Double
    let text: String
    enum CodingKeys: String, CodingKey {
        case id, speaker, text
        case startTime = "start"
        case endTime = "end"
    }
}

struct TranscriptWord: Codable, Equatable {
    let text: String
    let start: Double
    let end: Double
    let speaker: Int
}

struct EngineSnapshot: Decodable {
    let revision: Int
    let audioSeconds: Double
    let processedSeconds: Double
    let isFinal: Bool
    let text: String
    let words: [TranscriptWord]
    let segments: [TranscriptSegment]
    let speakerActivity: [SpeakerActivity]?
    enum CodingKeys: String, CodingKey {
        case revision, text, words, segments
        case audioSeconds = "audio_seconds"
        case processedSeconds = "processed_seconds"
        case isFinal = "is_final"
        case speakerActivity = "speaker_activity"
    }
}

struct ContextSettings: Codable, Equatable {
    var enabled = true
    var topic = ""
    var terms = ""

    var phrases: [String] {
        var seen = Set<String>()
        return terms.components(separatedBy: CharacterSet(charactersIn: ",;\n\r"))
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(64).map { $0 }
    }
}

struct SegmentCorrection: Codable, Equatable {
    let originalText: String
    let correctedText: String
    let elapsedSeconds: Double
    let sourceFingerprint: String
    let accepted: Bool
    let rejectionReason: String?
    var proposedText: String? = nil
    var provider: String? = nil
    var model: String? = nil
    var referenceIDs: [String]? = nil
}

struct SavedContext: Encodable {
    let enabled: Bool
    let topic: String
    let terms: [String]
    let applied_asr_terms: [String]
    let correction_model: String
    let correction_status: String
}

struct SavedSegment: Codable {
    let id: Int
    let speaker: Int
    let speaker_name: String?
    let start_time: Double
    let end_time: Double
    let text: String
    let corrected_text: String?
    let correction_seconds: Double?
    let correction_status: String?
    let correction_note: String?
    var recognition_provider: String? = nil
    var local_draft: String? = nil
    var proposed_text: String? = nil
    var correction_provider: String? = nil
    var correction_model: String? = nil
    var reference_ids: [String]? = nil
    var acoustic_speaker: Int? = nil
}

struct SavedRecognition: Encodable {
    let provider: String
    let model: String
    let diarization: String
    let status: String
    let error: String?
    let completed_chunks: Int
    let request_seconds: [Double]
    var local_fallback_chunks: [Int] = []
}

struct SavedAudioFile: Encodable {
    let path: String
    let format: String
    let codec: String
    let sample_rate: Int
    let channels: Int
    let bit_rate: Int
    let duration_seconds: Double
    let status: String
    let error: String?
}

struct SavedDiagnostics: Encodable {
    let event_log: String
    let comparison: String
    let status: String
    let cloud_target_seconds: Double
    let cloud_maximum_seconds: Double
}

struct SavedSpeaker: Codable {
    let speaker: Int
    let name: String?
}

struct TranscriptDocument: Encodable {
    let schema_version = 15
    let app = "테이블로그"
    let engine = "NVIDIA NeMo-Speech.cpp / Metal"
    let engine_revision = "6a3ca369370782acee0dd155e34394ba60b920c4"
    let language = "ko-KR"
    let speaker_capacity = 8
    let session_id: String
    let title: String
    let started_at: String
    let saved_at: String
    let source: String
    let status: String
    let duration_seconds: Double
    let text: String
    let corrected_text: String
    let context: SavedContext
    let speakers: [SavedSpeaker]
    let segments: [SavedSegment]
    var ended_at: String? = nil
    var transcript_edits: [TranscriptTextEdit]? = nil
    var manual_transcript_edits: [ManualTranscriptEdit]? = nil
    var meeting_materials: MaterialContext? = nil
    var voice_identity: VoiceIdentityExport? = nil
    var voice_name_assignments: VoiceNameAssignmentsExport? = nil
    var meeting_minutes: MeetingWorkRecord? = nil
    var meeting_assistant: AssistantState? = nil
    var speaker_reviews: [SpeakerReviewRecord]? = nil
    var speaker_overrides: [Int: SpeakerOverride]? = nil
    var engine_settings: EngineTuningSettings? = nil
    var correction: SavedCorrectionState? = nil
    var codex_corrections: [CodexCorrectionRecord]? = nil
    var audio_file: SavedAudioFile? = nil
    var diagnostics: SavedDiagnostics? = nil
    var recognition: SavedRecognition? = nil
    var local_draft_text: String? = nil
    var local_draft_segments: [TranscriptSegment]? = nil
    var reprocessing_origin: MeetingReprocessingOrigin? = nil

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum SessionFiles {
    static var directory: URL {
        StorageLocations.transcripts
    }
    static func write(_ document: TranscriptDocument, to explicitURL: URL? = nil) throws -> URL {
        let url = explicitURL ?? directory.appendingPathComponent(document.session_id + ".json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.data().write(to: url, options: .atomic)
        return url
    }
}
