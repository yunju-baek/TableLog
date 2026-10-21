import SwiftUI
import AppKit
import AVFoundation

/// The panel reads app-owned meeting state. Opening a detail always uses the
/// captured evidence snapshot, so a later transcript edit remains inspectable.
struct MeetingAssistantView: View {
    @ObservedObject var assistant: MeetingAssistant
    @ObservedObject var chat: MeetingEditingChat
    var provider: AITextProvider = .codex
    @State private var question = ""
    @State private var showSummary = false
    @State private var sheet: AssistantPanelSheet?
    @State private var showEarlierQuestions = false
    @State private var showArchivedSuggestions = false

    private var visibleSuggestions: [AssistantSuggestion] {
        let latest = assistant.state.suggestions
            .filter { $0.status == .active || $0.status == .review }
            .sorted { $0.createdAt > $1.createdAt }.prefix(3)
        // A refreshed card keeps its position; a new issue replaces the oldest.
        return latest.sorted { $0.createdAt < $1.createdAt }
    }
    private var archivedSuggestions: [AssistantSuggestion] {
        let visibleIDs = Set(visibleSuggestions.map(\.id))
        return assistant.state.suggestions.filter { !visibleIDs.contains($0.id) }
    }
    private var hasMeeting: Bool { assistant.state.sessionID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AppTheme.violet.opacity(0.12))
            ScrollViewReader { proxy in
              ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DisclosureGroup("회의 요약·제안", isExpanded: $showSummary) {
                        VStack(alignment: .leading, spacing: 16) {
                            status; agendaAndSummary; decisionsAndQuestions; suggestions
                        }.padding(.top, 8)
                    }.font(.caption)
                    EditingConversationView(chat: chat)
                    Color.clear.frame(height: 1).id("editing-end")
                }.padding(16)
              }
              .onChange(of: chat.entries.count) { _, _ in withAnimation { proxy.scrollTo("editing-end", anchor: .bottom) } }
              .onChange(of: chat.busy) { _, busy in if !busy { withAnimation { proxy.scrollTo("editing-end", anchor: .bottom) } } }
            }
            Divider()
            questionComposer
        }
        .frame(minWidth: 340, idealWidth: 370, maxWidth: 430, maxHeight: .infinity)
        .background(AppTheme.paper)
        .foregroundStyle(AppTheme.ink)
        .tint(AppTheme.violet)
        .environment(\.colorScheme, .light)
        .sheet(item: $sheet) { selected in
            switch selected {
            case .settings:
                AssistantSettingsView(assistant: assistant, provider: provider) { sheet = nil }
            case .evidence(let title, let items):
                AssistantEvidenceView(title: title, evidence: items, open: assistant.openEvidence) { sheet = nil }
            case .history:
                AssistantHistoryView(assistant: assistant) { sheet = nil }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(AppTheme.rose)
                Text("회의 편집").font(.system(size: 16, weight: .bold))
                Spacer(minLength: 4)
                Button { sheet = .history } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help("요약 변경·분석 기록").accessibilityLabel("회의 도우미 분석 기록")
                Button { sheet = .settings } label: { Image(systemName: "slider.horizontal.3") }
                    .help("주기·모델 설정").accessibilityLabel("회의 도우미 설정")
            }.buttonStyle(.plain)
            HStack {
                Toggle("자동 요약·제안", isOn: $assistant.enabled)
                    .toggleStyle(.switch).controlSize(.small).font(.caption)
                Spacer(minLength: 8)
                Button("지금 요약", action: assistant.requestSummary)
                    .controlSize(.small).disabled(!hasMeeting)
            }
        }.padding(16).background(AppTheme.sidebar.opacity(0.58))
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                if assistant.busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "circle.fill").font(.system(size: 6)).padding(.top, 4).foregroundStyle(AppTheme.rose) }
                Text(assistant.status).font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if assistant.busy { Button("취소", action: assistant.cancel).font(.caption) }
            }
            if assistant.state.updatedAt != nil && !assistant.status.contains("발언까지 반영") {
                Text("\(assistantTime(assistant.state.coverageSeconds)) 발언까지 반영")
                    .font(.caption.monospacedDigit()).foregroundStyle(AppTheme.violet)
            }
            Text("선택 자료 \(assistant.selectedMaterialCount)개 · 맥락 분석 완료 \(assistant.readyMaterialCount)개")
                .font(.caption2).foregroundStyle(AppTheme.muted)
            if let error = assistant.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.caption).textSelection(.enabled)
                    Button("분석 재시도", action: assistant.retry).controlSize(.small)
                        .disabled(assistant.busy || !hasMeeting)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.blush, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var agendaAndSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("현재 안건", symbol: "text.bubble")
                Text(assistant.state.currentAgenda.isEmpty ? "회의 맥락을 기다리고 있어요" : assistant.state.currentAgenda)
                    .font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if assistant.state.summary.isEmpty {
                Text(hasMeeting ? "발언과 자료를 모아 핵심 내용을 정리합니다. ‘지금 요약’으로 바로 분석할 수 있어요." : "새 회의를 준비한 뒤 자료를 추가하고 녹음을 시작하세요.")
                    .font(.caption).foregroundStyle(AppTheme.muted).lineSpacing(3)
            } else {
                ForEach(assistant.state.summary) { item in
                    itemRow(item, confirmable: false)
                }
            }
        }.assistantCard()
    }

    @ViewBuilder private var decisionsAndQuestions: some View {
        if !assistant.state.decisionCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("결정 후보·확인", symbol: "checkmark.seal")
                Text("근거 발언을 확인한 뒤 결정으로 표시하세요.")
                    .font(.caption2).foregroundStyle(AppTheme.muted)
                ForEach(assistant.state.decisionCandidates) { item in itemRow(item, confirmable: true) }
            }.assistantCard()
        }
        if !assistant.state.openQuestions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("남은 질문", symbol: "questionmark.bubble")
                ForEach(assistant.state.openQuestions) { item in itemRow(item, confirmable: false) }
            }.assistantCard()
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("지금 함께 생각할 점", symbol: "lightbulb")
            if visibleSuggestions.isEmpty {
                Text("현재 논의에 필요한 질문·관련 자료·대안을 이곳에 제안합니다.")
                    .font(.caption).foregroundStyle(AppTheme.muted).lineSpacing(3)
            }
            ForEach(visibleSuggestions) { suggestion in suggestionCard(suggestion) }
            if !archivedSuggestions.isEmpty {
                DisclosureGroup("다른 제안·보관 \(archivedSuggestions.count)개", isExpanded: $showArchivedSuggestions) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(archivedSuggestions.reversed()) { suggestion in
                            if suggestion.status == .active || suggestion.status == .review {
                                suggestionCard(suggestion)
                            } else {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(suggestionStatus(suggestion.status)).font(.caption2).foregroundStyle(AppTheme.rose)
                                    Spacer()
                                    Button("다시 검토") { assistant.setSuggestionStatus(id: suggestion.id, status: .review) }
                                        .font(.caption2)
                                }
                                Button { sheet = .evidence(suggestion.title, suggestion.evidence) } label: {
                                    Text(suggestion.title).font(.caption).multilineTextAlignment(.leading)
                                }.buttonStyle(.plain)
                            }.padding(9).background(.white, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }.padding(.top, 8)
                }.font(.caption).foregroundStyle(AppTheme.muted)
            }
        }
    }

    private var questionComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("내용을 고치거나 질문해 보세요", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...6)
                .font(.callout).accessibilityLabel("회의 편집 요청")
            HStack(alignment: .center) {
                Text("녹취 · 화자 · 회의록 · 자료").font(.system(size: 10)).foregroundStyle(AppTheme.muted)
                Spacer(minLength: 6)
                if chat.busy {
                    Button { chat.cancel() } label: { Image(systemName: "stop.fill") }
                        .help("요청 중단").accessibilityLabel("편집 요청 중단")
                } else {
                    Button(action: sendQuestion) { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("요청 보내기 · ⌘↩").accessibilityLabel("편집 요청 보내기")
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.count > 12_000)
                }
            }
            if question.count > 12_000 { Text("요청은 12,000자 이내로 입력하세요.").font(.caption2).foregroundStyle(AppTheme.rose) }
        }.padding(14).background(.white.opacity(0.75))
    }

    private func itemRow(_ item: AssistantItem, confirmable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: item.confirmed ? "checkmark.circle.fill" : "circle.fill")
                    .font(.system(size: item.confirmed ? 12 : 5))
                    .foregroundStyle(AppTheme.violet).padding(.top, item.confirmed ? 3 : 7)
                Text(item.text).font(.callout).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if item.stale { Label("근거 갱신 확인 중", systemImage: "arrow.triangle.2.circlepath").font(.caption2).foregroundStyle(AppTheme.rose) }
                else if item.confirmed { Text("사용자 확인").font(.caption2).foregroundStyle(AppTheme.violet) }
                evidenceButton(title: item.text, evidence: item.evidence)
                Spacer(minLength: 0)
                if confirmable && !item.confirmed {
                    Button("결정 확인") { assistant.confirmDecision(id: item.id) }
                        .font(.caption2).disabled(item.stale)
                }
            }
        }
    }

    private func suggestionCard(_ item: AssistantSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(suggestionKind(item.kind), systemImage: suggestionSymbol(item.kind))
                    .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.violet)
                Spacer()
                if item.status == .review { Text("검토 목록").font(.caption2).foregroundStyle(AppTheme.rose) }
            }
            Button { sheet = .evidence(item.title, item.evidence) } label: {
                Text(item.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).help("제안의 근거 확인")
            Text(item.reason).font(.caption).foregroundStyle(AppTheme.muted).lineSpacing(3)
            if !item.premise.isEmpty {
                Text("확인할 전제 · \(item.premise)").font(.caption2).foregroundStyle(AppTheme.rose)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.stale { Label("근거가 바뀌어 다시 검토합니다", systemImage: "arrow.triangle.2.circlepath").font(.caption2).foregroundStyle(AppTheme.rose) }
            evidenceButton(title: item.title, evidence: item.evidence)
            HStack(spacing: 6) {
                if item.status == .review {
                    Button("검토 완료") { assistant.setSuggestionStatus(id: item.id, status: .resolved) }
                } else {
                    Button("검토 목록에 추가") { assistant.setSuggestionStatus(id: item.id, status: .review) }
                        .disabled(item.stale)
                }
                Spacer(minLength: 0)
                Button("나중에") { assistant.setSuggestionStatus(id: item.id, status: .deferred) }
                Button("닫기") { assistant.setSuggestionStatus(id: item.id, status: .dismissed) }
            }.font(.caption2).controlSize(.mini)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(AppTheme.rose.opacity(0.6)).frame(width: 3).padding(.vertical, 13) }
    }

    private func questionRow(_ item: AssistantQuestion) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(item.text).font(.callout.weight(.medium)).textSelection(.enabled)
            if let answer = item.answer {
                Text(answer).font(.callout).lineSpacing(3).textSelection(.enabled)
                evidenceButton(title: "질문 답변의 근거", evidence: item.evidence)
                if item.includedInMinutes == true {
                    Label("회의 메모에 추가됨", systemImage: "note.text.badge.plus")
                        .font(.caption2).foregroundStyle(AppTheme.violet)
                } else {
                    Button("회의 메모에 추가") { assistant.addQuestionToMinutes(id: item.id) }
                        .font(.caption2).controlSize(.mini)
                }
            } else {
                HStack(spacing: 6) {
                    if item.status == "running" { ProgressView().controlSize(.mini) }
                    Text(questionStatus(item.status)).font(.caption).foregroundStyle(AppTheme.muted)
                }
            }
            if let error = item.error { Text(error).font(.caption2).foregroundStyle(AppTheme.rose) }
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.lavender.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private func evidenceButton(title: String, evidence: [AssistantEvidence]) -> some View {
        Button { sheet = .evidence(title, evidence) } label: {
            Label("근거 \(evidence.count)개", systemImage: "quote.bubble")
        }.font(.caption2).buttonStyle(.plain).foregroundStyle(AppTheme.violet)
            .disabled(evidence.isEmpty)
    }

    private func sendQuestion() {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !chat.busy, value.count <= 12_000 else { return }
        chat.send(value); question = ""
    }
}

