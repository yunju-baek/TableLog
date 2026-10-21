import Foundation

struct CloudResult {
    let id: Int
    let start: Double
    let end: Double
    let transcript: GeminiTranscript
}

/// Projects cloud words onto the current local dominant-speaker timeline.
/// Rebuilding on each local snapshot also incorporates late speaker revisions.
enum HybridTranscript {
    struct Projection {
        var segments: [TranscriptSegment]
        var cloudIDs: Set<Int>
        var localDrafts: [Int: String]
    }

    static func project(local: EngineSnapshot, results: [CloudResult]) -> Projection {
        guard !results.isEmpty else { return Projection(segments: local.segments, cloudIDs: [], localDrafts: [:]) }
        // The parser owns timestamp quantization tolerance. This epsilon only
        // compensates for floating-point subtraction of absolute chunk times.
        let clockEpsilon = 0.000_000_001
        // The native JSON serializes audio_seconds to three decimal places.
        let snapshotRoundingTolerance = 0.0005 + clockEpsilon
        let readyResults = results.enumerated().filter { _, result in
            guard local.audioSeconds.isFinite, result.start.isFinite, result.end.isFinite,
                  result.start >= 0, result.end > result.start,
                  result.end <= local.audioSeconds + snapshotRoundingTolerance else { return false }
            let textIsEmpty = result.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if result.transcript.words.isEmpty { return textIsEmpty }
            guard !textIsEmpty else { return false }
            let duration = result.end - result.start
            var previousStart = -Double.infinity
            for word in result.transcript.words {
                guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      word.start.isFinite, word.end.isFinite,
                      word.start >= 0, word.end >= word.start,
                      word.end <= duration + clockEpsilon,
                      word.start >= previousStart else { return false }
                previousStart = word.start
            }
            return true
        }.sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        // Replace a chunk atomically. Malformed or not-yet-covered results keep
        // their complete local draft until a later valid projection is possible.
        guard !readyResults.isEmpty else { return Projection(segments: local.segments, cloudIDs: [], localDrafts: [:]) }
        struct Item {
            let word: TranscriptWord
            let chunk: Int?
            let ordinal: Int
        }
        func overlap(_ start: Double, _ end: Double, _ a: Double, _ b: Double) -> Double {
            max(0, min(end, b) - max(start, a))
        }
        func contains(_ time: Double, start: Double, end: Double) -> Bool {
            start.isFinite && end.isFinite && start <= time && time < end
        }
        func pointTime(_ time: Double, chunkEnd: Double) -> Double {
            // A word at the exact submitted audio end belongs to the final
            // available frame. Its displayed timestamp remains a point.
            time >= chunkEnd - clockEpsilon ? time.nextDown : time
        }
        func speaker(start: Double, end: Double, chunkEnd: Double) -> Int {
            if start == end {
                let time = pointTime(start, chunkEnd: chunkEnd)
                let activity = (local.speakerActivity ?? []).filter {
                    (1...8).contains($0.speaker) && contains(time, start: $0.start, end: $0.end)
                }.map(\.speaker)
                if let speaker = activity.min() { return speaker }
                return local.words.filter {
                    (1...8).contains($0.speaker) && contains(time, start: $0.start, end: $0.end)
                }.map(\.speaker).min() ?? 0
            }
            var votes: [Int: Double] = [:]
            for frame in local.speakerActivity ?? [] where (1...8).contains(frame.speaker) {
                votes[frame.speaker, default: 0] += overlap(start, end, frame.start, frame.end)
            }
            if !votes.values.contains(where: { $0 > 0 }) {
                for word in local.words where (1...8).contains(word.speaker) {
                    votes[word.speaker, default: 0] += overlap(start, end, word.start, word.end)
                }
            }
            if let winner = votes.filter({ $0.value > 0 }).sorted(by: {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }).first { return winner.key }
            // Uncovered timing is explicitly shown as pending speaker attribution.
            return 0
        }
        var items: [Item] = local.words.filter { word in
            let middle = (word.start + word.end) / 2
            return !readyResults.contains { middle >= $0.start && middle < $0.end }
        }.enumerated().map { Item(word: $0.element, chunk: nil, ordinal: $0.offset) }
        for result in readyResults {
            for word in result.transcript.words {
                let start = min(local.audioSeconds, result.end, result.start + word.start)
                let end = min(local.audioSeconds, result.end, result.start + word.end)
                items.append(Item(word: TranscriptWord(text: word.text, start: start, end: end,
                    speaker: speaker(start: start, end: end, chunkEnd: min(local.audioSeconds, result.end))), chunk: result.id, ordinal: items.count))
            }
        }
        items.sort { $0.word.start == $1.word.start ? $0.ordinal < $1.ordinal : $0.word.start < $1.word.start }
        var output: [TranscriptSegment] = []
        var cloudIDs = Set<Int>()
        var drafts: [Int: String] = [:]
        var group: [Item] = []
        var groupEnd = -Double.infinity
        var groupCounts: [Int: Int] = [:]
        var localCount = 0
        func flush() {
            guard let first = group.first else { return }
            let id: Int
            if let chunk = first.chunk {
                let count = groupCounts[chunk, default: 0]
                id = 1_000_000 + chunk * 1_000 + count
                groupCounts[chunk] = count + 1
                cloudIDs.insert(id)
                drafts[id] = local.words.filter {
                    if first.word.start == groupEnd {
                        let chunkEnd = min(local.audioSeconds, readyResults.first { $0.id == chunk }?.end ?? groupEnd)
                        return contains(pointTime(groupEnd, chunkEnd: chunkEnd), start: $0.start, end: $0.end)
                    }
                    return overlap(first.word.start, groupEnd, $0.start, $0.end) > 0
                }.map(\.text).joined(separator: " ")
            } else { id = 500_000_000 + localCount; localCount += 1 }
            output.append(TranscriptSegment(id: id, speaker: first.word.speaker,
                startTime: first.word.start, endTime: groupEnd,
                text: group.map { $0.word.text }.joined(separator: " ")))
            group.removeAll(keepingCapacity: true)
            groupEnd = -Double.infinity
        }
        for item in items {
            if let last = group.last,
               last.word.speaker != item.word.speaker || last.chunk != item.chunk ||
               item.word.start - groupEnd > 0.7 ||
               last.word.text.last.map({ ".!?。！？".contains($0) }) == true { flush() }
            group.append(item)
            groupEnd = max(groupEnd, item.word.end)
        }
        flush()
        return Projection(segments: output, cloudIDs: cloudIDs, localDrafts: drafts)
    }
}
