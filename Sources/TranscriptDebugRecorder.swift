import Foundation

/// A local, append-only event history plus an atomic, human-readable comparison.
/// Audio samples and service credentials are deliberately outside this interface.
final class TranscriptDebugRecorder: @unchecked Sendable {
    let logURL: URL
    let comparisonURL: URL

    private let queue = DispatchQueue(label: "local.TableLog.transcript-debug", qos: .utility)
    private let sessionID: UUID
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private let formatter: ISO8601DateFormatter
    private var firstError: Error?
    private var sequence = 0
    private var previousText: String?
    private var previousSegments: [TranscriptSegment] = []
    private var previousSpeakerNames: [Int: String]?
    private var previousFinishData: Data?
    private var comparison: DebugComparisonDocument

    init(directory: URL, sessionID: UUID) throws {
        self.sessionID = sessionID
        logURL = directory.appendingPathComponent(sessionID.uuidString + ".debug.jsonl")
        comparisonURL = directory.appendingPathComponent(sessionID.uuidString + ".comparison.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let created = formatter.string(from: Date())
        comparison = DebugComparisonDocument(session_id: sessionID.uuidString, started_at: created)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: comparisonURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try Data().write(to: logURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        handle = try FileHandle(forWritingTo: logURL)
        try appendEvent("session_started", payload: DebugStarted(comparison_file: comparisonURL.lastPathComponent))
        try writeComparison()
    }

    deinit { try? handle.close() }

    func recordLocal(snapshot: EngineSnapshot) {
        enqueue {
            // Revisions and advancing clocks alone do not create duplicate events.
            guard self.previousText != snapshot.text || self.previousSegments != snapshot.segments else { return }
            let previousByID = Dictionary(self.previousSegments.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let currentIDs = Set(snapshot.segments.map(\.id))
            let changed = snapshot.segments.filter { previousByID[$0.id] != $0 }
            let removed = self.previousSegments.map(\.id).filter { !currentIDs.contains($0) }.sorted()
            let changedIDs = Set(changed.map(\.id)).union(removed)
            let previousChanged = self.previousSegments.filter { changedIDs.contains($0.id) }
            let patch = TranscriptTextPatch.between(self.previousText ?? "", snapshot.text)
            let payload = DebugLocalUpdate(
                revision: snapshot.revision, audio_seconds: snapshot.audioSeconds,
                processed_seconds: snapshot.processedSeconds, is_final: snapshot.isFinal,
                text_patch: patch,
                text_diff: TranscriptTextDifference.between(patch.removed_text, patch.inserted_text),
                changed_segments: changed, previous_changed_segments: previousChanged, deleted_segment_ids: removed)
            try self.appendEvent("local_updated", payload: payload)
            self.previousText = snapshot.text
            self.previousSegments = snapshot.segments
            self.comparison.local_update_count += 1
        }
    }

    func recordCloud(chunkID: Int, start: Double, end: Double,
                     localAtSubmission: String, localAtResponse: String,
                     transcript: GeminiTranscript, speakers: [TranscriptSegment]) {
        enqueue {
            let item = DebugChunkComparison(
                chunk_id: chunkID, start_time: start, end_time: end,
                received_at: self.timestamp(), request_seconds: transcript.elapsedSeconds,
                local_at_submission: localAtSubmission, local_at_response: localAtResponse,
                gemini_text: transcript.text, gemini_words: transcript.words, gemini_segments: speakers,
                gemini_timing_notes: transcript.timingNotes,
                submission_to_response_diff: TranscriptTextDifference.between(localAtSubmission, localAtResponse),
                submission_to_gemini_diff: TranscriptTextDifference.between(localAtSubmission, transcript.text),
                response_to_gemini_diff: TranscriptTextDifference.between(localAtResponse, transcript.text))
            try self.appendEvent("gemini_received", payload: item)
            // Keep every response in the event history; the sidecar keeps the latest
            // response per request ID so a future explicit retry remains readable.
            if let index = self.comparison.chunks.firstIndex(where: { $0.chunk_id == chunkID }) {
                self.comparison.chunks[index] = item
            } else {
                self.comparison.chunks.append(item)
            }
            self.comparison.chunks.sort { $0.chunk_id < $1.chunk_id }
            try self.writeComparison()
        }
    }

    func recordSpeakerReview(_ record: SpeakerReviewRecord) {
        enqueue {
            try self.appendEvent("speaker_review", payload: record)
            if let index = self.comparison.speaker_reviews.firstIndex(where: { $0.id == record.id }) {
                self.comparison.speaker_reviews[index] = record
            } else { self.comparison.speaker_reviews.append(record) }
            try self.writeComparison()
        }
    }

    func recordCodex(_ record: CodexCorrectionRecord) {
        enqueue {
            try self.appendEvent("codex_correction", payload: record)
            self.comparison.codex_corrections.append(record)
            try self.writeComparison()
        }
    }

    func recordFailure(message: String, detailsJSON: String? = nil) {
        enqueue {
            let details = detailsJSON.map { text in
                (try? JSONDecoder().decode(DebugJSONValue.self, from: Data(text.utf8))) ?? .string(text)
            }
            let failure = DebugFailure(timestamp: self.timestamp(), message: Self.safeErrorMessage(message), details: details)
            try self.appendEvent("cloud_failed", payload: failure)
            self.comparison.failures.append(failure)
            try self.writeComparison()
        }
    }

    func recordSpeakerNames(_ names: [Int: String]) {
        enqueue {
            guard self.previousSpeakerNames != names else { return }
            let speakers = names.keys.sorted().map { SavedSpeaker(speaker: $0, name: names[$0]) }
            try self.appendEvent("speaker_names_changed", payload: DebugSpeakerNames(speakers: speakers))
            self.previousSpeakerNames = names
            self.comparison.speakers = speakers
            try self.writeComparison()
        }
    }

    func recordAudioFile(url: URL, status: String, duration: Double) {
        enqueue {
            let audio = DebugAudioFile(path: url.path, status: status, duration_seconds: duration)
            guard self.comparison.audio_file != audio else { return }
            try self.appendEvent("audio_file_updated", payload: audio)
            self.comparison.audio_file = audio
            try self.writeComparison()
        }
    }

    func finish(local: EngineSnapshot?, displayed: [TranscriptSegment], speakerNames: [Int: String]) {
        enqueue {
            let names = speakerNames.keys.sorted().map { SavedSpeaker(speaker: $0, name: speakerNames[$0]) }
            let final = DebugFinished(local_revision: local?.revision, local_text: local?.text,
                                      local_segments: local?.segments, displayed_segments: displayed, speakers: names)
            let finalData = try self.encoder.encode(final)
            guard self.previousFinishData != finalData else { return }
            for index in self.comparison.chunks.indices {
                let chunk = self.comparison.chunks[index]
                if let local {
                    let aligned = Self.localText(in: local, start: chunk.start_time, end: chunk.end_time)
                    self.comparison.chunks[index].final_local_text = aligned.text
                    self.comparison.chunks[index].final_local_alignment = aligned.method
                    self.comparison.chunks[index].final_local_to_gemini_diff =
                        TranscriptTextDifference.between(aligned.text, chunk.gemini_text)
                }
            }
            self.comparison.finalized_at = self.timestamp()
            self.comparison.final_local_text = local?.text
            self.comparison.final_local_segments = local?.segments
            self.comparison.displayed_segments = displayed
            self.comparison.speakers = names
            self.previousSpeakerNames = speakerNames
            try self.appendEvent("session_finished", payload: final)
            try self.writeComparison()
            self.previousFinishData = finalData
        }
    }

    /// Waits for queued writes, synchronizes the event file, and reports the first
    /// write failure. Call after the final event and before marking a save complete.
    func flush() throws {
        try queue.sync {
            do {
                try writeComparison()
                try handle.synchronize()
            } catch { if firstError == nil { firstError = error } }
            if let firstError { throw firstError }
        }
    }

    private func enqueue(_ operation: @escaping @Sendable () throws -> Void) {
        queue.async {
            do { try operation() }
            catch { if self.firstError == nil { self.firstError = error } }
        }
    }

    private func timestamp() -> String { formatter.string(from: Date()) }

    private func appendEvent<Payload: Encodable>(_ type: String, payload: Payload) throws {
        let event = DebugEvent(schema_version: 1, session_id: sessionID.uuidString,
                               sequence: sequence, timestamp: timestamp(), event: type, payload: payload)
        var data = try encoder.encode(event)
        data.append(0x0a)
        try handle.write(contentsOf: data)
        sequence += 1
    }

    private func writeComparison() throws {
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try pretty.encode(comparison).write(to: comparisonURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: comparisonURL.path)
    }

    private static func localText(in snapshot: EngineSnapshot, start: Double, end: Double) -> (text: String, method: String) {
        if !snapshot.words.isEmpty {
            let text = snapshot.words.filter {
                let midpoint = ($0.start + $0.end) / 2
                return midpoint >= start && midpoint < end
            }.map(\.text).joined(separator: " ")
            return (text, "word_midpoint")
        }
        let text = snapshot.segments.filter { $0.endTime > start && $0.startTime < end }
            .map(\.text).joined(separator: " ")
        return (text, "segment_overlap")
    }

    private static func safeErrorMessage(_ message: String) -> String {
        var result = String(message.prefix(2_000))
        for pattern in [#"AQ\.[A-Za-z0-9_.-]{20,}"#, #"AIza[A-Za-z0-9_-]{20,}"#,
                        #"(?i)(?:x-goog-api-key|authorization)\s*[:=]\s*[^\s,;]+"#,
                        #"(?i)Bearer\s+[A-Za-z0-9_.-]+"#] {
            result = result.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        return result
    }
}

/// Retains only the edited range, so incremental local updates do not repeatedly
/// write an entire meeting transcript. Counts refer to Swift Character graphemes.
struct TranscriptTextPatch: Codable, Equatable {
    let prefix_characters: Int
    let suffix_characters: Int
    let removed_text: String
    let inserted_text: String

    static func between(_ before: String, _ after: String) -> Self {
        let old = Array(before), new = Array(after)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        return Self(prefix_characters: prefix, suffix_characters: suffix,
                    removed_text: String(old[prefix..<(old.count - suffix)]),
                    inserted_text: String(new[prefix..<(new.count - suffix)]))
    }
}

/// The exact source strings live beside this diff. Character-based operations
/// preserve Korean graphemes, whitespace, and punctuation for debugging.
struct TranscriptTextDifference: Codable, Equatable {
    struct Operation: Codable, Equatable {
        let operation: String
        let text: String
    }
    let before_characters: Int
    let after_characters: Int
    let inserted_characters: Int
    let deleted_characters: Int
    let truncated: Bool
    let operations: [Operation]

    static func between(_ before: String, _ after: String) -> Self {
        let old = Array(before), new = Array(after)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let oldMiddle = Array(old[prefix..<(old.count - suffix)])
        let newMiddle = Array(new[prefix..<(new.count - suffix)])
        // Common prefixes/suffixes make long, slowly evolving transcripts cheap.
        // A wholesale rewrite uses a bounded coarser diff with exact full strings.
        let coarse = oldMiddle.count + newMiddle.count > 20_000 ||
            (oldMiddle.count > 0 && newMiddle.count > 1_000_000 / oldMiddle.count)
        var output: [Operation] = []
        var inserted = 0, deleted = 0
        func append(_ kind: String, _ characters: [Character]) {
            guard !characters.isEmpty else { return }
            let value = String(characters)
            if let last = output.last, last.operation == kind {
                output[output.count - 1] = Operation(operation: kind, text: last.text + value)
            } else { output.append(Operation(operation: kind, text: value)) }
            if kind == "insert" { inserted += characters.count }
            if kind == "delete" { deleted += characters.count }
        }
        append("equal", Array(old.prefix(prefix)))
        if coarse {
            append("delete", oldMiddle)
            append("insert", newMiddle)
        } else {
            let changes = newMiddle.difference(from: oldMiddle)
            var removals = Set<Int>(), additions = Set<Int>()
            for change in changes {
                switch change {
                case .remove(let offset, _, _): removals.insert(offset)
                case .insert(let offset, _, _): additions.insert(offset)
                }
            }
            var oldIndex = 0, newIndex = 0
            while oldIndex < oldMiddle.count || newIndex < newMiddle.count {
                if oldIndex < oldMiddle.count && removals.contains(oldIndex) {
                    append("delete", [oldMiddle[oldIndex]]); oldIndex += 1
                } else if newIndex < newMiddle.count && additions.contains(newIndex) {
                    append("insert", [newMiddle[newIndex]]); newIndex += 1
                } else if oldIndex < oldMiddle.count && newIndex < newMiddle.count {
                    append("equal", [oldMiddle[oldIndex]]); oldIndex += 1; newIndex += 1
                } else {
                    // CollectionDifference always accounts for any trailing item.
                    // Preserve it defensively if a future implementation changes.
                    if oldIndex < oldMiddle.count { append("delete", [oldMiddle[oldIndex]]); oldIndex += 1 }
                    if newIndex < newMiddle.count { append("insert", [newMiddle[newIndex]]); newIndex += 1 }
                }
            }
        }
        append("equal", Array(old.suffix(suffix)))
        return Self(before_characters: old.count, after_characters: new.count,
                    inserted_characters: inserted, deleted_characters: deleted,
                    truncated: coarse, operations: output)
    }
}

private struct DebugEvent<Payload: Encodable>: Encodable {
    let schema_version: Int
    let session_id: String
    let sequence: Int
    let timestamp: String
    let event: String
    let payload: Payload
}

private struct DebugStarted: Encodable { let comparison_file: String }

private struct DebugLocalUpdate: Encodable {
    let revision: Int
    let audio_seconds: Double
    let processed_seconds: Double
    let is_final: Bool
    let text_patch: TranscriptTextPatch
    let text_diff: TranscriptTextDifference
    let changed_segments: [TranscriptSegment]
    let previous_changed_segments: [TranscriptSegment]
    let deleted_segment_ids: [Int]
}

private struct DebugFailure: Encodable {
    let timestamp: String
    let message: String
    let details: DebugJSONValue?
}

private struct DebugSpeakerNames: Encodable { let speakers: [SavedSpeaker] }

private enum DebugJSONValue: Codable {
    case object([String: DebugJSONValue]), array([DebugJSONValue]), string(String), number(Double), boolean(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: DebugJSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([DebugJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private struct DebugChunkComparison: Encodable {
    let chunk_id: Int
    let start_time: Double
    let end_time: Double
    let received_at: String
    let request_seconds: Double
    let local_at_submission: String
    let local_at_response: String
    let gemini_text: String
    let gemini_words: [GeminiWord]
    let gemini_segments: [TranscriptSegment]
    let gemini_timing_notes: [GeminiTimingNote]
    let submission_to_response_diff: TranscriptTextDifference
    let submission_to_gemini_diff: TranscriptTextDifference
    let response_to_gemini_diff: TranscriptTextDifference
    var final_local_text: String?
    var final_local_alignment: String?
    var final_local_to_gemini_diff: TranscriptTextDifference?
}

private struct DebugFinished: Encodable {
    let local_revision: Int?
    let local_text: String?
    let local_segments: [TranscriptSegment]?
    let displayed_segments: [TranscriptSegment]
    let speakers: [SavedSpeaker]
}

private struct DebugAudioFile: Encodable, Equatable {
    let path: String
    let format = "m4a"
    let codec = "aac"
    let sample_rate = 16_000
    let channels = 1
    let status: String
    let duration_seconds: Double
}

private struct DebugComparisonDocument: Encodable {
    let schema_version = 1
    let session_id: String
    let started_at: String
    let cloud_model = "gemini-3.5-transcribe"
    let word_timestamp_origin = "chunk_start"
    let segment_timestamp_origin = "session_start"
    var local_update_count = 0
    var chunks: [DebugChunkComparison] = []
    var codex_corrections: [CodexCorrectionRecord] = []
    var speaker_reviews: [SpeakerReviewRecord] = []
    var failures: [DebugFailure] = []
    var finalized_at: String?
    var final_local_text: String?
    var final_local_segments: [TranscriptSegment]?
    var displayed_segments: [TranscriptSegment]?
    var speakers: [SavedSpeaker] = []
    var audio_file: DebugAudioFile?
}
