import Foundation

struct GeminiWord: Codable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

struct GeminiTimingNote: Codable, Sendable {
    let annotation_index: Int
    let reason: String
    let original_start: Double
    let original_end: Double
    let start: Double
    let end: Double
}

struct GeminiTranscript: Sendable {
    let text: String
    let words: [GeminiWord]
    let elapsedSeconds: Double
    var timingNotes: [GeminiTimingNote] = []
}

struct GeminiResponseDiagnosticError: LocalizedError {
    let message: String
    let diagnosticJSON: String
    var errorDescription: String? { message }
}

enum GeminiTranscriberError: LocalizedError {
    case missingKey, invalidAudio, audioTooLong, authentication, quota, unavailable
    case rejected, timeout, network, response, timestamps

    var errorDescription: String? {
        switch self {
        case .missingKey: return "클라우드 전사를 시작하려면 Gemini API 키를 등록해 주세요."
        case .invalidAudio: return "전송할 음성의 샘플과 길이를 확인해 주세요. 로컬 전사 결과를 유지합니다."
        case .audioTooLong: return "Gemini 전사에는 5분 이하의 음성 구간을 사용합니다. 로컬 전사 결과를 유지합니다."
        case .authentication: return "Gemini API 키와 프로젝트의 API 사용 권한을 확인해 주세요."
        case .quota: return "Gemini 요청 한도 또는 사용량 한도에 도달했습니다. 한도를 확인한 뒤 다시 시작해 주세요."
        case .unavailable: return "Gemini 서비스가 일시적으로 응답하기 어렵습니다. 로컬 전사 결과를 유지합니다."
        case .rejected: return "Gemini 전사 요청이 거절되었습니다. 모델 사용 권한과 요청 설정을 확인해 주세요."
        case .timeout: return "Gemini 전사 응답 대기 시간이 60초를 초과했습니다. 로컬 전사 결과를 유지합니다."
        case .network: return "Gemini 연결 상태를 확인해 주세요. 로컬 전사 결과를 유지합니다."
        case .response: return "Gemini 전사 결과를 확인하는 중 오류가 발생했습니다. 로컬 전사 결과를 유지합니다."
        case .timestamps: return "Gemini 단어 시간 정보의 검증이 필요해 로컬 전사 결과를 유지합니다."
        }
    }
}

