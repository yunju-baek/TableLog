import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var lectureTranscript = false
    private struct VoiceLearningRequest: Identifiable { let id = UUID(); let speaker: Int? }
    @State private var voiceLearningRequest: VoiceLearningRequest?
    @State private var textEditRequest: TranscriptEditRequest?
    @State private var showingSpeakerReview = false
    @State private var showingMeeting = false
    @AppStorage("assistant.panel.visible") private var showingAssistant = true
    @State private var meetingTab = 0
    @State private var showingEngineSettings = false
    @State private var showingStorageSettings = false
    @State private var showingMeetingHistory = false
    @State private var showingComparison = false
    @State private var comparisonTurnID: String?
    @State private var followLatest = true
    @State private var transcriptAtBottom = true
    @State private var scrollingTranscript = false
    @State private var latestTranscriptJump = 0
    @State private var copied = false
    @State private var showingSpeakerNames = false
    @State private var showingContextEditor = false
    @State private var showingCloudSettings = false
    @State private var preferredSpeaker: Int?
    @State private var speakerEditorID = UUID()
    @State private var contextEditorID = UUID()
    @State private var cloudSettingsID = UUID()

    private let ink = AppTheme.ink
    private let muted = AppTheme.muted
    private let violet = AppTheme.violet
    private let paper = AppTheme.paper
    private var transcriptInset: CGFloat { showingAssistant ? 16 : 32 }
    private var shouldFollowTranscript: Bool {
        followLatest && transcriptAtBottom && !scrollingTranscript
            && !showingSpeakerNames && !showingContextEditor && !showingCloudSettings
            && !showingComparison && !showingSpeakerReview
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 270)
            mainPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
            if showingAssistant {
                Divider().overlay(AppTheme.violet.opacity(0.12))
                MeetingAssistantView(assistant: model.assistant, chat: model.editingChat,
                                     provider: model.codexSettings.provider, onConnectAI: openAISettings)
                    .onAppear { model.editingChat.syncSession(model.editingSessionID) }
                    .onChange(of: model.editingSessionID) { _, id in model.editingChat.syncSession(id) }
                    .containerRelativeFrame(.horizontal) { width, _ in width / 2 }
            }
        }
        .background(paper)
        .frame(minWidth: showingAssistant ? 1240 : 900, minHeight: 680)
        .tint(AppTheme.violet)
        .environment(\.colorScheme, .light)
        .sheet(item: $voiceLearningRequest) { request in
            VoiceIdentityView(model: model, voice: model.voice, initialSpeaker: request.speaker) { voiceLearningRequest = nil }
        }
        .sheet(item: $textEditRequest) { request in
            TranscriptTextEditor(model:model,request:request) { textEditRequest=nil }
        }
        .sheet(isPresented: $showingMeeting) {
            MeetingWorkspaceView(model: model, workspace: model.meeting, dismiss: { showingMeeting = false }, initialTab: meetingTab)
        }
        .sheet(isPresented: $showingContextEditor) {
            ContextEditorView(model: model) { showingContextEditor = false }.id(contextEditorID)
        }
        .sheet(isPresented: $showingComparison) {
            RecognitionComparisonView(model: model, turnID: comparisonTurnID) { showingComparison = false }
        }
        .sheet(isPresented: $showingSpeakerReview) {
            SpeakerReviewView(model: model) { showingSpeakerReview = false }
        }
        .sheet(isPresented: $showingStorageSettings) {
            StorageSettingsView(dismiss: { showingStorageSettings = false })
        }
        .sheet(isPresented: $showingMeetingHistory) {
            MeetingHistoryView(model: model, history: model.history) { showingMeetingHistory = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: MeetingHistoryPresentation.show)) { _ in
            showingMeetingHistory = true
        }
        .onReceive(NotificationCenter.default.publisher(for: AppHelp.showAISettings)) { _ in
            openAISettings()
        }
        .onChange(of: model.speakerIDs) { _, speakers in
            if speakers.isEmpty { showingSpeakerNames = false }
        }
        .onChange(of: model.editingSessionID) { _, _ in
            transcriptAtBottom = true
            scrollingTranscript = false
        }
        .onChange(of: followLatest) { _, enabled in
            if enabled { jumpToLatestTranscript() }
        }
    }

    private func openAISettings() {
        showingSpeakerNames = false
        showingCloudSettings = false
        contextEditorID = UUID()
        showingContextEditor = true
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(violet)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.70), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("테이블로그")
                        .font(.system(size: 20, weight: .bold))
                    Text("누가, 언제, 무엇을 말했는지.")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.muted)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 28)

            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    captureStatus

                    VStack(spacing: 10) {
                        Button {
                            model.newMeeting();meetingTab=0;showingMeeting=true
                        } label: {
                            Label("새 회의",systemImage:"plus.circle.fill")
                                .font(.system(size:14,weight:.semibold)).frame(maxWidth:.infinity).padding(.vertical,12)
                                .foregroundStyle(AppTheme.violet).background(.white.opacity(0.7),in:RoundedRectangle(cornerRadius:11))
                        }.buttonStyle(.plain).disabled(!model.canPrepareMeeting)

                        if model.canStop {
                            if !model.processingFile {
                                Button(action: model.togglePause) {
                                    Label(model.pauseTransition ? "일시정지 중…" : model.pauseTitle,
                                          systemImage: model.phase == .paused ? "play.fill" : "pause.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                                        .foregroundStyle(violet)
                                        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 11))
                                }
                                .buttonStyle(.plain).disabled(!model.canPause)
                                .keyboardShortcut("p", modifiers: [.command, .shift])
                                .help("같은 회의에서 녹음을 일시정지하거나 재개해요. (⇧⌘P)")
                            }
                            Button(action: model.stop) {
                                Label("종료 · 저장", systemImage: "stop.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .foregroundStyle(Color(red: 0.30, green: 0.12, blue: 0.12))
                                    .background(Color(red: 1, green: 0.79, blue: 0.74), in: RoundedRectangle(cornerRadius: 11))
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(".", modifiers: [.command])
                        } else if model.canCancelQwen {
                            Button(action: model.cancelQwen) {
                                Label("Qwen 중지 · 초안 저장", systemImage: "stop.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .foregroundStyle(AppTheme.rose)
                                    .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 11))
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(".", modifiers: [.command])
                        } else {
                            Button(action: model.start) {
                                Label(model.phase == .finishing ? "저장하고 있어요" : "녹음 시작", systemImage: "mic.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .foregroundStyle(Color.white)
                                    .background(violet, in: RoundedRectangle(cornerRadius: 11))
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.canStartRecording)
                            .opacity(model.canStartRecording ? 1 : 0.42)
                            .keyboardShortcut("r", modifiers: [.command])
                        }
                        Button(action: model.importAudio) {
                            Label("음성 파일 열기", systemImage: "folder")
                                .font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(AppTheme.violet.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canStart)
                        .opacity(model.canStart ? 1 : 0.42)
                        .keyboardShortcut("o", modifiers: [.command])
                    }

                    MeetingSidebarButton(workspace: model.meeting) { meetingTab=0;showingMeeting = true }
                    Button { showingMeetingHistory = true } label: {
                        Label("지난 회의", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .foregroundStyle(AppTheme.violet)
                            .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                    Button { showingAssistant.toggle() } label: {
                        Label(showingAssistant ? "회의 도우미 접기" : "회의 도우미 열기", systemImage: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .foregroundStyle(AppTheme.violet)
                            .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                    Button { meetingTab=2;showingMeeting=true } label: {
                        Label("자료·맥락 · \(model.materials.context.documents.count)개",systemImage:"doc.on.doc").font(.system(size:12,weight:.medium))
                    }.buttonStyle(.plain)

                    Rectangle().fill(AppTheme.violet.opacity(0.12)).frame(height: 1)

                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            sectionLabel("마이크")
                            Spacer()
                            Button(action: model.refreshDevices) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(4)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.muted)
                            .disabled(model.isBusy)
                            .help("마이크 목록 새로 고침")
                            .accessibilityLabel("마이크 목록 새로 고침")
                        }
                        Picker("입력 마이크", selection: $model.selectedDeviceID) {
                            Text("시스템 기본 마이크").tag(UInt32(0))
                            ForEach(model.devices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity)
                        .disabled(!model.canStart)
                        .environment(\.colorScheme, .light)
                        Text("녹음을 시작하기 전에 입력 장치를 선택해 주세요.")
                            .font(.system(size: 11))
                            .lineSpacing(3)
                            .foregroundStyle(AppTheme.muted)
                    }

                    VoiceMappingSidebar(model: model, voice: model.voice) {
                        voiceLearningRequest = VoiceLearningRequest(speaker: nil)
                    }

                    Button { showingEngineSettings = true } label: {
                        Label("NVIDIA 음성·화자 설정", systemImage: "slider.horizontal.3")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                    .popover(isPresented: $showingEngineSettings) {
                        EngineSettingsView(model: model) { showingEngineSettings = false }
                    }

                    Button { showingStorageSettings = true } label: {
                        Label("저장 위치 설정", systemImage: "folder.badge.gearshape")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 9) {
                        Toggle(isOn: $model.lowLatency) {
                            Text("빠른 응답")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(violet)
                        .disabled(!model.canStart)
                        Text("짧은 간격으로 발언을 표시해요.\n설정은 다음 녹음부터 적용돼요.")
                            .font(.system(size: 11))
                            .lineSpacing(3)
                            .foregroundStyle(AppTheme.muted)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(model.codexSettings.mode.title, systemImage: "text.badge.checkmark").font(.system(size: 12, weight: .medium))
                        Text(model.correctionStatus).font(.system(size: 10)).foregroundStyle(AppTheme.muted)
                        if model.correctionNeedsRetry {
                            Button("AI 교정 재시도", action: model.retryCodexCorrection).font(.system(size: 11))
                        }
                    }

                    if let saved = model.lastSavedURL {
                        Button(action: model.revealLastSave) {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(violet)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.canStop ? "기록을 임시 저장했어요" : "기록이 저장되었어요")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("Finder에서 열기")
                                        .font(.system(size: 11))
                                        .foregroundStyle(AppTheme.muted)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(AppTheme.muted)
                            }
                            .padding(12)
                            .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .help(saved.path)
                    }
                    if let audioURL = model.savedAudioURL {
                        Button(action: model.revealSavedAudio) {
                            Label("음성 M4A", systemImage: "waveform.circle")
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .help(audioURL.path)
                        .accessibilityLabel("저장한 M4A 음성 열기")
                    } else if model.canStop || model.audioSaveStatus.contains("오류") {
                        Label(model.audioSaveStatus, systemImage: "waveform")
                            .font(.system(size: 10)).foregroundStyle(AppTheme.muted)
                    }
                    Button { showingSpeakerReview = true } label: {
                        Label("LLM 화자 검토", systemImage: "person.2.badge.gearshape")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).help("앞뒤 발언으로 화자 재검토 · 원음 확인 후 적용")
                    Group {
                        Button {
                            comparisonTurnID = nil
                            showingComparison = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("인식 변경 기록", systemImage: "arrow.left.arrow.right")
                                    .font(.system(size: 12, weight: .medium))
                                Text("클릭해서 차이와 변경 과정 보기")
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppTheme.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .help("클릭해서 인식 결과 비교 · " + model.debugStatus)
                        .accessibilityLabel("인식 변경 기록 열기")
                        if model.debugStatus.contains("오류") {
                            Text(model.debugStatus).font(.system(size: 10)).foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Button(action: AppHelp.openGuide) { Label("사용법·도움말", systemImage: "questionmark.circle") }
                        .buttonStyle(.plain).help("GitHub 사용법 열기").accessibilityLabel("사용법·도움말 열기")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "테이블로그")
                        .font(.system(size: 9)).foregroundStyle(AppTheme.muted)
                }.font(.system(size: 11)).padding(.bottom, 5)
                Label(model.usesQwen ? "Qwen 재전사 · Mac 화자 분리" :
                      model.usesGemini ? "Gemini 전사 · Mac 화자 분리" :
                      (model.codexSettings.mode == .codex ? "로컬 전사 · \(model.codexSettings.provider.title) 교정" : "로컬 음성 인식"),
                      systemImage: model.usesGemini ? "cloud" : "desktopcomputer")
                    .font(.system(size: 11, weight: .medium))
                Text(model.usesQwen ? "Qwen3-ASR 1.7B + NVIDIA Nemotron" :
                     model.usesGemini ? "Google Gemini + NVIDIA Nemotron" : "NVIDIA Nemotron · 한국어")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.muted)
            }
            .foregroundStyle(AppTheme.muted)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.violet.opacity(0.055))
        }
        .foregroundStyle(AppTheme.ink)
        .background(AppTheme.sidebar)
    }

    private var captureStatus: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(phaseTitle).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                Spacer()
                if model.phase == .loading || model.phase == .finishing {
                    ProgressView().controlSize(.mini).tint(violet)
                }
            }
            Text(AppModel.time(model.audioSeconds))
                .font(.system(size: 38, weight: .light, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            if model.processingFile {
                VStack(alignment: .leading, spacing: 9) {
                    if let fraction = model.fileProgress?.progressFraction {
                        ProgressView(value: fraction).tint(violet)
                            .accessibilityLabel("음성 파일 처리 진행률")
                        HStack {
                            Text("음성 파일 처리")
                            Spacer()
                            Text("\(Int(fraction * 100))%")
                                .monospacedDigit()
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.muted)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini).tint(violet)
                            Text("음성 파일 준비 중")
                                .font(.system(size: 10))
                                .foregroundStyle(AppTheme.muted)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    InputLevelMeter(level: model.inputLevel, active: model.phase == .recording)
                        .frame(height: 22)
                    HStack {
                        Text("마이크 입력")
                        Spacer()
                        Text(model.phase == .paused ? "일시정지" : model.phase == .recording ? "듣는 중" : "대기")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.muted)
                }
            }
            Text(model.displayStatusMessage)
                .font(.system(size: 11))
                .lineSpacing(4)
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if model.queuedSeconds > 1 {
                Label(String(format: "처리 대기 %.1f초", model.queuedSeconds), systemImage: "clock")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.rose)
            }
        }
    }

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("전사록")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(ink)
                transcriptSettings
            }
            .padding(.horizontal, transcriptInset)
            .padding(.top, 22)
            .padding(.bottom, 16)

            transcriptContent
        }
    }

    private var transcriptSettings: some View {
        HStack(spacing: 6) {
            Button {
                showingSpeakerNames = false
                showingContextEditor = false
                cloudSettingsID = UUID()
                showingCloudSettings = true
            } label: {
                Label("인식 엔진", systemImage: model.usesGemini ? "cloud" : "desktopcomputer")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.violet)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppTheme.lavender, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("NVIDIA, Qwen, Gemini 중 음성 인식 엔진을 선택해요.")
            .accessibilityLabel("인식 엔진 설정")
            .accessibilityValue(model.recognitionProvider.title)
            .popover(isPresented: $showingCloudSettings, arrowEdge: .top) {
                CloudSettingsView(model: model) { showingCloudSettings = false }
                    .id(cloudSettingsID)
            }
            .padding(.top, 4)
            Button(action: openAISettings) {
                HStack(spacing: 7) {
                    Image(systemName: "text.badge.checkmark")
                    Text("AI 설정")
                    Circle()
                        .fill(model.codexSettings.mode != .off ? AppTheme.violet : muted.opacity(0.4))
                        .frame(width: 6, height: 6)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.violet)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppTheme.lavender, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("AI CLI 선택, 모델·연결·문맥 교정을 설정해요.")
            .accessibilityLabel("AI CLI 설정")
            .accessibilityValue(model.codexSettings.provider.title + " · " + model.codexSettings.mode.title)
            .padding(.top, 4)
            Button {
                editSpeakerNames()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "person.2.fill")
                    Text("화자 이름")
                    if !model.speakerIDs.isEmpty {
                        Text("\(model.speakerIDs.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .frame(minWidth: 17, minHeight: 17)
                            .background(.white.opacity(0.7), in: Circle())
                    }
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.violet)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppTheme.lavender, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.speakerIDs.isEmpty)
            .opacity(model.speakerIDs.isEmpty ? 0.55 : 1)
            .help(model.speakerIDs.isEmpty ? "화자가 감지되면 이름을 입력할 수 있어요." : "현재 대화의 화자 이름 입력 또는 수정")
            .popover(isPresented: $showingSpeakerNames, arrowEdge: .top) {
                SpeakerNamesEditor(model: model, preferredSpeaker: preferredSpeaker) {
                    showingSpeakerNames = false
                }
                .id(speakerEditorID)
            }
            .padding(.top, 4)
        }
    }

    private var transcriptContent: some View {
        Group {
            if model.isReprocessing || (!model.isBusy && model.meeting.canGenerate) {
                VStack(alignment: .leading, spacing: 9) {
                    Label(model.isReprocessing ? "지난 회의 재가공본 · 원본 보관" : "전사 저장 완료 · 회의록", systemImage: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                    Text("발언과 화자를 편집하고, 회의자료를 더해 다시 정리할 수 있어요.")
                        .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                    HStack(spacing: 10) {
                        Button(model.meeting.lastURL == nil ? "회의록 생성" : "회의록 다시 생성", action: model.generateMinutes)
                            .buttonStyle(.borderedProminent).disabled(!model.canGenerateMinutes)
                        Button("회의록 보기") { meetingTab=1;showingMeeting=true }
                            .buttonStyle(.bordered).disabled(model.meeting.lastURL == nil)
                        if model.isReprocessing {
                            Button("문맥 다시 교정", action: model.recorrectHistoryTranscript)
                                .buttonStyle(.bordered).disabled(model.isBusy)
                        }
                    }.font(.system(size: 11))
                }
                .foregroundStyle(AppTheme.violet)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.lavender.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, transcriptInset)
                .padding(.bottom, 16)
            }

            HStack(alignment: .top, spacing: 7) {
                if model.usesGemini ? model.cloudPendingSeconds > 0 : !model.correctingSegmentIDs.isEmpty {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: model.usesGemini ? "cloud" : (model.contextSettings.enabled ? "checkmark.shield" : "slider.horizontal.3"))
                        .font(.system(size: 11))
                        .padding(.top, 1)
                }
                Text(model.usesGemini ? model.cloudStatus : model.correctionStatus)
                    .font(.system(size: 11))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .foregroundStyle(muted)
            .padding(.horizontal, transcriptInset)
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(model.sessionTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                            .help(model.sessionTitle)
                        if model.canEditMeetingTitle {
                            Button {
                                meetingTab = 0
                                showingMeeting = true
                            } label: {
                                Image(systemName: "pencil").foregroundStyle(violet)
                            }
                            .buttonStyle(.plain)
                            .help("회의 제목 편집")
                            .accessibilityLabel("회의 제목 편집")
                        }
                    }
                    Text(model.segments.isEmpty ? "대화 기록" : "\(model.conversationTurns.count)개의 발언")
                        .font(.system(size: 11))
                        .foregroundStyle(muted)
                }
                HStack(spacing: 6) {
                    if model.canStop && !model.processingFile {
                        Button {
                            model.materials.pickFiles(provider: model.meeting.provider, settings: model.codexSettings)
                        } label: {
                            Label("자료 첨부", systemImage: "paperclip")
                        }
                        .help("녹음을 이어가면서 이번 회의에 자료를 추가해요.")
                    }
                    Button {
                        model.copyTranscript()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Label(copied ? "복사 완료" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(!model.canExport)
                    .help("화자와 시간을 포함한 전사 내용 복사")
                    Button(action: model.saveJSON) {
                        Label("JSON 저장", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!model.canExport)
                    .keyboardShortcut("s", modifiers: [.command])
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.horizontal, transcriptInset)
            .padding(.bottom, 20)

            if let error = model.errorMessage {
                errorBanner(error)
                    .padding(.horizontal, transcriptInset)
                    .padding(.bottom, 18)
            }

            Rectangle().fill(ink.opacity(0.08)).frame(height: 1)
                .padding(.horizontal, transcriptInset)

            if model.meeting.mode == .lecture && !lectureTranscript {
                LectureDashboard(assistant:model.assistant, openInput:{ openWindow(id:"lecture-input") }, showTranscript:{ lectureTranscript=true })
            } else if model.processingFile && (!model.segments.isEmpty || !model.liveText.isEmpty) {
                FileTranscriptPreview(text: fileTranscriptText, followLatest: shouldFollowTranscript,
                                      jump: latestTranscriptJump, onScroll: { transcriptAtBottom = $0 })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.segments.isEmpty && model.liveText.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
            }

            if model.meeting.mode == .lecture && lectureTranscript {
                Button("강의 흐름으로 돌아가기") { lectureTranscript=false }.padding(.horizontal,32).padding(.top,8)
            }
            HStack(spacing: 8) {
                if followLatest && !transcriptAtBottom {
                    Button(action: jumpToLatestTranscript) {
                        Label("최신 발언으로", systemImage: "arrow.down")
                    }.controlSize(.small)
                }
                Image(systemName: "sparkle")
                    .foregroundStyle(AppTheme.rose)
                Text(model.usesQwen ? "녹음이 끝나면 Qwen 전사가 반영돼요." :
                     model.codexSettings.mode == .codex ? "초안에 AI 교정이 이어서 반영돼요. 차이 보기에서 변경을 확인해 주세요." :
                     (model.usesGemini ? "로컬 초안에 Gemini 전사가 이어서 반영돼요." : "화자와 문장은 녹음 중 보정돼요."))
                    .font(.system(size: 11))
                    .foregroundStyle(muted)
                Spacer(minLength: 12)
                Toggle("최신 발언 따라가기", isOn: $followLatest)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundStyle(muted)
                    .controlSize(.small)
            }
            .padding(.horizontal, transcriptInset)
            .padding(.vertical, 17)
            .background(paper)
        }
    }

    private func jumpToLatestTranscript() {
        transcriptAtBottom = true
        scrollingTranscript = false
        latestTranscriptJump += 1
    }

    private func isNearTranscriptBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY <= 24
    }

    private var fileTranscriptText: String {
        if model.segments.isEmpty { return TranscriptPresentation.format(model.liveText) }
        return model.conversationTurns.map { turn in
            let name = model.speakerName(for: turn.speaker)
            let text = TranscriptPresentation.format(model.displayedText(for: turn))
            return "\(AppModel.time(turn.start))  \(name)\n\(text)"
        }.joined(separator: "\n\n")
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.transcriptUndoCount > 0 {
                        HStack {
                            Text("수동 교정 적용").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("수동 교정 되돌리기",action:model.undoTranscriptEdit)
                        }.padding(10).background(AppTheme.lavender,in:RoundedRectangle(cornerRadius:10))
                    }
                    if model.segments.isEmpty {
                        TranscriptCard(speaker: 0, speakerName: "화자 확인 중", start: 0, end: model.audioSeconds,
                                       text: model.liveText, originalText: nil, isCorrecting: false, isCloudTranscript: false, onEditName: nil)
                    } else {
                        ForEach(model.conversationTurns) { turn in
                            TranscriptCard(speaker: turn.speaker, speakerName: model.speakerName(for: turn.speaker),
                                           start: turn.start, end: turn.end, text: model.displayedText(for: turn),
                                           originalText: nil,
                                           isCorrecting: turn.segments.contains { model.correctingSegmentIDs.contains($0.id) },
                                           isCloudTranscript: turn.segments.contains { model.cloudSegmentIDs.contains($0.id) },
                                           onEditName: turn.speaker > 0 ? { editSpeakerNames(focusing: turn.speaker) } : nil,
                                           recognitionLabel: model.recognitionLabel(for: turn),
                                           onCompare: {
                                               comparisonTurnID = turn.id
                                               showingComparison = true
                                           }, onLearnVoice: turn.speaker > 0 ? {
                                               voiceLearningRequest = VoiceLearningRequest(speaker: turn.speaker)
                                           } : nil,
                                           onEditText: { textEditRequest=model.editRequest(for:turn) },
                                           onDeleteText: { model.deleteRecognizedTurn(turn) },
                                           voiceName: model.voiceNamePresentation(for: turn.speaker),
                                           onConfirmVoiceName: { model.confirmVoiceName(turn.speaker) },
                                           onDismissVoiceName: { model.dismissVoiceSuggestion(turn.speaker) },
                                           onUndoVoiceName: { model.undoAutomaticVoiceName(turn.speaker) },
                                           continuousVoiceLearningEnabled: model.voice.vault.continuousLearningEnabled)
                        }
                    }
                    if model.phase == .recording {
                        HStack(spacing: 7) {
                            Circle().fill(AppTheme.rose).frame(width: 5, height: 5)
                            Text(model.processingFile ? "다음 발언을 정리하고 있어요" : "대화를 계속 듣고 있어요")
                                .font(.system(size: 11))
                                .foregroundStyle(muted)
                        }
                        .padding(.leading, 4)
                        .padding(.top, 3)
                    }
                    Color.clear.frame(height: 1).id("latest-transcript")
                }
                .padding(.horizontal, 32)
                .padding(.top, 22)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(shouldFollowTranscript ? .bottom : nil, for: .initialOffset)
            .defaultScrollAnchor(shouldFollowTranscript ? .bottom : nil, for: .sizeChanges)
            .onScrollPhaseChange { _, phase, context in
                let userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                if scrollingTranscript && !userScrolling {
                    transcriptAtBottom = isNearTranscriptBottom(context.geometry)
                }
                scrollingTranscript = userScrolling
            }
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
                guard old.contentOffset.y != new.contentOffset.y,
                      scrollingTranscript || (old.contentSize == new.contentSize && old.containerSize == new.containerSize
                          && old.contentInsets == new.contentInsets) else { return }
                transcriptAtBottom = isNearTranscriptBottom(new)
            }
            .onChange(of: latestTranscriptJump) { _, _ in
                proxy.scrollTo("latest-transcript", anchor: .bottom)
            }
            .onDisappear { scrollingTranscript = false }
        }
    }

    private func editSpeakerNames(focusing speaker: Int? = nil) {
        guard !model.speakerIDs.isEmpty else { return }
        showingContextEditor = false
        showingCloudSettings = false
        preferredSpeaker = speaker
        speakerEditorID = UUID()
        showingSpeakerNames = true
    }

    private func originalText(for segment: TranscriptSegment) -> String? {
        if model.cloudSegmentIDs.contains(segment.id) {
            guard let draft = model.localDraftText(for: segment),
                  draft != model.displayedText(for: segment) else { return nil }
            return draft
        }
        guard let correction = model.corrections[segment.id],
              correction.originalText == segment.text,
              correction.correctedText != correction.originalText,
              model.displayedText(for: segment) == correction.correctedText else { return nil }
        return correction.originalText
    }

    private var emptyState: some View {
        VStack(spacing: 17) {
            ConversationIllustration()
                .frame(width: 212, height: 145)
                .accessibilityHidden(true)
            if model.phase == .loading || model.phase == .finishing || model.processingFile {
                ProgressView().controlSize(.small)
            }
            VStack(spacing: 10) {
                Text(emptyTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ink)
                Text(emptyDescription)
                    .font(.system(size: 13))
                    .lineSpacing(5)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(muted)
                    .frame(maxWidth: 330)
            }
        }
        .padding(24)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color(red: 0.73, green: 0.40, blue: 0.18))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 9) {
                Text(error)
                    .font(.system(size: 12))
                    .lineSpacing(4)
                    .foregroundStyle(Color(red: 0.47, green: 0.31, blue: 0.21))
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    if model.phase == .failed {
                        Button("다시 준비", action: model.reloadEngine)
                    }
                    if error.contains("마이크") {
                        Button("마이크 권한 설정", action: model.openMicrophoneSettings)
                    }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.99, green: 0.92, blue: 0.83), in: RoundedRectangle(cornerRadius: 12))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.muted)
    }

    private var phaseTitle: String {
        switch model.phase {
        case .loading: return "준비 중"
        case .ready: return "대화 준비 완료"
        case .recording: return model.processingFile ? "파일 전사 중" : "녹음 중"
        case .paused: return "녹음 일시정지"
        case .finishing: return "기록 정리 중"
        case .completed: return "저장 완료"
        case .failed: return "설정 확인"
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .recording: return AppTheme.rose
        case .paused: return Color.orange
        case .failed: return Color(red: 0.68, green: 0.37, blue: 0.13)
        case .ready, .completed: return violet
        case .loading, .finishing: return AppTheme.muted.opacity(0.6)
        }
    }

    private var emptyTitle: String {
        switch model.phase {
        case .loading: return "잠시 후 대화를 기록할 수 있어요"
        case .ready, .completed: return "녹음을 시작할 수 있어요"
        case .recording: return model.processingFile ? "음성을 읽고 있어요" : "첫 발언을 기다리고 있어요"
        case .paused: return "녹음을 잠시 멈췄어요"
        case .finishing: return "마지막 발언을 정리하고 있어요"
        case .failed: return "입력과 설정을 확인해 주세요"
        }
    }

    private var emptyDescription: String {
        switch model.phase {
        case .loading: return model.statusMessage
        case .ready, .completed: return "바로 녹음하거나 새 회의를 준비할 수 있어요.\n회의 제목과 자료는 녹음 중에도 추가할 수 있어요."
        case .recording: return model.processingFile ? "음성에서 발언과 화자를 정리하고 있어요." : "말씀하시면 화자와 함께 내용이 표시돼요."
        case .paused: return "녹음 재개를 누르면 같은 회의에 이어서 기록해요."
        case .finishing: return "정리가 끝나면 대화 기록이 자동으로 저장돼요."
        case .failed: return "위 안내를 확인한 뒤 다시 준비해 주세요."
        }
    }
}