private enum AssistantPanelSheet: Identifiable {
    case settings, evidence(String, [AssistantEvidence]), history
    var id: String {
        switch self { case .settings: return "settings"; case .history: return "history"; case .evidence: return "evidence" }
    }
}

private struct AssistantSettingsView: View {
    @ObservedObject var assistant: MeetingAssistant
    let dismiss: () -> Void
    @State private var model: String
    @State private var effort: String
    @State private var summarySeconds: Double
    @State private var suggestionSeconds: Double
    var provider: AITextProvider
    @State private var options = CodexModelOption.cached()

    init(assistant: MeetingAssistant, provider: AITextProvider, dismiss: @escaping () -> Void) {
        self.assistant = assistant; self.provider = provider; self.dismiss = dismiss
        _model = State(initialValue: assistant.model); _effort = State(initialValue: assistant.effort)
        _summarySeconds = State(initialValue: Double(assistant.summaryInterval))
        _suggestionSeconds = State(initialValue: Double(assistant.suggestionInterval))
    }
    private var efforts: [String] { options.first { $0.id == model }?.efforts ?? ["low", "medium", "high", "xhigh"] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("회의 도우미 설정").font(.title2.bold())
            Text("선택한 발언과 관련 자료를 \(provider.title)로 분석합니다. CLI 선택과 공통 모델은 상단 AI 설정에서 변경할 수 있습니다.")
                .font(.caption).foregroundStyle(AppTheme.muted).lineSpacing(3)
            GroupBox("갱신 주기") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("절약") { summarySeconds = 120; suggestionSeconds = 240 }
                        Button("균형") { summarySeconds = 60; suggestionSeconds = 120 }
                        Button("자주 갱신") { summarySeconds = 30; suggestionSeconds = 90 }
                    }
                    Stepper("요약 · \(Int(summarySeconds))초", value: $summarySeconds, in: 30...600, step: 15)
                    Stepper("제안 검토 · \(Int(suggestionSeconds))초", value: $suggestionSeconds, in: 60...900, step: 30)
                    Text("새 발언이 쌓이면 설정한 주기에 분석을 요청합니다. 처리 시간에 따라 화면 반영 시점이 달라집니다.")
                        .font(.caption2).foregroundStyle(AppTheme.muted)
                }.padding(8)
            }
            if provider == .codex {
            GroupBox("Codex 요약 모델 · 선택 사항") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("모델", selection: $model) {
                        Text("공통 AI 설정 사용").tag("")
                        ForEach(options) { Text($0.name).tag($0.id) }
                        if !model.isEmpty && !options.contains(where: { $0.id == model }) { Text(model).tag(model) }
                    }
                    TextField("모델 ID 직접 입력", text: $model).textFieldStyle(.roundedBorder)
                    Picker("추론 강도", selection: $effort) {
                        Text("모델 기본값").tag("")
                        ForEach(efforts, id: \.self) { Text($0).tag($0) }
                        if !effort.isEmpty && !efforts.contains(effort) { Text(effort).tag(effort) }
                    }
                    HStack {
                        Text("이 Mac의 모델 목록 · 계정별 사용 가능 범위 적용").font(.caption2).foregroundStyle(AppTheme.muted)
                        Spacer()
                        Button("목록 갱신") { options = CodexModelOption.cached() }.font(.caption)
                    }
                }.padding(8)
            }
            }
            Text("설정은 다음 요청부터 적용됩니다. 분석 기록에서 모델·입력·처리 범위와 요약 변화를 확인할 수 있어요.")
                .font(.caption).foregroundStyle(AppTheme.muted)
            HStack {
                Spacer()
                Button("취소", action: dismiss).keyboardShortcut(.cancelAction)
                Button("적용") {
                    assistant.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    assistant.effort = effort
                    assistant.summaryInterval = Int(summarySeconds)
                    assistant.suggestionInterval = Int(max(summarySeconds, suggestionSeconds))
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520).background(AppTheme.paper).tint(AppTheme.violet)
            .onChange(of: model) { _, _ in if !effort.isEmpty && !efforts.contains(effort) { effort = "" } }
    }
}

