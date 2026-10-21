import Foundation
import Combine
import AVFoundation
import AppKit
import CryptoKit

struct VoiceSample: Codable, Identifiable {
    let id: UUID
    let created: Date
    let seconds: Double
    let source: String
    let vector: [Float]
    var sourceKey: String? = nil
    var confirmedName: String? = nil
    var sessionID: UUID? = nil
    var speaker: Int? = nil
    var start: Double? = nil
    var end: Double? = nil
    var confirmation: String? = nil
    var fileName: String { id.uuidString + ".m4a" }
}
struct VoiceLearningBatch: Codable, Identifiable {
    let id: UUID
    let created: Date
    let action: String
    let addedSampleIDs: [UUID]
    let beforeModel: VoiceLearnedModel?
    let priorActiveIDs: [UUID]
    let resultingSampleCount: Int
    let revision: Int
    let confirmedName: String
    var rolledBackAt: Date? = nil
}
struct VoiceProfile: Codable, Identifiable {
    let id: UUID
    var name: String
    var samples: [VoiceSample]
    var removedSamples: [VoiceSample] = []
    var beforeRebuild: [UUID]? = nil
    var learnedModel: VoiceLearnedModel? = nil
    var learningHistory: [VoiceLearningBatch] = []
    init(id: UUID, name: String, samples: [VoiceSample], removedSamples: [VoiceSample] = [], beforeRebuild: [UUID]? = nil, learnedModel: VoiceLearnedModel? = nil, learningHistory: [VoiceLearningBatch] = []) {
        self.id=id;self.name=name;self.samples=samples;self.removedSamples=removedSamples;self.beforeRebuild=beforeRebuild;self.learnedModel=learnedModel;self.learningHistory=learningHistory
    }
    enum CodingKeys: String, CodingKey { case id, name, samples, removedSamples, beforeRebuild, learnedModel, learningHistory }
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(UUID.self,forKey:.id);name=try c.decode(String.self,forKey:.name)
        samples=try c.decode([VoiceSample].self,forKey:.samples)
        removedSamples=try c.decodeIfPresent([VoiceSample].self,forKey:.removedSamples) ?? []
        beforeRebuild=try c.decodeIfPresent([UUID].self,forKey:.beforeRebuild)
        learnedModel=try c.decodeIfPresent(VoiceLearnedModel.self,forKey:.learnedModel)
        learningHistory=try c.decodeIfPresent([VoiceLearningBatch].self,forKey:.learningHistory) ?? []
    }
}
enum VoiceMappingMode: String, Codable, CaseIterable, Identifiable {
    case off, suggest, automatic
    var id: String { rawValue }
    var title: String {
        switch self { case .off: return "끔"; case .suggest: return "이름 제안만"; case .automatic: return "자동 연결 · 후보 제안" }
    }
}
struct VoiceVault: Codable {
    var modelID = VoiceEmbedding.modelID
    var profiles: [VoiceProfile] = []
    var archived: [VoiceProfile] = []
    var threshold: Float = 0.65
    var enabled = true
    var mode: VoiceMappingMode = .automatic
    var continuousLearningEnabled = true
    init() {}
    enum CodingKeys: String, CodingKey { case modelID, profiles, archived, threshold, enabled, mode, continuousLearningEnabled }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? VoiceEmbedding.modelID
        profiles = try c.decodeIfPresent([VoiceProfile].self, forKey: .profiles) ?? []
        archived = try c.decodeIfPresent([VoiceProfile].self, forKey: .archived) ?? []
        threshold = try c.decodeIfPresent(Float.self, forKey: .threshold) ?? 0.65
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mode = try c.decodeIfPresent(VoiceMappingMode.self, forKey: .mode) ?? (enabled ? .automatic : .off)
        continuousLearningEnabled=try c.decodeIfPresent(Bool.self,forKey:.continuousLearningEnabled) ?? true
        if !enabled { mode = .off }
        enabled = mode != .off
    }
}
struct VoiceSuggestion: Codable, Equatable {
    let profileID: UUID
    let name: String
    let similarity: Float
    let margin: Float
    let evidenceCount: Int
    var evidenceSeconds: Double = 0
    var minimumSimilarity: Float = 0
    var enrolledClipCount: Int = 0
    var enrolledSeconds: Double = 0
    var evidenceStart: Double = 0
    var evidenceEnd: Double = 0
    var automaticEligible: Bool = false
    enum CodingKeys: String, CodingKey {
        case profileID, name, similarity, margin, evidenceCount, evidenceSeconds, minimumSimilarity,
             enrolledClipCount, enrolledSeconds, evidenceStart, evidenceEnd, automaticEligible
    }
    init(profileID: UUID, name: String, similarity: Float, margin: Float, evidenceCount: Int,
         evidenceSeconds: Double = 0, minimumSimilarity: Float = 0, enrolledClipCount: Int = 0,
         enrolledSeconds: Double = 0, evidenceStart: Double = 0, evidenceEnd: Double = 0,
         automaticEligible: Bool = false) {
        self.profileID=profileID; self.name=name; self.similarity=similarity; self.margin=margin
        self.evidenceCount=evidenceCount; self.evidenceSeconds=evidenceSeconds; self.minimumSimilarity=minimumSimilarity
        self.enrolledClipCount=enrolledClipCount; self.enrolledSeconds=enrolledSeconds
        self.evidenceStart=evidenceStart; self.evidenceEnd=evidenceEnd; self.automaticEligible=automaticEligible
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID=try c.decode(UUID.self,forKey:.profileID); name=try c.decode(String.self,forKey:.name)
        similarity=try c.decode(Float.self,forKey:.similarity); margin=try c.decode(Float.self,forKey:.margin)
        evidenceCount=try c.decode(Int.self,forKey:.evidenceCount)
        evidenceSeconds=try c.decodeIfPresent(Double.self,forKey:.evidenceSeconds) ?? 0
        minimumSimilarity=try c.decodeIfPresent(Float.self,forKey:.minimumSimilarity) ?? 0
        enrolledClipCount=try c.decodeIfPresent(Int.self,forKey:.enrolledClipCount) ?? 0
        enrolledSeconds=try c.decodeIfPresent(Double.self,forKey:.enrolledSeconds) ?? 0
        evidenceStart=try c.decodeIfPresent(Double.self,forKey:.evidenceStart) ?? 0
        evidenceEnd=try c.decodeIfPresent(Double.self,forKey:.evidenceEnd) ?? 0
        // Older exports have proposal evidence only, so automatic application requires a fresh match.
        automaticEligible=try c.decodeIfPresent(Bool.self,forKey:.automaticEligible) ?? false
    }
}
struct VoiceMatchEvidence {
    let candidate: VoiceCandidate
    let profileID: UUID
    let similarity: Float
    let margin: Float
    var automaticSafe = true
}
struct VoiceIdentityEvent: Codable, Identifiable {
    let id: UUID
    let at: Date
    let speaker: Int
    let start: Double
    let end: Double
    let name: String?
    let similarity: Float?
    let action: String
}
struct VoiceIdentityExport: Encodable {
    let model: String
    let threshold: Float
    let mode: VoiceMappingMode
    let suggestions: [Int:VoiceSuggestion]
    let events: [VoiceIdentityEvent]
}
struct VoiceCandidate: Identifiable {
    let speaker: Int
    let start: Double
    let end: Double
    let text: String
    var id: String { "\(speaker):\(start):\(end)" }
}