/// AppKit lays out the growing transcript inside the scroll view, independently
/// of the surrounding SwiftUI controls. The full editor is available after import.
private struct FileTranscriptPreview: NSViewRepresentable {
    let text: String
    let followLatest: Bool
    let jump: Int
    let onScroll: (Bool) -> Void

    final class Coordinator: NSObject {
        var followedLatest = false
        var atBottom = true
        var isUpdating = false
        var jump = 0
        var previousBounds: CGRect?
        var onScroll: ((Bool) -> Void)?

        @objc func boundsChanged(_ notification: Notification) {
            guard !isUpdating, let clip = notification.object as? NSClipView,
                  let scroll = clip.enclosingScrollView, let document = scroll.documentView else { return }
            let previous = previousBounds
            previousBounds = clip.bounds
            guard let previous, previous.size == clip.bounds.size, previous.minY != clip.bounds.minY else { return }
            let nearBottom = document.bounds.maxY - scroll.documentVisibleRect.maxY <= 24
            guard nearBottom != atBottom else { return }
            atBottom = nearBottom
            onScroll?(nearBottom)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let document = scroll.documentView as? NSTextView {
            document.isEditable = false
            document.isRichText = false
            document.drawsBackground = false
            document.font = .systemFont(ofSize: 14)
            document.textContainerInset = NSSize(width: 22, height: 18)
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.boundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let document = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.onScroll = onScroll
        coordinator.isUpdating = true
        defer {
            coordinator.previousBounds = scroll.contentView.bounds
            coordinator.isUpdating = false
        }
        let changed = document.string != text
        let jumped = coordinator.jump != jump
        let shouldScroll = followLatest && (jumped || (coordinator.atBottom && (changed || !coordinator.followedLatest)))
        coordinator.jump = jump
        coordinator.followedLatest = followLatest
        if changed {
            let origin = scroll.contentView.bounds.origin
            let selection = document.selectedRange()
            document.string = text
            if NSMaxRange(selection) <= text.utf16.count {
                document.setSelectedRange(selection)
            }
            if !shouldScroll {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        if shouldScroll {
            document.scrollRangeToVisible(NSRange(location: text.utf16.count, length: 0))
            coordinator.atBottom = true
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
}

private struct TranscriptCard: View {
    let speaker: Int
    let speakerName: String
    let start: Double
    let end: Double
    let text: String
    let originalText: String?
    let isCorrecting: Bool
    let isCloudTranscript: Bool
    let onEditName: (() -> Void)?
    var recognitionLabel: String? = nil
    var onCompare: (() -> Void)? = nil
    var onLearnVoice: (() -> Void)? = nil
    var onEditText: (() -> Void)? = nil
    var onDeleteText: (() -> Void)? = nil
    var voiceName: VoiceNamePresentation? = nil
    var onConfirmVoiceName: (() -> Void)? = nil
    var onDismissVoiceName: (() -> Void)? = nil
    var onUndoVoiceName: (() -> Void)? = nil
    var continuousVoiceLearningEnabled = false
    @State private var showingOriginal = false

    private var accent: Color {
        let palette = AppTheme.speakers
        return speaker > 0 ? palette[(speaker - 1) % palette.count] : AppTheme.muted
    }

    @State private var showingVoiceStatus = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                identity
                HStack { Spacer(); actions }
            }
            Text(TranscriptPresentation.format(text))
                .font(.system(size: 15)).lineSpacing(5)
                .foregroundStyle(AppTheme.ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showingOriginal, let originalText {
                Text(originalText).font(.caption).lineSpacing(4)
                    .foregroundStyle(AppTheme.muted).textSelection(.enabled)
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.paper, in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(.white, in: RoundedRectangle(cornerRadius: 13))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.7))
                .frame(width: 3).padding(.vertical, 14)
        }
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.black.opacity(0.035)))
        .confirmationDialog("이 발언을 삭제할까요?", isPresented: $confirmingDelete) {
            Button("발언 삭제", role: .destructive) { onDeleteText?() }
        } message: { Text("삭제 후 전사 편집 되돌리기로 복원할 수 있어요.") }
        .onChange(of: originalText) { _, value in if value == nil { showingOriginal = false } }
    }

