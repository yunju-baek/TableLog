import AppKit
import Combine
import Foundation

@MainActor final class MeetingAssistant: ObservableObject {
    @Published var enabled: Bool { didSet { defaults.set(enabled,forKey:"assistant.enabled"); if !enabled { pauseAutomatic() }; didChange?() } }
    @Published var model: String { didSet { defaults.set(model,forKey:"assistant.model") } }
    @Published var effort: String { didSet { defaults.set(effort,forKey:"assistant.effort") } }
    @Published var summaryInterval: Int { didSet { defaults.set(max(30,summaryInterval),forKey:"assistant.summaryInterval") } }
    @Published var suggestionInterval: Int { didSet { defaults.set(max(60,suggestionInterval),forKey:"assistant.suggestionInterval") } }
    @Published private(set) var busy=false
    @Published private(set) var status="회의를 준비하면 도우미가 맥락을 이어갑니다."
    @Published private(set) var error: String?
    @Published private(set) var state=AssistantState()
    @Published private(set) var runs:[AssistantRunLog]=[]
    var didChange:(() -> Void)?
    var selectedMaterialCount:Int { record?.materials?.documents.filter(\.enabled).count ?? 0 }
    var readyMaterialCount:Int { record?.materials?.documents.filter { $0.enabled && $0.analyzed }.count ?? 0 }
    private let directory:URL
    private let generator:any AssistantGenerating
    private let defaults:UserDefaults
    private let now:() -> Date
    private var record:MeetingWorkRecord?
    private var audioURL:URL?
    private var task:Task<Void,Never>?
    private var runningKind:String?
    private var generation=UUID()
    private var summaryPending=false
    private var explicitSummary=false
    private var nextAttempt=Date.distantPast
    private var failures=0
    private var receivedFingerprint=""
    private var stableSince:[String:(String,Date)]=[:]
    private var lastStart=Date.distantPast
    private var loadFailed=false
    private var recordedSourceSignature=""
    private var refreshAfter=Date.distantFuture

