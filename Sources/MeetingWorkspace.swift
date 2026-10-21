import AppKit
import Combine
import Foundation

struct MeetingWorkRecord: Codable {
    var id: UUID
    var revision: Int
    var savedRevision: Int
    var date: String
    var title: String
    var purpose: String
    var template: MeetingTemplate
    var bindings: MeetingSpeakerBindings
    var names: [Int: String]
    var segments: [MeetingUtterance]
    var ended: Bool
    var provider: MinutesProvider
    var settings: CodexCorrectionSettings
    var output: String?
    var error: String?
    var updatedAt: Date
    var materials: MaterialContext? = nil
    var assistantAppendix: String? = nil
    var editedOutput: String? = nil
    var input: MinutesGenerationInput {
        MinutesGenerationInput(segments: segments, purpose: purpose, relatedTopics: template.similarTopics,
                               speakerNames: Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) }), materials: materials, title: title)
    }
    func snapshot(facts: MeetingMinutesFacts) -> MeetingMinutesSnapshot {
        var people = bindings.confirmedParticipants, speakers = bindings.speakers
        for (speaker,name) in names.sorted(by: { $0.key < $1.key }) where speakers[speaker] == nil {
            let person = MeetingPerson(id: "manual-\(speaker)", name: name)
            speakers[speaker] = person
            if !people.contains(where: { $0.name == name }) { people.append(person) }
        }
        return MeetingMinutesSnapshot(sessionID:id,revision:revision,date:date,purpose:purpose,
            confirmedParticipants:people,speakerBindings:speakers,utterances:segments,facts:facts,title:title)
    }
}

@MainActor final class MeetingWorkspace: ObservableObject {
    static let defaultID = UUID(uuidString: "7054856B-265F-4AE5-A4A0-E55C5D69A081")!
    static var defaultTemplate: MeetingTemplate {
        var value = MeetingTemplate.fromMeetingMarkdown("",name:"기본 회의",similarTopics:[],participantCandidates:[])
        value.id = defaultID
        return value
    }
    static var directory: URL { StorageLocations.minutes }
    @Published var templates: [MeetingTemplate] = []
    @Published var selectedID = defaultID { didSet { defaults.set(selectedID.uuidString,forKey:"minutes.template") } }
    @Published var purpose = ""
    @Published var provider: MinutesProvider = .codex { didSet { defaults.set(provider.rawValue,forKey:"minutes.provider") } }
    @Published var automatic = true { didSet { defaults.set(automatic,forKey:"minutes.automatic") } }
    @Published var interval = 90 { didSet { defaults.set(interval,forKey:"minutes.interval") } }
    @Published private(set) var bindings = MeetingSpeakerBindings(sessionID:UUID())
    @Published private(set) var status = "전사문이 쌓이면 회의록을 생성합니다."
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private var generatedURL: URL?
    @Published private var editedURL: URL?
    var lastURL: URL? { editedURL ?? generatedURL }
    @Published private var generatedPreview = ""
    @Published private var editedPreview: String?
    private var editedRevision = UUID()
    var preview: String { editedPreview ?? generatedPreview }
    var isShowingEditedDraft: Bool { editedPreview != nil }
    @Published private(set) var sessionID: UUID?
    private let store: MeetingFileStore
    private let generator: any MinutesGenerating
    private let directory: URL
    private let defaults: UserDefaults
    private var records: [UUID:MeetingWorkRecord] = [:]
    // Archived records stay dormant until this process explicitly works on a session.
    private var activeSessions = Set<UUID>()
    private var manualOnlySessions = Set<UUID>()
    private var signatures: [UUID:Data] = [:]
    private var queue: [UUID] = []
    private var runningID: UUID?
    private var task: Task<Void,Never>?
    private var lastAttempt: [UUID:Date] = [:]
    private var lastTick = Date.distantPast
    private var closing = false
    private var minimumEditRevision: [UUID:Int] = [:]
    private var transcriptSaveTask: Task<Void,Never>?
    var selectedTemplate: MeetingTemplate { templates.first(where:{$0.id==selectedID}) ?? Self.defaultTemplate }
    var canGenerate: Bool { sessionID.flatMap { records[$0] }?.segments.isEmpty == false }
    var materialContext = MaterialContext()
    var usesLiveAssistant = false
    var assistantAppendix = ""
    var metadata: MeetingWorkRecord? { sessionID.flatMap { records[$0] } }