private struct AssistantEvidenceView: View {
    let title: String
    let evidence: [AssistantEvidence]
    let open: (AssistantEvidence) -> Void
    let dismiss: () -> Void
    @State private var player: AVPlayer?
    @State private var playingID: String?
    @State private var playbackError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("근거 확인").font(.title2.bold())
                    Text(title).font(.callout).lineLimit(3)
                }
                Spacer()
                Button("닫기", action: dismiss).keyboardShortcut(.cancelAction)
            }
            Text("분석에 사용한 시점의 발언과 자료 원문입니다.").font(.caption).foregroundStyle(AppTheme.muted)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if evidence.isEmpty { Text("연결된 근거가 준비되면 이곳에 표시합니다.").foregroundStyle(AppTheme.muted).padding(.vertical) }
                    ForEach(evidence) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(item.kind == "utterance" ? "회의 발언" : "참고 자료", systemImage: item.kind == "utterance" ? "waveform" : "doc.text")
                                .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.violet)
                            Text(item.title).font(.headline)
                            Text(item.location).font(.caption.monospacedDigit()).foregroundStyle(AppTheme.muted)
                            Text(item.text).font(.callout).lineSpacing(4).textSelection(.enabled)
                            HStack {
                                if item.sourcePath != nil {
                                    Button("원본 열기") { open(item) }.controlSize(.small)
                                }
                                if item.audioPath != nil {
                                    Button { play(item) } label: {
                                        Label(playingID == item.id ? "구간 처음부터 듣기" : "이 구간 듣기", systemImage: "play.circle")
                                    }.controlSize(.small)
                                }
                                if playingID == item.id {
                                    Button("정지") { player?.pause(); playingID = nil }.controlSize(.small)
                                }
                                Spacer()
                            }
                            DisclosureGroup("근거 식별 정보") {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.id)
                                    Text("버전 · \(item.fingerprint)")
                                    if let path = item.sourcePath { Text(path) }
                                }.font(.system(size: 10, design: .monospaced)).textSelection(.enabled).padding(.top, 5)
                            }.font(.caption2).foregroundStyle(AppTheme.muted)
                        }.assistantCard()
                    }
                }.padding(.trailing, 6)
            }
            if let playbackError { Text(playbackError).font(.caption).foregroundStyle(AppTheme.rose) }
        }.padding(24).frame(width: 700, height: 600).background(AppTheme.paper).tint(AppTheme.violet)
            .onDisappear { player?.pause(); player = nil }
    }

    private func play(_ evidence: AssistantEvidence) {
        guard let path = evidence.audioPath, FileManager.default.fileExists(atPath: path) else {
            playbackError = "M4A 저장 위치를 확인해 주세요. 녹음 중인 파일은 저장 완료 후 재생할 수 있어요."
            return
        }
        player?.pause(); playbackError = nil
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        if let end = evidence.end, end > 0 { item.forwardPlaybackEndTime = CMTime(seconds: end + 0.25, preferredTimescale: 600) }
        let next = AVPlayer(playerItem: item)
        next.seek(to: CMTime(seconds: max(0, evidence.start ?? 0), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player = next; playingID = evidence.id; next.play()
    }
}

private struct AssistantHistoryView: View {
    @ObservedObject var assistant: MeetingAssistant
    let dismiss: () -> Void
    @State private var selectedID: UUID?
    @State private var input = ""
    @State private var output = ""
    @State private var validation = ""
    private var selected: AssistantRunLog? { assistant.runs.first { $0.id == selectedID } ?? assistant.runs.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("요약 변경·분석 기록").font(.title2.bold())
                    Text("요청마다 입력 범위·사용 자료·모델과 결과를 함께 보관합니다.").font(.caption).foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Button("기록 폴더", action: assistant.showDebugFolder)
                Button("닫기", action: dismiss).keyboardShortcut(.cancelAction)
            }
            Divider()
            if assistant.runs.isEmpty {
                ContentUnavailableView("첫 분석을 기다리고 있어요", systemImage: "clock.arrow.circlepath", description: Text("회의 요약이나 질문을 실행하면 변경 기록이 쌓입니다."))
            } else {
                HSplitView {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(assistant.runs.reversed()) { run in
                                Button { selectedID = run.id } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(run.date.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit())
                                        Text(runKind(run.kind)).font(.callout.weight(.semibold))
                                        Text("\(runStatus(run.status)) · \(assistantTime(run.coverageSeconds))까지").font(.caption2)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                        .background(selected?.id == run.id ? AppTheme.lavender : Color.white, in: RoundedRectangle(cornerRadius: 9))
                                }.buttonStyle(.plain)
                            }
                        }.padding(.trailing, 6)
                    }.frame(minWidth: 160, idealWidth: 180, maxWidth: 210)
                    ScrollView {
                        if let run = selected { runDetail(run).padding(.leading, 10) }
                    }.frame(minWidth: 460)
                }
            }
        }.padding(24).frame(width: 900, height: 670).background(AppTheme.paper).tint(AppTheme.violet)
            .task(id: selected.map { $0.id.uuidString + $0.status }) {
                input = ""; output = ""; validation = ""
                guard let run = selected else { return }
                let path = run.folderPath
                let files = await Task.detached(priority: .utility) {
                    ["input.json", "output.json", "validation.json"].map { name in
                        let file = URL(fileURLWithPath: path).appendingPathComponent(name)
                        guard let data = try? Data(contentsOf: file) else { return "파일 준비 대기" }
                        let text = String(data: data, encoding: .utf8) ?? "UTF-8 텍스트 변환을 확인해 주세요."
                        return text.count > 160_000 ? String(text.prefix(160_000)) + "\n… 전체 내용은 기록 폴더에서 확인하세요." : text
                    }
                }.value
                guard !Task.isCancelled else { return }
                input = files[0]; output = files[1]; validation = files[2]
            }
    }

    private func runDetail(_ run: AssistantRunLog) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(runKind(run.kind)) · \(runStatus(run.status))").font(.headline)
            Text("\(run.model.isEmpty ? "기본 모델" : run.model) · \(run.effort.isEmpty ? "기본 추론" : run.effort)")
                .font(.caption).foregroundStyle(AppTheme.violet)
            Text("\(assistantTime(run.coverageSeconds)) 발언까지 · \(String(format: "%.1f", run.elapsed))초")
                .font(.caption.monospacedDigit()).foregroundStyle(AppTheme.muted)
            if !run.message.isEmpty { Text(run.message).font(.caption).textSelection(.enabled) }
            summaryDiff(before: run.beforeSummary, after: run.afterSummary)
            jsonDisclosure("요청 입력 · 발언·자료·맥락", value: input)
            jsonDisclosure("모델 응답", value: output)
            jsonDisclosure("검증 결과", value: validation)
            Button("이 요청의 파일 위치") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: run.folderPath)])
            }.font(.caption)
        }.textSelection(.enabled)
    }

    private func summaryDiff(before: String, after: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("요약 변화").font(.subheadline.weight(.semibold))
            HStack(alignment: .top, spacing: 12) {
                diffColumn("이전 요약", text: before, comparison: after, color: AppTheme.rose)
                diffColumn("새 요약", text: after, comparison: before, color: AppTheme.violet)
            }
            Text("색으로 표시한 문장은 비교 시점의 다른 요약에 포함된 문장과 차이가 있습니다.")
                .font(.caption2).foregroundStyle(AppTheme.muted)
        }
    }

    private func diffColumn(_ title: String, text: String, comparison: String, color: Color) -> some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let other = Set(comparison.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        return VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
            if lines.isEmpty { Text("기록 대기").font(.caption).foregroundStyle(AppTheme.muted) }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(5).background(other.contains(line) ? Color.clear : color.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 9))
    }

    private func jsonDisclosure(_ title: String, value: String) -> some View {
        DisclosureGroup(title) {
            Text(value.isEmpty ? "기록을 읽고 있습니다." : value)
                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.white)
        }.font(.caption)
    }
}

