import Foundation

struct ManualTranscriptPart: Codable, Equatable, Identifiable {
    let id: Int
    var start: Double
    var end: Double
    var speaker: Int
    var text: String
}

/// A user-owned interval. Empty parts retain the interval as a deletion marker.
struct ManualTranscriptEdit: Codable, Equatable, Identifiable {
    let id: UUID
    let sourceID: Int
    let sourceSpeaker: Int
    let start: Double
    let end: Double
    let sourceText: String
    var parts: [ManualTranscriptPart]
    var editedAt: Date
}

struct ManualTranscriptDraft: Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var speaker: Int
    var text: String

    /// NSTextView uses UTF-16 offsets; keep composed Korean/emoji characters intact.
    func split(atUTF16 offset: Int) -> [Self]? {
        let ns = text as NSString
        guard offset > 0, offset < ns.length, end-start > 0.04 else { return nil }
        let boundary = ns.rangeOfComposedCharacterSequence(at: offset).location
        guard boundary > 0 else { return nil }
        let left = ns.substring(to: boundary).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = ns.substring(from: boundary).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        let time = start + (end-start) * Double(boundary)/Double(ns.length)
        return [Self(start:start,end:time,speaker:speaker,text:left),
                Self(start:time,end:end,speaker:speaker,text:right)]
    }

    static func valid(_ parts: [Self], within segment: TranscriptSegment) -> Bool {
        guard !parts.isEmpty, abs(parts[0].start-segment.startTime)<0.001,
              abs(parts.last!.end-segment.endTime)<0.001 else { return false }
        for (index,part) in parts.enumerated() {
            guard part.start.isFinite, part.end.isFinite, part.end>=part.start,
                  (0...8).contains(part.speaker), part.text.count<=100_000 else { return false }
            if index>0 && abs(parts[index-1].end-part.start)>0.001 { return false }
        }
        return true
    }
}

struct ManualTranscriptProjection {
    var segments: [TranscriptSegment] = []
    var texts: [Int:String] = [:]
    var lockedIDs = Set<Int>()
    var breakIDs = Set<Int>()
    var acousticSpeakers: [Int:Int] = [:]

    static func render(segments: [TranscriptSegment], words: [TranscriptWord],
                       edits: [ManualTranscriptEdit], base: (TranscriptSegment)->String) -> Self {
        var result = Self()
        for source in segments {
            let matches = edits.filter { edit in
                let overlaps=source.endTime > edit.start && source.startTime < edit.end
                let point=edit.start==edit.end && source.id==edit.sourceID && abs(source.startTime-edit.start)<0.001
                guard overlaps || point else { return false }
                if source.id == edit.sourceID || source.speaker == edit.sourceSpeaker { return true }
                // Preserve a confirmed interval even when a decoder changes IDs or labels.
                // An independently overlapping source speaker keeps its own transcript.
                return !segments.contains {
                    $0.id != source.id && $0.endTime>max(edit.start,source.startTime) &&
                    $0.startTime<min(edit.end,source.endTime) &&
                    ($0.id==edit.sourceID || $0.speaker==edit.sourceSpeaker)
                }
            }.sorted { $0.start < $1.start }
            guard !matches.isEmpty else {
                result.segments.append(source); result.texts[source.id]=base(source)
                continue
            }
            var gaps:[(Double,Double)]=[], cursor=source.startTime
            for edit in matches {
                if edit.start>cursor { gaps.append((cursor,min(source.endTime,edit.start))) }
                cursor=max(cursor,edit.end)
            }
            if cursor<source.endTime { gaps.append((cursor,source.endTime)) }
            for (start,end) in gaps where end>start {
                let text:String
                if let preceding=matches.last(where:{abs($0.end-start)<0.001}),
                   abs(preceding.start-source.startTime)<0.001,
                   !preceding.sourceText.isEmpty,source.text.hasPrefix(preceding.sourceText) {
                    text=String(source.text.dropFirst(preceding.sourceText.count)).trimmingCharacters(in:.whitespacesAndNewlines)
                } else {
                    let timed=words.filter {
                        let middle=($0.start+$0.end)/2
                        return middle>=start && middle<end && (source.speaker<=0 || $0.speaker==source.speaker)
                    }
                    if !timed.isEmpty { text=timed.map(\.text).joined(separator:" ") }
                    else {
                        // A fallback for providers without word timing. The editor marks
                        // these boundaries as estimates and lets the user adjust them.
                        let chars=Array(base(source)), duration=max(0.001,source.endTime-source.startTime)
                        let from=min(chars.count,max(0,Int((start-source.startTime)/duration*Double(chars.count))))
                        let to=min(chars.count,max(from,Int((end-source.startTime)/duration*Double(chars.count))))
                        text=String(chars[from..<to]).trimmingCharacters(in:.whitespacesAndNewlines)
                    }
                }
                let id=fragmentID(source.id,start,end)
                let part=TranscriptSegment(id:id,speaker:source.speaker,startTime:start,endTime:end,text:text)
                result.segments.append(part);result.texts[id]=text
            }
        }
        for edit in edits {
            for (index,part) in edit.parts.enumerated() {
                result.segments.append(TranscriptSegment(id:part.id,speaker:part.speaker,startTime:part.start,endTime:part.end,text:part.text))
                result.texts[part.id]=part.text;result.lockedIDs.insert(part.id)
                result.acousticSpeakers[part.id]=edit.sourceSpeaker
                if index>0 { result.breakIDs.insert(part.id) }
            }
        }
        result.segments=result.segments.filter { !(result.texts[$0.id] ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
            .sorted { $0.startTime==$1.startTime ? $0.id<$1.id : $0.startTime<$1.startTime }
        return result
    }

    private static func fragmentID(_ source:Int,_ start:Double,_ end:Double)->Int {
        var hash:UInt64=14695981039346656037
        for byte in "\(source)|\(start)|\(end)".utf8 { hash=(hash ^ UInt64(byte)) &* 1099511628211 }
        return -1_000_000_000-Int(hash % 1_000_000_000_000)
    }
}