    init(directory requestedDirectory: URL? = nil, generator: any MinutesGenerating = MinutesGenerator(), defaults: UserDefaults = .standard) {
        let directory = requestedDirectory ?? Self.directory
        self.directory=directory;self.store=MeetingFileStore(directory:directory);self.generator=generator;self.defaults=defaults
        provider=MinutesProvider(rawValue:defaults.string(forKey:"minutes.provider") ?? "codex") ?? .codex
        automatic=defaults.object(forKey:"minutes.automatic") as? Bool ?? true
        interval=max(30,defaults.object(forKey:"minutes.interval") as? Int ?? 90)
        selectedID=UUID(uuidString:defaults.string(forKey:"minutes.template") ?? "") ?? Self.defaultID
        templates=[Self.defaultTemplate]
        do {
            let folder=directory.appendingPathComponent("Templates")
            if FileManager.default.fileExists(atPath:folder.path) {
                for file in try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) where file.pathExtension=="json" {
                    if let value=try? JSONDecoder().decode(MeetingTemplate.self,from:Data(contentsOf:file)) {
                        templates.removeAll {$0.id==value.id};templates.append(value.minutesOnly)
                    }
                }
            }
            let pending=directory.appendingPathComponent("Sessions")
            if FileManager.default.fileExists(atPath:pending.path) {
                let files=try FileManager.default.contentsOfDirectory(at:pending,includingPropertiesForKeys:nil)
                for file in files where file.pathExtension=="json" {
                    if var record=try? JSONDecoder().decode(MeetingWorkRecord.self,from:Data(contentsOf:file)) {
                        record.ended=true;records[record.id]=record
                    }
                }
            }
        } catch { self.error="회의록 저장 폴더를 확인해 주세요. " + error.localizedDescription }
    }
    func begin(id:UUID) {
        // A previous meeting continues to save from its immutable capture while the new meeting records.
        if let old=sessionID,activeSessions.contains(old),records[old] != nil { records[old]?.ended=true;if automatic && !manualOnlySessions.contains(old) { enqueue(old) } }
        let attendance=sessionID == nil ? bindings.confirmedParticipants : []
        activeSessions.insert(id)
        sessionID=id;bindings=MeetingSpeakerBindings(sessionID:id)
        for person in attendance { bindings.confirmAttendance(person) }
        generatedURL=nil;generatedPreview="";error=nil;status="회의록 작성 대기"
        let draft=editingDraftURL(id)
        editedPreview=try? String(contentsOf:draft,encoding:.utf8)
        editedURL=editedPreview == nil ? nil : draft;editedRevision=UUID()
    }
    @discardableResult func openReprocessing(record source: MeetingWorkRecord) -> Bool {
        // A caller supplies a fresh identity and remapped participant bindings for the new work.
        guard source.bindings.sessionID==source.id else {
            error="새 회의 식별자에 맞춰 참석자 연결을 준비해 주세요."
            return false
        }
        guard records[source.id] == nil,
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Sessions").appendingPathComponent(source.id.uuidString + ".json").path) else {
            error="다시 처리할 회의는 새 식별자로 준비해 주세요. 기존 회의는 기록에서 확인할 수 있습니다."
            return false
        }
        begin(id:source.id)
        manualOnlySessions.insert(source.id)
        var record=source
        record.template = record.template.minutesOnly
        record.revision=1;record.savedRevision = -1;record.output=nil;record.error=nil
        record.editedOutput=nil
        record.ended=true;record.assistantAppendix="";record.updatedAt=Date()
        bindings=record.bindings;purpose=record.purpose;provider=record.provider
        templates.removeAll { $0.id==record.template.id };templates.append(record.template);selectedID=record.template.id
        materialContext=record.materials ?? MaterialContext();assistantAppendix=""
        records[record.id]=record;signatures.removeValue(forKey:record.id)
        lastAttempt[record.id]=Date();lastTick = .distantPast
        persist(record.id)
        saveTranscriptBaseline(record.id)
        status="전사 편집 후 ‘지금 생성·저장’으로 회의록을 생성하세요."
        return true
    }
    func bind(_ person:MeetingPerson,speaker:Int) { bindings.bind(person,to:speaker) }
    func unbind(speaker:Int) { bindings.unbind(speaker:speaker) }
    func attend(_ person:MeetingPerson) { bindings.confirmAttendance(person) }
    func remove(personID:String) { bindings.removeAttendance(personID:personID) }
    func saveTemplate(_ template:MeetingTemplate) {
        let template = template.minutesOnly
        do {
            // Validate placeholders before saving; a malformed template never replaces a working one.
            _ = try MeetingMinutesRenderer.render(MeetingMinutesSnapshot(sessionID:UUID(),revision:0,date:"",purpose:"",confirmedParticipants:[],speakerBindings:[:],utterances:[],facts:MeetingMinutesFacts()),template:template)
            let folder=directory.appendingPathComponent("Templates")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(template).write(to:folder.appendingPathComponent(template.id.uuidString+".json"),options:.atomic)
            templates.removeAll {$0.id==template.id};templates.append(template);selectedID=template.id;error=nil
        } catch { self.error="템플릿 저장 실패 · 변수 이름과 저장 경로를 확인해 주세요. " + error.localizedDescription }
    }
    func receive(id:UUID,title:String,date:Date,segments:[MeetingUtterance],names:[Int:String],ended:Bool,settings:CodexCorrectionSettings,force:Bool=false) {
        if sessionID != id { begin(id:id) }
        let now=Date()
        if !force && now.timeIntervalSince(lastTick)<1 { return };lastTick=now
        let formatter=DateFormatter();formatter.dateFormat="yyyy-MM-dd HH:mm:ss zzz"
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        struct Signature:Encodable { let segments:[MeetingUtterance];let names:[Int:String];let bindings:MeetingSpeakerBindings;let template:MeetingTemplate;let purpose:String;let provider:MinutesProvider;let settings:CodexCorrectionSettings;let materials:MaterialContext;let assistantAppendix:String }
        let signature=try? encoder.encode(Signature(segments:segments,names:names,bindings:bindings,template:selectedTemplate,purpose:purpose,provider:provider,settings:settings,materials:materialContext,assistantAppendix:assistantAppendix))
        if signatures[id] != signature {
            let old=records[id]
            records[id]=MeetingWorkRecord(id:id,revision:(old?.revision ?? 0)+1,savedRevision:old?.savedRevision ?? -1,date:formatter.string(from:date),title:title,purpose:purpose,template:selectedTemplate,bindings:bindings,names:names,segments:segments,ended:ended,provider:provider,settings:settings,output:old?.output,error:nil,updatedAt:now,materials:materialContext,assistantAppendix:assistantAppendix,editedOutput:old?.editedOutput)
            signatures[id]=signature
            persist(id)
            if old == nil { lastAttempt[id]=now; saveTranscriptBaseline(id) }
        } else { records[id]?.ended=ended }
        tick()
    }
    func tick() {
        guard automatic,!closing else { return }
        let now=Date()
        for record in records.values where activeSessions.contains(record.id) && !manualOnlySessions.contains(record.id) && record.savedRevision<record.revision && !record.segments.isEmpty {
            if usesLiveAssistant && !record.ended { continue }
            let elapsed=now.timeIntervalSince(lastAttempt[record.id] ?? .distantPast)
            let quiet=now.timeIntervalSince(record.updatedAt)
            if record.error != nil { continue }
            if (record.ended && quiet>=3) || elapsed>=Double(interval) && quiet>=1 { enqueue(record.id) }
        }
    }
    func updateRecovered(settings: CodexCorrectionSettings) {
        guard let id=sessionID,var record=records[id] else { return }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let before=try? encoder.encode(record)
        record.template=selectedTemplate;record.bindings=bindings;record.purpose=purpose;record.provider=provider;record.settings=settings;record.materials=materialContext;record.assistantAppendix=assistantAppendix
        if before != (try? encoder.encode(record)) {
            record.revision += 1;record.updatedAt=Date();record.error=nil;records[id]=record;persist(id)
        }
    }
    func invalidateTranscriptAfterEdit() {
        guard let id=sessionID,var record=records[id] else { return }
        minimumEditRevision[id]=record.revision
        record.savedRevision = -1;records[id]=record;persist(id)
        if runningID==id {
            task?.cancel()
            if automatic && !manualOnlySessions.contains(id) && !queue.contains(id) { queue.append(id) }
        }
        // The store serializes this empty-facts replacement with any older generation.
        // Its revision guard prevents an obsolete result from restoring removed speech.
        transcriptSaveTask=Task {
            do {
                let url=try await store.save(record.snapshot(facts:MeetingMinutesFacts()),template:record.template)
                if sessionID==id, records[id]?.revision==record.revision {
                    generatedURL=url;generatedPreview=(try? String(contentsOf:url,encoding:.utf8)) ?? ""
                    status=record.segments.isEmpty ? "모든 발언 삭제 · 저장 완료" : "편집된 전사문 저장 · 회의록 갱신 대기"
                    if record.segments.isEmpty { records[id]?.savedRevision=record.revision;persist(id) }
                }
                if automatic && !manualOnlySessions.contains(id) { enqueue(id,force:true) }
            } catch { if sessionID==id, records[id]?.revision==record.revision { self.error="편집된 전사문 저장 실패 · " + error.localizedDescription } }
        }
    }
    func generateNow() { if let id=sessionID { enqueue(id,force:true) } }
    func report(_ message:String) { error=message }
    func openFile() { if let lastURL { NSWorkspace.shared.open(lastURL) } }
    func showFolder() {
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        NSWorkspace.shared.open(directory)
    }
    private func persist(_ id:UUID) {
        guard let record=records[id] else { return }
        do {
            let folder=directory.appendingPathComponent("Sessions")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(record).write(to:folder.appendingPathComponent(id.uuidString+".json"),options:.atomic)
        } catch { self.error="회의록 복구 자료 저장 실패 · " + error.localizedDescription }
    }
    private func saveTranscriptBaseline(_ id:UUID) {
        guard let record=records[id],record.savedRevision < 0 else { return }
        do {
            let markdown=try MeetingMinutesRenderer.render(record.snapshot(facts:MeetingMinutesFacts()),template:record.template).replacingOccurrences(of:"확인된 내용 없음",with:"회의록 생성 대기").replacingOccurrences(of:"확인된 결정 없음",with:"회의록 생성 대기").replacingOccurrences(of:"확인된 할 일 없음",with:"회의록 생성 대기")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let url=directory.appendingPathComponent(id.uuidString+".md")
            try Data(markdown.utf8).write(to:url,options:.atomic)
            records[id]?.output=url.path;persist(id)
            if sessionID==id { generatedURL=url;generatedPreview=markdown;status="회의록 작성 대기" }
        } catch { self.error="회의록 초안 저장 실패 · " + error.localizedDescription }
    }
    private func reportProgress(id:UUID,part:Int,total:Int,provider:MinutesProvider) {
        if sessionID==id { status="안건별 회의록 작성 · \(part)/\(total) · \(provider.title)" }
    }
    private func enqueue(_ id:UUID,force:Bool=false) {
        guard activeSessions.contains(id),force || !manualOnlySessions.contains(id),let record=records[id],(!record.segments.isEmpty || force),force || record.revision>record.savedRevision else { return }
        guard record.provider.isAvailable else {
            if sessionID == id { status="전사문 보관 중 · 회의록 설정에서 AI CLI 사용을 선택하세요." }
            return
        }
        if runningID==id { return }
        if !queue.contains(id) { queue.append(id) }
        if sessionID==id { error=nil;status="회의록 생성 준비 · AI 작업 순서 대기" }
        guard task==nil else { return }
        busy=true
        task=Task { [weak self] in
            guard let self else { return }
            while !self.queue.isEmpty && !Task.isCancelled {
                let id=self.queue.removeFirst()
                guard let record=self.records[id], record.provider.isAvailable else { continue }
                if record.segments.isEmpty {
                    do {
                        let url=try await self.store.save(record.snapshot(facts:MeetingMinutesFacts()),template:record.template)
                        self.records[id]?.savedRevision=record.revision;self.records[id]?.output=url.path;self.persist(id)
                        if self.sessionID==id { self.generatedURL=url;self.generatedPreview=(try? String(contentsOf:url,encoding:.utf8)) ?? "" }
                    } catch { if self.sessionID==id { self.error=error.localizedDescription } }
                    continue
                }
                self.runningID=id;self.lastAttempt[id]=Date()
                do {
                    let facts=try await CodexJobContext.$priority.withValue(.minutes) {
                        try await self.generator.generate(record.input,provider:record.provider,settings:record.settings) { [weak self] part,total in
                            await self?.reportProgress(id:id,part:part,total:total,provider:record.provider)
                        }
                    }
                    try Task.checkCancellation()
                    if record.revision < self.minimumEditRevision[id,default:-1] {
                        self.runningID=nil
                        if self.automatic && !self.manualOnlySessions.contains(id) { self.queue.append(id) }
                        continue
                    }
                    let url=try await self.store.save(record.snapshot(facts:facts),template:record.template)
                    if record.revision < self.minimumEditRevision[id,default:-1] {
                        self.runningID=nil
                        if self.automatic && !self.manualOnlySessions.contains(id) { self.queue.append(id) }
                        continue
                    }
                    self.records[id]?.savedRevision=record.revision;self.records[id]?.output=url.path;self.records[id]?.error=nil
                    self.persist(id)
                    if self.sessionID==id {
                        self.generatedURL=url;self.generatedPreview=(try? String(contentsOf:url,encoding:.utf8)) ?? "";self.error=nil
                        self.status="회의록 저장 · " + Date().formatted(date:.omitted,time:.standard)
                    }
                } catch {
                    if record.revision < self.minimumEditRevision[id,default:-1] {
                        self.runningID=nil
                        if self.automatic && !self.manualOnlySessions.contains(id) { self.queue.append(id) }
                        continue
                    }
                    self.saveTranscriptBaseline(id)
                    self.records[id]?.error=error.localizedDescription;self.persist(id)
                    if self.sessionID==id { self.error="회의록 갱신 대기 · " + error.localizedDescription;self.status="전사문과 직전 회의록 보존 · 다시 생성 가능" }
                }
                self.runningID=nil
                if self.closing,let latest=self.records[id],latest.revision>record.revision,self.automatic,!self.manualOnlySessions.contains(id) { self.queue.append(id) }
            }
            self.task=nil;self.busy=false
            if let next=self.queue.first { self.enqueue(next,force:true) }
        }
    }
    func finish() async {
        closing=true
        await transcriptSaveTask?.value
        if automatic {
            for id in activeSessions where records[id] != nil && !manualOnlySessions.contains(id) { records[id]?.ended=true;persist(id);enqueue(id) }
        }
        while let current=task { await current.value }
    }
}


