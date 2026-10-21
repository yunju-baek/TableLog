import SwiftUI

struct ContextEditorView: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void
    @State private var settings: CodexCorrectionSettings
    @State private var topic: String
    @State private var terms: String
    @State private var options = CodexModelOption.cached()
    @State private var connectionMessage = "CLI를 선택한 뒤 설치 확인과 연결 테스트를 진행하세요."
    @State private var checking = false
    @State private var checkID = UUID()
    @State private var checkTask: Task<Void,Never>?
    init(model: AppModel, dismiss: @escaping () -> Void) {
        self.model=model;self.dismiss=dismiss
        _settings=State(initialValue:model.codexSettings)
        _topic=State(initialValue:model.contextSettings.topic);_terms=State(initialValue:model.contextSettings.terms)
    }
    private var efforts: [String] {
        settings.provider == .claude ? ["low","medium","high","xhigh","max"] :
            options.first{$0.id==settings.model}?.efforts ?? ["low","medium","high","xhigh"]
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("AI CLI · 교정 설정").font(.title3.bold())
                Spacer()
                Button(action:AppHelp.openCLISetup) { Image(systemName:"questionmark.circle") }
                    .help("AI CLI 연결 안내").accessibilityLabel("AI CLI 연결 안내")
            }
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    Picker("AI CLI",selection:Binding(get:{settings.provider},set:{value in
                        checkTask?.cancel();checkID=UUID();checking=false;settings.selectProvider(value)
                        connectionMessage="설치 확인 또는 연결 테스트를 실행하세요."
                    })) {
                        ForEach(AITextProvider.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityLabel("사용할 AI CLI")
                    Text("편집 채팅·문맥 교정·회의 요약·회의록·자료 분석·화자 검토에 적용합니다. 요청에 필요한 발언과 자료를 \(settings.provider.destination)로 전달하며, 해당 CLI 계정의 사용 조건과 한도가 적용됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("실행 파일 경로 · 비우면 자동 탐색",text:$settings.executablePath)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("AI CLI 실행 파일 경로")
                    HStack {
                        Button("설치 확인") { check(connection:false) }.disabled(checking)
                        Button("연결 테스트") { check(connection:true) }.disabled(checking)
                        if checking { ProgressView().controlSize(.small);Button("중단") { checkTask?.cancel() } }
                    }
                    Text(connectionMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Text("터미널 로그인: \(settings.provider.loginCommand)").font(.caption2).textSelection(.enabled)
                        Spacer()
                        if settings.provider == .codex {
                            Button(model.codexLoginRunning ? "로그인 대기 중" : "ChatGPT 로그인") { model.loginCodex(settings:settings) }
                                .disabled(model.codexLoginRunning)
                        }
                    }
                    if model.codexLoginRunning { Text(model.codexAuthStatus).font(.caption);Button("로그인 취소",action:model.cancelCodexLogin) }
                    if settings.provider == .codex {
                        Picker("모델",selection:$settings.model) {
                            Text("CLI 기본 모델").tag("")
                            ForEach(options) { Text($0.name).tag($0.id) }
                            if !settings.model.isEmpty && !options.contains(where:{$0.id==settings.model}) { Text(settings.model).tag(settings.model) }
                        }
                    }
                    TextField("모델 ID · 비우면 CLI 기본값",text:$settings.model).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("AI 모델 ID")
                    if settings.provider != .gemini {
                        Picker("추론 강도",selection:$settings.effort) {
                            Text("모델 기본값").tag("")
                            ForEach(efforts,id:\.self) { Text($0).tag($0) }
                        }
                    }
                    Divider()
                    Picker("실시간 문맥 교정",selection:$settings.mode) {
                        Text("끔").tag(CorrectionMode.off);Text("선택한 AI로 교정").tag(CorrectionMode.codex)
                    }.pickerStyle(.segmented)
                    if settings.mode == .codex {
                        Picker("교정할 발언 묶음",selection:$settings.batchSeconds) {
                            Text("15초").tag(15);Text("20초").tag(20);Text("30초").tag(30)
                        }.pickerStyle(.segmented)
                        if model.correctionNeedsRetry { Button("교정 재시도",action:model.retryCodexCorrection) }
                    }
                    TextField("회의 주제",text:$topic,axis:.vertical).textFieldStyle(.roundedBorder).lineLimit(2...3)
                    Text("이름·전문용어 · 줄바꿈·쉼표로 구분").font(.caption)
                    TextEditor(text:$terms).font(.callout).frame(height:65).border(.gray.opacity(0.25))
                        .accessibilityLabel("교정에 참고할 이름과 용어")
                    Text("용어는 최대 64개, 각 80자입니다. 숫자·날짜·의미 변화는 확인 대상으로 표시합니다.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(.trailing,6)
            }
            Divider()
            HStack {
                Text("AI 선택은 적용 후 새 요청부터 반영됩니다.").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("취소",action:dismiss).keyboardShortcut(.cancelAction)
                Button("적용") { model.updateCorrectionSettings(settings,topic:topic,terms:terms);dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width:530,height:690).environment(\.colorScheme,.light)
            .onDisappear { checkTask?.cancel() }
    }
    private func check(connection:Bool) {
        guard !checking else { return }
        let captured=settings,identifier=UUID();checkID=identifier;checking=true;connectionMessage=connection ? "예시 요청으로 연결 확인 중…" : "실행 파일 확인 중…"
        checkTask=Task {
            defer { if checkID==identifier { checking=false } }
            do {
                let text=try await (connection ? AITextRunner.connectionTest(captured) : AITextRunner.installationStatus(captured))
                try Task.checkCancellation();guard checkID==identifier else { return };connectionMessage=text
            } catch { guard checkID==identifier else { return };connectionMessage=error is CancellationError ? "연결 확인을 중단했습니다." : error.localizedDescription }
        }
    }
}