    init(directory:URL?=nil,generator:any AssistantGenerating=AssistantGenerator(),defaults:UserDefaults = .standard,now:@escaping () -> Date = Date.init) {
        self.directory=directory ?? StorageLocations.assistant
        self.generator=generator;self.defaults=defaults;self.now=now
        enabled=defaults.object(forKey:"assistant.enabled") as? Bool ?? true
        model=defaults.string(forKey:"assistant.model") ?? ""
        effort=defaults.string(forKey:"assistant.effort") ?? ""
        summaryInterval=max(30,defaults.object(forKey:"assistant.summaryInterval") as? Int ?? 60)
        suggestionInterval=max(60,defaults.object(forKey:"assistant.suggestionInterval") as? Int ?? 120)
    }
    private func folder(_ id:UUID)->URL { directory.appendingPathComponent(id.uuidString,isDirectory:true) }
    private func sourceSignature(_ record:MeetingWorkRecord)->String {
        AssistantFiles.hash((record.materials?.documents.filter(\.enabled).map { $0.id.uuidString+"|"+$0.hash+"|"+$0.chunks.map { $0.id+($0.summary ?? "") }.joined() }.sorted().joined() ?? ""))
    }
    private func fingerprint(_ record:MeetingWorkRecord)->String {
        struct Input:Encodable { let segments:[MeetingUtterance];let names:[Int:String];let bindings:MeetingSpeakerBindings;let purpose:String;let title:String;let sources:String }
        return AssistantFiles.hash(String(decoding:(try? AssistantFiles.encoded(Input(segments:record.segments,names:record.names,bindings:record.bindings,purpose:record.purpose,title:record.title,sources:sourceSignature(record)))) ?? Data(),as:UTF8.self))
    }
    private func evidenceMap(_ record:MeetingWorkRecord)->[String:AssistantEvidence] {
        var map:[String:AssistantEvidence]=[:]
        for segment in record.segments {
            let name=record.bindings.speakers[segment.speaker]?.name ?? record.names[segment.speaker] ?? "화자 \(segment.speaker)"
            let key="utterance:\(segment.id)"
            let hash=AssistantFiles.hash("\(segment.id)|\(segment.speaker)|\(name)|\(segment.start)|\(segment.end)|\(segment.text)")
            map[key]=AssistantEvidence(id:key,kind:"utterance",title:name,location:MeetingMinutesRenderer.time(segment.start)+"–"+MeetingMinutesRenderer.time(segment.end),text:segment.text,fingerprint:hash,start:segment.start,end:segment.end,audioPath:audioURL?.path)
        }
        for doc in record.materials?.documents.filter(\.enabled) ?? [] {
            for chunk in doc.chunks {
                let key="material:"+chunk.id
                map[key]=AssistantEvidence(id:key,kind:"material",title:doc.title,location:chunk.location,text:chunk.text,fingerprint:AssistantFiles.hash(doc.id.uuidString+"|"+doc.hash+"|"+chunk.text),sourceID:doc.id.uuidString,sourcePath:doc.originalPath)
            }
        }
        return map
    }
    func receive(record next:MeetingWorkRecord,audioURL:URL?=nil) {
        let date=now(), switched=state.sessionID != next.id
        if switched {
            stop(requeue:true)
            record=next;self.audioURL=audioURL;state=AssistantState(sessionID:next.id);runs=[];loadFailed=false;stableSince=[:]
            receivedFingerprint="";recordedSourceSignature=sourceSignature(next);failures=0;nextAttempt = .distantPast;refreshAfter = .distantFuture;lastStart=date
            let url=folder(next.id).appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath:url.path) {
                do {
                    let restored=try JSONDecoder().decode(AssistantState.self,from:Data(contentsOf:url))
                    guard restored.sessionID==next.id else { throw AssistantError.response("저장된 회의 식별자를 확인해 주세요.") }
                    state=restored
                    runs=(try? JSONDecoder().decode([AssistantRunLog].self,from:Data(contentsOf:folder(next.id).appendingPathComponent("runs.json")))) ?? []
                    for i in state.questions.indices where state.questions[i].status=="running" { state.questions[i].status="queued" }
                    for i in runs.indices where runs[i].status=="running" { runs[i].status="interrupted";runs[i].message="앱 재시작 후 요청 대기" }
                    status="저장된 회의 도우미 기록을 불러왔습니다."
                } catch { loadFailed=true;self.error="도우미 기록 복구를 확인해 주세요. 원본 기록은 저장 폴더에 보관되어 있습니다. " + error.localizedDescription }
            } else { status="회의 맥락 수집 중 · 기본 \(max(30,summaryInterval))초마다 요약";error=nil }
        }
        let wasEnded=record?.ended ?? next.ended
        record=next
        self.audioURL=audioURL ?? state.audioPath.map { URL(fileURLWithPath:$0) }
        if let path=self.audioURL?.path,path != state.audioPath { state.audioPath=path;hydrateAudio(path);persist() }
        let signature=fingerprint(next),changed=signature != receivedFingerprint
        guard changed || switched || wasEnded != next.ended else { return }
        let map=evidenceMap(next)
        for e in map.values where e.kind=="utterance" {
            if stableSince[e.id]?.0 != e.fingerprint { stableSince[e.id]=(e.fingerprint,date) }
        }
        stableSince=stableSince.filter { map[$0.key] != nil }
        receivedFingerprint=signature
        let oldPurpose=state.purpose
        state.purpose=next.purpose
        let invalidated=invalidate(using:map,purposeChanged:!oldPurpose.isEmpty && oldPurpose != next.purpose)
        let sources=sourceSignature(next)
        if !switched && sources != recordedSourceSignature { refreshAfter=date.addingTimeInterval(8) }
        recordedSourceSignature=sources
        if invalidated { refreshAfter=date.addingTimeInterval(5);event("evidence_changed",message:"교정·화자·자료 변경에 따른 근거 재검토") }
        if enabled && !wasEnded && next.ended && !next.segments.isEmpty { summaryPending=true }
        if switched || invalidated || oldPurpose != state.purpose { persist() }
    }
    private func hydrateAudio(_ path:String) {
        func refs(_ values:[AssistantEvidence])->[AssistantEvidence] { values.map { item in var copy=item;if copy.kind=="utterance" { copy.audioPath=path };return copy } }
        for i in state.summary.indices { state.summary[i].evidence=refs(state.summary[i].evidence) }
        for i in state.decisionCandidates.indices { state.decisionCandidates[i].evidence=refs(state.decisionCandidates[i].evidence) }
        for i in state.openQuestions.indices { state.openQuestions[i].evidence=refs(state.openQuestions[i].evidence) }
        for i in state.suggestions.indices { state.suggestions[i].evidence=refs(state.suggestions[i].evidence) }
        for i in state.questions.indices { state.questions[i].evidence=refs(state.questions[i].evidence) }
    }
    @discardableResult private func invalidate(using map:[String:AssistantEvidence],purposeChanged:Bool)->Bool {
        func valid(_ evidence:[AssistantEvidence])->Bool { !purposeChanged && evidence.allSatisfy { map[$0.id]?.fingerprint==$0.fingerprint } }
        var changed=false
        for i in state.summary.indices where !state.summary[i].stale && !valid(state.summary[i].evidence) { state.summary[i].stale=true;changed=true }
        for i in state.decisionCandidates.indices where !state.decisionCandidates[i].stale && !valid(state.decisionCandidates[i].evidence) { state.decisionCandidates[i].stale=true;changed=true }
        for i in state.openQuestions.indices where !state.openQuestions[i].stale && !valid(state.openQuestions[i].evidence) { state.openQuestions[i].stale=true;changed=true }
        for i in state.suggestions.indices where !state.suggestions[i].stale && !valid(state.suggestions[i].evidence) { state.suggestions[i].stale=true;changed=true }
        return changed
    }
    func tick() {
        guard !loadFailed,let record else { return }
        let date=now()
        if enabled && !record.ended && !record.segments.isEmpty && receivedFingerprint != state.lastInputFingerprint && (date.timeIntervalSince(lastStart)>=Double(max(30,summaryInterval)) || date>=refreshAfter) { summaryPending=true }
        if !record.ended || explicitSummary || (enabled && summaryPending) { startIfNeeded() }
    }
    func requestSummary() {
        guard record != nil else { status="새 회의를 준비해 주세요.";return }
        summaryPending=true;explicitSummary=true;nextAttempt = .distantPast
        startIfNeeded(force:true)
    }
    func ask(_ text:String) {
        let question=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard record != nil,!question.isEmpty else { return }
        guard question.count<=6000 else { error="질문은 6,000자 이내로 입력해 주세요.";return }
        guard state.questions.filter({ ["queued","running"].contains($0.status) }).count<20 else { error="대기 질문 20개를 처리한 뒤 다음 질문을 추가해 주세요.";return }
        state.questions.append(AssistantQuestion(id:UUID(),text:question,createdAt:now()))
        event("question_queued",message:question);persist();nextAttempt = .distantPast
        startIfNeeded(force:true)
    }
    func retry() {
        nextAttempt = .distantPast;failures=0;error=nil
        var found=false
        for i in state.questions.indices where state.questions[i].status=="failed" || state.questions[i].status=="cancelled" {
            state.questions[i].status="queued";state.questions[i].error=nil;found=true
        }
        if !found { summaryPending=true;explicitSummary=true }
        persist();startIfNeeded(force:true)
    }
    func cancel() { stop(requeue:false);status="도우미 분석을 중단했습니다. 저장된 요약과 근거를 확인할 수 있습니다." }
    func resetForNewSession() {
        // Persist the previous session's completed content and stop its pending work before clearing the view.
        stop(requeue:false)
        record=nil;audioURL=nil;state=AssistantState();runs=[]
        status="새 회의를 준비하면 도우미가 맥락을 살펴봅니다.";error=nil
        receivedFingerprint="";recordedSourceSignature="";stableSince=[:]
        loadFailed=false;failures=0;nextAttempt = .distantPast;lastStart = .distantPast;refreshAfter = .distantFuture
        didChange?()
    }
    private func pauseAutomatic() {
        let preserveSummary=explicitSummary
        if runningKind=="automatic" { stop(requeue:true) }
        summaryPending=preserveSummary;explicitSummary=preserveSummary
        startIfNeeded()
    }
    private func stop(requeue:Bool) {
        generation=UUID();task?.cancel();task=nil;runningKind=nil;busy=false;summaryPending=false;explicitSummary=false
        for i in state.questions.indices where state.questions[i].status=="running" || (!requeue && state.questions[i].status=="queued") { state.questions[i].status=requeue ? "queued" : "cancelled" }
        for i in runs.indices where runs[i].status=="running" { runs[i].status="cancelled";runs[i].message="회의 전환 또는 사용자 중단" }
        if state.sessionID != nil { persist() }
    }
    private func buildRequest(question:AssistantQuestion?,explicit:Bool)->AssistantRequest? {
        guard let record else { return nil }
        let date=now(),map=evidenceMap(record)
        let ordered=record.segments.sorted { $0.start==$1.start ? $0.id<$1.id : $0.start<$1.start }
        var speech=Array(ordered.prefix { segment in
            let key="utterance:\(segment.id)"
            return explicit || record.ended || date.timeIntervalSince(stableSince[key]?.1 ?? date)>=2
        })
        // Consume unseen speech chronologically so long pauses or queued work retain coverage.
        let uncovered=speech.filter { $0.end>state.coverageSeconds }.sorted { $0.start<$1.start }
        var batch:[MeetingUtterance]=[],batchCharacters=0
        for segment in uncovered {
            guard segment.text.count<=60_000 else { error="60,000자를 초과하는 단일 발언은 구간을 나누어 다시 분석해 주세요.";status="긴 발언 구간 확인 필요";return nil }
            if !batch.isEmpty && (batch.count>=60 || batchCharacters+segment.text.count>16_000) { break }
            batch.append(segment);batchCharacters+=segment.text.count
        }
        let coverage=batch.map(\.end).max() ?? speech.map(\.end).max() ?? 0
        let hasMoreSpeech=uncovered.count>batch.count
        if let first=batch.first {
            speech=Array(speech.filter { $0.end<=first.start && $0.end>=first.start-30 }.suffix(12))+batch
        } else { speech=Array(speech.filter { $0.end>=max(0,coverage-180) }.suffix(80)) }
        var coveredRecord=record
        coveredRecord.segments=record.segments.filter { $0.end<=coverage }
        let coveredFingerprint=fingerprint(coveredRecord)
        var evidence:[AssistantEvidence]=[],used=0,seen=Set<String>()
        func add(_ e:AssistantEvidence) { if seen.insert(e.id).inserted { evidence.append(e) } }
        for segment in speech.reversed() {
            guard let e=map["utterance:\(segment.id)"] else { continue }
            let required=batch.contains { $0.id==segment.id }
            guard required || used+e.text.count<=20_000 else { continue }
            used+=e.text.count;add(e)
        }
        evidence.reverse()
        if let question {
            let latestEnd=ordered.map(\.end).max() ?? 0
            let queryTokens=MaterialContext.tokens(question.text)
            let relevant=ordered.sorted { a,b in
                MaterialContext.tokens(a.text).intersection(queryTokens).count > MaterialContext.tokens(b.text).intersection(queryTokens).count
            }
            var extraCharacters=0
            let extra=Array(ordered.filter { $0.end>=latestEnd-90 }.suffix(12))+Array(relevant.prefix(6))
            for segment in extra.reversed() {
                guard let e=map["utterance:\(segment.id)"],!seen.contains(e.id),extraCharacters+e.text.count<=6000 else { continue }
                extraCharacters+=e.text.count;used+=e.text.count;add(e)
            }
        }
        let memory=state.summary+state.decisionCandidates+state.openQuestions
        // Corrections to an older cited decision remain reviewable beyond the recent speech window.
        let changedMemory=memory.filter(\.stale).flatMap(\.evidence)+state.suggestions.filter(\.stale).flatMap(\.evidence)
        var changedCharacters=0
        for old in changedMemory {
            if let latest=map[old.id],changedCharacters+latest.text.count<=16_000,!seen.contains(latest.id) {
                changedCharacters+=latest.text.count;used+=latest.text.count;add(latest)
            }
        }
        for old in memory.flatMap(\.evidence) { if let e=map[old.id],e.fingerprint==old.fingerprint,used+e.text.count<=36_000,!seen.contains(e.id) { used+=e.text.count;add(e) } }
        let query=[question?.text ?? "",record.purpose,state.currentAgenda,speech.suffix(20).map(\.text).joined(separator:" ")].joined(separator:" ")
        let selected=MaterialContext(documents:record.materials?.documents.filter(\.enabled) ?? [])
        for excerpt in selected.excerpts(query:query,limit:6,characters:9000) {
            if let e=map["material:"+excerpt.id] { add(e) }
        }
        let available=Set(evidence.map(\.id))
        func usable(_ values:[AssistantItem])->[AssistantItem] {
            Array(values.filter { $0.evidence.allSatisfy { available.contains($0.id) } }.suffix(12)).map { item in
                var compact=item;compact.evidence=item.evidence.compactMap { e in guard var ref=map[e.id] else { return nil };ref.text="";ref.sourcePath=nil;ref.audioPath=nil;return ref };return compact
            }
        }
        return AssistantRequest(sessionID:record.id,runID:UUID(),kind:question == nil ? (explicit ? "manual_summary" : "automatic") : "question",title:record.title,purpose:record.purpose,baseStateRevision:state.revision,recordRevision:record.revision,coveredThroughSeconds:coverage,inputFingerprint:coveredFingerprint,hasMoreSpeech:hasMoreSpeech,reviewSuggestions:question != nil || explicit || date.timeIntervalSince(state.lastSuggestionAt ?? .distantPast)>=Double(max(60,suggestionInterval)),questionID:question?.id,question:question?.text,currentAgenda:state.currentAgenda,previousSummary:usable(state.summary),decisionCandidates:usable(state.decisionCandidates),openQuestions:usable(state.openQuestions),existingSuggestions:Array(state.suggestions.suffix(20)).map { s in var compact=s;compact.evidence=[];return compact },recentQuestions:Array(state.questions.filter { $0.status=="completed" }.suffix(4)).map { q in var brief=q;brief.text=String(q.text.prefix(1000));brief.answer=q.answer.map { String($0.prefix(1600)) };brief.evidence=[];return brief },evidence:evidence,materialOverview:selected.documents.prefix(40).map { doc in doc.title+" · "+String(doc.chunks.compactMap(\.summary).joined(separator:" ").prefix(350)) })
    }
    private func startIfNeeded(force:Bool=false) {
        let question=state.questions.first { $0.status=="queued" }
        guard task==nil,!loadFailed,let record,(enabled || force || question != nil || explicitSummary),now()>=nextAttempt else { return }
        guard question != nil || summaryPending else { return }
        let explicit=question != nil || explicitSummary
        guard let request=buildRequest(question:question,explicit:explicit) else { return }
        if question==nil && request.evidence.isEmpty { summaryPending=false;explicitSummary=false;status="발언이나 회의자료를 추가하면 요약할 수 있습니다.";return }
        if let question,let i=state.questions.firstIndex(where:{$0.id==question.id}) { state.questions[i].status="running" }
        if question==nil { summaryPending=false;explicitSummary=false }
        let token=generation,date=now(),runFolder=folder(record.id).appendingPathComponent("runs").appendingPathComponent(request.runID.uuidString)
        var settings=record.settings
        if settings.provider == .codex && !model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { settings.model=model.trimmingCharacters(in:.whitespacesAndNewlines) }
        if settings.provider == .codex && !effort.isEmpty { settings.effort=effort }
        lastStart=date;refreshAfter = .distantFuture;runningKind=request.kind;busy=true;error=nil;status=question == nil ? "회의 맥락 요약 중" : "질문 답변 준비 중"
        runs.append(AssistantRunLog(id:request.runID,date:date,kind:request.kind,model:settings.modelLabel,effort:settings.effort,coverageSeconds:request.coveredThroughSeconds,status:"running",folderPath:runFolder.path,beforeSummary:state.summary.map(\.text).joined(separator:"\n")))
        if runs.count>300 { runs.removeFirst(runs.count-300) }
        persist()
        task=Task { [weak self] in
            guard let self else { return }
            do {
                try AssistantFiles.write(request,to:runFolder.appendingPathComponent("input.json"))
                let response=try await self.generator.generate(request,settings:settings,debugDirectory:runFolder)
                try Task.checkCancellation()
                try AssistantGenerator.validate(response,request:request)
                guard self.generation==token,self.state.sessionID==request.sessionID else { return }
                try AssistantFiles.write(response,to:runFolder.appendingPathComponent("output.json"))
                let rejected=self.apply(response,request:request)
                let message=rejected.isEmpty ? "근거 ID·버전 검증 완료" : "변경된 근거 \(rejected.count)개 · 관련 항목 재검토"
                try AssistantFiles.write(["status":rejected.isEmpty ? "accepted" : "partial","message":message,"changedEvidenceIDs":rejected.joined(separator:",")],to:runFolder.appendingPathComponent("validation.json"))
                self.finishLog(request.runID,status:rejected.isEmpty ? "completed" : "partial",message:message,started:date)
                self.failures=0;self.nextAttempt = .distantPast;self.error=nil
                self.status="\(MeetingMinutesRenderer.time(request.coveredThroughSeconds)) 발언까지 반영"+(rejected.isEmpty ? "" : " · 근거 재검토")
                self.event("analysis_completed",message:message)
                if request.hasMoreSpeech { self.summaryPending=true;self.explicitSummary=self.explicitSummary || request.kind != "automatic" }
            } catch {
                guard self.generation==token,self.state.sessionID==request.sessionID else { return }
                let cancelled=error is CancellationError
                self.finishLog(request.runID,status:cancelled ? "cancelled" : "failed",message:error.localizedDescription,started:date)
                if let id=request.questionID,let i=self.state.questions.firstIndex(where:{$0.id==id}) { self.state.questions[i].status=cancelled ? "cancelled" : "failed";self.state.questions[i].error=error.localizedDescription }
                if !cancelled {
                    self.failures+=1
                    let quota=(error as? CodexFailure)?.kind == .quota
                    self.nextAttempt=self.now().addingTimeInterval(quota ? 900 : min(600,30*pow(2,Double(min(4,self.failures-1)))))
                    self.error=error.localizedDescription;self.status="도우미 재시도 대기 · 저장된 회의 맥락 유지"
                    self.summaryPending=request.questionID==nil
                    self.event("analysis_failed",message:error.localizedDescription)
                }
                try? AssistantFiles.write(["status":cancelled ? "cancelled" : "failed","message":error.localizedDescription],to:runFolder.appendingPathComponent("validation.json"))
            }
            guard self.generation==token else { return }
            self.task=nil;self.runningKind=nil;self.busy=false;self.persist()
            if self.state.questions.contains(where:{$0.status=="queued"}) || self.summaryPending { self.startIfNeeded() }
        }
    }
    private func finishLog(_ id:UUID,status:String,message:String,started:Date) {
        if let i=runs.firstIndex(where:{$0.id==id}) { runs[i].status=status;runs[i].message=message;runs[i].elapsed=max(0,now().timeIntervalSince(started));runs[i].afterSummary=state.summary.map(\.text).joined(separator:"\n") }
    }
    @discardableResult private func apply(_ response:AssistantResponse,request:AssistantRequest)->[String] {
        guard let record else { return [] }
        let map=evidenceMap(record),input=Dictionary(request.evidence.map { ($0.id,$0) },uniquingKeysWith: { first,_ in first })
        let purposeChanged=request.purpose != record.purpose
        let changed=request.evidence.filter { map[$0.id]?.fingerprint != $0.fingerprint }.map(\.id)
        let changedSet=Set(changed)
        func evidence(_ ids:[String])->[AssistantEvidence] { ids.compactMap { input[$0] } }
        func stale(_ ids:[String])->Bool { purposeChanged || !Set(ids).isDisjoint(with:changedSet) }
        func items(_ drafts:[AssistantDraftItem],kind:String)->[AssistantItem] {
            drafts.map { AssistantItem(id:AssistantFiles.hash(kind+"|"+$0.text),text:$0.text,evidence:evidence($0.evidenceIDs),stale:stale($0.evidenceIDs)) }
        }
        state.summary=items(response.summary,kind:"summary")
        var decisions=items(response.decisionCandidates,kind:"decision")
        for old in state.decisionCandidates where old.confirmed {
            if let i=decisions.firstIndex(where:{$0.id==old.id}) { decisions[i].confirmed=true }
            else { var preserved=old;preserved.stale=old.stale || old.evidence.contains { map[$0.id]?.fingerprint != $0.fingerprint };decisions.append(preserved) }
        }
        state.decisionCandidates=decisions
        state.openQuestions=items(response.openQuestions,kind:"question")
        if !purposeChanged {
            let old=MaterialContext.tokens(state.currentAgenda),new=MaterialContext.tokens(response.currentAgenda)
            if !old.isEmpty && !new.isEmpty && Double(old.intersection(new).count)/Double(max(old.count,new.count))<0.25 {
                for i in state.suggestions.indices where state.suggestions[i].status == .active { state.suggestions[i].status = .deferred }
            }
            state.currentAgenda=response.currentAgenda
        }
        let date=now()
        let resolvable=Set(response.resolvedSuggestionIDs.filter { id in
            guard let current=state.suggestions.first(where:{$0.id==id}),let old=request.existingSuggestions.first(where:{$0.id==id}) else { return false }
            return current.status==old.status && current.updatedAt<=old.updatedAt && !current.stale
        })
        for draft in response.suggestions {
            let exact=state.suggestions.firstIndex(where:{$0.id==draft.key})
            let similar=state.suggestions.firstIndex { s in
                let a=MaterialContext.tokens(s.title),b=MaterialContext.tokens(draft.title)
                return s.kind==draft.kind && !a.isEmpty && Double(a.intersection(b).count)/Double(max(a.count,b.count))>=0.72
            }
            let index=exact ?? similar
            if let index {
                // Preserve every user-controlled status while refreshing the source snapshots.
                state.suggestions[index].title=draft.title;state.suggestions[index].reason=draft.reason;state.suggestions[index].premise=draft.premise
                state.suggestions[index].evidence=evidence(draft.evidenceIDs);state.suggestions[index].stale=stale(draft.evidenceIDs);state.suggestions[index].updatedAt=date
            } else {
                if request.kind=="automatic" && date.timeIntervalSince(state.lastNewSuggestionAt ?? .distantPast)<60 { continue }
                let id=AssistantFiles.hash("suggestion|"+request.currentAgenda+"|"+draft.key)
                state.suggestions.append(AssistantSuggestion(id:id,kind:draft.kind,title:draft.title,reason:draft.reason,premise:draft.premise,evidence:evidence(draft.evidenceIDs),stale:stale(draft.evidenceIDs),createdAt:date,updatedAt:date))
                state.lastNewSuggestionAt=date
            }
        }
        for id in response.resolvedSuggestionIDs {
            if resolvable.contains(id),let i=state.suggestions.firstIndex(where:{$0.id==id}),!state.suggestions[i].stale { state.suggestions[i].status = .resolved;state.suggestions[i].updatedAt=date }
        }
        if let id=request.questionID,let i=state.questions.firstIndex(where:{$0.id==id}) {
            state.questions[i].answer=response.answer;state.questions[i].evidence=evidence(response.answerEvidenceIDs);state.questions[i].status="completed";state.questions[i].completedAt=date
            if stale(response.answerEvidenceIDs) { state.questions[i].error="응답의 근거가 변경되었습니다. 새 질문으로 최신 맥락을 확인해 주세요." }
        }
        state.coverageSeconds=max(state.coverageSeconds,request.coveredThroughSeconds);state.updatedAt=date;state.lastRunID=request.runID;state.lastSummaryAt=date
        if request.reviewSuggestions { state.lastSuggestionAt=date }
        // New appended utterances remain eligible for the following tick. Edited dependencies trigger a refresh.
        state.lastInputFingerprint=request.inputFingerprint
        if !changed.isEmpty || purposeChanged { refreshAfter=date.addingTimeInterval(5) }
        if let path=state.audioPath { hydrateAudio(path) }
        state.revision+=1
        return changed+(purposeChanged ? ["meeting:purpose"] : [])
    }
    func setSuggestionStatus(id:String,status:AssistantSuggestionStatus) {
        guard let i=state.suggestions.firstIndex(where:{$0.id==id}) else { return }
        state.suggestions[i].status=status;state.suggestions[i].updatedAt=now();state.revision+=1
        event("suggestion_status",message:id+" · "+status.rawValue);persist()
    }
    func confirmDecision(id:String) {
        guard let i=state.decisionCandidates.firstIndex(where:{$0.id==id}),!state.decisionCandidates[i].stale else { return }
        state.decisionCandidates[i].confirmed.toggle();state.revision+=1
        event("decision_confirmed",message:id+" · "+String(state.decisionCandidates[i].confirmed));persist()
    }
    func addQuestionToMinutes(id:UUID) {
        guard let i=state.questions.firstIndex(where:{$0.id==id}),state.questions[i].status=="completed" else { return }
        state.questions[i].includedInMinutes=true;state.revision+=1
        event("question_added_to_minutes",message:id.uuidString);persist()
    }
    private func event(_ kind:String,message:String) {
        guard let id=state.sessionID,!loadFailed else { return }
        struct Event:Encodable { let date:Date;let kind:String;let message:String;let revision:Int }
        let url=folder(id).appendingPathComponent("events.jsonl")
        do {
            try AssistantFiles.directory(folder(id))
            var data=try JSONEncoder().encode(Event(date:now(),kind:kind,message:message,revision:state.revision));data.append(0x0A)
            if !FileManager.default.fileExists(atPath:url.path) { try AssistantFiles.writeData(Data(),to:url) }
            let handle=try FileHandle(forWritingTo:url);defer { try? handle.close() };try handle.seekToEnd();try handle.write(contentsOf:data)
        } catch { self.error="도우미 변경 기록 저장 확인 · "+error.localizedDescription }
    }
    private func persist() {
        guard let id=state.sessionID,!loadFailed else { return }
        do { try AssistantFiles.write(state,to:folder(id).appendingPathComponent("state.json"));try AssistantFiles.write(runs,to:folder(id).appendingPathComponent("runs.json")) }
        catch { self.error="도우미 기록 저장 확인 · "+error.localizedDescription }
        didChange?()
    }
    func showDebugFolder() {
        let target=state.sessionID.map(folder) ?? directory
        try? AssistantFiles.directory(target);NSWorkspace.shared.open(target)
    }
    func openEvidence(_ evidence:AssistantEvidence) {
        if let path=evidence.sourcePath,FileManager.default.fileExists(atPath:path) { NSWorkspace.shared.open(URL(fileURLWithPath:path)) }
        else if let path=evidence.audioPath,FileManager.default.fileExists(atPath:path) { NSWorkspace.shared.open(URL(fileURLWithPath:path)) }
    }
    func appendixMarkdown(sessionID:UUID)->String {
        let value:AssistantState?
        if state.sessionID==sessionID { value=state }
        else { value=(try? Data(contentsOf:folder(sessionID).appendingPathComponent("state.json"))).flatMap { try? JSONDecoder().decode(AssistantState.self,from:$0) } }
        guard let value,!value.summary.isEmpty || !value.suggestions.isEmpty || !value.questions.isEmpty else { return "" }
        func safe(_ s:String)->String { s.replacingOccurrences(of:"\n",with:" ") }
        func sources(_ refs:[AssistantEvidence])->String { refs.map { $0.title+" · "+$0.location }.joined(separator:" / ") }
        var lines=["", "# 회의 도우미 기록", "", "AI 요약·제안과 사용자 확인 이력입니다. 근거 발언과 자료를 함께 확인합니다.", "", "- 반영 범위: "+MeetingMinutesRenderer.time(value.coverageSeconds), "- 현재 안건: "+safe(value.currentAgenda), "", "## 누적 요약", ""]
        for item in value.summary { lines.append("- "+safe(item.text)+(item.stale ? " · 근거 재검토" : "")+" — "+sources(item.evidence)) }
        lines += ["", "## 결정 후보와 사용자 확인", ""]
        for item in value.decisionCandidates { lines.append("- ["+(item.confirmed ? "사용자 확인" : "결정 후보")+(item.stale ? " · 근거 재검토" : "")+"] "+safe(item.text)+" — "+sources(item.evidence)) }
        lines += ["", "## 미해결 질문", ""]
        for item in value.openQuestions { lines.append("- "+safe(item.text)+" — "+sources(item.evidence)) }
        lines += ["", "## 도우미 제안 이력", ""]
        for item in value.suggestions { lines.append("- [\(item.status.title)] \(safe(item.title)) · \(safe(item.reason)) · 확인할 전제: \(safe(item.premise)) — \(sources(item.evidence))"+(item.stale ? " · 근거 재검토" : "")) }
        let selectedQuestions=value.questions.filter { $0.includedInMinutes == true }
        if !selectedQuestions.isEmpty { lines += ["", "## 사용자 추가 메모 · 도우미 대화", "", "사용자가 회의 메모에 추가한 질문과 AI 답변입니다.", ""] }
        for q in selectedQuestions { lines.append("- 사용자 질문: "+safe(q.text));if let answer=q.answer { lines.append("  - AI 답변: "+safe(answer)+" — "+sources(q.evidence)) } }
        let allEvidence=(value.summary+value.decisionCandidates+value.openQuestions).flatMap(\.evidence)+value.suggestions.flatMap(\.evidence)+selectedQuestions.flatMap(\.evidence)
        var seen=Set<String>()
        let refs=allEvidence.filter { seen.insert($0.id+"|"+$0.fingerprint).inserted }
        if !refs.isEmpty { lines += ["", "## 도우미 근거 원문과 버전", ""] }
        for ref in refs {
            lines += ["### "+safe(ref.title)+" · "+safe(ref.location), "", "- 근거 ID: `"+ref.id+"`", "- 분석 당시 SHA-256: `"+ref.fingerprint+"`"]
            if let path=ref.sourcePath { lines.append("- [보관 자료 원본]("+URL(fileURLWithPath:path).absoluteString+")") }
            if let path=ref.audioPath { lines.append("- [회의 M4A]("+URL(fileURLWithPath:path).absoluteString+") · "+safe(ref.location)) }
            lines += ["", ref.text.components(separatedBy:.newlines).map { "> "+$0 }.joined(separator:"\n"), ""]
        }
        return lines.joined(separator:"\n")+"\n"
    }
}