private struct AssistantCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
    }
}
private extension View { func assistantCard() -> some View { modifier(AssistantCardModifier()) } }

private func sectionTitle(_ title: String, symbol: String) -> some View {
    Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.violet)
}
private func assistantTime(_ value: Double) -> String {
    let seconds = Int(max(0, value.isFinite ? value : 0))
    if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
private func suggestionKind(_ kind: String) -> String {
    switch kind { case "reference": return "관련 자료"; case "alternative": return "대안"; default: return "확인 질문" }
}
private func suggestionSymbol(_ kind: String) -> String {
    switch kind { case "reference": return "doc.text.magnifyingglass"; case "alternative": return "arrow.triangle.branch"; default: return "questionmark.bubble" }
}
private func suggestionStatus(_ value: AssistantSuggestionStatus) -> String {
    switch value { case .active: return "새 제안"; case .review: return "검토 목록"; case .deferred: return "나중에"; case .dismissed: return "닫은 제안"; case .resolved: return "검토 완료" }
}
private func questionStatus(_ value: String) -> String {
    switch value { case "running": return "답변을 정리하고 있어요"; case "completed": return "응답 완료"; case "failed": return "재시도 대기"; case "cancelled": return "취소됨"; default: return "순서대로 답변을 준비합니다" }
}
private func runKind(_ value: String) -> String {
    switch value { case "question": return "질문 응답"; case "suggestions", "suggestion": return "요약·제안"; case "manual": return "직접 요청"; default: return "회의 요약" }
}
private func runStatus(_ value: String) -> String {
    switch value { case "completed": return "완료"; case "partial": return "일부 반영"; case "running": return "분석 중"; case "failed": return "확인 필요"; case "cancelled": return "취소됨"; default: return "대기" }
}
