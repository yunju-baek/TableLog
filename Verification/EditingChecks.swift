import Foundation
import AppKit
import SwiftUI
import Combine
import CoreAudio
import AVFoundation

final class ControlledMicrophone: MicrophoneCapturing {
    var starts = 0
    var automaticallyDrain = false
    var failStart = false
    var pendingStops: [() -> Void] = []
    var level: ((Float) -> Void)?
    func start(deviceID: AudioDeviceID?, onAudio: @escaping ([Float]) -> Void,
               onLevel: @escaping (Float) -> Void, onError: @escaping (Error) -> Void) throws {
        if failStart { throw MicrophoneCaptureError.inputUnavailable }
        starts += 1; level = onLevel
    }
    func stop(completion: @escaping () -> Void) {
        pendingStops.append(completion)
        if automaticallyDrain { DispatchQueue.main.async { self.drain() } }
    }
    func drain() { let pending = pendingStops; pendingStops = []; pending.forEach { $0() } }
}

@main struct EditingChecks {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "/private/tmp/tablelog-edit-checks",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let defaults=UserDefaults(suiteName:"local.TableLog.Verification."+UUID().uuidString)!
        defaults.set(false,forKey:"assistant.enabled");defaults.set(false,forKey:"minutes.automatic")
        var settings=CodexCorrectionSettings();settings.mode = .off
        defaults.set(try JSONEncoder().encode(settings),forKey:"codexCorrection.v1")
        let minutes=MeetingWorkspace(directory:root.appendingPathComponent("Minutes"),defaults:defaults)
        let materialRoot=root.appendingPathComponent("Materials")
        try FileManager.default.createDirectory(at:materialRoot,withIntermediateDirectories:true)
        let source=materialRoot.appendingPathComponent("original.md")
        try Data("원본 기획 자료".utf8).write(to:source)
        let original=MeetingMaterial(id:UUID(),title:"교과목 기획",origin:"fixture",importedAt:Date(),hash:"fixture",
            originalPath:source.path,extractedPath:source.path,
            chunks:[.init(id:"c1",location:"1쪽",text:"과목명은 인공 지능 기초다."),.init(id:"c2",location:"2쪽",text:"모집 인원은 30명이다.")],warnings:[])
        try JSONEncoder().encode([original]).write(to:materialRoot.appendingPathComponent("library.json"))
        let materials=MeetingMaterials(root:materialRoot)
        let previewMicrophone = ControlledMicrophone()
        previewMicrophone.automaticallyDrain = true
        let model=AppModel(materials:materials,meeting:minutes,
            assistant:MeetingAssistant(directory:root.appendingPathComponent("Assistant"),defaults:defaults),loadEngine:false,
            voice:VoiceIdentity(root:root.appendingPathComponent("Voice")),
            history:MeetingHistoryStore(transcripts:root.appendingPathComponent("Transcripts"),minutes:root.appendingPathComponent("Minutes")),
            transcriptDirectory:root.appendingPathComponent("Transcripts"),startBackgroundServices:false,preferences:defaults,microphone:previewMicrophone)
        model.loadEditingFixture()
        if CommandLine.arguments.contains("--preview-recording") {
            try model.loadRecordingFixture(directory: root.appendingPathComponent("PreviewAudio"))
            showPreview(model); return
        }
        if CommandLine.arguments.contains("--preview") { showPreview(model);return }
        var passed=0
        func check(_ condition:Bool,_ name:String) { if !condition { fatalError("FAIL: "+name) };passed += 1; print("PASS: "+name) }
        func expectFailure(_ name:String,_ block:() throws -> Void) {
            do { try block();fatalError("Expected rejection: "+name) } catch { passed += 1;print("PASS: "+name) }
        }
        func plan(_ doc:EditingDocument,_ text:String?=nil,speaker:Int = -1)->EditingPlan {
            EditingPlan(answer:"수정안입니다.",changes:[.init(targetID:doc.id,before:doc.text,after:text ?? doc.text,speaker:speaker)])
        }
        let legacy=Data(#"{"mode":"codex","model":"old-model","effort":"low","batchSeconds":20,"executablePath":"/legacy/codex"}"#.utf8)
        var profiles=try JSONDecoder().decode(CodexCorrectionSettings.self,from:legacy)
        check(profiles.provider == .codex && profiles.model=="old-model","legacy CLI settings restored")
        profiles.selectProvider(.claude);check(profiles.model.isEmpty && profiles.executablePath.isEmpty,"new CLI uses own defaults")
        profiles.model="claude-test";profiles.executablePath="/custom/claude";profiles.selectProvider(.gemini);profiles.selectProvider(.claude)
        check(profiles.model=="claude-test" && profiles.executablePath=="/custom/claude","CLI profile restored")
        profiles.selectProvider(.codex);check(profiles.model=="old-model" && profiles.executablePath=="/legacy/codex","Codex profile preserved")
        let roundtrip=try JSONDecoder().decode(CodexCorrectionSettings.self,from:JSONEncoder().encode(profiles))
        check(roundtrip==profiles,"CLI profiles persisted")
        let claude=try AITextRunner.normalizedResponse(#"{"is_error":false,"structured_output":{"ok":true}}"#,provider:.claude)
        check((try JSONSerialization.jsonObject(with:claude) as? [String:Bool])?["ok"]==true,"Claude structured response decoded")
        let gemini=try AITextRunner.normalizedResponse(#"{"response":"```json\n{\"ok\":true}\n```","stats":{"tools":{"totalCalls":0}}}"#,provider:.gemini)
        check((try JSONSerialization.jsonObject(with:gemini) as? [String:Bool])?["ok"]==true,"Gemini JSON response decoded")
        expectFailure("AI tool usage rejected") { _=try AITextRunner.normalizedResponse(#"{"response":"{}","stats":{"tools":{"totalCalls":1}}}"#,provider:.gemini) }
        expectFailure("AI permission denial rejected") { _=try AITextRunner.normalizedResponse(#"{"result":"{}","permission_denials":[{}]}"#,provider:.claude) }
        expectFailure("malformed AI JSON rejected") { _=try AITextRunner.normalizedResponse(#"{"response":"not JSON"}"#,provider:.gemini) }
        expectFailure("AI error response rejected") { _=try AITextRunner.normalizedResponse(#"{"is_error":true,"result":"authentication required"}"#,provider:.claude) }
        let merged=AITextRunner.merge(["security":["auth":"enterprise"],"admin":["mcp":["enabled":true],"other":true]],["admin":["mcp":["enabled":false]]])
        check((merged["security"] as? [String:String])?["auth"]=="enterprise" && (merged["admin"] as? [String:Any])?["other"] as? Bool==true,"Gemini administrator settings preserved")
        let capture=model.editingSnapshot(), speech=capture.documents.first{$0.id=="utterance.2"}!
        let receipt=try model.applyEditingPlan(plan(speech,speaker:2),capture:capture)
        check(model.visibleSegments.contains{model.displayedText(for:$0)==speech.text && model.effectiveSpeaker($0)==2},"speaker reassignment applied")
        check(model.visibleSegments.first{$0.id==1}?.speaker==1,"unrelated speech preserved")
        check(model.lastSavedURL.map{FileManager.default.fileExists(atPath:$0.path)} ?? false,"transcript saved")
        expectFailure("stale proposal rejected") { _=try model.applyEditingPlan(plan(speech,"새 문장"),capture:capture) }
        try receipt.undo()
        check(model.visibleSegments.contains{$0.id==2 && model.effectiveSpeaker($0)==1},"speaker undo restored")
        let rename=model.editingSnapshot(), name=rename.documents.first{$0.id=="speaker.2"}!
        let renameReceipt=try model.applyEditingPlan(plan(name,"박교수"),capture:rename)
        check(model.speakerName(for:2)=="박교수","speaker name changed")
        try renameReceipt.undo();check(model.speakerName(for:2)=="김교수","speaker name undo")
        let first=model.editingSnapshot(), firstDoc=first.documents.first{$0.id=="utterance.1"}!
        let textReceipt=try model.applyEditingPlan(plan(firstDoc,"이번 학기에는 실습 과목 두 개를 운영하겠습니다."),capture:first)
        check(model.visibleSegments.contains{model.displayedText(for:$0).contains("과목 두 개")},"text correction applied")
        let subsequent=model.editingSnapshot(), nextDoc=subsequent.documents.first{$0.kind == .transcript && $0.text.contains("과목 두 개")}!
        _=try model.applyEditingPlan(plan(nextDoc,"이번 학기에는 실습 과목 세 개를 운영하겠습니다."),capture:subsequent)
        expectFailure("undo cannot overwrite later edit") { try textReceipt.undo() }
        model.undoTranscriptEdit();model.undoTranscriptEdit()
        let appendCapture=model.editingSnapshot(), appendDoc=appendCapture.documents.first{$0.id=="utterance.3"}!
        model.segments.append(.init(id:4,speaker:1,startTime:24,endTime:30,text:"추가 발언입니다."))
        let appended=try model.applyEditingPlan(plan(appendDoc,"학생 의견을 다음 주에 공유하겠습니다."),capture:appendCapture)
        check(model.visibleSegments.contains{$0.id==4},"new recording speech survives unrelated edit")
        try appended.undo();check(model.visibleSegments.contains{$0.id==4},"undo preserves new recording speech")
        let snapshot=model.editingSnapshot()
        expectFailure("unknown target rejected") { try EditingPlan(answer:"",changes:[.init(targetID:"invented",before:"",after:"x",speaker:-1)]).validate(in:snapshot) }
        expectFailure("before text mismatch rejected") { try EditingPlan(answer:"",changes:[.init(targetID:"utterance.1",before:"wrong",after:"x",speaker:-1)]).validate(in:snapshot) }
        let dup=plan(snapshot.documents.first{$0.id=="utterance.1"}!,"새 내용").changes[0]
        expectFailure("duplicate target rejected") { try EditingPlan(answer:"",changes:[dup,dup]).validate(in:snapshot) }
        expectFailure("invalid speaker rejected") { try plan(snapshot.documents.first{$0.id=="utterance.1"}!,speaker:9).validate(in:snapshot) }
        check(snapshot.focused(on:"예산",limit:1000).omittedCount>0,"partial context explicitly marked")
        let minuteDoc=model.editingSnapshot().documents.first{$0.kind == .minutes}!, originalMinutes=minutes.preview
        check(minutes.lastURL==nil && minutes.metadata?.output==nil,"pending minutes have no exported document")
        check(model.canGenerateMinutes && !model.canRegenerateHistoryMinutes && model.displayStatusMessage.contains("회의록 생성"),"ordinary completed meeting exposes generation and pending status")
        let minutesReceipt=try model.applyEditingPlan(plan(minuteDoc,"# 회의록 편집본\n\n- 실습 과목 두 개 운영\n- 학생 의견 수렴"),capture:model.editingSnapshot())
        check(minutes.preview.contains("회의록 편집본"),"minutes preview reflects edit")
        check(try String(contentsOf:minutesReceipt.url!,encoding:.utf8)==minutes.preview,"minutes draft persisted")
        model.syncMeetingMinutes(force:true);minutes.invalidateTranscriptAfterEdit()
        try await Task.sleep(nanoseconds:250_000_000)
        check(minutes.preview.contains("회의록 편집본"),"automatic baseline cannot overwrite draft")
        let reopened=MeetingWorkspace(directory:root.appendingPathComponent("Minutes"),defaults:defaults)
        reopened.begin(id:model.editingSessionID)
        check(reopened.preview==minutes.preview,"minutes edit survives reopen")
        check(minutes.metadata?.editedOutput==minutesReceipt.url?.path,"history points to edited minutes")
        try minutesReceipt.undo();check(!minutes.isShowingEditedDraft,"minutes undo returns generated view")
        check(originalMinutes.isEmpty,"pending minutes stay empty until content is generated")
        let materialCapture=model.editingSnapshot(), materialDoc=materialCapture.documents.first{$0.kind == .material && $0.text.contains("인공 지능")}!
        let materialReceipt=try model.applyEditingPlan(plan(materialDoc,"과목명은 인공지능 기초다."),capture:materialCapture)
        check(materials.context.documents.count==1,"edited material replaces active selection")
        check(materials.context.documents[0].chunks[1].text==original.chunks[1].text,"unrelated material chunk preserved")
        check(try String(contentsOf:source,encoding:.utf8)=="원본 기획 자료","material original preserved")
        check(materials.context.documents[0].chunks[0].text=="과목명은 인공지능 기초다.","material text updated")
        let loaded=MeetingMaterials(root:materialRoot)
        check(loaded.context.documents[0].id==materials.context.documents[0].id,"material edit survives reopen")
        try materialReceipt.undo();check(materials.context.documents[0].id==original.id,"material undo restores selection")

        // Text materials, multi-material transactions and compatibility use isolated synthetic data.
        let oldPlan=try JSONDecoder().decode(EditingPlan.self,from:Data(#"{"answer":"이전 대화","changes":[]}"#.utf8))
        check(oldPlan.newMaterials.isEmpty && oldPlan.changeCount==0,"old saved editing plans remain readable")
        let pasted="  \n회의 배경\n\n"+String(repeating:"자료 내용과 숫자 30을 보존합니다.\n",count:75)
        let textID=try materials.addText(title:"",text:pasted)
        let secondID=try materials.addText(title:"회의 배경",text:"예산은 3000만원, 일정은 11월입니다.")
        let textDocument=materials.context.documents.first{$0.id==textID}!
        check(textID != secondID && materials.context.documents.count==3,"multiple pasted materials coexist with file material and duplicate titles")
        check(textDocument.title=="회의 배경" && textDocument.chunks.count>1 && textDocument.chunks.map(\.text).joined()==pasted,"pasted text title and all chunk boundaries preserve content")
        check(try String(contentsOfFile:textDocument.originalPath,encoding:.utf8)==pasted,"pasted original preserves whitespace and line breaks")
        check(MeetingMaterials(root:materialRoot).context.documents.count==3,"all pasted materials survive reopen")
        check(minutes.materialContext.documents.count==3,"pasted material updates active meeting context")
        materials.select(secondID,enabled:false)
        check(materials.context.documents.count==2 && materials.context.documents.contains{$0.id==textID},"material selections are independent")
        materials.select(secondID,enabled:true)
        expectFailure("blank pasted text rejected") { _=try materials.addText(title:"빈 자료",text:" \n ") }
        expectFailure("oversized pasted text rejected") { _=try materials.addText(title:"긴 자료",text:String(repeating:"가",count:200_001)) }
        expectFailure("multiline material title rejected") { _=try materials.addText(title:"두\n줄",text:"본문") }
        let multiCapture=model.editingSnapshot()
        let targetA=multiCapture.documents.first{$0.sourceID==textID.uuidString}!
        let targetB=multiCapture.documents.first{$0.sourceID==secondID.uuidString}!
        let multiPlan=EditingPlan(answer:"자료 변경안",changes:[
            .init(targetID:targetA.id,before:targetA.text,after:targetA.text+"\n추가 배경입니다.",speaker:-1),
            .init(targetID:targetB.id,before:targetB.text,after:"예산은 3000만원, 일정은 12월입니다.",speaker:-1)
        ],additions:[.init(title:"후속 검토",text:"참고 자료를 다음 회의 전에 확인합니다.")])
        let multiReceipt=try model.applyEditingPlan(multiPlan,capture:multiCapture)
        check(materials.context.documents.count==4 && materials.context.documents.contains{$0.title=="후속 검토"},"chat applies multiple material updates and additions together")
        check(materials.context.documents.contains{$0.chunks.contains{$0.text.contains("12월")}},"chat updates requested material facts")
        check(materials.documents.first{$0.id==textID}?.currentVersion==false && materials.documents.first{$0.id==secondID}?.currentVersion==false,"edited originals become archived versions")
        check(materials.context.documents.contains(original) && materials.context.documents.first{$0.supersedesID==textID}?.chunks.dropFirst().map(\.text)==textDocument.chunks.dropFirst().map(\.text),"multi-material edits preserve unrelated materials and chunks")
        check(MeetingMaterials(root:materialRoot).context.documents.count==4,"chat additions and updates persist together")
        expectFailure("stale multi-material proposal applies no duplicate additions") { _=try model.applyEditingPlan(multiPlan,capture:multiCapture) }
        let unrelatedID=try materials.addText(title:"독립 자료",text:"뒤이어 추가한 내용을 보존합니다.")
        try multiReceipt.undo()
        check(materials.context.documents.contains{$0.id==textID} && materials.context.documents.contains{$0.id==secondID} && materials.context.documents.contains{$0.id==unrelatedID} && !materials.context.documents.contains{$0.title=="후속 검토"},"batch undo restores originals and retains unrelated later additions")
        let addCapture=model.editingSnapshot()
        let onlyAdd=EditingPlan(answer:"자료 추가안",changes:[],additions:[.init(title:"채팅 자료",text:"새로 추가할 배경입니다.")])
        let addReceipt=try model.applyEditingPlan(onlyAdd,capture:addCapture)
        check(onlyAdd.changeCount==1 && materials.context.documents.contains{$0.title=="채팅 자료"},"addition-only chat plan applies")
        try addReceipt.undo()
        check(!materials.context.documents.contains{$0.title=="채팅 자료"},"addition-only undo removes selected addition")
        let emptyCapture=EditingSnapshot(sessionID:UUID(),documents:[])
        try onlyAdd.validate(in:emptyCapture)
        check(true,"new materials can be proposed before any transcript exists")
        expectFailure("addition proposal from another session rejected") { try onlyAdd.validateCurrent(captured:emptyCapture,current:model.editingSnapshot()) }
        let transcriptTarget=model.editingSnapshot().documents.first{$0.kind == .transcript}!
        expectFailure("mixed transcript and material creation rejected") {
            try EditingPlan(answer:"",changes:plan(transcriptTarget,"수정 문장").changes,additions:onlyAdd.additions).validate(in:model.editingSnapshot())
        }
        let beforeFailed=materials.documents
        expectFailure("invalid addition rolls back whole batch") {
            _=try materials.applyMaterialChanges(replacements:[textID:[textDocument.chunks[0].id:"일괄 변경"]],additions:[.init(title:"유효",text:"본문"),.init(title:"빈 내용",text:" ")])
        }
        check(materials.documents==beforeFailed,"failed batch preserves the material library")
        let writeFailure=MeetingMaterials(root:root.appendingPathComponent("BlockedMaterials"))
        try Data("파일로 막힌 저장 위치".utf8).write(to:writeFailure.root)
        expectFailure("text storage failure is reported") { _=try writeFailure.addText(title:"저장 실패",text:"검증용 본문") }
        check(writeFailure.documents.isEmpty,"text storage failure leaves selection unchanged")

        // Exercise the main-screen observer across async generation, without an AI/network call.
        let generationRoot=root.appendingPathComponent("GenerationStatus")
        let controlled=SuspendedMinutesGenerator()
        let generating=MeetingWorkspace(directory:generationRoot.appendingPathComponent("Minutes"),generator:controlled,defaults:defaults)
        let main=AppModel(materials:MeetingMaterials(root:generationRoot.appendingPathComponent("Materials")),meeting:generating,
            assistant:MeetingAssistant(directory:generationRoot.appendingPathComponent("Assistant"),defaults:defaults),loadEngine:false,
            voice:VoiceIdentity(root:generationRoot.appendingPathComponent("Voice")),
            history:MeetingHistoryStore(transcripts:generationRoot.appendingPathComponent("Transcripts"),minutes:generationRoot.appendingPathComponent("Minutes")),
            transcriptDirectory:generationRoot.appendingPathComponent("Transcripts"),startBackgroundServices:false,preferences:defaults)
        main.loadEditingFixture(reprocessing:true)
        var mainChanges=0
        let observation=main.objectWillChange.sink { mainChanges += 1 }
        func waitForGenerator() async throws {
            for _ in 0..<200 {
                if await controlled.hasPending { return }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            fatalError("Timed out waiting for minutes generator")
        }
        func waitForSave() async throws {
            for _ in 0..<200 {
                if !generating.busy { return }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            fatalError("Timed out waiting for minutes save")
        }
        check(main.canRegenerateHistoryMinutes,"regeneration starts enabled")
        main.regenerateHistoryMinutes()
        check(!main.canRegenerateHistoryMinutes && generating.busy,"regeneration disables while running")
        check(main.displayStatusMessage.contains("생성 준비"),"main screen shows queue state immediately")
        let changesAtStart=mainChanges
        try await waitForGenerator()
        check(mainChanges>changesAtStart && main.displayStatusMessage.contains("1/1"),"async progress refreshes main screen")
        main.regenerateHistoryMinutes()
        check(await controlled.callCount==1,"duplicate regeneration is ignored")
        var facts=MeetingMinutesFacts()
        facts.summary=[EvidencedItem(text:"실습 과목 운영을 검토했습니다.",evidenceIDs:[1])]
        let changesBeforeSave=mainChanges
        await controlled.resolve(.success(facts))
        try await waitForSave()
        check(mainChanges>changesBeforeSave,"async completion refreshes main screen")
        check(main.canRegenerateHistoryMinutes && main.displayStatusMessage.hasPrefix("회의록 저장 · "),"saved state reenables regeneration")
        check(generating.metadata?.savedRevision==generating.metadata?.revision && generating.preview.contains("실습 과목 운영을 검토했습니다."),"saved preview matches completed revision")
        let savedURL=generating.lastURL!, savedData=try Data(contentsOf:savedURL)
        main.regenerateHistoryMinutes()
        try await waitForGenerator()
        let changesBeforeFailure=mainChanges
        await controlled.resolve(.failure(MinutesGenerationError.response))
        try await waitForSave()
        check(mainChanges>changesBeforeFailure && main.canRegenerateHistoryMinutes,"failure refreshes and reenables main screen")
        check(main.displayStatusMessage.hasPrefix("회의록 갱신 대기 · "),"main screen explains generation failure")
        check(try Data(contentsOf:savedURL)==savedData,"failed regeneration preserves saved minutes")
        main.regenerateHistoryMinutes()
        check(generating.error==nil && main.displayStatusMessage.contains("생성 준비"),"retry clears previous failure immediately")
        try await waitForGenerator()
        await controlled.resolve(.success(facts))
        try await waitForSave()
        check(main.canRegenerateHistoryMinutes && main.displayStatusMessage.hasPrefix("회의록 저장 · "),"retry returns to saved state")
        let previousSpeech=main.segments[0]
        main.segments[0]=TranscriptSegment(id:previousSpeech.id,speaker:previousSpeech.speaker,startTime:previousSpeech.startTime,
            endTime:previousSpeech.endTime,text:"편집한 실습 운영 계획입니다.")
        main.syncMeetingMinutes(force:true);generating.invalidateTranscriptAfterEdit()
        try await Task.sleep(nanoseconds:50_000_000)
        check(try Data(contentsOf:savedURL)==savedData && generating.hasOutdatedMinutes,"transcript edits preserve prior minutes and mark them outdated")
        main.regenerateHistoryMinutes()
        try await waitForGenerator()
        await controlled.resolve(.success(MeetingMinutesFacts()))
        try await waitForSave()
        let afterEmptyGeneration=try Data(contentsOf:savedURL)
        check(generating.error != nil && afterEmptyGeneration==savedData,"empty generation result cannot replace completed minutes")
        observation.cancel()

        let autoRoot=root.appendingPathComponent("AutoFinish")
        let autoGenerator=SuspendedMinutesGenerator()
        let auto=MeetingWorkspace(directory:autoRoot,generator:autoGenerator,defaults:defaults)
        auto.automatic=false;auto.generateOnFinish=true
        let autoID=UUID(), autoSpeech=[MeetingUtterance(id:1,speaker:1,start:0,end:8,text:"실습 과목 운영을 검토합니다.")]
        func receiveAuto(_ ended:Bool) {
            auto.receive(id:autoID,title:"종료 시 생성 검사",date:Date(),segments:autoSpeech,names:[:],ended:ended,settings:settings,force:true)
        }
        receiveAuto(false)
        auto.tick(at:Date().addingTimeInterval(300))
        check(!auto.busy && auto.lastURL==nil,"finish-only mode waits while recording")
        check(!FileManager.default.fileExists(atPath:autoRoot.appendingPathComponent(autoID.uuidString+".md").path),"recording creates no blank Markdown")
        receiveAuto(true)
        auto.tick(at:Date().addingTimeInterval(4))
        for _ in 0..<200 {
            if await autoGenerator.hasPending { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        check(await autoGenerator.callCount==1 && auto.busy,"finish-only mode automatically generates after recording")
        await autoGenerator.resolve(.success(facts))
        for _ in 0..<200 {
            if !auto.busy { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        check(auto.metadata?.savedRevision==auto.metadata?.revision && auto.lastURL != nil,"automatic finish saves completed content")
        let completed=MeetingHistoryReader.scan(transcripts:root.appendingPathComponent("Absent"),minutes:autoRoot)
        check(completed.items.first?.hasMinutes==true,"history recognizes completed minutes")

        let copyID=UUID()
        var copy=auto.metadata!;copy.id=copyID;copy.bindings=MeetingSpeakerBindings(sessionID:copyID)
        check(auto.openReprocessing(record:copy),"reprocessing opens with separate identity")
        auto.tick(at:Date().addingTimeInterval(300))
        check(!auto.busy && auto.lastURL==nil,"reprocessing waits for explicit generation even with finish mode enabled")
        let emptyID=UUID()
        auto.receive(id:emptyID,title:"빈 녹음",date:Date(),segments:[],names:[:],ended:true,settings:settings,force:true)
        auto.generateNow()
        check(!auto.busy && auto.lastURL==nil,"zero speech never generates an empty artifact")
        let restoredAuto=MeetingWorkspace(directory:autoRoot,defaults:defaults)
        check(!restoredAuto.automatic && restoredAuto.generateOnFinish,"recording and finish preferences persist separately")

        let legacyRoot=root.appendingPathComponent("PendingHistory")
        var pending=copy;pending.id=UUID();pending.bindings=MeetingSpeakerBindings(sessionID:pending.id);pending.savedRevision = -1
        let placeholderURL=legacyRoot.appendingPathComponent(pending.id.uuidString+".md")
        pending.output=placeholderURL.path
        let sessions=legacyRoot.appendingPathComponent("Sessions")
        try FileManager.default.createDirectory(at:sessions,withIntermediateDirectories:true)
        try JSONEncoder().encode(pending).write(to:sessions.appendingPathComponent(pending.id.uuidString+".json"))
        let placeholder=try MeetingMinutesRenderer.render(pending.snapshot(facts:MeetingMinutesFacts()),template:pending.template)
        try Data(placeholder.utf8).write(to:placeholderURL)
        let legacyList=MeetingHistoryReader.scan(transcripts:root.appendingPathComponent("Absent"),minutes:legacyRoot)
        check(legacyList.items.count==1 && !legacyList.items[0].hasMinutes,"history marks legacy blank document as pending")
        let legacySnapshot=try MeetingHistoryReader.load(legacyList.items[0])
        check(legacySnapshot.markdown.isEmpty && legacySnapshot.minutesURL==nil && legacySnapshot.segments.count==1,"legacy placeholder stays out of preview while transcript is available")
        check(try String(contentsOf:placeholderURL,encoding:.utf8)==placeholder,"legacy source file is preserved")
        let guardedStore=MeetingFileStore(directory:root.appendingPathComponent("RevisionGuard"))
        await guardedStore.requireRevision(pending.revision+1,for:pending.id)
        do { _=try await guardedStore.save(pending.snapshot(facts:facts),template:pending.template);fatalError("Obsolete generation accepted") }
        catch { check(true,"edit revision barrier rejects obsolete generation") }
        let trashRoot = root.appendingPathComponent("HistoryTrash")
        let trashMinutes = trashRoot.appendingPathComponent("Minutes")
        let trashTranscripts = trashRoot.appendingPathComponent("Transcripts")
        try FileManager.default.createDirectory(at: trashMinutes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashTranscripts, withIntermediateDirectories: true)
        let originalID = UUID(), trashCopyID = UUID()
        let sharedAudio = trashRoot.appendingPathComponent("shared.m4a")
        let sharedMaterial = trashRoot.appendingPathComponent("shared-reference.md")
        try Data("shared audio fixture".utf8).write(to: sharedAudio)
        try Data("공유 참고 자료".utf8).write(to: sharedMaterial)
        for id in [originalID, trashCopyID] {
            let json: [String:Any] = ["session_id":id.uuidString,"title":"같은 제목의 회의","started_at":"2026-10-22T01:52:25Z",
                "duration_seconds":8,"segments":[["id":1,"speaker":1,"start_time":0,"end_time":8,"text":"자료 검토"]],
                "audio_file":["path":sharedAudio.path]]
            try JSONSerialization.data(withJSONObject: json).write(to: trashTranscripts.appendingPathComponent(id.uuidString+".json"))
            try Data("# 회의록\n\n- 자료를 검토했다.".utf8).write(to: trashMinutes.appendingPathComponent(id.uuidString+".md"))
        }
        let standalone = trashMinutes.appendingPathComponent("직접 작성한 회의록.md")
        try Data("# 직접 작성한 회의록".utf8).write(to: standalone)
        let preservedFiles = [sharedAudio,sharedMaterial,standalone] + [originalID,trashCopyID].flatMap { id in
            [trashTranscripts.appendingPathComponent(id.uuidString+".json"),trashMinutes.appendingPathComponent(id.uuidString+".md")]
        }
        let preservedBytes = try preservedFiles.map { try Data(contentsOf: $0) }
        let trashHistory = MeetingHistoryStore(transcripts: trashTranscripts, minutes: trashMinutes)
        await trashHistory.refresh()
        check(trashHistory.items.count == 3 && trashHistory.deletedItems.isEmpty, "history starts with every saved meeting")
        let originalEntry = trashHistory.items.first { $0.id == originalID }!
        let copyEntry = trashHistory.items.first { $0.id == trashCopyID }!
        let standaloneEntry = trashHistory.items.first { $0.transcriptURL == nil }!
        try trashHistory.setDeleted(originalEntry, deleted: true)
        check(trashHistory.items.count == 2 && trashHistory.deletedItems.map(\.id) == [originalID], "delete moves only the selected identity to deleted meetings")
        check(trashHistory.items.contains { $0.id == trashCopyID }, "same-title reprocessing copy remains in the list")
        check(try preservedFiles.map { try Data(contentsOf: $0) } == preservedBytes, "delete preserves transcript, Markdown, shared audio and reference bytes")
        await trashHistory.refresh()
        check(trashHistory.items.count == 2 && trashHistory.deletedItems.count == 1, "refresh keeps the deleted meeting out of the active list")
        let reopenedHistory = MeetingHistoryStore(transcripts: trashTranscripts, minutes: trashMinutes)
        await reopenedHistory.refresh()
        check(reopenedHistory.items.count == 2 && reopenedHistory.deletedItems.first?.id == originalID, "deleted state survives store relaunch")
        let deletedSnapshot = try await reopenedHistory.load(reopenedHistory.deletedItems[0])
        check(deletedSnapshot.audioURL == sharedAudio && !deletedSnapshot.markdown.isEmpty, "deleted meeting remains available for read-only preview")
        try reopenedHistory.setDeleted(copyEntry, deleted: true)
        try trashHistory.setDeleted(standaloneEntry, deleted: true)
        await reopenedHistory.refresh()
        check(reopenedHistory.items.isEmpty && reopenedHistory.deletedItems.count == 3, "deletions preserve earlier index entries and support standalone Markdown")
        try reopenedHistory.setDeleted(originalEntry, deleted: false)
        check(reopenedHistory.items.map(\.id) == [originalID] && reopenedHistory.deletedItems.count == 2, "restore returns the selected meeting to its original list")
        let trashIndex = trashMinutes.appendingPathComponent(".history-trash.json")
        let goodIndex = try Data(contentsOf: trashIndex)
        let invalidIndex = Data("invalid index fixture".utf8)
        try invalidIndex.write(to: trashIndex)
        expectFailure("corrupt deletion index blocks overwrite") { try reopenedHistory.setDeleted(copyEntry, deleted: false) }
        check(try Data(contentsOf: trashIndex) == invalidIndex && reopenedHistory.deletedItems.count == 2, "failed change preserves deletion index and visible state")
        let damagedHistory = MeetingHistoryStore(transcripts: trashTranscripts, minutes: trashMinutes)
        await damagedHistory.refresh()
        check(damagedHistory.items.count == 3 && damagedHistory.error != nil, "unreadable deletion index keeps original history available with an error")
        try goodIndex.write(to: trashIndex)
        try reopenedHistory.setDeleted(copyEntry, deleted: false)
        try reopenedHistory.setDeleted(standaloneEntry, deleted: false)
        await reopenedHistory.refresh()
        check(reopenedHistory.items.count == 3 && reopenedHistory.deletedItems.isEmpty, "all meetings restore after relaunch and refresh")
        check(try preservedFiles.map { try Data(contentsOf: $0) } == preservedBytes, "restore preserves all original file bytes")
        let blockedParent = trashRoot.appendingPathComponent("regular-file")
        try Data("keep".utf8).write(to: blockedParent)
        let blockedTrash = MeetingHistoryTrash(url: blockedParent.appendingPathComponent("index.json"))
        expectFailure("unwritable deletion index reports failure") { _ = try blockedTrash.setDeleted(originalID, deleted: true) }
        let microphone = ControlledMicrophone()
        let captureModel = AppModel(materials: materials,
            meeting: MeetingWorkspace(directory: root.appendingPathComponent("CaptureMinutes"), defaults: defaults),
            assistant: MeetingAssistant(directory: root.appendingPathComponent("CaptureAssistant"), defaults: defaults), loadEngine: false,
            voice: VoiceIdentity(root: root.appendingPathComponent("CaptureVoice")),
            history: MeetingHistoryStore(transcripts: root.appendingPathComponent("CaptureTranscripts"), minutes: root.appendingPathComponent("CaptureMinutes")),
            transcriptDirectory: root.appendingPathComponent("CaptureTranscripts"), startBackgroundServices: false,
            preferences: defaults, microphone: microphone)
        captureModel.meeting.generateOnFinish = false
        try captureModel.loadRecordingFixture(directory: root.appendingPathComponent("CaptureAudio"))
        let captureBefore = captureModel.captureFixture
        let speechBefore = captureModel.segments
        captureModel.appendCaptureFixture()
        for _ in 0..<100 where captureModel.captureFixture.seconds < 1 { try await Task.sleep(for: .milliseconds(10)) }
        check(captureModel.canPause && microphone.starts == 1, "microphone capture is ready to pause")
        captureModel.pauseRecording(); captureModel.pauseRecording(); captureModel.resumeRecording()
        check(captureModel.phase == .paused && captureModel.pauseTransition && microphone.pendingStops.count == 1 && microphone.starts == 1,
              "pause drains once and blocks premature or duplicate resume")
        check(captureModel.canStop && captureModel.isBusy && !captureModel.canStart && !captureModel.canGenerateMinutes,
              "paused meeting allows stop and keeps new-session and generation guards")
        check(!captureModel.canDeleteHistory(captureBefore.id) && captureModel.canDeleteHistory(originalID),
              "live and paused capture is protected while previous meetings can be deleted")
        microphone.level?(0.9)
        try await Task.sleep(for: .milliseconds(20))
        check(captureModel.inputLevel == 0, "queued input meter events stay silent during pause")
        microphone.drain()
        check(captureModel.canPause && !captureModel.pauseTransition && captureModel.captureFixture.end == nil,
              "pause completes without marking the meeting ended")
        captureModel.syncMeetingMinutes(force: true)
        check(captureModel.meeting.metadata?.ended == false, "pause does not trigger end-of-meeting generation")
        let pausedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: captureModel.lastSavedURL!)) as! [String:Any]
        check(pausedJSON["status"] as? String == "in_progress" && pausedJSON["ended_at"] == nil,
              "paused transcript persists as an ongoing meeting")
        captureModel.resumeRecording(); captureModel.resumeRecording()
        check(captureModel.phase == .recording && microphone.starts == 2 && captureModel.captureFixture.id == captureBefore.id && captureModel.segments == speechBefore,
              "resume preserves session identity and transcript and starts only once")
        check(captureModel.captureFixture.path == captureBefore.path && captureModel.captureFixture.seconds == 1,
              "resume reuses the same audio file with no pause samples")
        captureModel.appendCaptureFixture()
        for _ in 0..<100 where captureModel.captureFixture.seconds < 2 { try await Task.sleep(for: .milliseconds(10)) }
        check(captureModel.captureFixture.seconds == 2, "resumed audio appends to the existing recording")
        captureModel.processingFile = true; captureModel.pauseRecording()
        check(captureModel.phase == .recording && !captureModel.canPause, "file transcription keeps its own stop flow")
        captureModel.processingFile = false
        captureModel.pauseRecording(); captureModel.stop()
        let capturedEnd = captureModel.captureFixture.end
        check(captureModel.phase == .finishing && capturedEnd != nil && microphone.pendingStops.count == 2,
              "stop during pause drain fixes the wall-clock meeting end")
        microphone.drain()
        for _ in 0..<100 where captureModel.phase == .finishing { try await Task.sleep(for: .milliseconds(10)) }
        // This fixture has no native ASR engine, so finalization takes the preserved-data error path.
        check(captureModel.phase == .failed && captureModel.captureFixture.end == capturedEnd && captureModel.savedAudioURL != nil,
              "finalization failure preserves audio and the original stop time")
        let stoppedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: captureModel.lastSavedURL!)) as! [String:Any]
        check(stoppedJSON["ended_at"] as? String != nil, "wall-clock end persists independently of audio duration")
        let captureHistory = MeetingHistoryReader.scan(transcripts: root.appendingPathComponent("CaptureTranscripts"), minutes: root.appendingPathComponent("CaptureMinutes"))
        let restoredCapture = try MeetingHistoryReader.load(captureHistory.items[0])
        check(restoredCapture.endedAt != nil && abs(restoredCapture.endedAt!.timeIntervalSince(capturedEnd!)) < 1,
              "history restores actual end time including pause elapsed time")
        captureModel.phase = .paused; microphone.failStart = true
        captureModel.resumeRecording()
        check(captureModel.phase == .finishing && captureModel.errorMessage != nil, "resume device failure follows the save-and-finish path")
        microphone.drain()
        for _ in 0..<100 where captureModel.phase == .finishing { try await Task.sleep(for: .milliseconds(10)) }
        captureModel.phase = .paused
        var quitFinished = false
        captureModel.prepareToQuit { quitFinished = true }
        check(captureModel.phase == .finishing && !captureModel.canPause, "quit from pause finishes the same capture")
        microphone.drain()
        for _ in 0..<200 where !quitFinished { try await Task.sleep(for: .milliseconds(10)) }
        check(quitFinished, "quit from pause drains and releases engine resources")
        print("RESULT: \(passed) checks passed")
        if CommandLine.arguments.contains("--live-materials") {
            var liveSettings=CodexCorrectionSettings();liveSettings.selectProvider(.codex)
            print("LIVE MATERIALS START: synthetic references only");fflush(stdout)
            let liveCapture=model.editingSnapshot()
            let addition=try await EditingChatGenerator.generate("다음 두 내용을 별도의 회의자료로 추가해 줘. 첫 자료 제목은 검증용 일정, 본문은 '워크숍은 11월 5일 진행 예정입니다.' 둘째 제목은 검증용 예산, 본문은 '검토 중인 예산은 100만원입니다.'",snapshot:liveCapture,history:[],settings:liveSettings)
            check(addition.newMaterials.count==2 && addition.changes.isEmpty,"live Codex proposes two new materials")
            let added=try model.applyEditingPlan(addition,capture:liveCapture)
            let updateCapture=model.editingSnapshot()
            let update=try await EditingChatGenerator.generate("회의자료 두 개를 함께 업데이트해 줘. '검증용 일정'의 11월 5일을 11월 12일로, '검증용 예산'의 100만원을 120만원으로 바꿔 줘. 예정과 검토 중이라는 표현은 유지해 줘.",snapshot:updateCapture,history:[],settings:liveSettings)
            check(update.changes.count==2 && update.newMaterials.isEmpty,"live Codex targets two existing materials")
            let updated=try model.applyEditingPlan(update,capture:updateCapture)
            check(materials.context.documents.contains{$0.title.hasPrefix("검증용 일정") && $0.chunks.contains{$0.text.contains("11월 12일")}} && materials.context.documents.contains{$0.title.hasPrefix("검증용 예산") && $0.chunks.contains{$0.text.contains("120만원")}},"live Codex material updates applied")
            try updated.undo();try added.undo()
            print("LIVE MATERIALS RESULT: 3 checks passed");fflush(stdout)
        }
        if CommandLine.arguments.contains("--live-all") {
            var failures=0
            for provider in AITextProvider.allCases {
                var liveSettings=CodexCorrectionSettings();liveSettings.selectProvider(provider)
                do {
                    print("LIVE START: "+provider.title);fflush(stdout)
                    print(try await AITextRunner.connectionTest(liveSettings))
                    let result=try await EditingChatGenerator.generate("‘실습 예산은 삼천만원으로 검토하겠습니다.’라는 발언의 화자만 김교수로 바꿔 줘.",snapshot:model.editingSnapshot(),history:[],settings:liveSettings)
                    check(result.changes.count==1 && result.changes[0].targetID=="utterance.2" && result.changes[0].speaker==2 && result.changes[0].before==result.changes[0].after,"live "+provider.title+" natural-language speaker edit")
                } catch { failures += 1;print("LIVE FAIL: "+provider.title+" · "+error.localizedDescription) }
                fflush(stdout)
            }
            print("LIVE FAILURES: \(failures)")
            if failures>0 { exit(2) }
        }
        if CommandLine.arguments.contains("--live-codex") {
            let liveCapture=model.editingSnapshot()
            let result=try await EditingChatGenerator.generate("‘실습 예산은 삼천만원으로 검토하겠습니다.’라는 발언의 화자만 김교수로 바꿔 줘.",snapshot:liveCapture,history:[],settings:settings)
            check(result.changes.count==1 && result.changes[0].targetID=="utterance.2" && result.changes[0].speaker==2 && result.changes[0].before==result.changes[0].after,"live Codex natural-language speaker edit")
            print("LIVE RESULT: \(passed) checks passed")
        }
    }
    @MainActor static func showPreview(_ model:AppModel) {
        let app=NSApplication.shared
        app.setActivationPolicy(.regular)
        let window=NSWindow(contentRect:NSRect(x:100,y:100,width:1440,height:850),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="테이블로그 편집 UI 미리보기 · 예시 데이터"
        window.contentView=NSHostingView(rootView:ContentView(model:model))
        window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
        app.run()
    }
}

private actor SuspendedMinutesGenerator: MinutesGenerating {
    private var pending: CheckedContinuation<MeetingMinutesFacts,Error>?
    private(set) var callCount=0
    var hasPending: Bool { pending != nil }
    func generate(_ input:MinutesGenerationInput,provider:MinutesProvider,settings:CodexCorrectionSettings,
                  progress:@escaping @Sendable (Int,Int) async -> Void) async throws -> MeetingMinutesFacts {
        callCount += 1
        await progress(1,1)
        return try await withCheckedThrowingContinuation { pending=$0 }
    }
    func resolve(_ result:Result<MeetingMinutesFacts,Error>) {
        let continuation=pending;pending=nil
        continuation?.resume(with:result)
    }
}
