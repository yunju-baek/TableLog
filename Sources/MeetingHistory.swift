import Foundation
import Combine
import CryptoKit
import Darwin

struct MeetingHistoryEntry: Identifiable {
    let id: UUID
    let title: String
    let date: Date
    let duration: Double
    let segmentCount: Int
    let materialCount: Int
    let hasMinutes: Bool
    let transcriptURL: URL?
    let recordURL: URL?
    let minutesURL: URL?
    let assistantURL: URL?
    let warnings: [String]
}

struct MeetingHistorySnapshot {
    let id: UUID
    let title: String
    let date: Date
    let duration: Double
    let segments: [MeetingUtterance]
    let names: [Int: String]
    let materials: MaterialContext
    let record: MeetingWorkRecord?
    let markdown: String
    let audioURL: URL?
    let transcriptURL: URL?
    let recordURL: URL?
    let diagnosticsURL: URL?
    let comparisonURL: URL?
    let minutesURL: URL?
    let context: ContextSettings
    let assistantState: AssistantState?
    let warnings: [String]
}

struct MeetingHistoryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor final class MeetingHistoryStore: ObservableObject {
    @Published private(set) var items: [MeetingHistoryEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var status = "지난 회의를 불러올 수 있습니다."
    private let transcripts: URL
    private let minutes: URL
    private let assistant: URL
    private var generation = UUID()
    private let snapshotCache: MeetingHistorySnapshotCache

    init(transcripts: URL = StorageLocations.transcripts, minutes: URL = StorageLocations.minutes, assistant: URL? = nil) {
        self.transcripts = transcripts; self.minutes = minutes
        self.assistant = assistant ?? minutes.deletingLastPathComponent().appendingPathComponent("Assistant")
        self.snapshotCache = MeetingHistorySnapshotCache(transcripts: transcripts, minutes: minutes, assistant: self.assistant)
    }
    func refresh() async {
        let token = UUID(); generation = token; loading = true; error = nil
        await snapshotCache.invalidate()
        let transcripts = transcripts, minutes = minutes, assistant = assistant
        let result = await Task.detached(priority: .utility) { MeetingHistoryReader.scan(transcripts: transcripts, minutes: minutes, assistant: assistant) }.value
        guard generation == token, !Task.isCancelled else { if generation == token { loading = false }; return }
        items = result.items; loading = false
        status = items.isEmpty ? "저장된 회의가 여기에 표시됩니다." : "\(items.count)개 회의 · 원본 열람과 사본 재가공"
        if !result.warnings.isEmpty {
            status += " · \(result.warnings.count)개 기록 확인 필요"
            error = result.warnings.prefix(3).joined(separator: "\n")
        }
    }
    func load(_ entry: MeetingHistoryEntry) async throws -> MeetingHistorySnapshot {
        try Task.checkCancellation()
        let result = try await snapshotCache.load(entry)
        try Task.checkCancellation(); return result
    }
}

/// All I/O is read-only. Parsed values are snapshots, independent of any live meeting state.
enum MeetingHistoryReader {
    struct ScanResult { let items: [MeetingHistoryEntry]; let warnings: [String] }
    private struct Sources {
        let id: UUID
        var transcript: URL?
        var record: URL?
        var markdown: URL?
        var assistant: URL?
        var transcriptSaved = Date.distantPast
        var recordSaved = Date.distantPast
        var transcriptMetadata: IndexMetadata?
        var recordMetadata: IndexMetadata?
    }
    private struct IndexMetadata {
        let title: String?
        let date: Date?
        let saved: Date?
        let preciseSavedTime: Bool
        let duration: Double
        let count: Int
        let lastEnd: Double
        let materialCount: Int?
        let embeddedTitle: String?
        let embeddedDate: Date?
        let embeddedMaterialCount: Int?
        let embeddedOutput: URL?
        let warnings: [String]
    }
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }
    private struct Segment: Decodable {
        let id: Int?
        let speaker: Int?
        let name: String?
        let start: Double?
        let end: Double?
        let text: String
        let corrected: String?
        let status: String?
        enum CodingKeys: String, CodingKey { case id, speaker, text, start, end, start_time, end_time, speaker_name, corrected_text, correction_status }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try? c.decode(Int.self, forKey: .id); speaker = try? c.decode(Int.self, forKey: .speaker)
            name = try? c.decode(String.self, forKey: .speaker_name)
            start = (try? c.decode(Double.self, forKey: .start_time)) ?? (try? c.decode(Double.self, forKey: .start))
            end = (try? c.decode(Double.self, forKey: .end_time)) ?? (try? c.decode(Double.self, forKey: .end))
            text = (try? c.decode(String.self, forKey: .text)) ?? ""
            corrected = try? c.decode(String.self, forKey: .corrected_text)
            status = try? c.decode(String.self, forKey: .correction_status)
        }
        var effectiveText: String {
            if let status, ["corrected", "unchanged", "accepted"].contains(status), let corrected { return corrected }
            return text
        }
    }
    private struct Context: Decodable {
        let enabled: Bool?
        let topic: String?
        let terms: [String]
        enum CodingKeys: String, CodingKey { case enabled, topic, terms }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try? c.decode(Bool.self, forKey: .enabled); topic = try? c.decode(String.self, forKey: .topic)
            terms = (try? c.decode([String].self, forKey: .terms)) ?? [(try? c.decode(String.self, forKey: .terms)) ?? ""]
        }
        var settings: ContextSettings { var value = ContextSettings(); value.enabled = enabled ?? true; value.topic = topic ?? ""; value.terms = terms.joined(separator: "\n"); return value }
    }
    private struct Materials: Decodable {
        let documents: [MeetingMaterial]
        enum CodingKeys: String, CodingKey { case documents }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            documents = (try? c.decode([Lossy<MeetingMaterial>].self, forKey: .documents))?.compactMap(\.value) ?? []
        }
        var context: MaterialContext {
            var seen = Set<UUID>(), chunkIDs = Set<String>(), result = MaterialContext()
            result.documents = documents.filter { seen.insert($0.id).inserted }.map { document in
                var copy = document
                copy.chunks = copy.chunks.filter { chunkIDs.insert($0.id).inserted }
                return copy
            }
            return result
        }
    }
    private struct Transcript: Decodable {
        let id: UUID?
        let title: String?
        let started: String?
        let saved: String?
        let duration: Double?
        let segments: [Segment]
        let speakers: [SavedSpeaker]
        let context: Context?
        let materials: Materials?
        let record: MeetingWorkRecord?
        let assistant: AssistantState?
        let diagnostics: [String: String]?
        let audioPath: String?
        enum CodingKeys: String, CodingKey { case session_id, title, started_at, saved_at, duration_seconds, segments, speakers, context, meeting_materials, meeting_minutes, meeting_assistant, audio_file, diagnostics }
        private struct Audio: Decodable { let path: String? }
        private struct Diagnostics: Decodable { let event_log: String?; let comparison: String? }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(String.self, forKey: .session_id)).flatMap(UUID.init(uuidString:))
            title = try? c.decode(String.self, forKey: .title); started = try? c.decode(String.self, forKey: .started_at); saved = try? c.decode(String.self, forKey: .saved_at)
            duration = try? c.decode(Double.self, forKey: .duration_seconds)
            segments = (try? c.decode([Lossy<Segment>].self, forKey: .segments))?.compactMap(\.value) ?? []
            let indexOnly = decoder.userInfo[.historyIndexOnly] as? Bool == true
            speakers = indexOnly ? [] : ((try? c.decode([Lossy<SavedSpeaker>].self, forKey: .speakers))?.compactMap(\.value) ?? [])
            context = try? c.decode(Context.self, forKey: .context); materials = try? c.decode(Materials.self, forKey: .meeting_materials)
            record = try? c.decode(MeetingWorkRecord.self, forKey: .meeting_minutes); assistant = indexOnly ? nil : (try? c.decode(AssistantState.self, forKey: .meeting_assistant))
            audioPath = (try? c.decode(Audio.self, forKey: .audio_file))?.path
            if let d = try? c.decode(Diagnostics.self, forKey: .diagnostics) { diagnostics = ["event_log": d.event_log, "comparison": d.comparison].compactMapValues { $0 } } else { diagnostics = nil }
        }
    }
    private struct Record: Decodable {
        let id: UUID?
        let title: String?
        let date: String?
        let purpose: String?
        let updatedAt: Date?
        let segments: [Segment]
        let names: [Int: String]
        let materials: Materials?
        let output: String?
        let editedOutput: String?
        enum CodingKeys: String, CodingKey { case id, title, date, purpose, updatedAt, segments, names, materials, output, editedOutput }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try? c.decode(UUID.self, forKey: .id); title = try? c.decode(String.self, forKey: .title); date = try? c.decode(String.self, forKey: .date)
            purpose = try? c.decode(String.self, forKey: .purpose); updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? (try? c.decode(String.self, forKey: .updatedAt)).flatMap(MeetingHistoryReader.date)
            segments = (try? c.decode([Lossy<Segment>].self, forKey: .segments))?.compactMap(\.value) ?? []
            names = (try? c.decode([Int: String].self, forKey: .names)) ?? [:]
            materials = try? c.decode(Materials.self, forKey: .materials); output = try? c.decode(String.self, forKey: .output)
            editedOutput = try? c.decode(String.self, forKey: .editedOutput)
        }
    }
    private static let fm = FileManager.default
    private static func read(_ url: URL, limit: Int = 64 * 1024 * 1024) throws -> Data {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= limit else { throw MeetingHistoryError(message: "회의 파일 크기를 확인해 주세요: " + url.lastPathComponent) }
        return try Data(contentsOf: url)
    }
    private static func decoded<T: Decodable>(_ type: T.Type, _ url: URL, indexOnly: Bool = false) throws -> T {
        let decoder = JSONDecoder()
        decoder.userInfo[.historyIndexOnly] = indexOnly
        return try decoder.decode(type, from: read(url))
    }
    private static func modified(_ url: URL) -> Date { (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast }
    private static func date(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = iso.date(from: value) { return value }
        iso.formatOptions = [.withInternetDateTime]
        if let value = iso.date(from: value) { return value }
        let pieces = value.split(separator: " ")
        if pieces.count == 3, let zone = TimeZone(abbreviation: String(pieces[2])) {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let parsed = formatter.date(from: pieces.prefix(2).joined(separator: " ")) { return parsed }
        }
        for format in ["yyyy-MM-dd HH:mm:ss zzz", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = format
            if let value = formatter.date(from: value) { return value }
        }
        return nil
    }
    private static func files(_ directory: URL, extension suffix: String) throws -> [URL] {
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension.lowercased() == suffix && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private static func uuid(_ url: URL) -> UUID? { UUID(uuidString: url.deletingPathExtension().lastPathComponent) }
    private static func stableID(_ url: URL) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    private static func fileURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("file://"), let url = URL(string: value), url.isFileURL { return url }
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value)
    }
    private static func existing(_ url: URL?) -> URL? { url.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil } }
    private static func title(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func scan(transcripts: URL, minutes: URL, assistant: URL? = nil) -> ScanResult {
        let assistant = assistant ?? minutes.deletingLastPathComponent().appendingPathComponent("Assistant")
        var sources: [UUID: Sources] = [:], warnings: [String] = []
        func list(_ root: URL, _ suffix: String) -> [URL] {
            do { return try files(root, extension: suffix) }
            catch { warnings.append("저장 폴더 확인: " + root.lastPathComponent + " · " + error.localizedDescription); return [] }
        }
        for url in list(transcripts, "json") {
            do {
                let value = try decoded(Transcript.self, url, indexOnly: true)
                guard let id = value.id ?? uuid(url), value.id != nil || value.started != nil || !value.segments.isEmpty else { throw MeetingHistoryError(message: "회의 식별자와 전사 구조를 확인해 주세요.") }
                let stamp = value.saved.flatMap(date) ?? modified(url)
                var source = sources[id] ?? Sources(id: id)
                if source.transcript == nil || stamp > source.transcriptSaved {
                    source.transcript = url; source.transcriptSaved = stamp
                    let embedded = value.record.flatMap { $0.id == id ? $0 : nil }
                    var itemWarnings: [String] = []
                    let segments = utterances(value.segments, correctionsEnabled: value.context?.enabled != false, warnings: &itemWarnings).0
                    source.transcriptMetadata = IndexMetadata(title: value.title, date: value.started.flatMap(date), saved: value.saved.flatMap(date),
                        preciseSavedTime: value.saved?.contains(".") == true, duration: max(0, value.duration ?? 0), count: segments.count,
                        lastEnd: segments.map(\.end).max() ?? 0, materialCount: value.materials?.context.documents.count,
                        embeddedTitle: embedded?.title, embeddedDate: embedded.flatMap { date($0.date) }, embeddedMaterialCount: embedded?.materials?.documents.count,
                        embeddedOutput: existing(fileURL(embedded?.editedOutput ?? embedded?.output)), warnings: itemWarnings)
                }
                sources[id] = source
            } catch { warnings.append(url.lastPathComponent + " · " + error.localizedDescription) }
        }
        for url in list(minutes.appendingPathComponent("Sessions"), "json") {
            do {
                let value = try decoded(Record.self, url)
                guard let id = value.id ?? uuid(url), value.id != nil || value.date != nil || !value.segments.isEmpty else { throw MeetingHistoryError(message: "회의 식별자와 기록 구조를 확인해 주세요.") }
                let stamp = value.updatedAt ?? modified(url)
                var source = sources[id] ?? Sources(id: id)
                if source.record == nil || stamp > source.recordSaved {
                    source.record = url; source.recordSaved = stamp; source.markdown = existing(fileURL(value.editedOutput ?? value.output))
                    var itemWarnings: [String] = []
                    let segments = utterances(value.segments, warnings: &itemWarnings).0
                    source.recordMetadata = IndexMetadata(title: value.title, date: value.date.flatMap(date), saved: value.updatedAt,
                        preciseSavedTime: true, duration: 0, count: segments.count, lastEnd: segments.map(\.end).max() ?? 0,
                        materialCount: value.materials?.context.documents.count, embeddedTitle: nil, embeddedDate: nil,
                        embeddedMaterialCount: nil, embeddedOutput: existing(fileURL(value.editedOutput ?? value.output)), warnings: itemWarnings)
                }
                sources[id] = source
            } catch { warnings.append(url.lastPathComponent + " · " + error.localizedDescription) }
        }
        for url in list(minutes, "md") {
            if let id = uuid(url) { var source = sources[id] ?? Sources(id: id); if source.markdown == nil { source.markdown = url }; sources[id] = source }
            else if !sources.values.contains(where: { $0.markdown?.standardizedFileURL == url.standardizedFileURL }) { let id = stableID(url); sources[id] = Sources(id: id, markdown: url) }
        }
        var items: [MeetingHistoryEntry] = []
        for source in sources.values {
            let transcript = source.transcriptMetadata, record = source.recordMetadata
            let allowance: TimeInterval = transcript?.preciseSavedTime == true ? 0 : 1
            let newerRecord = record != nil && (transcript == nil || (record?.saved != nil && transcript?.saved != nil && record!.saved! > transcript!.saved!.addingTimeInterval(allowance)))
            let selected = newerRecord ? record : (transcript ?? record)
            let markdown = record?.embeddedOutput ?? transcript?.embeddedOutput ?? source.markdown
            let meetingTitle = title(newerRecord ? record?.title : transcript?.title,
                fallback: title(record?.title ?? transcript?.embeddedTitle, fallback: markdown?.deletingPathExtension().lastPathComponent ?? "저장된 회의"))
            let meetingDate = transcript?.date ?? record?.date ?? transcript?.embeddedDate ?? source.transcript.map(modified) ?? source.record.map(modified) ?? markdown.map(modified) ?? .distantPast
            let materialCount = newerRecord ? (record?.materialCount ?? transcript?.materialCount ?? transcript?.embeddedMaterialCount ?? 0) : (transcript?.materialCount ?? record?.materialCount ?? transcript?.embeddedMaterialCount ?? 0)
            let duration = max(selected?.lastEnd ?? 0, transcript?.duration ?? 0)
            let hasMinutes = markdown.flatMap { try? fm.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }.map { $0.int64Value > 0 } ?? false
            if selected == nil && !hasMinutes { continue }
            items.append(MeetingHistoryEntry(id: source.id, title: meetingTitle, date: meetingDate, duration: duration,
                segmentCount: selected?.count ?? 0, materialCount: materialCount, hasMinutes: hasMinutes,
                transcriptURL: source.transcript, recordURL: source.record, minutesURL: markdown,
                assistantURL: existing(assistant.appendingPathComponent(source.id.uuidString).appendingPathComponent("state.json")), warnings: selected?.warnings ?? []))
        }
        items.sort { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
        return ScanResult(items: items, warnings: warnings)
    }

    private static func utterances(_ raw: [Segment], correctionsEnabled: Bool = true, warnings: inout [String]) -> ([MeetingUtterance], [Int: String]) {
        var result: [MeetingUtterance] = [], names: [Int: String] = [:], used = Set<Int>(), dropped = 0, reassigned = 0
        let reserved = Set(raw.compactMap(\.id)); var nextID = -1
        for segment in raw {
            guard let start = segment.start, let end = segment.end, start.isFinite, end.isFinite, start >= 0, end >= start else { dropped += 1; continue }
            let text = (correctionsEnabled ? segment.effectiveText : segment.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var id = segment.id
            if id == nil || used.contains(id!) {
                while reserved.contains(nextID) || used.contains(nextID) { nextID -= 1 }
                id = nextID; nextID -= 1; reassigned += 1
            }
            used.insert(id!)
            let speaker = (0...8).contains(segment.speaker ?? -1) ? segment.speaker! : 0
            if let name = segment.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, speaker > 0 { names[speaker] = name }
            result.append(MeetingUtterance(id: id!, speaker: speaker, start: start, end: end, text: text))
        }
        if dropped > 0 { warnings.append("시간 정보를 확인할 발언 \(dropped)개를 별도로 남겼습니다. 원본 JSON에서 확인할 수 있습니다.") }
        if reassigned > 0 { warnings.append("중복·누락 발언 식별자 \(reassigned)개에 열람용 식별자를 부여했습니다.") }
        return (result.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }, names)
    }

    static func load(_ entry: MeetingHistoryEntry, beforeRead: ((URL) -> Void)? = nil) throws -> MeetingHistorySnapshot {
        func sourceData(_ url: URL, limit: Int = 64 * 1024 * 1024) throws -> Data {
            beforeRead?(url)
            return try read(url, limit: limit)
        }
        var warnings: [String] = [], transcript: Transcript?, recordDTO: Record?, record: MeetingWorkRecord?
        var transcriptURL: URL?, recordURL: URL?
        if let url = entry.transcriptURL {
            do {
                let value = try JSONDecoder().decode(Transcript.self, from: sourceData(url))
                guard (value.id ?? uuid(url)) == entry.id else { throw MeetingHistoryError(message: "목록의 회의 식별자와 원본 기록이 달라졌습니다.") }
                transcript = value; transcriptURL = url
            } catch { warnings.append("전사 원본 확인: " + error.localizedDescription) }
        }
        if let url = entry.recordURL {
            do {
                let data = try sourceData(url)
                let value = try JSONDecoder().decode(Record.self, from: data)
                guard (value.id ?? uuid(url)) == entry.id else { throw MeetingHistoryError(message: "목록의 회의 식별자와 회의록 기록이 달라졌습니다.") }
                recordDTO = value; recordURL = url; record = try? JSONDecoder().decode(MeetingWorkRecord.self, from: data)
            } catch { warnings.append("회의록 기록 확인: " + error.localizedDescription) }
        }
        if record == nil, let embedded = transcript?.record, embedded.id == entry.id { record = embedded }
        [fileURL(recordDTO?.editedOutput ?? recordDTO?.output), fileURL(record?.editedOutput ?? record?.output), entry.minutesURL].compactMap { $0 }.forEach { beforeRead?($0) }
        let minutesURL = existing(fileURL(recordDTO?.editedOutput ?? recordDTO?.output)) ?? existing(fileURL(record?.editedOutput ?? record?.output)) ?? existing(entry.minutesURL)
        var markdown = ""
        if let minutesURL { do { markdown = String(decoding: try sourceData(minutesURL, limit: 20 * 1024 * 1024), as: UTF8.self) } catch { warnings.append("회의록 파일 확인: " + error.localizedDescription) } }
        guard transcript != nil || recordDTO != nil || !markdown.isEmpty else { throw MeetingHistoryError(message: "회의 원본을 찾을 수 없습니다. 저장 위치를 확인한 뒤 목록을 새로고침해 주세요.") }
        // Saved transcripts already contain projected manual edits and effective speaker IDs.
        // Replaying edit logs here would apply the same operation twice.
        let transcriptTime = transcript?.saved.flatMap(date)
        let recordTime = recordDTO?.updatedAt
        let precisionAllowance: TimeInterval = transcript?.saved?.contains(".") == true ? 0 : 1
        let newerRecord = recordDTO != nil && (transcript == nil || (recordTime != nil && transcriptTime != nil && recordTime! > transcriptTime!.addingTimeInterval(precisionAllowance)))
        let raw = newerRecord ? (recordDTO?.segments ?? []) : (transcript?.segments ?? recordDTO?.segments ?? [])
        var (segments, names) = utterances(raw, correctionsEnabled: newerRecord || transcript?.context?.enabled != false, warnings: &warnings)
        for (speaker, name) in (recordDTO?.names ?? record?.names ?? [:]) where (1...8).contains(speaker) && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { names[speaker] = name }
        if !newerRecord {
            for speaker in transcript?.speakers ?? [] where (1...8).contains(speaker.speaker) {
                if let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { names[speaker.speaker] = name }
            }
            for segment in raw where (1...8).contains(segment.speaker ?? -1) { if let name = segment.name, !name.isEmpty { names[segment.speaker!] = name } }
        }
        let materials = newerRecord ? (recordDTO?.materials?.context ?? transcript?.materials?.context ?? record?.materials ?? MaterialContext()) : (transcript?.materials?.context ?? recordDTO?.materials?.context ?? record?.materials ?? MaterialContext())
        let title = title(newerRecord ? recordDTO?.title : transcript?.title, fallback: title(recordDTO?.title ?? record?.title, fallback: entry.minutesURL?.deletingPathExtension().lastPathComponent ?? "저장된 회의"))
        let meetingDate = transcript?.started.flatMap(date) ?? recordDTO?.date.flatMap(date) ?? record.flatMap { date($0.date) } ?? transcriptURL.map(modified) ?? recordURL.map(modified) ?? minutesURL.map(modified) ?? entry.date
        let segmentDuration = segments.map(\.end).max() ?? 0
        let recordedDuration = transcript?.duration ?? 0
        let duration = max(segmentDuration, recordedDuration.isFinite && recordedDuration >= 0 ? recordedDuration : 0)
        var context = transcript?.context?.settings ?? ContextSettings()
        if context.topic.isEmpty { context.topic = recordDTO?.purpose ?? record?.purpose ?? "" }
        var assistant = transcript?.assistant.flatMap { $0.sessionID == entry.id ? $0 : nil }
        if let url = entry.assistantURL {
            do {
                let value = try JSONDecoder().decode(AssistantState.self, from: sourceData(url))
                guard value.sessionID == entry.id else { throw MeetingHistoryError(message: "도우미 기록의 회의 식별자를 확인해 주세요.") }
                if assistant == nil || (value.updatedAt ?? modified(url)) > (assistant?.updatedAt ?? .distantPast) { assistant = value }
            } catch { warnings.append("도우미 기록 확인: " + error.localizedDescription) }
        }
        let audioURL = fileURL(transcript?.audioPath) ?? fileURL(assistant?.audioPath)
        if let audioURL { beforeRead?(audioURL) }
        if let audioURL, existing(audioURL) == nil { warnings.append("연결된 음성 파일은 저장 경로를 확인해 주세요.") }
        return MeetingHistorySnapshot(id: entry.id, title: title, date: meetingDate, duration: duration, segments: segments, names: names, materials: materials,
            record: record, markdown: markdown, audioURL: audioURL, transcriptURL: transcriptURL, recordURL: recordURL,
            diagnosticsURL: fileURL(transcript?.diagnostics?["event_log"]), comparisonURL: fileURL(transcript?.diagnostics?["comparison"]), minutesURL: minutesURL,
            context: context, assistantState: assistant, warnings: warnings)
    }
}

private extension CodingUserInfoKey {
    static let historyIndexOnly = CodingUserInfoKey(rawValue: "TableLog.historyIndexOnly")!
}

/// Serialized read-only cache. Every reuse verifies fresh filesystem metadata.
actor MeetingHistorySnapshotCache {
    private struct Stamp: Equatable {
        let path: String
        let link: [Int64]
        let target: [Int64]
        let bytes: Int64

        init(_ url: URL) {
            path = url.standardizedFileURL.path
            func values(_ info: stat) -> [Int64] {
                [Int64(info.st_dev), Int64(info.st_ino), Int64(info.st_mode), info.st_size,
                 Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                 Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
            }
            var linkInfo = stat(), targetInfo = stat()
            let linkResult = path.withCString { Darwin.lstat($0, &linkInfo) }
            link = linkResult == 0 ? values(linkInfo) : [Int64(linkResult), Int64(errno)]
            let targetResult = path.withCString { Darwin.fstatat(AT_FDCWD, $0, &targetInfo, 0) }
            target = targetResult == 0 ? values(targetInfo) : [Int64(targetResult), Int64(errno)]
            bytes = targetResult == 0 ? max(0, targetInfo.st_size) : 0
        }
    }
    private struct Cached {
        let snapshot: MeetingHistorySnapshot
        let stamps: [String: Stamp]
        let cost: Int64
        var accessed: UInt64
    }
    private let transcripts: URL
    private let minutes: URL
    private let assistant: URL
    private let maximumEntries: Int
    private let maximumBytes: Int64
    private var values: [String: Cached] = [:]
    private var access: UInt64 = 0
    private(set) var hitCount = 0
    var cachedCount: Int { values.count }

    init(transcripts: URL, minutes: URL, assistant: URL, maximumEntries: Int = 8, maximumBytes: Int64 = 64 * 1024 * 1024) {
        self.transcripts = transcripts; self.minutes = minutes; self.assistant = assistant
        self.maximumEntries = max(0, maximumEntries); self.maximumBytes = max(0, maximumBytes)
    }
    func invalidate() { values.removeAll() }

    func load(_ entry: MeetingHistoryEntry) throws -> MeetingHistorySnapshot {
        try Task.checkCancellation()
        let canonical = [transcripts.appendingPathComponent(entry.id.uuidString + ".json"),
                         minutes.appendingPathComponent("Sessions").appendingPathComponent(entry.id.uuidString + ".json"),
                         minutes.appendingPathComponent(entry.id.uuidString + ".md"),
                         assistant.appendingPathComponent(entry.id.uuidString).appendingPathComponent("state.json")]
        let requested = [entry.transcriptURL, entry.recordURL, entry.minutesURL, entry.assistantURL].compactMap { $0 }
        let key = entry.id.uuidString + "|" + [entry.transcriptURL, entry.recordURL, entry.minutesURL, entry.assistantURL]
            .map { $0?.standardizedFileURL.path ?? "" }.joined(separator: "|")
        access &+= 1
        if var cached = values[key], cached.stamps.allSatisfy({ Stamp(URL(fileURLWithPath: $0.key)) == $0.value }) {
            cached.accessed = access; values[key] = cached; hitCount += 1
            return cached.snapshot
        }
        values[key] = nil
        func available(_ url: URL) -> URL? { FileManager.default.fileExists(atPath: url.path) ? url : nil }
        for _ in 0..<3 {
            try Task.checkCancellation()
            var before: [String: Stamp] = [:]
            func observe(_ url: URL) {
                let path = url.standardizedFileURL.path
                if before[path] == nil { before[path] = Stamp(url) }
            }
            (canonical + requested).forEach(observe)
            let resolved = MeetingHistoryEntry(id: entry.id, title: entry.title, date: entry.date, duration: entry.duration,
                segmentCount: entry.segmentCount, materialCount: entry.materialCount, hasMinutes: entry.hasMinutes,
                transcriptURL: entry.transcriptURL ?? available(canonical[0]), recordURL: entry.recordURL ?? available(canonical[1]),
                minutesURL: entry.minutesURL ?? available(canonical[2]), assistantURL: entry.assistantURL ?? available(canonical[3]), warnings: entry.warnings)
            let snapshot = try MeetingHistoryReader.load(resolved, beforeRead: observe)
            try Task.checkCancellation()
            // A concurrent save during the read receives another complete read before publication.
            guard before.allSatisfy({ Stamp(URL(fileURLWithPath: $0.key)) == $0.value }) else { continue }
            let sourceBytes = before.values.filter { ["json", "md"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }
                .reduce(Int64(0)) { min(maximumBytes + 1, $0 + min(maximumBytes + 1, $1.bytes)) }
            // Allow room for decoded strings and value objects as well as the file payload.
            let cost = min(maximumBytes + 1, sourceBytes * 3)
            if maximumEntries > 0 && cost <= maximumBytes {
                values[key] = Cached(snapshot: snapshot, stamps: before, cost: cost, accessed: access)
                while values.count > maximumEntries || values.values.reduce(Int64(0), { $0 + $1.cost }) > maximumBytes {
                    guard let oldest = values.min(by: { $0.value.accessed < $1.value.accessed })?.key else { break }
                    values[oldest] = nil
                }
            }
            return snapshot
        }
        throw MeetingHistoryError(message: "회의 기록을 저장하는 중입니다. 저장이 끝난 뒤 다시 열어 주세요.")
    }
}
