import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MeetingWorkspaceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workspace: MeetingWorkspace
    let dismiss: () -> Void
    @State private var editor: MeetingTemplate?
    @State private var contactPicker = false
    @State private var contactSpeaker: Int?
    var initialTab = 0
    @State private var tab = 0
    @State private var manualName = ""
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Label(model.meetingPrepared ? "새 회의 준비" : "회의자료 · 회의록",systemImage:"doc.text").font(.title2.bold())
                Spacer()
                Button("닫기",action:dismiss).keyboardShortcut(.cancelAction)
            }
            Picker("화면",selection:$tab) {
                Text("회의 설정·참석자").tag(0)
                Text("회의자료·맥락").tag(2)
                Text("회의록 미리보기").tag(1)
            }.pickerStyle(.segmented)
            if tab==0 { settings } else if tab==2 { MeetingMaterialsView(materials:model.materials,model:model) } else {
                if workspace.isShowingEditedDraft {
                    Label("채팅 편집본 · 자동 생성본은 저장 폴더에서 확인할 수 있습니다.", systemImage: "pencil.line")
                        .font(.caption).foregroundStyle(AppTheme.violet)
                }
                MinutesTextView(documentID:workspace.sessionID ?? workspace.bindings.sessionID,
                    text:workspace.preview.isEmpty ? "인식된 전사문으로 회의록을 생성하면 여기에 표시됩니다." : workspace.preview)
                    .clipShape(RoundedRectangle(cornerRadius:10))
            }
            Divider()
            HStack {
                if workspace.busy { ProgressView().controlSize(.small) }
                Text(workspace.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.meetingPrepared { Button("준비 완료 · 녹음 시작") { dismiss();model.start() }.disabled(!model.canStart) }
                Button("저장 폴더",action:workspace.showFolder)
                Button("MD 열기",action:workspace.openFile).disabled(workspace.lastURL==nil)
                Button("지금 생성·저장") { model.syncMeetingMinutes(force:true);workspace.generateNow() }
                    .buttonStyle(.borderedProminent).disabled(!workspace.canGenerate || workspace.busy)
            }
            if let error=workspace.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(22).frame(width:900,height:720)
            .background(AppTheme.paper).tint(AppTheme.violet)
            .onAppear { tab=initialTab }
            .onDisappear { model.syncMeetingMinutes(force:true) }
            .sheet(item:$editor) { template in
                MeetingTemplateEditor(template:template,onSave:{ workspace.saveTemplate($0) },onClose:{ editor=nil })
            }
            .sheet(isPresented:$contactPicker) {
                MeetingContactsPicker(title:contactSpeaker.map { "화자 \($0)에 연락처 연결" } ?? "이번 회의 참석자 추가",onSelect:{ person in
                    if let speaker=contactSpeaker { model.bindMeetingContact(person,speaker:speaker) }
                    else { workspace.attend(person) }
                },onClose:{contactPicker=false})
            }
    }
    private var settings: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:17) {
                GroupBox("회의 템플릿") {
                    VStack(alignment:.leading,spacing:10) {
                        HStack {
                            Picker("템플릿",selection:$workspace.selectedID) {
                                ForEach(workspace.templates) { Text($0.name).tag($0.id) }
                            }
                            Button("편집") { editor=workspace.selectedTemplate }
                            Button("새로 만들기") {
                                var value=MeetingWorkspace.defaultTemplate;value.id=UUID();value.name="새 회의 템플릿";editor=value
                            }
                        }
                        HStack {
                            Button("기존 회의자료로 만들기",action:importTemplate)
                            Button("이번 회의를 템플릿으로 저장") {
                                var value=workspace.selectedTemplate;value.id=UUID();value.name=model.sessionTitle + " 템플릿"
                                value.participantCandidates=workspace.metadata?.snapshot(facts:MeetingMinutesFacts()).confirmedParticipants ?? workspace.bindings.confirmedParticipants
                                if !workspace.purpose.isEmpty && !value.similarTopics.contains(workspace.purpose) { value.similarTopics.append(workspace.purpose) }
                                editor=value
                            }
                        }
                        if !workspace.selectedTemplate.similarTopics.isEmpty {
                            Text("관련 주제: " + workspace.selectedTemplate.similarTopics.joined(separator:", ")).font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("회의 이름",text:$model.sessionTitle).textFieldStyle(.roundedBorder)
                        TextField("이번 회의 목적",text:$workspace.purpose).textFieldStyle(.roundedBorder)
                    }.padding(7)
                }
                GroupBox("참석자 · 화자 연결") {
                    VStack(alignment:.leading,spacing:9) {
                        if !workspace.selectedTemplate.participantCandidates.isEmpty {
                            Text("템플릿 참석자 후보 · 이번 참석 여부를 확인하세요.").font(.caption).foregroundStyle(.secondary)
                            ForEach(workspace.selectedTemplate.participantCandidates) { person in
                                HStack {
                                    personLabel(person)
                                    Spacer()
                                    Button(workspace.bindings.confirmedParticipants.contains(where:{$0.id==person.id}) ? "참석 확인됨" : "이번 회의 참석 확인") { workspace.attend(person) }
                                        .disabled(workspace.bindings.confirmedParticipants.contains(where:{$0.id==person.id}))
                                }
                            }
                            Divider()
                        }
                        HStack {
                            Button("Mac 연락처에서 참석자 추가") { contactSpeaker=nil;contactPicker=true }
                            TextField("이름 직접 입력",text:$manualName).textFieldStyle(.roundedBorder)
                            Button("추가") {
                                let name=String(manualName.trimmingCharacters(in:.whitespacesAndNewlines).prefix(64))
                                if !name.isEmpty { workspace.attend(MeetingPerson(id:UUID().uuidString,name:name));manualName="" }
                            }.disabled(manualName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        }
                        ForEach(workspace.bindings.confirmedParticipants) { person in
                            HStack {
                                personLabel(person)
                                Spacer()
                                if !model.speakerIDs.isEmpty {
                                    Menu("화자에 연결") {
                                        ForEach(model.speakerIDs,id:\.self) { speaker in
                                            Button("화자 \(speaker) · \(model.speakerName(for:speaker))") { model.bindMeetingContact(person,speaker:speaker) }
                                        }
                                    }
                                }
                                Button("참석 제외") { model.removeMeetingPerson(person.id) }
                            }
                        }
                        ForEach(model.speakerIDs,id:\.self) { speaker in
                            HStack {
                                Text("화자 \(speaker) → \(model.speakerName(for:speaker))").font(.callout)
                                Spacer()
                                Button("연락처 연결") { contactSpeaker=speaker;contactPicker=true }
                            }
                        }
                        Text("음성의 화자 번호를 확인한 뒤 이름을 연결하세요. 연락처 연결은 현재 회의에 적용됩니다.").font(.caption).foregroundStyle(.secondary)
                    }.padding(7)
                }
                GroupBox("회의록 자동 저장") {
                    VStack(alignment:.leading,spacing:10) {
                        HStack {
                            Toggle("주기적으로 갱신하고 종료 시 저장",isOn:$workspace.automatic)
                            Picker("간격",selection:$workspace.interval) { Text("60초").tag(60);Text("90초").tag(90);Text("3분").tag(180) }.frame(width:145)
                        }
                        HStack {
                            Label("작성 모델 · \(model.codexSettings.provider.title)",systemImage:"sparkles").font(.callout)
                            Text("\(model.codexSettings.model.isEmpty ? "기본 모델" : model.codexSettings.model) · \(model.codexSettings.effort.isEmpty ? "기본 추론" : model.codexSettings.effort)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if workspace.provider != .codex {
                                Button("AI CLI 사용") { workspace.provider = .codex }
                            }
                        }
                        if workspace.provider != .codex {
                            Text("이 회의의 회의록 작성과 자료 분석에 사용할 AI CLI를 선택해 주세요. ‘AI CLI 사용’을 누르면 설정이 적용됩니다.").font(.caption).foregroundStyle(AppTheme.violet)
                        }
                        Text("같은 회의의 Markdown 파일을 계속 갱신합니다. 선택한 AI CLI에 전사문·이름·주제와 회의자료의 추출문을 전달해 회의록을 작성합니다. CLI와 모델은 ‘AI 설정’에서 변경할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                    }.padding(7)
                }
            }.padding(.trailing,5)
        }
    }
    private func personLabel(_ person:MeetingPerson) -> some View {
        Text(person.organization.isEmpty ? person.name : "\(person.name) · \(person.organization)").font(.callout)
    }
    private func importTemplate() {
        let panel=NSOpenPanel();panel.allowsMultipleSelection=false
        panel.allowedContentTypes=[.plainText,UTType(filenameExtension:"md") ?? .plainText]
        panel.message="기존 Markdown 또는 텍스트 회의자료를 선택하세요. 형식과 주제를 새 템플릿으로 검토할 수 있습니다."
        panel.begin { response in
            guard response == .OK,let url=panel.url else { return }
            do {
                let data=try Data(contentsOf:url)
                guard data.count<=2_000_000,let source=String(data:data,encoding:.utf8) else { throw MinutesGenerationError.response }
                var template=MeetingTemplate.fromMeetingMarkdown(source,name:url.deletingPathExtension().lastPathComponent+" 템플릿",similarTopics:[],participantCandidates:[])
                let headings=source.components(separatedBy:.newlines).filter {$0.hasPrefix("## ")}.map {String($0.dropFirst(3))}
                template.similarTopics=Array(headings.prefix(20))
                editor=template
            } catch { workspace.report("회의자료를 UTF-8 Markdown·텍스트로 저장한 뒤 다시 선택하세요. " + error.localizedDescription) }
        }
    }
}

private struct MeetingTemplateEditor:View {
    @State var template:MeetingTemplate
    let onSave:(MeetingTemplate)->Void
    let onClose:()->Void
    @State private var topics=""
    @State private var contacts=false
    @State private var name=""
    @State private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("회의 템플릿 편집").font(.title2.bold())
            TextField("템플릿 이름",text:$template.name).textFieldStyle(.roundedBorder)
            TextField("관련·반복 주제 (쉼표로 구분)",text:$topics).textFieldStyle(.roundedBorder)
            HStack {
                Text("참석자 후보").font(.headline)
                Spacer()
                TextField("이름 입력",text:$name).textFieldStyle(.roundedBorder).frame(width:160)
                Button("추가") {
                    let value=name.trimmingCharacters(in:.whitespacesAndNewlines)
                    if !value.isEmpty { template.participantCandidates.append(MeetingPerson(id:UUID().uuidString,name:String(value.prefix(64))));name="" }
                }
                Button("연락처에서 추가") { contacts=true }
            }
            ScrollView(.horizontal) {
                HStack {
                    ForEach(template.participantCandidates) { person in
                        HStack {
                            Text(person.name)
                            Button { template.participantCandidates.removeAll {$0.id==person.id} } label:{Image(systemName:"xmark.circle")}.buttonStyle(.plain)
                        }.padding(7).background(.quaternary,in:Capsule())
                    }
                }
            }.frame(height:40)
            Text("Markdown 형식").font(.headline)
            TextEditor(text:$template.markdown).font(.system(size:12,design:.monospaced)).border(.quaternary)
            Text("변수: {{datetime}}, {{participants}}, {{purpose}}, {{summary}}, {{decisions}}, {{actions}}, {{discussion}}, {{open_issues}}, {{transcript}}")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("참석자와 주제는 다음 회의의 후보로 저장됩니다. 이번 회의의 내용은 전사문을 근거로 작성합니다.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("기본 형식 적용") { template.markdown=MeetingWorkspace.defaultTemplate.markdown }
                Spacer()
                Button("취소",action:onClose).keyboardShortcut(.cancelAction)
                Button("템플릿 저장") {
                    template.name=String(template.name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(120))
                    template.similarTopics=topics.components(separatedBy:CharacterSet(charactersIn:",\n")).map {$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter {!$0.isEmpty}
                    guard !template.name.isEmpty,template.markdown.contains("{{transcript}}") else { error="템플릿 이름과 {{transcript}} 변수를 입력하세요.";return }
                    do {
                        _ = try MeetingMinutesRenderer.render(MeetingMinutesSnapshot(sessionID:UUID(),revision:0,date:"",purpose:"",confirmedParticipants:[],speakerBindings:[:],utterances:[],facts:MeetingMinutesFacts()),template:template)
                        onSave(template);onClose()
                    } catch { self.error="사용 가능한 변수 이름을 확인하세요." }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(22).frame(width:760,height:650)
            .onAppear { topics=template.similarTopics.joined(separator:", ") }
            .sheet(isPresented:$contacts) {
                MeetingContactsPicker(title:"템플릿 참석자 후보 추가",onSelect:{ person in
                    if !template.participantCandidates.contains(where:{$0.id==person.id}) { template.participantCandidates.append(person) }
                },onClose:{contacts=false})
            }
    }
}

struct MeetingSidebarButton:View {
    @ObservedObject var workspace:MeetingWorkspace
    let action:()->Void
    var body:some View {
        Button(action:action) {
            VStack(alignment:.leading,spacing:5) {
                Label("회의 준비 · 자료 · 회의록",systemImage:"doc.text").font(.system(size:13,weight:.semibold))
                Text(workspace.busy ? "회의록 생성 중…" : (workspace.error == nil ? "연락처·참석자 · Markdown 자동 저장" : "저장 상태 확인 필요"))
                    .font(.system(size:10)).opacity(0.65).lineLimit(2)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(12)
                .background(.white.opacity(0.58),in:RoundedRectangle(cornerRadius:10))
        }.buttonStyle(.plain)
    }
}