enum VoiceMatching {
    static func cosine(_ a:[Float],_ b:[Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        return zip(a,b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }
    static func ranked(_ vector:[Float],profiles:[VoiceProfile]) -> [(VoiceProfile,Float)] {
        profiles.compactMap { profile -> (VoiceProfile,Float)? in
            if let model=profile.learnedModel, let score=VoiceLearningTrainer.score(vector,model:model) { return (profile,score) }
            let samples = profile.samples.map(\.vector).filter { $0.count == vector.count }
            guard !samples.isEmpty else { return nil }
            var mean = [Float](repeating:0,count:vector.count)
            for sample in samples { for i in mean.indices { mean[i] += sample[i] } }
            guard let center = VoiceEmbedding.normalized(mean) else { return nil }
            return (profile,cosine(vector,center))
        }.sorted { $0.1 > $1.1 }
    }
    static func rawSimilarity(_ vector:[Float],profile:VoiceProfile) -> Float {
        guard let normalized=VoiceEmbedding.normalized(vector) else { return -1 }
        let samples=profile.samples.filter{$0.seconds.isFinite && $0.seconds>=3 && $0.vector.count==normalized.count}.compactMap{VoiceEmbedding.normalized($0.vector)}
        var scores=samples.map{cosine(normalized,$0)}
        if let model=profile.learnedModel,VoiceLearningTrainer.valid(model) { scores += model.prototypes.map{cosine(normalized,$0)} }
        var mean=[Float](repeating:0,count:normalized.count)
        for sample in samples { for i in mean.indices { mean[i]+=sample[i] } }
        if let center=VoiceEmbedding.normalized(mean) { scores.append(cosine(normalized,center)) }
        return scores.max() ?? -1
    }
    static func best(_ vector:[Float],vault:VoiceVault) -> (VoiceProfile,Float,Float)? {
        let scores = ranked(vector,profiles:vault.profiles)
        guard let first = scores.first else { return nil }
        let competing=vault.profiles.filter{$0.id != first.0.id}.map{rawSimilarity(vector,profile:$0)}.max() ?? -1
        let margin = first.1-competing
        guard first.1 >= vault.threshold, margin >= 0.08 else { return nil }
        return (first.0,first.1,margin)
    }
    static func proposal(_ evidence: [VoiceMatchEvidence], profile: VoiceProfile, threshold: Float) -> VoiceSuggestion? {
        let ordered=evidence.filter { $0.profileID == profile.id && $0.similarity.isFinite && $0.margin.isFinite &&
            $0.similarity >= threshold && $0.margin >= 0.08 && $0.candidate.end-$0.candidate.start >= 3 }
            .sorted { $0.candidate.start < $1.candidate.start }
        var independent: [VoiceMatchEvidence] = []
        for item in ordered where independent.last.map({ item.candidate.start >= $0.candidate.end-0.01 }) ?? true {
            independent.append(item)
        }
        guard independent.count >= 2 else { return nil }
        let seconds=independent.reduce(0) { $0 + $1.candidate.end-$1.candidate.start }
        let mean=independent.map(\.similarity).reduce(0,+)/Float(independent.count)
        let minimum=independent.map(\.similarity).min() ?? 0, margin=independent.map(\.margin).min() ?? 0
        let training=profile.samples.filter { $0.seconds.isFinite && $0.seconds >= 3 }
        let trainingSeconds=training.reduce(0) { $0+$1.seconds }
        let minimumFloor=min(0.97,max(0.78,threshold+0.08)), meanFloor=min(0.98,max(0.82,threshold+0.10))
        let eligible=independent.count >= 3 && seconds >= 9 && minimum >= minimumFloor &&
            mean >= meanFloor && margin >= 0.15 && training.count >= 2 && trainingSeconds >= 6 && independent.allSatisfy(\.automaticSafe)
        return VoiceSuggestion(profileID:profile.id,name:profile.name,similarity:mean,margin:margin,
            evidenceCount:independent.count,evidenceSeconds:seconds,minimumSimilarity:minimum,
            enrolledClipCount:training.count,enrolledSeconds:trainingSeconds,
            evidenceStart:independent.first!.candidate.start,evidenceEnd:independent.last!.candidate.end,
            automaticEligible:eligible)
    }
    /// The rolling audio window can expire while a validated identity stays relevant to the meeting.
    /// Only an overlapping changed acoustic speaker label retracts that evidence.
    static func hasRelabel(_ candidate: VoiceCandidate, in snapshot: EngineSnapshot) -> Bool {
        if snapshot.words.isEmpty, snapshot.isFinal {
            return snapshot.segments.contains { segment in
                segment.startTime.isFinite && segment.endTime.isFinite && segment.speaker != candidate.speaker &&
                min(segment.endTime,candidate.end)-max(segment.startTime,candidate.start) > 0.12
            }
        }
        return snapshot.words.contains { word in
            word.start.isFinite && word.end.isFinite && word.speaker != candidate.speaker &&
            min(word.end,candidate.end)-max(word.start,candidate.start) > 0.12
        }
    }
    /// Select non-overlapping contiguous words with a single acoustic speaker label.
    static func candidates(_ snapshot:EngineSnapshot) -> [VoiceCandidate] {
        if snapshot.words.isEmpty { return snapshot.isFinal ? savedCandidates(snapshot) : [] }
        var groups: [[TranscriptWord]] = [], current: [TranscriptWord] = []
        for word in snapshot.words {
            guard word.start.isFinite,word.end.isFinite,word.end > word.start,word.end <= snapshot.audioSeconds - (snapshot.isFinal ? 0 : 1.5),word.speaker > 0 else {
                if !current.isEmpty { groups.append(current); current = [] }; continue
            }
            if let last = current.last, last.speaker != word.speaker || word.start - last.end > 0.65 || word.start < last.end - 0.10 || word.end - current[0].start > 7 {
                groups.append(current); current = []
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }
        return groups.compactMap { words in
            guard let first=words.first, let last=words.last, last.end-first.start >= 3 else { return nil }
            return VoiceCandidate(speaker:first.speaker,start:first.start,end:last.end,text:words.map(\.text).joined(separator:" "))
        }
    }

    /// Saved transcripts preserve utterance times. Use those bounds directly;
    /// word timestamps are available only during recognition.
    private static func savedCandidates(_ snapshot: EngineSnapshot) -> [VoiceCandidate] {
        guard snapshot.audioSeconds.isFinite, snapshot.audioSeconds > 0 else { return [] }
        let segments = snapshot.segments.filter {
            $0.startTime.isFinite && $0.endTime.isFinite && $0.startTime >= 0 &&
            $0.endTime > $0.startTime && $0.startTime < snapshot.audioSeconds
        }.sorted { $0.startTime < $1.startTime }
        var groups: [VoiceCandidate] = []
        for segment in segments {
            guard segment.speaker > 0, !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let end = min(segment.endTime, snapshot.audioSeconds)
            if let last = groups.last, last.speaker == segment.speaker,
               segment.startTime >= last.end - 0.10, segment.startTime - last.end <= 0.65 {
                groups[groups.count-1] = .init(speaker:last.speaker,start:last.start,end:end,text:last.text + " " + segment.text)
            } else {
                groups.append(.init(speaker:segment.speaker,start:segment.startTime,end:end,text:segment.text))
            }
        }
        var result: [VoiceCandidate] = []
        for group in groups {
            var start = group.start
            while group.end - start >= 3 {
                let end = min(group.end, start + 6)
                // Overlap and unassigned speech stay outside single-speaker examples.
                let overlaps = segments.contains {
                    $0.speaker != group.speaker && min($0.endTime,end)-max($0.startTime,start) > 0
                }
                if !overlaps { result.append(.init(speaker:group.speaker,start:start,end:end,text:group.text)) }
                start = end
            }
        }
        return result
    }
}

@MainActor final class VoiceIdentity: ObservableObject {
    @Published private(set) var vault = VoiceVault()
    @Published private(set) var suggestions: [Int:VoiceSuggestion] = [:]
    @Published private(set) var matchingSpeakers: Set<Int> = []
    @Published private(set) var rejectedSpeakers: Set<Int> = []
    var mappingMode: VoiceMappingMode { vault.enabled ? vault.mode : .off }
    @Published private(set) var candidates: [VoiceCandidate] = []
    @Published private(set) var trainingCandidates: [VoiceCandidate] = []
    @Published private(set) var pendingSpeaker: Int?
    @Published private(set) var pendingClipCount = 0
    @Published private(set) var pendingRevision = UUID()
    @Published private(set) var events: [VoiceIdentityEvent] = []
    @Published var status = "목소리를 등록하면 다음 대화에서 이름을 제안합니다."
    @Published private(set) var busy = false
    @Published private(set) var learningBusy = false
    @Published private(set) var learningStatus = "이름을 확인한 발언을 추가하면 개인별 목소리 분류기를 갱신합니다."
    @Published private(set) var recording = false
    @Published private(set) var recordingSeconds: Double = 0
    @Published private(set) var pendingSeconds: Double = 0
    let audio = VoiceAudioBuffer()
    let root: URL
    private let embedding: VoiceEmbedding
    private var generation = UUID()
    private var session = UUID()
    private var snapshot: EngineSnapshot?
    private var task: Task<Void,Never>?
    private var scanIDs = Set<String>()
    private var evidence: [Int:[VoiceMatchEvidence]] = [:]
    private var matchingSavedAudio: URL?
    private let extractEmbedding: (([Float]) async throws -> [Float])?
    private var closed = false
    private struct ConfirmedBinding { let profileID: UUID; let name: String; let sessionID: UUID; let token: UUID }
    private var confirmedBindings: [Int:ConfirmedBinding] = [:]
    private var learningTask: Task<Void,Never>?
    private var learningGeneration = UUID()
    private var learningScanIDs = Set<String>()
    private var nextLearningAt: [Int:Double] = [:]
    private var pendingSource = "recording:\(UUID().uuidString)"
    private static let maximumSamples = 1000
    private var pendingPCM: [Float] = []
    private struct PreparedClip { let pcm: [Float]; let candidate: VoiceCandidate; let source: String }
    private var pendingClips: [PreparedClip] = []
    private var pendingSession: UUID?
    var didEnroll: ((Int, String) -> Void)?
    private let enrollmentMic = MicrophoneCapture()
    private let enrollmentAudio = VoiceAudioBuffer()
    private var enrollmentSession = UUID()
    private var recordingTimer: Timer?
    private var player: AVAudioPlayer?
    private var filePanel: NSOpenPanel?
    var didChange: (() -> Void)?
    init(root:URL = StorageLocations.voiceProfiles, embedding:VoiceEmbedding = VoiceEmbedding(), extractEmbedding: (([Float]) async throws -> [Float])? = nil) {
        self.root=root;self.embedding=embedding;self.extractEmbedding=extractEmbedding
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let file=root.appendingPathComponent("profiles.json")
            if FileManager.default.fileExists(atPath:file.path) {
                let decoded=try JSONDecoder().decode(VoiceVault.self,from:Data(contentsOf:file))
                guard decoded.modelID == VoiceEmbedding.modelID,
                      (0.4...0.95).contains(decoded.threshold), decoded.profiles.count <= 200,
                      (decoded.profiles + decoded.archived).allSatisfy({ p in (p.samples+p.removedSamples).allSatisfy { $0.vector.count == 192 && $0.vector.allSatisfy(\.isFinite) } }) else { throw VoiceFailure(message:"목소리 프로필 모델·형식을 확인해 주세요.") }
                vault=decoded
            }
        } catch { status="프로필 읽기 오류 · \(error.localizedDescription)"; loadFailed=true }
    }
    private var loadFailed=false
    private func save() throws {
        guard !loadFailed else { throw VoiceFailure(message:"기존 프로필 파일 확인 후 앱을 다시 열어 주세요.") }
        let data=try JSONEncoder().encode(vault), url=root.appendingPathComponent("profiles.json")
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func configure(enabled:Bool,threshold:Float) {
        configure(mode: enabled ? (mappingMode == .off ? .automatic : mappingMode) : .off, threshold: threshold)
    }
    func configure(mode:VoiceMappingMode,threshold:Float) {
        var updated=vault;updated.enabled=mode != .off;updated.mode=mode
        updated.threshold=threshold.isFinite ? min(0.95,max(0.4,threshold)) : vault.threshold
        mutate(updated); requestRematch(savedAudio:matchingSavedAudio,reconsiderRejected:false)
    }
    private func mutate(_ updated:VoiceVault) {
        do { try commit(updated) } catch { status=error.localizedDescription }
    }
    private func invalidate() {
        generation=UUID();task?.cancel();task=nil;matchingSpeakers=[];evidence=[:];scanIDs=[];suggestions=[:]
    }
    /// An explicit recheck reconsiders rejected candidates; automatic setting/profile changes retain the choice.
    func requestRematch(savedAudio: URL? = nil, reconsiderRejected: Bool = true) {
        invalidate();matchingSavedAudio=savedAudio
        if reconsiderRejected { rejectedSpeakers=[] }
        didChange?()
        if let snapshot { receive(snapshot) }
    }
    func rejectSuggestion(speaker: Int) {
        rejectedSpeakers.insert(speaker)
        if let suggestion=suggestions[speaker] {
            record(speaker:speaker,name:suggestion.name,score:suggestion.similarity,action:"user_rejected")
        }
        suggestions[speaker]=nil;didChange?()
    }
    func allowRematch(speaker: Int) {
        rejectedSpeakers.remove(speaker)
        requestRematch(savedAudio:matchingSavedAudio,reconsiderRejected:false)
    }
    func reset(session:UUID) {
        cancelLearning();learningScanIDs=[];nextLearningAt=[:];invalidate();self.session=session;audio.reset(session);snapshot=nil;candidates=[];trainingCandidates=[];events=[]
        matchingSavedAudio=nil;rejectedSpeakers=[];closed=false;clearPending();didChange?()
    }
    private var scanCandidates: [VoiceCandidate] {
        guard matchingSavedAudio != nil else { return candidates }
        // An explicit saved-recording recheck samples each speaker across the whole meeting.
        return Dictionary(grouping:trainingCandidates,by: \.speaker).values.flatMap { values -> [VoiceCandidate] in
            let sorted=values.sorted { $0.start < $1.start }
            if sorted.count <= 8 { return sorted }
            return (0..<8).map { sorted[$0*(sorted.count-1)/7] }
        }.sorted { $0.start < $1.start }.suffix(64).map { $0 }
    }
    func receive(_ snapshot:EngineSnapshot) {
        guard !closed else { return }
        self.snapshot=snapshot
        trainingCandidates=VoiceMatching.candidates(snapshot)
        candidates=trainingCandidates.filter { $0.end >= snapshot.audioSeconds-170 }
        if !pendingClips.isEmpty, !pendingClips.allSatisfy({ clip in trainingCandidates.contains(where: { $0.id == clip.candidate.id }) }) {
            clearPending();status="화자 구간이 갱신되었습니다. 학습할 발언을 다시 선택하세요."
        }
        var changed=false
        for (speaker,items) in evidence {
            let valid=items.filter { !VoiceMatching.hasRelabel($0.candidate,in:snapshot) }
            if valid.count != items.count {
                evidence[speaker]=valid
                suggestions[speaker]=valid.first.flatMap { first in
                    vault.profiles.first(where: { $0.id == first.profileID }).flatMap { VoiceMatching.proposal(valid,profile:$0,threshold:vault.threshold) }
                }
                record(speaker:speaker,name:nil,action:"acoustic_evidence_revised");changed=true
            }
        }
        quarantineRelabeledSamples(snapshot)
        scheduleConfirmedLearning()
        let queue=scanCandidates
        scanIDs.formIntersection(Set(queue.map(\.id)))
        if changed { didChange?() }
        guard mappingMode != .off,!vault.profiles.isEmpty,task==nil else { return }
        var selected: (VoiceCandidate,[Float]?)?
        for candidate in queue where !scanIDs.contains(candidate.id) && !rejectedSpeakers.contains(candidate.speaker) {
            scanIDs.insert(candidate.id)
            // A growing word group can represent the same already-tested voice interval.
            if (evidence[candidate.speaker] ?? []).contains(where: {
                min($0.candidate.end,candidate.end)-max($0.candidate.start,candidate.start) > 0.01
            }) { continue }
            let pcm=audio.read(session:session,start:candidate.start,end:candidate.end)
            guard pcm != nil || matchingSavedAudio != nil else { scanIDs.remove(candidate.id);continue }
            selected=(candidate,pcm);break
        }
        guard let (candidate,buffered)=selected else { return }
        let generation=self.generation,session=self.session,savedAudio=matchingSavedAudio
        matchingSpeakers=[candidate.speaker]
        task=Task { [weak self] in
            guard let self else { return }
            do {
                let pcm: [Float]
                if let buffered { pcm=buffered }
                else if let savedAudio {
                    pcm=try await Task.detached(priority:.utility) {
                        try VoiceEmbedding.readAudio(savedAudio,start:candidate.start,duration:candidate.end-candidate.start)
                    }.value
                } else { throw VoiceFailure(message:"다음 발언의 목소리를 확인합니다.") }
                guard !Task.isCancelled,self.generation==generation,self.session==session else { return }
                let vector: [Float]
                if let extractEmbedding=self.extractEmbedding { vector=try await extractEmbedding(pcm) }
                else { vector=try await self.embedding.extract(pcm) }
                guard !Task.isCancelled,self.generation==generation,self.session==session,!self.closed else { return }
                guard let latest=self.snapshot,!VoiceMatching.hasRelabel(candidate,in:latest),!self.rejectedSpeakers.contains(candidate.speaker) else {
                    self.finishScan(generation:generation);return
                }
                if let (profile,score,margin)=VoiceMatching.best(vector,vault:self.vault) {
                    var items=self.evidence[candidate.speaker] ?? []
                    if items.last?.profileID != profile.id { items=[];self.suggestions[candidate.speaker]=nil }
                    if items.allSatisfy({ min(candidate.end,$0.candidate.end)-max(candidate.start,$0.candidate.start) <= 0.01 }) {
                        let automaticSafe: Bool
                        if profile.learnedModel?.automaticEligible ?? true { automaticSafe=true }
                        else {
                            let legacyProfiles=self.vault.profiles.map { original -> VoiceProfile in var copy=original;copy.learnedModel=nil;return copy }
                            let legacy=VoiceMatching.ranked(vector,profiles:legacyProfiles)
                            let own=legacy.first(where:{$0.0.id==profile.id})?.1 ?? -1
                            let other=self.vault.profiles.filter{$0.id != profile.id}.map{VoiceMatching.rawSimilarity(vector,profile:$0)}.max() ?? -1
                            automaticSafe=own >= min(0.98,max(0.82,self.vault.threshold+0.10)) && own-other >= 0.15
                        }
                        items.append(.init(candidate:candidate,profileID:profile.id,similarity:score,margin:margin,automaticSafe:automaticSafe))
                    }
                    items=Array(items.sorted { $0.candidate.start < $1.candidate.start }.suffix(8));self.evidence[candidate.speaker]=items
                    let proposal=VoiceMatching.proposal(items,profile:profile,threshold:self.vault.threshold)
                    let previous=self.suggestions[candidate.speaker]
                    self.suggestions[candidate.speaker]=proposal
                    if let proposal {
                        if previous?.profileID != proposal.profileID {
                            self.record(speaker:candidate.speaker,candidate:candidate,name:profile.name,score:score,action:"suggested")
                        }
                        self.status="화자 \(candidate.speaker) · \(profile.name) 추정 · \(items.count)개 구간 확인"
                    } else { self.status="화자 \(candidate.speaker) · 다음 발언에서 목소리를 함께 확인합니다." }
                    self.didChange?()
                } else {
                    self.evidence[candidate.speaker]=[];self.suggestions[candidate.speaker]=nil
                    self.record(speaker:candidate.speaker,candidate:candidate,name:nil,score:nil,action:"unknown_or_ambiguous")
                    self.didChange?()
                }
            } catch {
                if !Task.isCancelled,self.generation==generation,self.session==session { self.status=error.localizedDescription }
            }
            self.finishScan(generation:generation)
        }
    }
    private func finishScan(generation: UUID) {
        guard self.generation==generation else { return }
        task=nil;matchingSpeakers=[]
        if let latest=snapshot { receive(latest) }
    }
    func record(speaker:Int,candidate:VoiceCandidate?=nil,name:String?,score:Float?=nil,action:String) {
        events.append(.init(id:UUID(),at:Date(),speaker:speaker,start:candidate?.start ?? 0,end:candidate?.end ?? 0,name:name,similarity:score,action:action))
    }
    var export:VoiceIdentityExport { .init(model:VoiceEmbedding.modelID,threshold:vault.threshold,mode:mappingMode,suggestions:suggestions,events:events) }
    func confirm(speaker:Int) -> String? {
        guard let value=suggestions[speaker] else { return nil }
        record(speaker:speaker,name:value.name,score:value.similarity,action:"user_confirmed"); return value.name
    }
    func availableCandidates(speaker: Int, savedAudio: URL?) -> [VoiceCandidate] {
        (savedAudio == nil ? candidates : trainingCandidates).filter { $0.speaker == speaker }
    }
    func prepare(_ candidate:VoiceCandidate, savedAudio:URL?) {
        prepareMeetingClips([candidate], savedAudio: savedAudio)
    }
    func prepareMeeting(speaker: Int, savedAudio: URL?) {
        let all = availableCandidates(speaker: speaker, savedAudio: savedAudio)
        // Spread the examples over the meeting while bounding local work to five clips.
        let selected: [VoiceCandidate]
        if all.count <= 5 { selected = all }
        else { selected = (0..<5).map { all[$0 * (all.count - 1) / 4] } }
        prepareMeetingClips(selected, savedAudio: savedAudio)
    }
    private func prepareMeetingClips(_ selected: [VoiceCandidate], savedAudio: URL?) {
        guard !busy, !recording else { return }
        clearPending()
        guard let first=selected.first, selected.allSatisfy({ $0.speaker == first.speaker }) else {
            status="3초 이상 이어진 단일 화자 발언이 준비되면 선택할 수 있습니다."; return
        }
        let session=self.session, revision=pendingRevision
        busy=true
        Task {
            var clips: [PreparedClip] = []
            for candidate in selected {
                do {
                    let pcm: [Float]
                    if let buffered=audio.read(session:session,start:candidate.start,end:candidate.end) { pcm=buffered }
                    else if let savedAudio {
                        pcm=try await Task.detached(priority:.utility) {
                            try VoiceEmbedding.readAudio(savedAudio,start:candidate.start,duration:candidate.end-candidate.start)
                        }.value
                    } else { continue }
                    try VoiceEmbedding.quality(pcm)
                    clips.append(.init(pcm:pcm,candidate:candidate,source:"meeting:\(session.uuidString):\(candidate.id)"))
                } catch { continue }
            }
            defer { busy=false }
            guard self.session==session, pendingRevision==revision else { return }
            guard !clips.isEmpty else { status="선명한 3초 이상의 발언을 다시 선택하세요."; return }
            guard clips.allSatisfy({ clip in trainingCandidates.contains(where: { $0.id == clip.candidate.id }) }) else {
                status="화자 구간이 갱신되었습니다. 발언을 다시 선택하세요."; return
            }
            pendingClips=clips;pendingSession=session;pendingSpeaker=first.speaker
            pendingPCM=clips.flatMap(\.pcm);pendingSeconds=Double(pendingPCM.count)/16000
            pendingClipCount=clips.count;pendingRevision=UUID()
            status="화자 \(first.speaker) · \(clips.count)개 발언 준비. 목소리와 이름을 확인한 뒤 학습하세요."
        }
    }
    func loadFile(_ url:URL,start:Double,duration:Double) {
        guard !busy,!recording else { return };clearPending();busy=true
        let revision=pendingRevision
        Task {
            do {
                let pcm=try await Task.detached(priority:.utility) { try VoiceEmbedding.readAudio(url,start:start,duration:duration) }.value
                try VoiceEmbedding.quality(pcm)
                guard pendingRevision==revision else { busy=false;return }
                pendingPCM=pcm;pendingSource="file:\(Self.pcmDigest(pcm))";pendingSeconds=Double(pcm.count)/16000;pendingRevision=UUID();status="선택 음성을 들어보고 한 사람의 발언인지 확인하세요."
            } catch { status=error.localizedDescription }
            busy=false
        }
    }
    func pickAudio(start:Double,duration:Double) {
        guard !busy,!recording,filePanel==nil else { return }
        let panel=NSOpenPanel();panel.allowedContentTypes=[.audio];panel.allowsMultipleSelection=false;panel.canChooseDirectories=false
        filePanel=panel
        panel.begin { [weak self] result in
            guard let self else { return };self.filePanel=nil
            if result == .OK,let url=panel.url { self.loadFile(url,start:start,duration:duration) }
        }
    }
    func startRecording(device:UInt32) {
        guard !recording,!busy else { return }
        if MicrophoneCapture.authorizationStatus == .notDetermined {
            MicrophoneCapture.requestAccess { [weak self] granted in if granted { self?.startRecording(device:device) } }; return
        }
        guard MicrophoneCapture.authorizationStatus == .authorized else { status=MicrophoneCaptureError.permissionRequired.localizedDescription;return }
        let id=UUID();enrollmentSession=id;enrollmentAudio.reset(id);clearPending();pendingSource="recording:\(id.uuidString)";recordingSeconds=0
        do {
            try enrollmentMic.start(deviceID:device == 0 ? nil : device,onAudio:{ [enrollmentAudio] pcm in enrollmentAudio.append(pcm,session:id)
                Task { @MainActor [weak self] in self?.recordingSeconds += Double(pcm.count)/16000 }
            },onLevel:{ _ in },onError:{ [weak self] error in Task { @MainActor in self?.status=error.localizedDescription;self?.stopRecording() } })
            recording=true;status="한 사람의 목소리로 여러 문장을 읽어 주세요. 30초에서 자동 종료합니다."
            recordingTimer=Timer.scheduledTimer(withTimeInterval:0.3,repeats:true) { [weak self] _ in Task { @MainActor in if let self,self.recordingSeconds>=30 { self.stopRecording() } } }
        } catch { status=error.localizedDescription }
    }
    func stopRecording() {
        guard recording else { return };recordingTimer?.invalidate();recordingTimer=nil
        enrollmentMic.stop { [weak self] in
            guard let self else { return };self.recording=false
            if let pcm=self.enrollmentAudio.read(session:self.enrollmentSession,start:0,end:min(30,self.recordingSeconds)) {
                self.pendingPCM=pcm;self.pendingSeconds=Double(pcm.count)/16000;self.pendingRevision=UUID();self.status="녹음 완료 · 음성을 확인한 뒤 등록하세요."
            }
        }
    }
    func playPending() {
        guard !pendingPCM.isEmpty else { return }
        do {
            let url=root.appendingPathComponent("preview.m4a");try VoiceEmbedding.writeM4A(pendingPCM,to:url)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            player=try AVAudioPlayer(contentsOf:url);player?.play()
        } catch { status=error.localizedDescription }
    }
    func play(_ sample:VoiceSample) { do { player=try AVAudioPlayer(contentsOf:root.appendingPathComponent(sample.fileName));player?.play() } catch { status=error.localizedDescription } }
    func clearPending() { player?.stop();pendingPCM=[];pendingClips=[];pendingSession=nil;pendingSpeaker=nil;pendingClipCount=0;pendingSeconds=0;pendingRevision=UUID();pendingSource="recording:\(UUID().uuidString)";try? FileManager.default.removeItem(at:root.appendingPathComponent("preview.m4a")) }
    private static func pcmDigest(_ pcm:[Float]) -> String {
        pcm.withUnsafeBytes { SHA256.hash(data:Data($0)).map { String(format:"%02x",$0) }.joined() }
    }
    private func duplicate(_ source:String, key:String?, candidate:VoiceCandidate? = nil, sessionID:UUID? = nil, in samples:[VoiceSample]) -> Bool {
        samples.contains { sample in
            if sample.source == source || (key != nil && sample.sourceKey == key) { return true }
            guard let candidate,let sessionID else { return false }
            if sample.sessionID==sessionID,let start=sample.start,let end=sample.end { return min(end,candidate.end)-max(start,candidate.start) > 0.01 }
            let parts=sample.source.split(separator:":")
            if parts.count==5,parts[0]=="meeting",UUID(uuidString:String(parts[1]))==sessionID,
               let start=Double(parts[3]),let end=Double(parts[4]) { return min(end,candidate.end)-max(start,candidate.start)>0.01 }
            return false
        }
    }
    private func revisedProfile(_ profile:VoiceProfile, prior:VoiceProfile, action:String, added:[UUID], otherProfiles:[VoiceProfile]) async -> VoiceProfile {
        var result=profile
        let trainingSamples=result.samples,previousModel=prior.learnedModel
        result.learnedModel=await Task.detached(priority:.utility) { VoiceLearningTrainer.train(profileSamples:trainingSamples,otherProfiles:otherProfiles,previous:previousModel,now:Date()) }.value
        let revision=max((prior.learningHistory.map(\.revision).max() ?? 0)+1,result.learnedModel?.revision ?? 0)
        result.learningHistory.append(.init(id:UUID(),created:Date(),action:action,addedSampleIDs:added,beforeModel:prior.learnedModel,
            priorActiveIDs:prior.samples.map(\.id),resultingSampleCount:result.samples.count,revision:revision,confirmedName:result.name))
        return result
    }
    private func commit(_ updated:VoiceVault) throws {
        var permitted=updated
        let activeIDs=Set(permitted.profiles.flatMap{$0.samples.map(\.id)})
        for i in permitted.profiles.indices {
            guard let model=permitted.profiles[i].learnedModel,!Set(model.negativeSampleIDs).isSubset(of:activeIDs) else { continue }
            let prior=permitted.profiles[i]
            permitted.profiles[i].learnedModel=nil
            permitted.profiles[i].learningHistory.append(.init(id:UUID(),created:Date(),action:"evidence_revised",addedSampleIDs:[],beforeModel:nil,
                priorActiveIDs:prior.samples.map(\.id),resultingSampleCount:prior.samples.count,
                revision:(prior.learningHistory.map(\.revision).max() ?? 0)+1,confirmedName:prior.name))
        }
        let previous=vault;vault=permitted
        do { try save() } catch { vault=previous;throw error }
    }
    func enroll(name:String,existing:UUID?,rebuild:Bool=false) {
        guard !busy,!recording else { return }
        let cleaned=String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(64))
        guard !cleaned.isEmpty else { status="목소리에 연결할 이름을 입력하세요.";return }
        if existing==nil,vault.profiles.contains(where:{$0.name==cleaned}) { status="같은 이름의 프로필을 선택해 음성을 추가하세요.";return }
        guard existing != nil || vault.profiles.count < 200 else { status="등록 가능한 프로필은 200개입니다.";return }
        if let existing, !vault.profiles.contains(where:{$0.id==existing}) { status="학습할 프로필을 다시 선택하세요.";return }
        cancelLearning(clearBindings:false)
        let pcm=pendingPCM, clips=pendingClips, selectedSession=pendingSession, speaker=pendingSpeaker, sourcePrefix=pendingSource
        let revision=pendingRevision, operationGeneration=learningGeneration
        busy=true
        Task {
            var createdFiles: [URL] = [], committed = false
            defer { if !committed { for url in createdFiles { try? FileManager.default.removeItem(at:url) } };busy=false;didChange?() }
            do {
                var chunks: [([Float],String,VoiceCandidate?)] = []
                if clips.isEmpty {
                    try VoiceEmbedding.quality(pcm)
                    for offset in stride(from:0,to:pcm.count,by:16000*6) {
                        let chunk=Array(pcm[offset..<min(pcm.count,offset+16000*6)])
                        if chunk.count>=48000 { chunks.append((chunk,"\(sourcePrefix):\(offset)",nil)) }
                    }
                } else { chunks=clips.map { ($0.pcm,$0.source,$0.candidate) } }
                let allExisting=vault.profiles.flatMap { $0.samples+$0.removedSamples }+vault.archived.flatMap { $0.samples+$0.removedSamples }
                var samples:[VoiceSample]=[]
                var qualityRejected = 0
                for (chunk,source,candidate) in chunks {
                    do { try VoiceEmbedding.quality(chunk) }
                    catch { qualityRejected += 1; continue }
                    let key=Self.pcmDigest(chunk)
                    guard !duplicate(source,key:key,candidate:candidate,sessionID:selectedSession,in:allExisting+samples) else { continue }
                    let vector: [Float]
                    if let extractEmbedding { vector=try await extractEmbedding(chunk) } else { vector=try await embedding.extract(chunk) }
                    guard let normalized=VoiceEmbedding.normalized(vector),normalized.count==192 else { throw VoiceFailure(message:"목소리 특징 값 검증 오류") }
                    let sample=VoiceSample(id:UUID(),created:Date(),seconds:Double(chunk.count)/16000,source:source,vector:normalized,
                        sourceKey:key,confirmedName:cleaned,sessionID:selectedSession,speaker:candidate?.speaker,start:candidate?.start,end:candidate?.end,confirmation:"explicit_enrollment")
                    samples.append(sample)
                    let url=root.appendingPathComponent(sample.fileName);createdFiles.append(url)
                    try VoiceEmbedding.writeM4A(chunk,to:url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
                }
                guard !closed,learningGeneration==operationGeneration,pendingRevision==revision,selectedSession == nil || selectedSession==session else {
                    throw VoiceFailure(message:"회의 또는 화자 구간이 갱신되었습니다. 발언을 다시 선택하세요.")
                }
                guard !samples.isEmpty else {
                    if qualityRejected == chunks.count { throw VoiceFailure(message:"학습 가능한 음성을 확인해 주세요. 3초 이상 선명하게 말한 구간을 선택하세요.") }
                    throw VoiceFailure(message:"선택한 음성은 이미 보관되어 있습니다. 제외한 자료는 학습 자료 복원으로 추가하세요.")
                }
                if let latest=snapshot,clips.contains(where:{VoiceMatching.hasRelabel($0.candidate,in:latest)}) { throw VoiceFailure(message:"화자 구간이 갱신되었습니다. 발언을 다시 선택하세요.") }
                var updated=vault
                let profileID=existing ?? UUID()
                let prior=updated.profiles.first(where:{$0.id==profileID}) ?? VoiceProfile(id:profileID,name:cleaned,samples:[])
                var profile=prior
                guard profile.samples.count+profile.removedSamples.count+samples.count<=Self.maximumSamples else { throw VoiceFailure(message:"프로필당 원음 1,000개를 보관합니다. 추가 학습용 프로필을 만들어 주세요.") }
                if rebuild { profile.beforeRebuild=profile.samples.map(\.id);profile.removedSamples += profile.samples;profile.samples=[] }
                profile.samples += samples
                profile=await revisedProfile(profile,prior:prior,action:rebuild ? "rebuild" : "confirmed_enrollment",added:samples.map(\.id),otherProfiles:updated.profiles.filter{$0.id != profileID})
                guard !closed,learningGeneration==operationGeneration,pendingRevision==revision,selectedSession == nil || selectedSession==session else { throw VoiceFailure(message:"학습 대상이 갱신되었습니다. 다시 확인해 주세요.") }
                updated=vault
                if let index=updated.profiles.firstIndex(where:{$0.id==profileID}) { updated.profiles[index]=profile } else { updated.profiles.append(profile) }
                try commit(updated);committed=true
                clearPending();requestRematch(savedAudio:matchingSavedAudio,reconsiderRejected:false)
                status="\(cleaned) 누적 학습 완료 · 새 음성 \(samples.count)개 · 전체 \(profile.samples.count)개"
                if qualityRejected > 0 { status += " · 무음·음질 확인 \(qualityRejected)개 제외" }
                learningStatus=status
                if let speaker {
                    didEnroll?(speaker,cleaned)
                    if selectedSession==session { confirmedBindings[speaker] = .init(profileID:profileID,name:profile.name,sessionID:session,token:UUID()) }
                }
                if clips.isEmpty { record(speaker:0,name:cleaned,action:"enrollment_confirmed") }
                else { for clip in clips where samples.contains(where:{$0.source==clip.source}) { record(speaker:clip.candidate.speaker,candidate:clip.candidate,name:cleaned,action:rebuild ? "meeting_rebuilt" : "meeting_learned") } }
            } catch { status=error.localizedDescription;learningStatus=status }
        }
    }
    func configureLearning(enabled:Bool) {
        var updated=vault;updated.continuousLearningEnabled=enabled
        do { try commit(updated) } catch { learningStatus=error.localizedDescription;return }
        if enabled { learningStatus="확인한 화자의 새 발언을 누적 학습합니다.";scheduleConfirmedLearning() }
        else { cancelLearning(clearBindings:false);learningStatus="자동 수집 일시 정지 · 직접 추가 학습을 사용할 수 있습니다." }
        didChange?()
    }
    func cancelLearning(clearBindings:Bool = true) {
        learningGeneration=UUID();learningTask?.cancel();learningTask=nil;learningBusy=false
        if clearBindings { confirmedBindings=[:] }
    }
    func unbindConfirmedSpeaker(speaker:Int) {
        confirmedBindings[speaker]=nil;nextLearningAt[speaker]=nil
        cancelLearning(clearBindings:false)
    }
    func learnConfirmedSpeaker(speaker:Int,profileID:UUID,savedAudio:URL? = nil) async {
        guard !closed,let profile=vault.profiles.first(where:{$0.id==profileID}),speaker>0 else { return }
        let binding=ConfirmedBinding(profileID:profileID,name:profile.name,sessionID:session,token:UUID())
        confirmedBindings[speaker]=binding
        if let savedAudio { matchingSavedAudio=savedAudio }
        guard vault.continuousLearningEnabled else { learningStatus="이름 확인 완료 · 자동 수집은 설정에서 켤 수 있습니다.";return }
        scheduleConfirmedLearning(explicitSpeaker:speaker)
        if let learningTask { await learningTask.value }
    }
    private func scheduleConfirmedLearning(explicitSpeaker:Int? = nil) {
        guard vault.continuousLearningEnabled,!closed,!busy,!recording,!learningBusy,learningTask==nil,let latest=snapshot else { return }
        let speakers=explicitSpeaker.map { [$0] } ?? confirmedBindings.keys.sorted()
        for speaker in speakers {
            guard let binding=confirmedBindings[speaker],binding.sessionID==session,
                  let profile=vault.profiles.first(where:{$0.id==binding.profileID}),profile.name==binding.name,
                  explicitSpeaker != nil || latest.audioSeconds >= (nextLearningAt[speaker] ?? 0) else { continue }
            let allSamples=vault.profiles.flatMap{$0.samples+$0.removedSamples}+vault.archived.flatMap{$0.samples+$0.removedSamples}
            let available=(matchingSavedAudio == nil ? candidates : trainingCandidates).filter {
                $0.speaker==speaker && !VoiceMatching.hasRelabel($0,in:latest) &&
                !learningScanIDs.contains("\(profile.id):\($0.id)") &&
                !duplicate("meeting:\(session.uuidString):\($0.id)",key:nil,candidate:$0,sessionID:session,in:allSamples)
            }.sorted{$0.start<$1.start}
            var selected:[VoiceCandidate]=[]
            for clip in available where selected.last.map({clip.start >= $0.end}) ?? true {
                selected.append(clip);if selected.count==5 { break }
            }
            guard !selected.isEmpty else { continue }
            let generation=learningGeneration, currentSession=session, savedAudio=matchingSavedAudio, explicit=explicitSpeaker != nil
            learningBusy=true;learningStatus="\(profile.name) · 확인된 새 발언 학습 중"
            for clip in selected { learningScanIDs.insert("\(profile.id):\(clip.id)") }
            nextLearningAt[speaker]=latest.audioSeconds+30
            learningTask=Task { [weak self] in
                guard let self else { return }
                await self.collectConfirmed(selected,profile:profile,binding:binding,savedAudio:savedAudio,explicit:explicit,generation:generation,sessionID:currentSession)
                guard self.learningGeneration==generation else { return }
                self.learningBusy=false;self.learningTask=nil;self.didChange?()
                self.scheduleConfirmedLearning()
            }
            return
        }
    }
    private func collectConfirmed(_ selected:[VoiceCandidate],profile:VoiceProfile,binding:ConfirmedBinding,savedAudio:URL?,explicit:Bool,generation:UUID,sessionID:UUID) async {
        var files:[URL]=[],committed=false
        defer { if !committed { for file in files { try? FileManager.default.removeItem(at:file) } } }
        do {
            var added:[VoiceSample]=[]
            for candidate in selected {
                try Task.checkCancellation()
                let pcm:[Float]
                if let buffered=audio.read(session:sessionID,start:candidate.start,end:candidate.end) { pcm=buffered }
                else if let savedAudio { pcm=try await Task.detached(priority:.utility){ try VoiceEmbedding.readAudio(savedAudio,start:candidate.start,duration:candidate.end-candidate.start) }.value }
                else { continue }
                do { try VoiceEmbedding.quality(pcm) } catch { continue }
                let vector:[Float]
                if let extractEmbedding { vector=try await extractEmbedding(pcm) } else { vector=try await embedding.extract(pcm) }
                guard let normalized=VoiceEmbedding.normalized(vector),normalized.count==192 else { continue }
                let scores=VoiceMatching.ranked(normalized,profiles:vault.profiles)
                let own=scores.first(where:{$0.0.id==profile.id})?.1 ?? -1
                let other=vault.profiles.filter{$0.id != profile.id}.map{VoiceMatching.rawSimilarity(normalized,profile:$0)}.max() ?? -1
                // A human-confirmed first batch accepts broader acoustic conditions; following clips use stricter identity evidence.
                guard own >= (explicit ? 0.45 : max(0.78,vault.threshold+0.08)),
                      own-other >= (explicit ? -0.03 : 0.15) else { continue }
                let key=Self.pcmDigest(pcm),source="meeting:\(sessionID.uuidString):\(candidate.id)"
                let all=vault.profiles.flatMap{$0.samples+$0.removedSamples}+vault.archived.flatMap{$0.samples+$0.removedSamples}+added
                guard !duplicate(source,key:key,candidate:candidate,sessionID:sessionID,in:all) else { continue }
                guard let latest=snapshot,!VoiceMatching.hasRelabel(candidate,in:latest) else { continue }
                let sample=VoiceSample(id:UUID(),created:Date(),seconds:Double(pcm.count)/16000,source:source,vector:normalized,
                    sourceKey:key,confirmedName:binding.name,sessionID:sessionID,speaker:candidate.speaker,start:candidate.start,end:candidate.end,
                    confirmation:explicit ? "user_confirmed_name" : "confirmed_name_followup")
                let file=root.appendingPathComponent(sample.fileName);files.append(file)
                try VoiceEmbedding.writeM4A(pcm,to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                added.append(sample)
            }
            guard !added.isEmpty else { learningStatus="\(profile.name) · 선명하고 새로운 발언을 기다립니다.";return }
            guard !Task.isCancelled,!closed,self.session==sessionID,learningGeneration==generation,
                  confirmedBindings[selected[0].speaker]?.token==binding.token,vault.continuousLearningEnabled,
                  let i=vault.profiles.firstIndex(where:{$0.id==profile.id}),vault.profiles[i].name==binding.name,
                  vault.profiles[i].samples.map(\.id)==profile.samples.map(\.id) else { return }
            guard profile.samples.count+profile.removedSamples.count+added.count<=Self.maximumSamples else { learningStatus="프로필당 보관 상한 1,000개에 도달했습니다. 기존 학습 자료를 유지합니다.";return }
            var changed=profile;changed.samples+=added
            let learned=await revisedProfile(changed,prior:profile,action:explicit ? "confirmed_enrollment" : "confirmed_followup",added:added.map(\.id),otherProfiles:vault.profiles.filter{$0.id != profile.id})
            guard !Task.isCancelled,!closed,self.session==sessionID,learningGeneration==generation,
                  confirmedBindings[selected[0].speaker]?.token==binding.token,vault.continuousLearningEnabled,
                  let latest=snapshot,added.allSatisfy({ sample in !VoiceMatching.hasRelabel(.init(speaker:sample.speaker!,start:sample.start!,end:sample.end!,text:""),in:latest) }),
                  let current=vault.profiles.firstIndex(where:{$0.id==profile.id}),vault.profiles[current].name==binding.name,
                  vault.profiles[current].samples.map(\.id)==profile.samples.map(\.id) else { return }
            var updated=vault;updated.profiles[current]=learned;try commit(updated);committed=true
            learningStatus="\(profile.name) · 새 음성 \(added.count)개 누적 학습 · 전체 \(learned.samples.count)개"
            for sample in added { record(speaker:sample.speaker!,candidate:.init(speaker:sample.speaker!,start:sample.start!,end:sample.end!,text:""),name:binding.name,action:"confirmed_incremental_learning") }
            requestRematch(savedAudio:matchingSavedAudio,reconsiderRejected:false)
        } catch { if !Task.isCancelled,learningGeneration==generation { learningStatus=error.localizedDescription } }
    }
    private func quarantineRelabeledSamples(_ snapshot:EngineSnapshot) {
        var affected:[UUID:Set<UUID>]=[:]
        for profile in vault.profiles {
            for sample in profile.samples where sample.sessionID==session {
                guard let speaker=sample.speaker,let start=sample.start,let end=sample.end,
                      VoiceMatching.hasRelabel(.init(speaker:speaker,start:start,end:end,text:""),in:snapshot) else { continue }
                affected[profile.id,default:[]].insert(sample.id);confirmedBindings[speaker]=nil
            }
        }
        guard !affected.isEmpty,!busy else { return }
        cancelLearning(clearBindings:false)
        // Retract contaminated parameters immediately; the updated active samples supply a conservative centroid until retraining finishes.
        var updated=vault
        for i in updated.profiles.indices {
            guard let ids=affected[updated.profiles[i].id] else { continue }
            let prior=updated.profiles[i]
            updated.profiles[i].removedSamples+=prior.samples.filter{ids.contains($0.id)}
            updated.profiles[i].samples.removeAll{ids.contains($0.id)}
            updated.profiles[i].learnedModel=nil
            updated.profiles[i].learningHistory.append(.init(id:UUID(),created:Date(),action:"quarantined",addedSampleIDs:[],beforeModel:nil,
                priorActiveIDs:updated.profiles[i].samples.map(\.id),resultingSampleCount:updated.profiles[i].samples.count,
                revision:(prior.learningHistory.map(\.revision).max() ?? 0)+1,confirmedName:prior.name))
        }
        do { try commit(updated);learningStatus="화자 구간 갱신 · 해당 학습 음성을 확인 대기로 이동했습니다.";invalidate();didChange?() }
        catch { learningStatus=error.localizedDescription }
    }
    func canRollbackLearning(profileID:UUID) -> Bool {
        guard let profile=vault.profiles.first(where:{$0.id==profileID}),let batch=profile.learningHistory.last(where:{$0.rolledBackAt==nil}) else { return false }
        return batch.action != "quarantined"
    }
    func rollbackLastLearning(profileID:UUID) {
        guard !busy,canRollbackLearning(profileID:profileID) else { return }
        let revoked=confirmedBindings.filter{$0.value.profileID==profileID}.map(\.key)
        for speaker in revoked { confirmedBindings[speaker]=nil;nextLearningAt[speaker]=nil }
        cancelLearning(clearBindings:false)
        var updated=vault
        guard let i=updated.profiles.firstIndex(where:{$0.id==profileID}),let j=updated.profiles[i].learningHistory.lastIndex(where:{$0.rolledBackAt==nil}) else { return }
        let batch=updated.profiles[i].learningHistory[j],all=updated.profiles[i].samples+updated.profiles[i].removedSamples
        let restored=batch.priorActiveIDs.compactMap { id in all.first(where:{$0.id==id}) }
        guard restored.count==batch.priorActiveIDs.count else { learningStatus="복원할 원본 음성 자료를 확인해 주세요.";return }
        updated.profiles[i].samples=restored;updated.profiles[i].removedSamples=all.filter{!batch.priorActiveIDs.contains($0.id)}
        updated.profiles[i].learnedModel=batch.beforeModel;updated.profiles[i].learningHistory[j].rolledBackAt=Date();updated.profiles[i].beforeRebuild=nil
        do { try commit(updated);learningStatus="\(updated.profiles[i].name) · 직전 학습을 되돌리고 원음을 보관했습니다.";requestRematch(savedAudio:matchingSavedAudio,reconsiderRejected:false) }
        catch { learningStatus=error.localizedDescription }
    }
    private func editProfile(_ id:UUID,action:String,force:Bool=false,change:@escaping (inout VoiceProfile)->Void) {
        guard !busy,let prior=vault.profiles.first(where:{$0.id==id}) else { return }
        cancelLearning(clearBindings:false);let generation=learningGeneration
        var changed=prior;change(&changed)
        guard force || changed.samples.map(\.id) != prior.samples.map(\.id) else { return }
        busy=true
        Task {
            defer { busy=false;didChange?() }
            let learned=await revisedProfile(changed,prior:prior,action:action,added:changed.samples.filter{sample in !prior.samples.contains{$0.id==sample.id}}.map(\.id),otherProfiles:vault.profiles.filter{$0.id != id})
            guard !closed,learningGeneration==generation,let i=vault.profiles.firstIndex(where:{$0.id==id}) else { return }
            var updated=vault;updated.profiles[i]=learned
            do { try commit(updated);learningStatus="\(learned.name) · 학습 자료 \(learned.samples.count)개로 갱신했습니다.";requestRematch(savedAudio:matchingSavedAudio,reconsiderRejected:false) }
            catch { learningStatus=error.localizedDescription }
        }
    }
    func retrainProfile(profileID:UUID) { editProfile(profileID,action:"retrained",force:true) { _ in } }
    func undoRebuild(_ id: UUID) {
        if let profile=vault.profiles.first(where:{$0.id==id}),profile.learningHistory.last(where:{$0.rolledBackAt==nil})?.action=="rebuild" { rollbackLastLearning(profileID:id);return }
        editProfile(id,action:"restored") { profile in
            guard let oldIDs=profile.beforeRebuild else { return }
            let all=profile.samples+profile.removedSamples,old=oldIDs.compactMap { id in (profile.samples+profile.removedSamples).first{$0.id==id} }
            guard old.count==oldIDs.count else { return }
            profile.samples=old;profile.removedSamples=all.filter{!oldIDs.contains($0.id)};profile.beforeRebuild=nil
        }
    }
    func rename(_ id:UUID,name:String) {
        let cleaned=String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(64));guard !cleaned.isEmpty,!busy else { return };cancelLearning(clearBindings:false)
        var updated=vault;guard let i=updated.profiles.firstIndex(where:{$0.id==id}) else{return};updated.profiles[i].name=cleaned;mutate(updated);requestRematch(savedAudio:matchingSavedAudio,reconsiderRejected:false)
    }
    func archive(_ id:UUID) {
        guard !busy else{return};cancelLearning(clearBindings:false);var updated=vault
        guard let i=updated.profiles.firstIndex(where:{$0.id==id}) else{return}
        updated.archived.append(updated.profiles.remove(at:i));mutate(updated);requestRematch(savedAudio:matchingSavedAudio,reconsiderRejected:false);status="프로필을 보관함으로 이동했습니다. 복원할 수 있습니다."
    }
    func restore(_ id:UUID) {
        guard !busy else{return};cancelLearning(clearBindings:false);var updated=vault
        guard let i=updated.archived.firstIndex(where:{$0.id==id}) else{return}
        updated.profiles.append(updated.archived.remove(at:i));mutate(updated);requestRematch(savedAudio:matchingSavedAudio,reconsiderRejected:false)
    }
    func removeSample(profile:UUID,sample:UUID) {
        editProfile(profile,action:"excluded") { target in
            guard let i=target.samples.firstIndex(where:{$0.id==sample}) else { return }
            target.removedSamples.append(target.samples.remove(at:i))
        }
    }
    func restoreSamples(_ id:UUID) {
        editProfile(id,action:"restored") { target in
            guard target.samples.count+target.removedSamples.count<=Self.maximumSamples else { return }
            target.samples+=target.removedSamples;target.removedSamples=[]
        }
    }
    func close() { cancelLearning();closed=true;generation=UUID();stopRecording();player?.stop();task?.cancel();task=nil;matchingSpeakers=[] }
}