extension MeetingWorkspace {
    func restoreEditingBindings(_ value: MeetingSpeakerBindings) { bindings=value }
    private func editingDraftURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("Edited", isDirectory: true).appendingPathComponent(id.uuidString + ".md")
    }
    func applyChatDraft(_ text: String, expected: String) throws -> EditingReceipt {
        guard let id=sessionID, preview == expected else { throw EditingError.stale }
        let previous=editedPreview, previousOutput=records[id]?.editedOutput, url=editingDraftURL(id)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try Data(text.utf8).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        records[id]?.editedOutput=url.path;persist(id)
        editedPreview=text;editedURL=url;editedRevision=UUID()
        let revision=editedRevision
        status="채팅 편집본 저장 완료 · 자동 생성본은 별도로 보관합니다."
        return EditingReceipt(note:"회의록 편집본을 저장했습니다. 회의록 화면과 파일에서 확인할 수 있습니다.",url:url) { [weak self] in
            guard let self, self.sessionID==id, self.editedRevision==revision else { throw EditingError.stale }
            if let previous { try Data(previous.utf8).write(to:url,options:.atomic) }
            else { try FileManager.default.removeItem(at:url) }
            self.records[id]?.editedOutput=previousOutput;self.persist(id)
            self.editedPreview=previous;self.editedURL=previous == nil ? nil : url;self.editedRevision=UUID()
            self.status="회의록 편집을 되돌렸습니다."
        }
    }
}