actor GeminiTranscriber {
    static let modelName = "gemini-3.5-transcribe"
    static let sampleRate = 16_000
    static let maximumSeconds = 300
    private static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    private let suppliedKey: String?

    init(apiKey: String? = nil) { suppliedKey = apiKey }

    func transcribe(samples: [Float]) async throws -> GeminiTranscript {
        try Task.checkCancellation()
        guard let candidate = try suppliedKey ?? GeminiCredentials.read() else { throw GeminiTranscriberError.missingKey }
        let key = try GeminiCredentials.normalizedKey(candidate)
        let request = try Self.makeRequest(samples: samples, key: key)
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: GeminiRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let started = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw GeminiTranscriberError.response }
            try Self.validateHTTPStatus(http.statusCode)
            let duration = started.duration(to: .now)
            let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            return try Self.parseResponse(data, audioDuration: Double(samples.count) / Double(Self.sampleRate),
                                          elapsedSeconds: elapsed, apiKey: key)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let error = error as? GeminiTranscriberError { throw error }
            if let error = error as? GeminiResponseDiagnosticError { throw error }
            if (error as? URLError)?.code == .timedOut { throw GeminiTranscriberError.timeout }
            // HTTP failures and underlying URL errors keep fixed descriptions.
            // Only successful HTTP responses with invalid transcript data carry
            // an explicitly sanitized diagnostic for the local debug recorder.
            throw GeminiTranscriberError.network
        }
    }

    nonisolated static func makeRequest(samples: [Float], key: String) throws -> URLRequest {
        let wave = try encodeWAV(samples: samples)
        let body: [String: Any] = [
            "model": modelName,
            "input": [["type": "audio", "data": wave.base64EncodedString(), "mime_type": "audio/wav"]],
            "generation_config": ["transcription_config": [
                "language_codes": ["ko-KR"],
                "mode": ["type": "verbatim", "timestamp_granularities": ["word"]]
            ]]
        ]
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    nonisolated static func encodeWAV(samples: [Float]) throws -> Data {
        guard !samples.isEmpty else { throw GeminiTranscriberError.invalidAudio }
        guard samples.count <= sampleRate * maximumSeconds else { throw GeminiTranscriberError.audioTooLong }
        let byteCount = samples.count * 2
        var result = Data(capacity: 44 + byteCount)
        func ascii(_ text: String) { result.append(contentsOf: text.utf8) }
        func u16(_ value: UInt16) {
            result.append(UInt8(truncatingIfNeeded: value))
            result.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func u32(_ value: UInt32) {
            u16(UInt16(truncatingIfNeeded: value))
            u16(UInt16(truncatingIfNeeded: value >> 16))
        }
        ascii("RIFF"); u32(UInt32(36 + byteCount)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        ascii("data"); u32(UInt32(byteCount))
        for (index, sample) in samples.enumerated() {
            if index % sampleRate == 0 { try Task.checkCancellation() }
            guard sample.isFinite else { throw GeminiTranscriberError.invalidAudio }
            let clipped = max(-1, min(1, sample))
            let integer = Int16((clipped < 0 ? clipped * 32768 : clipped * 32767).rounded())
            u16(UInt16(bitPattern: integer))
        }
        return result
    }

    nonisolated static func validateHTTPStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw GeminiTranscriberError.authentication
        case 429: throw GeminiTranscriberError.quota
        case 408, 504: throw GeminiTranscriberError.timeout
        case 500...599: throw GeminiTranscriberError.unavailable
        default: throw GeminiTranscriberError.rejected
        }
    }

    nonisolated static func parse(_ data: Data, audioDuration: Double, elapsedSeconds: Double) throws -> GeminiTranscript {
        do {
            return try validatedTranscript(data, audioDuration: audioDuration, elapsedSeconds: elapsedSeconds)
        } catch let failure as ValidationFailure {
            // Preserve the existing error contract for callers that parse a
            // fixture directly, independently of a network request.
            throw failure.error
        }
    }

    nonisolated static func parseResponse(_ data: Data, audioDuration: Double, elapsedSeconds: Double,
                                         apiKey: String) throws -> GeminiTranscript {
        do {
            return try validatedTranscript(data, audioDuration: audioDuration, elapsedSeconds: elapsedSeconds)
        } catch let failure as ValidationFailure {
            throw GeminiResponseDiagnosticError(
                message: failure.error.localizedDescription,
                diagnosticJSON: diagnosticJSON(data, failure: failure, audioDuration: audioDuration,
                                               elapsedSeconds: elapsedSeconds, apiKey: apiKey)
            )
        }
    }

    private static let maximumResponseBytes = 8 * 1024 * 1024

    private struct ValidationFailure: Error {
        let error: GeminiTranscriberError
        let reasonCode: String
        var annotationIndex: Int? = nil
        var details: [String: String] = [:]
    }

    nonisolated private static func validatedTranscript(_ data: Data, audioDuration: Double,
                                                       elapsedSeconds: Double) throws -> GeminiTranscript {
        guard data.count <= maximumResponseBytes else {
            throw ValidationFailure(error: .response, reasonCode: "response_too_large")
        }
        guard audioDuration.isFinite, audioDuration > 0 else {
            throw ValidationFailure(error: .response, reasonCode: "invalid_audio_duration")
        }
        guard elapsedSeconds.isFinite, elapsedSeconds >= 0 else {
            throw ValidationFailure(error: .response, reasonCode: "invalid_elapsed_seconds")
        }
        let body: Interaction
        do { body = try JSONDecoder().decode(Interaction.self, from: data) }
        catch {
            // A completed silent microphone request can omit `steps` entirely.
            // Accept only the observed empty-output envelope; malformed steps,
            // another model, or missing/nonzero output usage retain the error.
            if case DecodingError.keyNotFound(let key, let context) = error,
               key.stringValue == "steps", context.codingPath.isEmpty,
               let empty = try? JSONDecoder().decode(EmptyOutputInteraction.self, from: data),
               empty.status == "completed", empty.model == modelName,
               empty.usage.total_output_tokens == 0 {
                return GeminiTranscript(text: "", words: [], elapsedSeconds: elapsedSeconds)
            }
            throw ValidationFailure(error: .response, reasonCode: "response_decoding_failed",
                                    details: decodingDetails(error))
        }
        guard body.status == "completed" else {
            throw ValidationFailure(error: .response, reasonCode: "interaction_not_completed",
                                    details: ["status": body.status])
        }
        let contents = body.steps.filter { $0.type == "model_output" }.flatMap(\.content).filter { $0.type == "text" }
        let text = contents.compactMap(\.text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let annotations = contents.flatMap({ $0.annotations ?? [] }).filter { $0.type == "word_info" }
        if text.isEmpty && annotations.isEmpty {
            return GeminiTranscript(text: "", words: [], elapsedSeconds: elapsedSeconds)
        }
        guard !text.isEmpty else {
            throw ValidationFailure(error: .response, reasonCode: "empty_transcript_with_word_annotations")
        }
        var words: [GeminiWord] = []
        var timingNotes: [GeminiTimingNote] = []
        var previousOriginalStart: Double?
        var previousOriginalEnd: Double?
        for (index, annotation) in annotations.enumerated() {
            let start = seconds(annotation.start_offset)
            let end = seconds(annotation.end_offset)
            var details: [String: String] = [
                "start_offset": annotation.start_offset ?? "<missing>",
                "end_offset": annotation.end_offset ?? "<missing>",
                "start": start.map(String.init(describing:)) ?? "<invalid>",
                "end": end.map(String.init(describing:)) ?? "<invalid>",
                "audio_end_tolerance_seconds": "0.5"
            ]
            if let previous = words.last {
                details["previous_start"] = String(previous.start)
                details["previous_end"] = String(previous.end)
            }
            if let previousOriginalStart { details["previous_original_start"] = String(previousOriginalStart) }
            if let previousOriginalEnd { details["previous_original_end"] = String(previousOriginalEnd) }
            func fail(_ reason: String) -> ValidationFailure {
                ValidationFailure(error: .timestamps, reasonCode: reason, annotationIndex: index, details: details)
            }
            guard let source = annotation.text, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw fail("missing_word_text")
            }
            guard let start else { throw fail("invalid_start_offset") }
            guard let end else { throw fail("invalid_end_offset") }
            guard start >= 0 else { throw fail("negative_start_offset") }
            guard end >= start else { throw fail("end_before_start") }
            guard end <= audioDuration + 0.5 else { throw fail("end_after_audio_tolerance") }
            if let previousOriginalStart {
                guard start >= previousOriginalStart else { throw fail("non_monotonic_start") }
            }
            // A zero-length annotation remains a point timestamp. Preserve its
            // word rather than inventing a duration or deleting provider text.
            // The existing end tolerance also bounds start because end >= start.
            let clippedStart = min(start, audioDuration)
            let clippedEnd = min(end, audioDuration)
            func note(_ reason: String) {
                timingNotes.append(GeminiTimingNote(annotation_index: index, reason: reason,
                    original_start: start, original_end: end, start: clippedStart, end: clippedEnd))
            }
            if clippedStart != start || clippedEnd != end { note("audio_end_clipped") }
            if clippedStart == clippedEnd { note("zero_duration") }
            if let previousOriginalEnd, end < previousOriginalEnd { note("nested_word_end") }
            words.append(GeminiWord(text: source, start: clippedStart, end: clippedEnd))
            previousOriginalStart = start
            previousOriginalEnd = end
        }
        guard !words.isEmpty else {
            throw ValidationFailure(error: .timestamps, reasonCode: "missing_word_annotations")
        }
        return GeminiTranscript(text: text, words: words, elapsedSeconds: elapsedSeconds, timingNotes: timingNotes)
    }

    nonisolated private static func decodingDetails(_ error: Error) -> [String: String] {
        let kind: String
        let path: [CodingKey]
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            kind = "missing_key"; path = context.codingPath + [key]
        case DecodingError.typeMismatch(_, let context):
            kind = "type_mismatch"; path = context.codingPath
        case DecodingError.valueNotFound(_, let context):
            kind = "missing_value"; path = context.codingPath
        case DecodingError.dataCorrupted(let context):
            kind = "invalid_json_or_value"; path = context.codingPath
        default:
            kind = "decoding_error"; path = []
        }
        // Avoid localized decoding errors, which may quote provider content.
        return ["decoding_reason": kind, "coding_path": path.map(\.stringValue).joined(separator: ".")]
    }

    nonisolated private static func diagnosticJSON(_ data: Data, failure: ValidationFailure,
                                                   audioDuration: Double, elapsedSeconds: Double,
                                                   apiKey: String) -> String {
        func redact(_ value: String) -> String {
            apiKey.isEmpty ? value : value.replacingOccurrences(of: apiKey, with: "[REDACTED_API_KEY]")
        }
        func sanitized(_ value: Any) -> Any {
            if let string = value as? String { return redact(string) }
            if let array = value as? [Any] { return array.map(sanitized) }
            if let object = value as? [String: Any] {
                var result: [String: Any] = [:]
                for (key, value) in object { result[redact(key)] = sanitized(value) }
                return result
            }
            return value
        }
        // Only the provider response is inspected. Request audio, headers and
        // request bodies never enter this diagnostic payload.
        // Include one key length beyond the excerpt boundary before redaction,
        // so a credential crossing that boundary is redacted in full.
        let excerptSource = data.prefix(4096 + apiKey.utf8.count)
        let excerpt = String(redact(String(decoding: excerptSource, as: UTF8.self)).prefix(4096))
        var result: [String: Any] = [
            "reason_code": failure.reasonCode,
            "audio_duration_seconds": audioDuration.isFinite ? audioDuration as Any : NSNull(),
            "elapsed_seconds": elapsedSeconds.isFinite ? elapsedSeconds as Any : NSNull(),
            "response_bytes": data.count,
            "validation_details": sanitized(failure.details)
        ]
        if let index = failure.annotationIndex { result["annotation_index"] = index }
        if data.count <= maximumResponseBytes,
           let response = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            result["response"] = sanitized(response)
        } else {
            result["response"] = ["safe_excerpt": excerpt]
            result["response_truncated"] = data.count > 4096
        }
        func encode() -> Data? { try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) }
        if let encoded = encode(), encoded.count <= maximumResponseBytes {
            return String(decoding: encoded, as: UTF8.self)
        }
        // Bound the complete diagnostic, including JSON escaping and metadata.
        result["response"] = ["safe_excerpt": excerpt]
        result["response_truncated"] = true
        return encode().map { String(decoding: $0, as: UTF8.self) }
            ?? "{\"reason_code\":\"diagnostic_encoding_failed\"}"
    }

    nonisolated private static func seconds(_ value: String?) -> Double? {
        guard let value, value.count <= 40,
              value.range(of: "^\\d+(?:\\.\\d+)?s$", options: .regularExpression) != nil,
              let number = Double(value.dropLast()), number.isFinite else { return nil }
        return number
    }

    private struct Interaction: Decodable {
        let status: String
        let steps: [Step]
    }
    private struct EmptyOutputInteraction: Decodable {
        struct Usage: Decodable { let total_output_tokens: Int }
        let status: String
        let model: String
        let usage: Usage
    }
    private struct Step: Decodable {
        let type: String
        let content: [Content]
    }
    private struct Content: Decodable {
        let type: String
        let text: String?
        let annotations: [Annotation]?
    }
    private struct Annotation: Decodable {
        let type: String
        let text: String?
        let start_offset: String?
        let end_offset: String?
    }
}

private final class GeminiRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