    private var identity: some View {
        HStack(spacing: 6) {
            Button { onEditName?() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "person.fill").font(.system(size: 10))
                    Text(speakerName).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                }
            }.buttonStyle(.plain).disabled(onEditName == nil || speaker <= 0)
                .help("화자 이름 수정").accessibilityLabel("\(speakerName), 이름 수정")
            if speakerName != "화자 \(speaker)", speaker > 0 {
                Text("화자 \(speaker)").font(.system(size: 9)).foregroundStyle(AppTheme.muted)
            }
            if isCorrecting { ProgressView().controlSize(.mini).help("문맥 교정 중") }
            else if let recognitionLabel {
                Text(recognitionLabel).font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(accent.opacity(0.08), in: Capsule())
            }
            if let voiceName, voiceName.kind == .suggested || voiceName.kind == .automatic {
                Button { showingVoiceStatus.toggle() } label: {
                    Image(systemName: voiceName.kind == .automatic ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.questionmark")
                }.buttonStyle(.plain).help("목소리 기반 이름 연결 확인")
                    .accessibilityLabel("목소리 기반 이름 연결 확인")
                    .popover(isPresented: $showingVoiceStatus) {
                        VoiceNameStatusView(presentation: voiceName, confirm: onConfirmVoiceName,
                            dismiss: onDismissVoiceName, undo: onUndoVoiceName,
                            continuousLearningEnabled: continuousVoiceLearningEnabled)
                            .padding(16).frame(width: 310)
                    }
            }
        }.foregroundStyle(accent)
    }
    private var timestamp: some View {
        Text("\(AppModel.time(start))–\(AppModel.time(end))")
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(AppTheme.muted)
    }
    private var actions: some View {
        HStack(spacing: 3) {
            timestamp.padding(.trailing, 5)
            if let onEditText { icon("pencil", "발언 분리·화자·문장 수정", action: onEditText) }
            if let onCompare { icon("arrow.left.arrow.right", "차이 보기·교정 확인", action: onCompare) }
            if let onLearnVoice { icon("person.badge.plus", "이 화자로 목소리 학습", action: onLearnVoice) }
            Menu {
                if originalText != nil {
                    Button(showingOriginal ? "원문 접기" : "인식 원문 보기") { showingOriginal.toggle() }
                }
                if onDeleteText != nil {
                    Button("발언 삭제", role: .destructive) { confirmingDelete = true }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("발언 더보기").accessibilityLabel("발언 더보기")
        }.foregroundStyle(accent)
    }
    private func icon(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

}

private struct SpeakerNamesEditor: View {
    @ObservedObject var model: AppModel
    let preferredSpeaker: Int?
    let dismiss: () -> Void
    @State private var drafts: [Int: String]
    @State private var initialDrafts: [Int: String]
    @FocusState private var focusedSpeaker: Int?
    @State private var contactSpeaker: Int?
    @State private var showContact = false

    init(model: AppModel, preferredSpeaker: Int?, dismiss: @escaping () -> Void) {
        self.model = model
        self.preferredSpeaker = preferredSpeaker
        self.dismiss = dismiss
        let initial = Dictionary(uniqueKeysWithValues: model.speakerIDs.map {
            ($0, model.enteredSpeakerName(for: $0))
        })
        _drafts = State(initialValue: initial)
        _initialDrafts = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Label("화자 이름", systemImage: "person.2.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                Text(model.voice.vault.continuousLearningEnabled
                     ? "등록된 목소리의 이름을 직접 입력해 확인하면 이 화자의 음성으로 누적 학습해요. 새 목소리는 ‘목소리 학습’에서 등록해 주세요."
                     : "이름은 현재 대화에 적용돼요. 목소리 학습 화면에서 추가 학습할 수 있어요.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 11) {
                        ForEach(model.speakerIDs, id: \.self) { speaker in
                            HStack(spacing: 11) {
                                Text("화자 \(speaker)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AppTheme.violet)
                                    .frame(width: 54, alignment: .leading)
                                TextField("이름 입력", text: Binding(
                                    get: { drafts[speaker] ?? model.enteredSpeakerName(for: speaker) },
                                    set: { drafts[speaker] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.large)
                                .focused($focusedSpeaker, equals: speaker)
                                .onSubmit(applyNames)
                                .accessibilityLabel("화자 \(speaker) 이름")
                                Button("연락처") { contactSpeaker = speaker; showContact = true }
                                Button {
                                    drafts[speaker] = ""
                                    focusedSpeaker = speaker
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 11, weight: .medium))
                                        .frame(width: 23, height: 26)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("화자 \(speaker) 기본 이름으로 복원")
                                .accessibilityLabel("화자 \(speaker) 기본 이름으로 복원")
                            }
                            .id(speaker)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: CGFloat(min(max(model.speakerIDs.count, 1), 6)) * 43)
                .onAppear {
                    let target = preferredSpeaker ?? model.speakerIDs.first
                    if let target { proxy.scrollTo(target, anchor: .center) }
                    DispatchQueue.main.async { focusedSpeaker = target }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("빈 이름을 적용하면 ‘화자 N’으로 표시돼요.")
                Text("이름은 64자까지 저장돼요.")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Divider()
            HStack {
                Text("녹음 중에도 수정할 수 있어요.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("취소", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("적용", action: applyNames)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.speakerIDs.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(AppTheme.paper)
        .tint(AppTheme.violet)
        .environment(\.colorScheme, .light)
        .sheet(isPresented: $showContact) {
            MeetingContactsPicker(onSelect: { person in
                if let speaker = contactSpeaker { model.bindMeetingContact(person, speaker: speaker); drafts[speaker] = person.name }
            }, onClose: { showContact = false })
        }
        .onChange(of: model.speakerIDs) { _, speakers in
            if speakers.isEmpty {
                drafts = [:]
                initialDrafts = [:]
                dismiss()
                return
            }
            // New detections join the editor while each existing text field keeps
            // its local draft and focus throughout streaming transcript revisions.
            for speaker in speakers where drafts[speaker] == nil {
                let initial = model.enteredSpeakerName(for: speaker)
                initialDrafts[speaker] = initial
                drafts[speaker] = initial
            }
        }
    }

    private func applyNames() {
        guard !model.speakerIDs.isEmpty else { dismiss(); return }
        for speaker in model.speakerIDs {
            guard let draft = drafts[speaker], let initial = initialDrafts[speaker], draft != initial else { continue }
            model.confirmEnteredSpeakerName(draft, for: speaker)
        }
        dismiss()
    }
}

private struct InputLevelMeter: View {
    let level: Double
    let active: Bool

    private var fraction: Double {
        guard active else { return 0 }
        return min(1, max(0, (20 * log10(max(level, 0.00001)) + 60) / 54))
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<24, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Double(index) / 24 < fraction
                          ? AppTheme.violet
                          : AppTheme.violet.opacity(0.12))
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.linear(duration: 0.08), value: fraction)
        .accessibilityLabel("마이크 입력 음량")
        .accessibilityValue("\(Int(fraction * 100))퍼센트")
    }
}

private struct ConversationIllustration: View {
    var body: some View {
        ZStack {
            Circle().fill(AppTheme.blush).frame(width: 136, height: 136)
            illustrationCard(color: AppTheme.rose, width: 148)
                .rotationEffect(.degrees(-7))
                .offset(x: -18, y: -20)
            illustrationCard(color: AppTheme.violet, width: 135)
                .rotationEffect(.degrees(5))
                .offset(x: 24, y: 32)
        }
    }

    private func illustrationCard(color: Color, width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.fill")
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 27, height: 27)
                .background(color.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 7) {
                Capsule().fill(color.opacity(0.35)).frame(width: 36, height: 5)
                Capsule().fill(Color.black.opacity(0.08)).frame(height: 4)
                Capsule().fill(Color.black.opacity(0.06)).frame(width: 47, height: 4)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: width)
        .background(.white, in: RoundedRectangle(cornerRadius: 13))
        .shadow(color: AppTheme.violet.opacity(0.07), radius: 12, y: 5)
    }
}

private struct LectureDashboard: View {
    @ObservedObject var assistant: MeetingAssistant
    let openInput: () -> Void
    let showTranscript: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack {
                    VStack(alignment:.leading,spacing:5) {
                        Text("강의 흐름").font(.title2.bold())
                        Text(assistant.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("전사 보기",action:showTranscript)
                    Button("메모·자료 창 열기",action:openInput).buttonStyle(.borderedProminent)
                }
                HStack {
                    Toggle("실시간 요약",isOn:$assistant.enabled)
                    Button("지금 요약",action:assistant.requestSummary).disabled(assistant.busy)
                    if assistant.busy { ProgressView().controlSize(.small) }
                }
                if let error=assistant.error { Text(error).foregroundStyle(.orange).font(.caption) }
                GroupBox("현재 주제") {
                    Text(assistant.state.currentAgenda.isEmpty ? "강의 내용이 쌓이면 현재 주제를 표시해요." : assistant.state.currentAgenda)
                        .frame(maxWidth:.infinity,alignment:.leading).padding(8)
                }
                GroupBox("지금까지의 강의 요약") {
                    VStack(alignment:.leading,spacing:10) {
                        if assistant.state.summary.isEmpty { Text("요약을 준비하고 있어요.").foregroundStyle(.secondary) }
                        ForEach(assistant.state.summary) { item in
                            Text("• " + item.text + (item.stale ? " · 내용 확인 필요" : ""))
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
                }
                GroupBox("생각해 볼 질문") {
                    VStack(alignment:.leading,spacing:10) {
                        let questions=assistant.state.suggestions.filter { $0.kind == "question" && ($0.status == .active || $0.status == .review) }
                        if questions.isEmpty && assistant.state.openQuestions.isEmpty { Text("강의 맥락을 분석한 뒤 질문을 표시해요.").foregroundStyle(.secondary) }
                        ForEach(questions) { item in Text("• " + item.title + (item.stale ? " · 내용 확인 필요" : "")) }
                        ForEach(assistant.state.openQuestions) { item in Text("• " + item.text + (item.stale ? " · 내용 확인 필요" : "")) }
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
                }
                Text("반영 범위: " + MeetingMinutesRenderer.time(assistant.state.coverageSeconds)).font(.caption).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}
