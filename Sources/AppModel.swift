import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor final class AppModel: ObservableObject {
    lazy var editingChat = MeetingEditingChat(
        directory: (transcriptDirectory ?? StorageLocations.assistant).appendingPathComponent("EditingChat"),
        snapshot: { [weak self] in self?.editingSnapshot() ?? EditingSnapshot(sessionID:UUID(),documents:[]) },
        settings: { [weak self] in self?.codexSettings ?? CodexCorrectionSettings() },
        commit: { [weak self] plan,capture in
            guard let self else { throw EditingError.unavailable }
            return try self.applyEditingPlan(plan,capture:capture)
        })
    var editingSessionID: UUID { session }
    let history: MeetingHistoryStore
    @Published private(set) var reprocessingOrigin: MeetingReprocessingOrigin?
    private var loadingHistory = false
    private let transcriptDirectory: URL?
    private let preferences: UserDefaults
    @Published private(set) var transcriptEdits: [TranscriptTextEdit] = [] { didSet { cachedEditedTexts=nil; cachedManualProjection=nil } }
    @Published private(set) var transcriptUndoCount = 0
    private struct TranscriptUndoState { let text:[TranscriptTextEdit]; let manual:[ManualTranscriptEdit] }
    private var transcriptUndo: [TranscriptUndoState] = []
    @Published private(set) var manualTranscriptEdits: [ManualTranscriptEdit] = [] { didSet { cachedManualProjection=nil } }
    private var manualEditRevision=UUID()
    private var nextManualPartID = -1
    let materials: MeetingMaterials
    private var materialsObservation: AnyCancellable?
    @Published private(set) var meetingPrepared = false
    let meeting: MeetingWorkspace
    let assistant: MeetingAssistant
    private var assistantSyncKey = ""
    private var assistantAppendixKey = ""
    private var folderSettingsKey = ""
    let voice: VoiceIdentity
    private var voiceObservation: AnyCancellable?
    @Published private var voiceNameAssignments = VoiceNameAssignments()
    private var reconcilingVoiceNames = false
    @Published var phase: AppPhase = .loading
    @Published var statusMessage = "한국어 음성 모델을 준비하고 있습니다."
    @Published var errorMessage: String?
    @Published var segments: [TranscriptSegment] = [] { didSet { cachedEditedTexts=nil; cachedManualProjection=nil } }
    @Published var liveText = ""
    @Published var audioSeconds: Double = 0
    @Published var inputLevel: Double = 0
    @Published var queuedSeconds: Double = 0
    @Published var devices: [MicrophoneDevice] = []
    @Published var selectedDeviceID: UInt32 = 0
    @Published private(set) var engineSettings = EngineTuningSettings()
    @Published var speakerReviewProvider: SpeakerReviewProvider = .codex
    @Published private(set) var speakerReviewRecords: [SpeakerReviewRecord] = []
    @Published private(set) var speakerReviewStatus = "녹음·본문 교정 완료 후 검토할 수 있습니다."
    @Published private(set) var speakerReviewRunning = false
    @Published private(set) var playingReviewAudio = false
    @Published private(set) var speakerOverrides: [Int: SpeakerOverride] = [:]
    private var speakerReviewTask: Task<Void, Never>?
    private var speakerReviewRun = UUID()
    private var reviewPlayer: AVAudioPlayer?
    private var reviewAudioStop: Task<Void, Never>?
    private var sessionEngineSettings = EngineTuningSettings()
    @Published var lowLatency = false {
        didSet {
            engineSettings.rightContext = lowLatency ? 3 : 13
            if let data = try? JSONEncoder().encode(engineSettings) { preferences.set(data, forKey: "engineTuning.v1") }
        }
    }
    @Published var lastSavedURL: URL?
    @Published var sessionTitle = "새로운 대화를 기다리고 있어요"
    @Published var processingFile = false
    @Published private(set) var fileProgress: AudioFileProgress?
    @Published private(set) var speakerNames: [Int: String] = [:]
    @Published private(set) var speakerIDs: [Int] = []
    @Published private(set) var contextSettings = ContextSettings() { didSet { cachedEditedTexts=nil; cachedManualProjection=nil } }
    @Published private(set) var correctionStatus = "문맥 교정 · 발언 대기"
    @Published private(set) var corrections: [Int: SegmentCorrection] = [:] { didSet { cachedEditedTexts=nil; cachedManualProjection=nil } }
    @Published private(set) var correctingSegmentIDs: Set<Int> = []

    @Published private(set) var recognitionProvider: RecognitionProvider = .local
    @Published private(set) var hasGeminiKey = false
    @Published private(set) var cloudStatus = "Gemini 전사 · 준비"
    @Published private(set) var cloudPendingSeconds: Double = 0
    @Published private(set) var cloudSegmentIDs: Set<Int> = []
    @Published private(set) var lastDebugURL: URL?
    @Published private(set) var comparisonURL: URL?
    @Published private(set) var debugStatus = "인식 변경 기록 · 준비"
    @Published private(set) var savedAudioURL: URL?
    @Published private(set) var audioSaveStatus = "M4A 저장 · 준비"
    private var audioRecorder: SessionAudioRecorder?
    private var audioFailure: String?
    private var audioFileStatus = "ready"
    private var debugRecorder: TranscriptDebugRecorder?
    private let cloudBuffer = CloudAudioBuffer()
    private let cloudClient = GeminiTranscriber()
    private var cloudTask: Task<Void, Never>?
    private var cloudResults: [CloudResult] = []
    private var cloudSkippedChunks: [Int] = []
    private var cloudDrafts: [Int: String] = [:]
    private var cloudFailure: String?
    private var cloudInputFinal = false
    private var cloudInFlightSeconds: Double = 0
    private var localSnapshot: EngineSnapshot?
    private var sessionProvider: RecognitionProvider = .local
    private var stoppedByUser = false
    var usesGemini: Bool { recognitionProvider == .gemini }
    var canChangeRecognitionProvider: Bool { !closing && !isBusy }

    private let worker = EngineWorker()
    private let microphone = MicrophoneCapture()
    @Published private(set) var codexSettings = CodexCorrectionSettings() { didSet { cachedEditedTexts=nil; cachedManualProjection=nil } }
    @Published private(set) var codexAuthStatus = "로그인 상태 확인 중"
    @Published private(set) var codexLoginRunning = false
    @Published private(set) var codexRecords: [CodexCorrectionRecord] = []
    private var codexLoginTask: Task<Void, Never>?
    private var codexRetryCount = 0
    private var correctionTask: Task<Void, Never>?
    private var correctionRun = UUID()
    private var contextRevision = UUID()
    private var observations: [Int: (fingerprint: String, changedAt: Date)] = [:]
    private var correctionAttempts: [Int: String] = [:]
    private var correctionInputFinal = false
    private var correctionFailure: String?
    private var correctionInterrupted = false
    private var correctionResumeAfter = Date.distantPast
    private var appliedASRTerms: [String] = []
    private var session = UUID()
    private var startedAt = Date()
    private var sourceName = "microphone"
    private var pendingFailure: String?
    private var finalStatus = "completed"
    private var quitCompletion: (() -> Void)?
    private var lastDraftAt = Date.distantPast
    private var timer: Timer?
    private var testStarted = false
    private var testCompleted = false
    private var closing = false
    private var activeFilePanel: NSSavePanel?
    private var filePanelRequested = false

    var canStart: Bool { !closing && !voice.recording && !voice.busy && (phase == .ready || phase == .completed) }
    var canStop: Bool { phase == .recording }
    var canExport: Bool { !liveText.isEmpty || !segments.isEmpty }
    var isBusy: Bool { phase == .loading || phase == .recording || phase == .finishing }
    var speakerCount: Int { Set(segments.map(effectiveSpeaker).filter { $0 > 0 }).count }

    func enteredSpeakerName(for speaker: Int) -> String { speakerNames[speaker] ?? "" }

    func speakerName(for speaker: Int) -> String {
        if let name = speakerNames[speaker] { return name }
        if !voiceNameAssignments.userControlled.contains(speaker), !voice.rejectedSpeakers.contains(speaker),
           let suggestion = voice.suggestions[speaker] { return suggestion.name + " 추정" }
        return speaker > 0 ? "화자 \(speaker)" : "화자 확인 중"
    }

    func setSpeakerName(_ name: String, for speaker: Int) {
        guard !closing, speakerIDs.contains(speaker), (1...8).contains(speaker) else { return }
        let cleaned = String(name.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ").prefix(64))
        let wasAutomatic = voiceNameAssignments.automatic[speaker] != nil
        let wasControlled = voiceNameAssignments.userControlled.contains(speaker)
        if cleaned != enteredSpeakerName(for: speaker) { voice.unbindConfirmedSpeaker(speaker: speaker) }
        voiceNameAssignments.userEdited(speaker)
        guard cleaned != enteredSpeakerName(for: speaker) || wasAutomatic || !wasControlled else { return }
        speakerNames[speaker] = cleaned.isEmpty ? nil : cleaned
        if let bound = meeting.bindings.speakers[speaker], bound.name != cleaned { meeting.unbind(speaker: speaker) }
        debugRecorder?.recordSpeakerNames(speakerNames)
        syncMeetingMinutes(force: true)
        // Names belong to this session; inference snapshots only update acoustic labels.
        if canExport {
            do {
                let status = phase == .recording || phase == .finishing ? "in_progress" : finalStatus
                lastSavedURL = try SessionFiles.write(document(status: status), to: sessionDocumentURL)
                lastDraftAt = Date()
            } catch { errorMessage = "화자 이름 저장 경로를 확인해 주세요. " + error.localizedDescription }
        }
    }

    init(materials requestedMaterials: MeetingMaterials? = nil, meeting requestedMeeting: MeetingWorkspace? = nil,
         assistant requestedAssistant: MeetingAssistant? = nil, loadEngine: Bool = true,
         voice requestedVoice: VoiceIdentity? = nil, history requestedHistory: MeetingHistoryStore? = nil,
         transcriptDirectory: URL? = nil, startBackgroundServices: Bool = true,
         preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.voice = requestedVoice ?? VoiceIdentity()
        self.history = requestedHistory ?? MeetingHistoryStore()
        self.transcriptDirectory = transcriptDirectory
        self.materials = requestedMaterials ?? MeetingMaterials()
        self.meeting = requestedMeeting ?? MeetingWorkspace()
        self.assistant = requestedAssistant ?? MeetingAssistant()
        self.meeting.materialContext=self.materials.context
        self.assistant.resetForNewSession()
        materialsObservation=materials.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        materials.didChange={ [weak self] in
            guard let self, !self.loadingHistory else { return }
            self.contextRevision=UUID();self.cancelCorrections()
            self.meeting.materialContext=self.materials.context
            self.syncMeetingMinutes(force:true)
            self.persistCurrentTranscript()
        }

        voiceObservation = voice.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        voice.didChange = { [weak self] in
            guard let self, !self.reconcilingVoiceNames else { return }
            self.reconcileVoiceNames()
            self.persistCurrentTranscript()
        }
        voice.didEnroll = { [weak self] speaker, name in self?.setSpeakerName(name, for: speaker) }

        speakerReviewProvider = SpeakerReviewProvider(rawValue: preferences.string(forKey: "speakerReviewProvider.v1") ?? "codex") ?? .codex
        if let data = preferences.data(forKey: "engineTuning.v1"),
           let tuning = try? JSONDecoder().decode(EngineTuningSettings.self, from: data), tuning.valid { engineSettings = tuning }
        lowLatency = engineSettings.rightContext == 3
        hasGeminiKey = startBackgroundServices ? GeminiCredentials.hasKey : false
        recognitionProvider = RecognitionProvider(rawValue: preferences.string(forKey: "recognitionProvider.v1") ?? "local") ?? .local
        if CommandLine.arguments.contains("--test-gemini") { recognitionProvider = .gemini }
        if CommandLine.arguments.contains("--test-local") { recognitionProvider = .local }
        if let data = preferences.data(forKey: "contextSettings.v1"),
           let saved = try? JSONDecoder().decode(ContextSettings.self, from: data) { contextSettings = saved }
        if CommandLine.arguments.contains("--test-context") {
            contextSettings = ContextSettings(enabled: true, topic: argument("--test-topic") ?? "한국어 회의 기록",
                terms: argument("--test-terms") ?? "")
        } else if CommandLine.arguments.contains("--test-no-context") { contextSettings.enabled = false }
        if let data = preferences.data(forKey: "codexCorrection.v1"),
           let saved = try? JSONDecoder().decode(CodexCorrectionSettings.self, from: data) {
            codexSettings = saved
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["mode"] as? String == "local", let migrated = try? JSONEncoder().encode(saved) {
                preferences.set(migrated, forKey: "codexCorrection.v1")
            }
        } else {
            // This upgrade enables the requested local ASR + ChatGPT correction path.
            recognitionProvider = .local
            preferences.set("local", forKey: "recognitionProvider.v1")
            if let data = try? JSONEncoder().encode(codexSettings) { preferences.set(data, forKey: "codexCorrection.v1") }
        }
        contextSettings.enabled = codexSettings.mode != .off
        if CommandLine.arguments.contains("--test-no-context") { codexSettings.mode = .off; contextSettings.enabled = false }
        if CommandLine.arguments.contains("--test-gemini") { recognitionProvider = .gemini }
        if CommandLine.arguments.contains("--test-local") { recognitionProvider = .local }
        if CommandLine.arguments.contains("--test-context") { codexSettings.mode = .off; contextSettings.enabled = false }
        if startBackgroundServices {
            refreshCodexLogin()
            refreshDevices()
            materials.resumeFolderWatching(provider: meeting.provider, settings: codexSettings)
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.runPeriodicTasks() }
            }
        }
        if loadEngine { reloadEngine() }
    }

    func runPeriodicTasks() {
        checkAudioRecording()
        let backlog = worker.backlogSeconds
        if queuedSeconds != backlog { queuedSeconds = backlog }
        let cloudPending = cloudBuffer.bufferedSeconds + cloudInFlightSeconds
        if cloudPendingSeconds != cloudPending { cloudPendingSeconds = cloudPending }
        scheduleCorrection()
        syncMeetingMinutes()
        meeting.tick()
        if !closing { assistant.tick() }
    }

    func refreshDevices() {
        do {
            devices = try MicrophoneCapture.devices()
            if selectedDeviceID != 0 && !devices.contains(where: { $0.id == selectedDeviceID }) { selectedDeviceID = 0 }
        } catch { errorMessage = error.localizedDescription }
    }

    func reloadEngine() {
        guard phase != .recording && phase != .finishing else { return }
        phase = .loading; errorMessage = nil
        statusMessage = "한국어 음성 모델을 준비하고 있습니다."
        worker.load(lowLatency: lowLatency, tuning: engineSettings) { [weak self] result in
            guard let self, !self.closing else { return }
            switch result {
            case .success:
                self.phase = .ready
                self.statusMessage = "새 회의를 만들고 자료·목적·참석자를 준비하세요."
                self.runRequestedTest()
            case .failure(let error): self.fail(error)
            }
        }
    }

    func start() {
        guard canStart,meetingPrepared else { return }
        switch MicrophoneCapture.authorizationStatus {
        case .authorized: beginMicrophone()
        case .notDetermined:
            phase = .loading; statusMessage = "마이크 사용 권한을 확인하고 있습니다."
            MicrophoneCapture.requestAccess { [weak self] granted in
                guard let self else { return }
                if granted { self.beginMicrophone() }
                else { self.fail(MicrophoneCaptureError.permissionRequired) }
            }
        default: fail(MicrophoneCaptureError.permissionRequired)
        }
    }

    @discardableResult private func resetSession(title: String, source: String, recordFromEngine: Bool = false, prepareOnly: Bool = false) -> Bool {
        cancelSpeakerReview(); stopReviewAudio()
        cancelCorrections()
        correctionInterrupted = true
        finishAudioRecording()
        finishDebugRecording()
        if canExport && !persistCurrentTranscript() { return false }
        assistant.resetForNewSession()
        assistantSyncKey="";assistantAppendixKey=""
        reprocessingOrigin=nil
        cancelCloud()
        sessionProvider = recognitionProvider
        sessionEngineSettings = engineSettings
        cloudResults = []; cloudSkippedChunks = []; cloudDrafts = [:]; cloudSegmentIDs = []
        localSnapshot = nil; cloudFailure = nil; cloudInputFinal = false; stoppedByUser = false
        session = UUID(); reconcilingVoiceNames = true
        voice.reset(session: session); voiceNameAssignments = VoiceNameAssignments()
        reconcilingVoiceNames = false; startedAt = Date(); sourceName = source
        meeting.begin(id: session)
        sessionTitle = title; segments = []; liveText = ""; audioSeconds = 0
        speakerNames = [:]; speakerIDs = []
        transcriptEdits = []; manualTranscriptEdits = []; manualEditRevision=UUID(); nextManualPartID = -1; transcriptUndo = []; transcriptUndoCount = 0
        corrections = [:]; correctionAttempts = [:]; observations = [:]
        codexRecords = []; codexRetryCount = 0
        speakerReviewRecords = []; speakerOverrides = [:]
        speakerReviewStatus = "녹음·본문 교정 완료 후 검토할 수 있습니다."
        correctionInputFinal = false; correctionFailure = nil; correctionInterrupted = false
        correctionResumeAfter = .distantPast
        appliedASRTerms = referenceTerms
        inputLevel = 0; queuedSeconds = 0; lastSavedURL = nil; fileProgress = nil
        errorMessage = nil; pendingFailure = nil; finalStatus = "in_progress"; lastDraftAt = .distantPast
        audioRecorder=nil; savedAudioURL=nil; debugRecorder=nil; lastDebugURL=nil; comparisonURL=nil
        audioFailure=nil; audioFileStatus="ready"; audioSaveStatus="M4A 저장 · 녹음 시작 대기"
        debugStatus="인식 변경 기록 · 녹음 시작 대기"
        if prepareOnly { meetingPrepared=true;phase = .ready;return true }
        meetingPrepared=false
        return beginSessionAudio(recordFromEngine:recordFromEngine)
    }
    private func beginSessionAudio(recordFromEngine:Bool=false) -> Bool {
        sessionProvider=recognitionProvider;sessionEngineSettings=engineSettings;appliedASRTerms=referenceTerms
        beginDebugRecording()
        guard beginAudioRecording() else { return false }
        let recordCloud = sessionProvider == .gemini
        worker.setAudioObserver { [cloudBuffer, recorder = audioRecorder, voiceAudio = voice.audio] id, samples in
            voiceAudio.append(samples, session: id)
            if recordCloud { cloudBuffer.append(session: id, samples: samples) }
            if recordFromEngine { recorder?.append(samples) }
        }
        if sessionProvider == .gemini { startCloud() }
        return true
    }

    private func beginMicrophone() {
        guard !closing else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "M월 d일 HH:mm 대화"
        guard meetingPrepared else { return }
        startedAt=Date();if sessionTitle == "새 회의" { sessionTitle=formatter.string(from:Date()) }
        guard beginSessionAudio() else { return }
        meetingPrepared=false
        processingFile = false; phase = .loading; statusMessage = "마이크를 연결하고 있습니다."
        let id = session
        worker.begin(id, lowLatency: lowLatency, phrases: appliedASRTerms, tuning: sessionEngineSettings) { [weak self] result in
            guard let self, !self.closing, self.session == id else { return }
            switch result {
            case .failure(let error): self.fail(error)
            case .success:
                do {
                    try self.microphone.start(deviceID: self.selectedDeviceID == 0 ? nil : self.selectedDeviceID,
                        onAudio: { [weak self, worker = self.worker, recorder = self.audioRecorder] samples in
                            recorder?.append(samples)
                            let accepted = worker.submit(samples, session: id, onSnapshot: { snapshot in
                                guard let self, self.session == id else { return }
                                self.apply(snapshot)
                            }, onError: { error in
                                guard let self, self.session == id else { return }
                                self.stopAfterFailure(error)
                            })
                            if !accepted {
                                DispatchQueue.main.async {
                                    self?.stopAfterFailure(AppFailure(message: "음성 처리 대기가 8초를 초과했습니다. 현재까지의 발언을 저장합니다. 다른 작업을 줄이거나 빠른 응답 설정을 꺼 주세요."))
                                }
                            }
                        }, onLevel: { [weak self] level in
                            DispatchQueue.main.async { if self?.session == id { self?.inputLevel = Double(level) } }
                        }, onError: { [weak self] error in
                            DispatchQueue.main.async { if self?.session == id { self?.stopAfterFailure(error) } }
                        })
                    self.phase = .recording; self.statusMessage = "듣고 있습니다 · 발언과 화자를 실시간으로 정리합니다."
                } catch {
                    self.pendingFailure = error.localizedDescription
                    self.phase = .recording
                    self.stop()
                }
            }
        }
    }

    private func apply(_ snapshot: EngineSnapshot) {
        localSnapshot = snapshot
        debugRecorder?.recordLocal(snapshot: snapshot)
        // The model can emit a padded final token beyond the captured audio.
        let duration = max(0, snapshot.audioSeconds)
        segments = snapshot.segments.map { segment in
            let start = min(duration, max(0, segment.startTime))
            let end = min(duration, max(start, segment.endTime))
            return TranscriptSegment(id: segment.id, speaker: segment.speaker,
                startTime: start, endTime: end, text: segment.text)
        }
        if sessionProvider == .gemini, !cloudResults.isEmpty {
            let projection = HybridTranscript.project(local: snapshot, results: cloudResults)
            segments = projection.segments
            cloudSegmentIDs = projection.cloudIDs
            cloudDrafts = projection.localDrafts
            liveText = segments.map(\.text).joined(separator: " ")
        } else { liveText = snapshot.text }
        audioSeconds = duration
        let discovered = Set(segments.map(\.speaker) + snapshot.words.map(\.speaker))
            .filter { (1...8).contains($0) }
        let knownSpeakers = Set(speakerIDs).union(discovered).sorted()
        if knownSpeakers != speakerIDs { speakerIDs = knownSpeakers }
        voice.receive(voiceSnapshot(snapshot))
        reconcileVoiceNames()
        correctionInputFinal = snapshot.isFinal
        let now = Date()
        let validIDs = Set(segments.map(\.id))
        observations = observations.filter { validIDs.contains($0.key) }
        for segment in segments {
            let key = fingerprint(segment)
            if observations[segment.id]?.fingerprint != key {
                observations[segment.id] = (key, now)
                corrections[segment.id] = nil
            }
        }
        corrections = corrections.filter { validIDs.contains($0.key) }
        scheduleCorrection()
        if canExport && Date().timeIntervalSince(lastDraftAt) >= 10 {
            do {
                lastSavedURL = try SessionFiles.write(document(status: "in_progress"), to: sessionDocumentURL)
                lastDraftAt = Date()
            } catch { errorMessage = "임시 저장 경로를 확인해 주세요. " + error.localizedDescription }
        }
    }

    func stop() {
        guard phase == .recording else { return }
        phase = .finishing; statusMessage = "마지막 발언과 화자를 정리하고 저장합니다."
        if processingFile { worker.cancelFile(); return }
        let id = session
        microphone.stop { [weak self] in
            guard let self else { return }
            self.worker.finish(session: id) { [weak self] result in
                guard let self, self.session == id else { return }
                switch result {
                case .success(let snapshot): self.complete(snapshot, stopped: false)
                case .failure(let error): self.fail(error, preserve: true)
                }
            }
        }
    }

    private func stopAfterFailure(_ error: Error) {
        guard phase == .recording || phase == .finishing else { return }
        pendingFailure = error.localizedDescription; errorMessage = pendingFailure
        if phase == .recording { stop() }
    }

    func importAudio() {
        guard canStart, activeFilePanel == nil, !filePanelRequested else { return }
        // A button/accessibility action can arrive before AppKit promotes the visible
        // main window. Resolve that window instead of silently dropping the request.
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }),
              window.attachedSheet == nil else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let selectionSession = session
        filePanelRequested = true
        // Return from the SwiftUI action before creating the AppKit panel.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            defer { self.filePanelRequested = false }
            guard let window, window.attachedSheet == nil, self.activeFilePanel == nil,
                  self.canStart, self.session == selectionSession else { return }
            let panel = NSOpenPanel()
            panel.title = "전사할 음성 파일 선택"
            panel.allowedContentTypes = [.audio]
            panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
            panel.canChooseFiles = true
            self.activeFilePanel = panel
            panel.beginSheetModal(for: window) { [weak self, weak panel] response in
                guard let self, let panel, self.activeFilePanel === panel else { return }
                self.activeFilePanel = nil
                guard response == .OK, let url = panel.url, !self.closing else { return }
                guard self.canStart, self.session == selectionSession else {
                    self.errorMessage = "현재 대화가 끝난 뒤 음성 파일을 다시 선택해 주세요."
                    return
                }
                // Let the native file sheet dismiss before saving the prior session
                // and setting up the next audio stream on the main actor.
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closing, self.canStart, self.session == selectionSession else { return }
                    self.processFile(url)
                }
            }
        }
    }

    private func processFile(_ url: URL) {
        guard resetSession(title: url.deletingPathExtension().lastPathComponent, source: url.lastPathComponent, recordFromEngine: true) else { return }
        processingFile = true; phase = .recording
        fileProgress = AudioFileProgress(stage: .preparingEngine, processedSeconds: 0, totalSeconds: nil)
        statusMessage = fileProgress!.statusText
        let id = session
        worker.transcribeFile(url, session: id, lowLatency: lowLatency, phrases: appliedASRTerms, tuning: sessionEngineSettings,
            shouldPauseAudio: sessionProvider == .gemini ? { [cloudBuffer] _ in
                cloudBuffer.failure == nil && cloudBuffer.bufferedSeconds >= Double(CloudAudioBuffer.filePauseSeconds)
            } : nil, onProgress: { [weak self] progress in
            guard let self, self.session == id, self.processingFile, self.phase == .recording else { return }
            self.fileProgress = progress
            self.statusMessage = progress.statusText
        }, onSnapshot: { [weak self] snapshot in
            guard let self, self.session == id else { return }
            self.apply(snapshot)
        }, completion: { [weak self] result in
            guard let self, self.session == id else { return }
            switch result {
            case .success(let (snapshot, stopped)): self.complete(snapshot, stopped: stopped)
            case .failure(let error): self.fail(error, preserve: true)
            }
        })
        if CommandLine.arguments.contains("--test-cancel-immediately") { stop() }
    }

    private func complete(_ snapshot: EngineSnapshot, stopped: Bool) {
        apply(snapshot); inputLevel = 0; queuedSeconds = 0
        finishAudioRecording()
        stoppedByUser = stopped
        cloudInputFinal = true
        cloudBuffer.finish(session: session)
        processingFile = false; fileProgress = nil
        if sessionProvider == .gemini, cloudTask != nil, cloudFailure == nil, !closing {
            phase = .finishing
            statusMessage = "마지막 Gemini 전사 결과를 받아 저장합니다."
            persistCurrentTranscript()
            return
        }
        finalizeSession()
    }

    private func finalizeSession() {
        finishAudioRecording()
        finishDebugRecording()
        do {
            finalStatus = pendingFailure == nil ? (stoppedByUser ? "stopped" : "completed") : "partial"
            lastSavedURL = try SessionFiles.write(document(status: finalStatus), to: sessionDocumentURL)
            if let pendingFailure {
                phase = .failed; errorMessage = pendingFailure
                statusMessage = "현재까지의 발언을 저장했습니다."
            } else {
                phase = .completed
                statusMessage = cloudFailure != nil ? "로컬 전사로 보완해 저장했습니다 · Gemini 연결 상태를 확인해 주세요." :
                    (!cloudSkippedChunks.isEmpty ? "Gemini 전사와 로컬로 보존한 \(cloudSkippedChunks.count)개 구간을 함께 저장했습니다." :
                    (stoppedByUser ? "중지한 지점까지 저장했습니다." : "전사가 완료되었습니다 · JSON 자동 저장 완료"))
            }
            finishTestWhenCorrectionsSettle()
        } catch { fail(error, preserve: false) }
        syncMeetingMinutes(force: true)
        scheduleCorrection()
        finishQuitIfNeeded()
    }

    private func fail(_ error: Error, preserve: Bool = false) {
        finishAudioRecording()
        debugRecorder?.recordFailure(message: error.localizedDescription, detailsJSON: "{\"source\":\"audio_pipeline\"}")
        finishDebugRecording()
        if cloudTask != nil { cloudFailure = "음성 입력 중단 · 로컬 초안 보존" }; cancelCloud()
        finalStatus = "partial"
        if preserve && canExport { lastSavedURL = try? SessionFiles.write(document(status: "partial"), to: sessionDocumentURL) }
        phase = .failed; errorMessage = error.localizedDescription
        statusMessage = "입력과 설정을 확인한 뒤 다시 준비해 주세요."
        inputLevel = 0; processingFile = false; fileProgress = nil
        finishRequestedTest(success: false)
        finishQuitIfNeeded()
    }

    private var sessionDocumentURL: URL? { testOutputURL ?? transcriptDirectory?.appendingPathComponent(session.uuidString + ".json") }

    private func document(status: String) -> TranscriptDocument {
        let iso = ISO8601DateFormatter()
        var value = TranscriptDocument(session_id: session.uuidString, title: sessionTitle,
            started_at: iso.string(from: startedAt), saved_at: iso.string(from: Date()),
            source: sourceName, status: status, duration_seconds: audioSeconds, text: segments.isEmpty ? liveText : visibleSegments.map { displayedText(for:$0) }.joined(separator:" "),
            corrected_text: segments.isEmpty ? liveText : visibleSegments.map { displayedText(for: $0) }.joined(separator: " "),
            context: SavedContext(enabled: codexSettings.mode != .off && contextSettings.enabled, topic: contextSettings.topic,
                terms: contextSettings.phrases, applied_asr_terms: appliedASRTerms,
                correction_model: codexSettings.mode == .codex ? codexSettings.model : "", correction_status: correctionDocumentStatus),
            speakers: speakerIDs.map { SavedSpeaker(speaker: $0, name: speakerNames[$0]) },
            segments: visibleSegments.map { SavedSegment(id: $0.id, speaker: effectiveSpeaker($0), speaker_name: speakerNames[effectiveSpeaker($0)],
                start_time: $0.startTime, end_time: $0.endTime, text: wasManuallyEdited($0) ? displayedText(for:$0) : $0.text,
                corrected_text: wasManuallyEdited($0) ? displayedText(for:$0) : corrections[$0.id]?.correctedText,
                correction_seconds: corrections[$0.id]?.elapsedSeconds,
                correction_status: corrections[$0.id].map { $0.accepted ? ($0.originalText == $0.correctedText ? "unchanged" : "corrected") : "original_retained" },
                correction_note: corrections[$0.id]?.rejectionReason,
                recognition_provider: manualProjection.lockedIDs.contains($0.id) ? "manual" : isReprocessing ? "saved-transcript" : cloudSegmentIDs.contains($0.id) ? "gemini-3.5-transcribe" : "nvidia-local",
                local_draft: cloudDrafts[$0.id], proposed_text: corrections[$0.id]?.proposedText,
                correction_provider: corrections[$0.id]?.provider, correction_model: corrections[$0.id]?.model, reference_ids: corrections[$0.id]?.referenceIDs, acoustic_speaker: manualProjection.acousticSpeakers[$0.id] ?? $0.speaker) })
        value.transcript_edits = transcriptEdits
        value.manual_transcript_edits = manualTranscriptEdits
        value.reprocessing_origin = reprocessingOrigin
        value.meeting_materials = materials.context
        value.voice_identity = voice.export
        value.voice_name_assignments = voiceNameAssignments.export
        value.meeting_minutes = meeting.metadata
        if assistant.state.sessionID == session { value.meeting_assistant = assistant.state }
        value.speaker_reviews = speakerReviewRecords
        value.speaker_overrides = speakerOverrides
        value.engine_settings = sessionEngineSettings
        value.correction = SavedCorrectionState(settings: codexSettings, status: correctionDocumentStatus,
            error: correctionFailure, pending_segment_ids: remainingCorrections.map(\.id),
            review_segment_ids: corrections.filter { $0.value.proposedText != nil && !$0.value.accepted }.keys.sorted())
        value.codex_corrections = codexRecords
        value.recognition = SavedRecognition(provider: isReprocessing ? "history" : sessionProvider.rawValue,
            model: isReprocessing ? "saved-transcript" : sessionProvider == .gemini ? GeminiTranscriber.modelName : "nemotron-3.5-asr-streaming-0.6b",
            diarization: isReprocessing ? "saved-speaker-assignments" : "NVIDIA Nemotron-3-Diarization / local Metal",
            status: isReprocessing ? "restored" : recognitionDocumentStatus,
            error: cloudFailure ?? (cloudSkippedChunks.isEmpty ? nil : "\(cloudSkippedChunks.count)개 구간은 응답 검증 기록과 함께 로컬 결과로 보존했습니다."),
            completed_chunks: cloudResults.count,
            request_seconds: cloudResults.map { $0.transcript.elapsedSeconds },
            local_fallback_chunks: cloudSkippedChunks)
        if sessionProvider == .gemini {
            value.local_draft_text = localSnapshot?.text
            value.local_draft_segments = localSnapshot?.segments
        }
        if let recorder = audioRecorder {
            value.audio_file = SavedAudioFile(path: audioArtifactURL?.path ?? recorder.url.path, format: "m4a", codec: "aac",
                sample_rate: Int(SessionAudioRecorder.sampleRate), channels: 1, bit_rate: SessionAudioRecorder.bitRate,
                duration_seconds: recorder.capturedSeconds, status: audioFileStatus, error: audioFailure)
        } else if let savedAudioURL {
            value.audio_file = SavedAudioFile(path:savedAudioURL.path,format:savedAudioURL.pathExtension,
                codec:"aac",sample_rate:Int(SessionAudioRecorder.sampleRate),channels:1,
                bit_rate:SessionAudioRecorder.bitRate,duration_seconds:audioSeconds,status:"referenced",error:nil)
        }
        if let recorder = debugRecorder {
            value.diagnostics = SavedDiagnostics(event_log: recorder.logURL.path,
                comparison: recorder.comparisonURL.path, status: debugStatus,
                cloud_target_seconds: CloudAudioBuffer.targetSeconds,
                cloud_maximum_seconds: CloudAudioBuffer.maximumSeconds)
        } else if let lastDebugURL, let comparisonURL {
            value.diagnostics = SavedDiagnostics(event_log:lastDebugURL.path,comparison:comparisonURL.path,
                status:"source_reference",cloud_target_seconds:CloudAudioBuffer.targetSeconds,
                cloud_maximum_seconds:CloudAudioBuffer.maximumSeconds)
        }
        return value
    }

    func saveJSON() {
        guard canExport, !closing, activeFilePanel == nil, !filePanelRequested,
              let window = NSApp.mainWindow ?? NSApp.keyWindow,
              window.attachedSheet == nil else { return }
        let exportSession = session
        filePanelRequested = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            defer { self.filePanelRequested = false }
            guard let window, window.attachedSheet == nil, self.activeFilePanel == nil,
                  self.canExport, !self.closing, self.session == exportSession else { return }
            let panel = NSSavePanel()
            panel.title = "화자별 전사 JSON 저장"; panel.allowedContentTypes = [.json]
            panel.directoryURL = SessionFiles.directory
            panel.nameFieldStringValue = self.sessionTitle.replacingOccurrences(of: "/", with: "-") + ".json"
            self.activeFilePanel = panel
            panel.beginSheetModal(for: window) { [weak self, weak panel] response in
                guard let self, let panel, self.activeFilePanel === panel else { return }
                self.activeFilePanel = nil
                guard response == .OK, let url = panel.url, !self.closing else { return }
                guard self.canExport, self.session == exportSession else {
                    self.errorMessage = "저장할 대화가 변경되었습니다. 현재 대화에서 JSON 저장을 다시 선택해 주세요."
                    return
                }
                do {
                    let status = self.phase == .recording || self.phase == .finishing ? "in_progress" : self.finalStatus
                    self.lastSavedURL = try SessionFiles.write(self.document(status: status), to: url)
                } catch { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func copyTranscript() {
        let text = segments.isEmpty ? liveText : visibleSegments.map {
            "[\(Self.time($0.startTime))–\(Self.time($0.endTime))] \(speakerName(for: effectiveSpeaker($0)))\(speakerNames[effectiveSpeaker($0)] == nil ? "" : " (화자 \(effectiveSpeaker($0)))"): \(displayedText(for: $0))"
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    func revealLastSave() { if let lastSavedURL { NSWorkspace.shared.activateFileViewerSelecting([lastSavedURL]) } }
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
    }
    func prepareToQuit(_ completion: @escaping () -> Void) {
        closing = true
        editingChat.cancel()
        assistant.cancel()
        materials.cancel()
        voice.close()
        cancelSpeakerReview(); stopReviewAudio()
        if cloudTask != nil { cloudFailure = "앱 종료 · 로컬 초안과 수신한 Gemini 결과 보존" }
        cancelCloud()
        cancelCorrections()
        if phase != .recording && phase != .finishing { finishAudioRecording(); finishDebugRecording() }
        persistCurrentTranscript()
        if phase == .finishing && cloudInputFinal {
            quitCompletion = completion
            finalizeSession()
            return
        }
        if phase == .recording || phase == .finishing {
            quitCompletion = completion
            if phase == .recording { stop() }
        } else { shutdownEngines(completion) }
    }
    private func finishQuitIfNeeded() {
        if let completion = quitCompletion {
            quitCompletion = nil
            shutdownEngines(completion)
        }
    }

    var conversationTurns: [ConversationTurn] { ConversationTurn.grouped(visibleSegments, speaker: effectiveSpeaker, breakBefore: manualProjection.breakIDs) }

    func displayedText(for turn: ConversationTurn) -> String {
        turn.segments.map { displayedText(for: $0) }.joined(separator: " ")
    }

    func localDraftText(for turn: ConversationTurn) -> String {
        if turn.segments.contains(where: { manualProjection.lockedIDs.contains($0.id) }) {
            var seen=Set<UUID>()
            return turn.segments.compactMap { segment in
                guard let edit=manualTranscriptEdits.first(where:{$0.parts.contains(where:{$0.id==segment.id})}), seen.insert(edit.id).inserted else { return nil }
                return edit.sourceText
            }.joined(separator:" ")
        }
        if turn.segments.contains(where: { effectiveSpeaker($0) != $0.speaker }) {
            return turn.segments.map { cloudDrafts[$0.id] ?? $0.text }.joined(separator: " ")
        }
        guard let localSnapshot else { return turn.segments.map(\.text).joined(separator: " ") }
        if !localSnapshot.words.isEmpty {
            return localSnapshot.words.filter {
                let midpoint = ($0.start + $0.end) / 2
                return midpoint >= turn.start && midpoint <= turn.end && $0.speaker == turn.speaker
            }.map(\.text).joined(separator: " ")
        }
        return localSnapshot.segments.filter {
            $0.endTime > turn.start && $0.startTime < turn.end && $0.speaker == turn.speaker
        }.map(\.text).joined(separator: " ")
    }

    func recognitionLabel(for turn: ConversationTurn) -> String {
        if turn.segments.contains(where: { manualProjection.lockedIDs.contains($0.id) }) { return "수동 교정 · 화자 확정" }
        if turn.segments.contains(where:wasManuallyEdited) { return "사용자 편집 적용" }
        if isReprocessing {
            let providers=Set(turn.segments.compactMap { corrections[$0.id]?.accepted == true ? corrections[$0.id]?.provider : nil })
            return providers.isEmpty ? "저장된 전사" : "저장된 전사 · " + (providers.contains(where: { AITextProvider(rawValue:$0) != nil }) ? "AI" : "로컬") + " 재교정"
        }
        let cloudCount = turn.segments.filter { cloudSegmentIDs.contains($0.id) }.count
        if turn.segments.contains(where: { AITextProvider(rawValue: corrections[$0.id]?.provider ?? "") != nil && corrections[$0.id]?.accepted == true }) {
            return cloudCount > 0 ? "Gemini + AI 교정" : "로컬 전사 + AI 교정"
        }
        if cloudCount == turn.segments.count { return "Gemini 전사" }
        if cloudCount > 0 { return "Gemini 전사 · 이어지는 로컬 초안" }
        return sessionProvider == .gemini ? "로컬 초안 · Gemini 대기" : "로컬 전사"
    }

    private func correctedBaseText(for segment: TranscriptSegment) -> String {
        guard contextSettings.enabled, codexSettings.mode != .off, let value = corrections[segment.id],
              value.sourceFingerprint == fingerprint(segment) else { return segment.text }
        return value.correctedText
    }

    private var cachedEditedTexts: [Int:String]?
    private var editedTexts: [Int:String] {
        if let cachedEditedTexts { return cachedEditedTexts }
        let result=TranscriptTextProjection.render(segments:segments,words:localSnapshot?.words ?? [],edits:transcriptEdits,base:correctedBaseText)
        cachedEditedTexts=result
        return result
    }
    private var cachedManualProjection: ManualTranscriptProjection?
    private var manualProjection: ManualTranscriptProjection {
        if let cachedManualProjection { return cachedManualProjection }
        let texts=editedTexts
        let value=ManualTranscriptProjection.render(segments:segments, words:localSnapshot?.words ?? [], edits:manualTranscriptEdits,
            base:{ texts[$0.id] ?? $0.text })
        cachedManualProjection=value
        return value
    }
    var visibleSegments: [TranscriptSegment] { manualProjection.segments }
    func displayedText(for segment: TranscriptSegment) -> String {
        manualProjection.texts[segment.id] ?? editedTexts[segment.id] ?? correctedBaseText(for:segment)
    }
    private func wasManuallyEdited(_ segment: TranscriptSegment) -> Bool {
        manualProjection.lockedIDs.contains(segment.id) || transcriptEdits.contains { $0.overlaps(segment) }
    }

    func updateContextSettings(enabled: Bool, topic: String, terms: String) {
        guard !closing else { return }
        let value = ContextSettings(enabled: enabled,
            topic: String(topic.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600)),
            terms: String(terms.prefix(6000)))
        guard value != contextSettings || correctionFailure != nil else { return }
        cancelCorrections()
        contextSettings = value
        corrections = [:]; correctionAttempts = [:]; correctionFailure = nil
        if let data = try? JSONEncoder().encode(value) { preferences.set(data, forKey: "contextSettings.v1") }
        persistCurrentTranscript()
        scheduleCorrection()
    }

    private func fingerprint(_ segment: TranscriptSegment) -> String {
        "\(segment.id)|\(segment.speaker)|\(segment.startTime)|\(segment.endTime)|\(segment.text)"
    }

    private func cancelCorrections() {
        cancelSpeakerReview()
        contextRevision = UUID()
        correctionTask?.cancel()
        correctingSegmentIDs = []
    }

    private var remainingCorrections: [TranscriptSegment] {
        visibleSegments.filter { !wasManuallyEdited($0) && correctionAttempts[$0.id] != fingerprint($0) }
    }

    private var correctionDocumentStatus: String {
        if codexSettings.mode == .codex { return correctionFailure == nil ? ((correctionTask != nil || !remainingCorrections.isEmpty) ? "pending" : "completed") : "waiting_retry" }
        if sessionProvider == .gemini && !isReprocessing { return "cloud_transcription" }
        if !contextSettings.enabled { return "disabled" }
        if correctionFailure != nil { return "failed" }
        if closing || correctionInterrupted { return remainingCorrections.isEmpty ? "completed" : "interrupted" }
        if correctionTask != nil || !remainingCorrections.isEmpty { return "pending" }
        return correctionInputFinal ? "completed" : "listening"
    }

    @discardableResult private func persistCurrentTranscript() -> Bool {
        guard canExport else { return true }
        syncMeetingMinutes(force: true)
        do {
            let status = phase == .recording || phase == .finishing ? "in_progress" : finalStatus
            lastSavedURL = try SessionFiles.write(document(status: status), to: sessionDocumentURL)
            lastDraftAt = Date()
            return true
        } catch { errorMessage = "전사 저장 경로를 확인해 주세요. " + error.localizedDescription; return false }
    }

    private func updateCorrectionStatus(_ status: String) {
        if correctionStatus != status { correctionStatus = status }
    }

    private func scheduleCorrection() {
        guard !speakerReviewRunning, !closing else { return }
        if codexSettings.mode == .codex { scheduleCodexCorrection(); return }
        updateCorrectionStatus("문맥 교정 꺼짐 · 음성 인식 원문 표시")
        finishTestWhenCorrectionsSettle()
    }

    private func finishCorrectionRun(_ run: UUID) {
        guard run == correctionRun else { return }
        correctionTask = nil; correctingSegmentIDs = []
        if correctionInputFinal { persistCurrentTranscript(); finishDebugRecording() }
        scheduleCorrection()
    }

    private func finishTestWhenCorrectionsSettle() {
        guard phase == .completed, argument("--test-file") != nil else { return }
        guard (sessionProvider == .gemini && codexSettings.mode != .codex) || !contextSettings.enabled || correctionFailure != nil ||
                (correctionTask == nil && remainingCorrections.isEmpty) else { return }
        persistCurrentTranscript()
        finishRequestedTest(success: correctionFailure == nil && cloudFailure == nil && cloudSkippedChunks.isEmpty)
    }

    private func shutdownEngines(_ completion: @escaping () -> Void) {
        closing = true
        cancelSpeakerReview(); stopReviewAudio()
        codexLoginTask?.cancel()
        correctionTask?.cancel()
        cancelCloud()
        syncMeetingMinutes(force: true)
        Task {
            await meeting.finish()
            worker.shutdown(completion: completion)
        }
    }

    func localDraftText(for segment: TranscriptSegment) -> String? { cloudDrafts[segment.id] }

    @discardableResult func updateCloudSettings(provider: RecognitionProvider, apiKey: String) -> Bool {
        guard canChangeRecognitionProvider else { return false }
        do {
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try GeminiCredentials.save(apiKey) }
            hasGeminiKey = GeminiCredentials.hasKey
            if provider == .gemini && !hasGeminiKey { throw GeminiTranscriberError.missingKey }
            recognitionProvider = provider
            preferences.set(provider.rawValue, forKey: "recognitionProvider.v1")
            if provider == .gemini && codexSettings.mode != .codex { cancelCorrections() }
            errorMessage = nil
            cloudStatus = provider == .gemini ? "Gemini 준비 완료 · 로컬 화자 분리" : "로컬 전사 준비 완료"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func removeGeminiKey() {
        guard canChangeRecognitionProvider else { return }
        do {
            try GeminiCredentials.delete(); hasGeminiKey = false
            recognitionProvider = .local
            preferences.set("local", forKey: "recognitionProvider.v1")
            cloudStatus = "키 삭제 완료 · 로컬 전사"
        } catch { errorMessage = error.localizedDescription }
    }

    private func startCloud() {
        cloudBuffer.begin(session: session)
        let id = session
        cloudStatus = "Gemini 문맥 전사 · 약 \(Int(CloudAudioBuffer.targetSeconds))초 구간을 모으고 있습니다"
        cloudTask = Task { [weak self, cloudClient] in
            while !Task.isCancelled {
                guard let self, self.session == id, !self.closing else { return }
                if let failure = self.cloudBuffer.failure {
                    self.cloudFailed(failure, session: id); return
                }
                if let chunk = self.cloudBuffer.takeNext(session: id) {
                    self.cloudInFlightSeconds = chunk.endTime - chunk.startTime
                    self.cloudStatus = "Gemini 전사 중 · \(Self.time(chunk.startTime))–\(Self.time(chunk.endTime))"
                    let localAtSubmission = self.localText(start: chunk.startTime, end: chunk.endTime)
                    do {
                        let transcript = try await cloudClient.transcribe(samples: chunk.samples)
                        guard !Task.isCancelled, self.session == id, !self.closing else { return }
                        self.cloudResults.append(CloudResult(id: chunk.id, start: chunk.startTime, end: chunk.endTime, transcript: transcript))
                        self.cloudInFlightSeconds = 0
                        if let snapshot = self.localSnapshot { self.apply(snapshot) }
                        self.debugRecorder?.recordCloud(chunkID: chunk.id, start: chunk.startTime, end: chunk.endTime,
                            localAtSubmission: localAtSubmission,
                            localAtResponse: self.localText(start: chunk.startTime, end: chunk.endTime),
                            transcript: transcript, speakers: self.segments.filter {
                                self.cloudSegmentIDs.contains($0.id) &&
                                (($0.startTime < chunk.endTime && $0.endTime > chunk.startTime) ||
                                 ($0.startTime == $0.endTime && $0.startTime >= chunk.startTime && $0.endTime <= chunk.endTime))
                            })
                        self.cloudStatus = "Gemini \(self.cloudResults.count)개 구간 완료 · 듣는 중" + self.cloudFallbackSummary
                        if self.argument("--test-file") != nil {
                            let line = "HWAJA_GEMINI_APPLIED chunk=\(chunk.id) start=\(chunk.startTime) end=\(chunk.endTime) elapsed=\(transcript.elapsedSeconds) recording=\(self.phase == .recording)\n"
                            FileHandle.standardError.write(Data(line.utf8))
                        }
                        self.persistCurrentTranscript()
                    } catch {
                        guard !Task.isCancelled, self.session == id, !self.closing else { return }
                        let recoverable = error is GeminiResponseDiagnosticError
                        var details: [String: Any] = ["chunk_id": chunk.id, "start": chunk.startTime, "end": chunk.endTime,
                            "local_at_submission": localAtSubmission,
                            "local_at_response": self.localText(start: chunk.startTime, end: chunk.endTime),
                            "action": recoverable ? "retain_local_chunk_continue_stream" : "stop_cloud_use_local"]
                        if let diagnostic = error as? GeminiResponseDiagnosticError,
                           let data = diagnostic.diagnosticJSON.data(using: .utf8),
                           let response = try? JSONSerialization.jsonObject(with: data) { details["provider_diagnostic"] = response }
                        let detailsJSON = (try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]))
                            .flatMap { String(data: $0, encoding: .utf8) }
                        self.debugRecorder?.recordFailure(message: error.localizedDescription, detailsJSON: detailsJSON)
                        if recoverable {
                            self.cloudSkippedChunks.append(chunk.id)
                            self.cloudInFlightSeconds = 0
                            let range = "\(Self.time(chunk.startTime))–\(Self.time(chunk.endTime))"
                            self.errorMessage = "Gemini 응답 확인 · \(range) 구간은 로컬 결과로 보존합니다. 이후 구간의 Gemini 처리는 계속됩니다."
                            self.cloudStatus = "Gemini 계속 인식 중" + self.cloudFallbackSummary
                            self.persistCurrentTranscript()
                            continue
                        }
                        self.cloudFailed(error.localizedDescription, session: id, alreadyRecorded: true); return
                    }
                } else if self.cloudInputFinal {
                    self.cloudTask = nil; self.cloudPendingSeconds = 0; self.cloudInFlightSeconds = 0
                    self.worker.setAudioObserver(nil)
                    self.cloudStatus = "Gemini 전사 완료 · \(self.cloudResults.count)개 구간" + self.cloudFallbackSummary
                    self.finalizeSession()
                    return
                } else {
                    do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                }
            }
        }
    }

    private func cloudFailed(_ message: String, session id: UUID, alreadyRecorded: Bool = false) {
        guard session == id else { return }
        if !alreadyRecorded { debugRecorder?.recordFailure(message: message) }
        cloudFailure = message
        cloudTask = nil; cloudInFlightSeconds = 0; cloudPendingSeconds = 0
        cloudBuffer.clear()
        cloudStatus = codexSettings.mode == .codex ? "로컬 전사 + AI 교정으로 계속" : "로컬 전사로 계속 · " + message
        errorMessage = message
        scheduleCorrection()
        persistCurrentTranscript()
        if cloudInputFinal { finalizeSession() }
    }

    private func cancelCloud() {
        cloudTask?.cancel(); cloudTask = nil
        cloudBuffer.clear()
        cloudInFlightSeconds = 0; cloudPendingSeconds = 0
    }

    private var cloudFallbackSummary: String {
        cloudSkippedChunks.isEmpty ? "" : " · 로컬 보존 \(cloudSkippedChunks.count)개"
    }

    private var recognitionDocumentStatus: String {
        if sessionProvider == .local { return "local" }
        if cloudFailure != nil { return "local_fallback" }
        let completed = cloudInputFinal && cloudTask == nil
        if cloudSkippedChunks.isEmpty { return completed ? "completed" : "pending" }
        return completed ? "completed_with_local_fallback" : "pending_with_local_fallback"
    }

    private func localText(start: Double, end: Double) -> String {
        localSnapshot?.words.filter {
            let midpoint = ($0.start + $0.end) / 2
            return midpoint >= start && midpoint < end
        }.map(\.text).joined(separator: " ") ?? ""
    }

    private func beginDebugRecording() {
        debugRecorder = nil; lastDebugURL = nil; comparisonURL = nil
        let directory = testOutputURL?.deletingLastPathComponent().appendingPathComponent("Debug", isDirectory: true)
            ?? StorageLocations.diagnostics
        do {
            let recorder = try TranscriptDebugRecorder(directory: directory, sessionID: session)
            debugRecorder = recorder; lastDebugURL = recorder.logURL; comparisonURL = recorder.comparisonURL
            debugStatus = "인식 변경 기록 저장 중"
        } catch { debugStatus = "변경 기록 저장 오류 · " + error.localizedDescription }
    }

    private func finishDebugRecording() {
        guard let recorder = debugRecorder else { return }
        if let audio = audioRecorder {
            recorder.recordAudioFile(url: audioArtifactURL ?? audio.url, status: audioFileStatus, duration: audio.capturedSeconds)
        }
        let displayed = segments.map { TranscriptSegment(id: $0.id, speaker: effectiveSpeaker($0), startTime: $0.startTime, endTime: $0.endTime, text: $0.text) }
        recorder.finish(local: localSnapshot, displayed: displayed, speakerNames: speakerNames)
        do { try recorder.flush(); debugStatus = "인식 변경 기록 저장 완료" }
        catch { debugStatus = "변경 기록 저장 오류 · " + error.localizedDescription }
    }

    func revealDebugRecords() {
        guard let recorder = debugRecorder else { return }
        do {
            try recorder.flush()
            NSWorkspace.shared.activateFileViewerSelecting([recorder.logURL, recorder.comparisonURL])
        } catch { debugStatus = "변경 기록 저장 오류 · " + error.localizedDescription }
    }

    private func beginAudioRecording() -> Bool {
        audioRecorder = nil; savedAudioURL = nil; audioFailure = nil
        audioFileStatus = "recording"; audioSaveStatus = "M4A 음성 저장 중"
        let directory = testOutputURL?.deletingLastPathComponent().appendingPathComponent("Audio", isDirectory: true)
            ?? StorageLocations.recordings
        do {
            let recorder = try SessionAudioRecorder(directory: directory, sessionID: session)
            audioRecorder = recorder
            debugRecorder?.recordAudioFile(url: recorder.recordingURL, status: "recording", duration: 0)
            return true
        } catch {
            audioFailure = error.localizedDescription; audioFileStatus = "failed"
            audioSaveStatus = "M4A 저장 오류 · " + error.localizedDescription
            fail(error)
            return false
        }
    }

    private func checkAudioRecording() {
        guard phase == .recording, audioFailure == nil, let recorder = audioRecorder else { return }
        do { try recorder.checkError() }
        catch {
            audioFailure = error.localizedDescription; audioFileStatus = "failed"
            audioSaveStatus = "M4A 저장 오류 · " + error.localizedDescription
            debugRecorder?.recordFailure(message: audioSaveStatus, detailsJSON: "{\"source\":\"audio_recording\"}")
            stopAfterFailure(error)
        }
    }

    private func finishAudioRecording() {
        guard let recorder = audioRecorder else { return }
        do {
            savedAudioURL = try recorder.finish()
            audioFileStatus = savedAudioURL == nil ? "empty" : "saved"
            audioSaveStatus = savedAudioURL == nil ? "M4A 입력 대기" : "M4A 음성 저장 완료"
        } catch {
            audioFailure = error.localizedDescription; audioFileStatus = "failed"
            audioSaveStatus = "M4A 저장 오류 · " + error.localizedDescription
            pendingFailure = audioSaveStatus; errorMessage = audioSaveStatus
            if FileManager.default.fileExists(atPath: recorder.recordingURL.path) {
                savedAudioURL = recorder.recordingURL
            }
            debugRecorder?.recordFailure(message: audioSaveStatus, detailsJSON: "{\"source\":\"audio_recording\"}")
        }
    }

    private var audioArtifactURL: URL? {
        if let savedAudioURL { return savedAudioURL }
        guard let recorder = audioRecorder else { return nil }
        return audioFileStatus == "recording" || audioFileStatus == "failed" ? recorder.recordingURL : recorder.url
    }

    func revealSavedAudio() {
        if let savedAudioURL { NSWorkspace.shared.activateFileViewerSelecting([savedAudioURL]) }
    }

    static func time(_ value: Double) -> String {
        let total = max(0, Int(value))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%02d:%02d", total / 60, total % 60)
    }

    // Repeatable app-level smoke mode; uses AVAudioFile and the production engine worker.
    private func argument(_ flag: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }
    private var testOutputURL: URL? { argument("--test-output").map { URL(fileURLWithPath: $0) } }
    private func runRequestedTest() {
        guard !testStarted, let file = argument("--test-file") else { return }
        testStarted = true
        DispatchQueue.main.async { self.processFile(URL(fileURLWithPath: file)) }
    }
    private func finishRequestedTest(success: Bool) {
        guard argument("--test-file") != nil && !testCompleted else { return }
        testCompleted = true
        let message = success ? "HWAJA_APP_SMOKE_OK" : "HWAJA_APP_SMOKE_FAILED: \(errorMessage ?? "unknown")"
        FileHandle.standardError.write(Data((message + "\n").utf8))
        if CommandLine.arguments.contains("--test-exit") { shutdownEngines { exit(success ? 0 : 1) } }
    }
}

extension AppModel {
    var correctionNeedsRetry: Bool { correctionFailure != nil && codexSettings.mode == .codex }
    var codexPendingCount: Int { remainingCorrections.count }

    func refreshCodexLogin(settings: CodexCorrectionSettings? = nil) {
        let settings = settings ?? codexSettings
        Task { [weak self] in
            do { let value = try await AITextRunner.installationStatus(settings); self?.codexAuthStatus = value }
            catch { self?.codexAuthStatus = error.localizedDescription }
        }
    }
    func loginCodex(settings: CodexCorrectionSettings) {
        guard !codexLoginRunning else { return }
        codexLoginRunning = true; codexAuthStatus = "브라우저에서 ChatGPT 로그인을 완료해 주세요."
        codexLoginTask = Task { [weak self] in
            do {
                try await CodexCorrector.login(settings: settings)
                guard let self, !Task.isCancelled else { return }
                self.codexAuthStatus = try await CodexCorrector.loginStatus(settings: settings)
            } catch {
                if !Task.isCancelled { self?.codexAuthStatus = error.localizedDescription }
            }
            self?.codexLoginRunning = false
        }
    }
    func cancelCodexLogin() {
        codexLoginTask?.cancel(); codexLoginTask = nil; codexLoginRunning = false
        codexAuthStatus = "로그인을 취소했습니다."
    }
    func updateCorrectionSettings(_ settings: CodexCorrectionSettings, topic: String, terms: String) {
        guard !closing else { return }
        cancelCorrections()
        var cleaned = settings
        cleaned.model = String(settings.model.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        cleaned.executablePath = String(settings.executablePath.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1024))
        cleaned.effort = ["", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(settings.effort) ? settings.effort : "low"
        cleaned.batchSeconds = min(30, max(15, settings.batchSeconds))
        let previousProvider=codexSettings.provider
        codexSettings = cleaned
        if previousProvider != cleaned.provider { assistant.cancel() }
        contextSettings = ContextSettings(enabled: cleaned.mode != .off, topic: String(topic.prefix(600)), terms: String(terms.prefix(6000)))
        corrections = [:]; correctionAttempts = [:]; correctionFailure = nil
        codexRetryCount = 0; correctionResumeAfter = .distantPast
        if let data = try? JSONEncoder().encode(cleaned) { preferences.set(data, forKey: "codexCorrection.v1") }
        if let data = try? JSONEncoder().encode(contextSettings) { preferences.set(data, forKey: "contextSettings.v1") }
        if cleaned.mode == .codex { refreshCodexLogin() }
        syncMeetingMinutes(force:true);persistCurrentTranscript(); scheduleCorrection()
    }
    func retryCodexCorrection() {
        correctionFailure = nil; codexRetryCount = 0; correctionResumeAfter = .distantPast
        scheduleCorrection()
    }
    func acceptCodexProposal(segmentID: Int) {
        guard let segment = segments.first(where: { $0.id == segmentID }),
              let value = corrections[segmentID], let proposed = value.proposedText,
              value.sourceFingerprint == fingerprint(segment) else { return }
        corrections[segmentID] = SegmentCorrection(originalText: value.originalText, correctedText: proposed,
            elapsedSeconds: value.elapsedSeconds, sourceFingerprint: value.sourceFingerprint, accepted: true,
            rejectionReason: "사용자 확인 후 적용", proposedText: nil, provider: "codex", model: value.model,referenceIDs:value.referenceIDs)
        let record = CodexCorrectionRecord(id: UUID().uuidString, requested_at: Date().ISO8601Format(),
            model: value.model ?? codexSettings.model, effort: codexSettings.effort, elapsed_seconds: 0,
            status: "user_accepted", message: "사용자 확인 후 적용", inputs: [codexInput(segment)],
            outputs: [CodexCorrectionOutput(id: segmentID, corrected_text: proposed, needs_review: false, note: "사용자 확인")])
        appendCodexRecord(record); persistCurrentTranscript()
    }
    private func codexInput(_ segment: TranscriptSegment) -> CodexCorrectionInput {
        CodexCorrectionInput(id: segment.id, speaker: segment.speaker, start: segment.startTime, end: segment.endTime,
            text: segment.text, fingerprint: fingerprint(segment), source: cloudSegmentIDs.contains(segment.id) ? "gemini" : "local")
    }
    private func appendCodexRecord(_ record: CodexCorrectionRecord) {
        codexRecords.append(record); debugRecorder?.recordCodex(record)
    }
    private func scheduleCodexCorrection() {
        guard contextSettings.enabled else { return }
        if let correctionFailure {
            updateCorrectionStatus("AI 교정 대기 · \(remainingCorrections.count)개 · \(correctionFailure)")
            finishTestWhenCorrectionsSettle(); return
        }
        guard correctionTask == nil else { return }
        guard Date() >= correctionResumeAfter else { return }
        let candidates = remainingCorrections.filter { segment in
            if sessionProvider == .gemini && cloudFailure == nil && !cloudSegmentIDs.contains(segment.id) && !(cloudInputFinal && cloudTask == nil) { return false }
            if correctionInputFinal { return true }
            guard let observation = observations[segment.id], Date().timeIntervalSince(observation.changedAt) >= 1.5 else { return false }
            return segment.endTime <= audioSeconds - 1.5
        }
        guard let first = candidates.first else {
            updateCorrectionStatus(remainingCorrections.isEmpty ? "AI 교정 \(corrections.count)개 완료" : "AI 교정 · 발언 확정 대기 \(remainingCorrections.count)개")
            finishTestWhenCorrectionsSettle(); return
        }
        var batch: [TranscriptSegment] = [], characters = 0
        for candidate in candidates {
            if !batch.isEmpty && (candidate.endTime - first.startTime > 30 || batch.count >= 24 || characters + candidate.text.count > 6000) { break }
            batch.append(candidate); characters += candidate.text.count
        }
        let waited = observations[first.id].map { Date().timeIntervalSince($0.changedAt) } ?? 0
        if !correctionInputFinal && (batch.last?.endTime ?? first.endTime) - first.startTime < Double(codexSettings.batchSeconds) && waited < 30 && characters < 5000 {
            updateCorrectionStatus("AI 문맥 수집 중 · \(codexSettings.batchSeconds)초 목표 · \(batch.count)개 발언"); return
        }
        let inputs = batch.map(codexInput)
        let settings = codexSettings, sessionID = session, revision = contextRevision, run = UUID()
        let requested = Date().ISO8601Format()
        let prior = visibleSegments.prefix(while: { $0.id != first.id }).suffix(8).map {
            "\(speakerName(for: effectiveSpeaker($0))): \(String(displayedText(for: $0).suffix(300)))"
        }
        correctionRun = run; correctingSegmentIDs = Set(inputs.map(\.id))
        correctionStatus = "\(settings.provider.title) 교정 중 · \(settings.model) · \(inputs.count)개 발언"
        let topic = contextSettings.topic, terms = referenceTerms
        let references=materials.context.excerpts(query:inputs.map(\.text).joined(separator:" "),limit:5,characters:5000)
        correctionTask = Task { [weak self] in
            let started = Date()
            do {
                let result = try await CodexCorrector.correct(inputs, context: prior, topic: topic, terms: terms, settings: settings,references:references)
                guard let self else { return }
                defer { self.finishCorrectionRun(run) }
                guard !Task.isCancelled, !self.closing, self.session == sessionID, self.contextRevision == revision else { return }
                var staleCount = 0, reviewCount = 0
                for input in inputs {
                    guard let current = self.segments.first(where: { $0.id == input.id }), self.fingerprint(current) == input.fingerprint else {
                        staleCount += 1; continue
                    }
                    guard let output = result.response.segments.first(where: { $0.id == input.id }) else { continue }
                    let review = CodexCorrector.reviewReason(original: input.text, output: output)
                    if review != nil { reviewCount += 1 }
                    self.correctionAttempts[input.id] = input.fingerprint
                    self.corrections[input.id] = SegmentCorrection(originalText: input.text,
                        correctedText: review == nil ? output.corrected_text : input.text,
                        elapsedSeconds: result.elapsed, sourceFingerprint: input.fingerprint,
                        accepted: review == nil, rejectionReason: review,
                        proposedText: review == nil ? nil : output.corrected_text, provider: settings.provider.rawValue, model: result.model,referenceIDs:references.map(\.id))
                }
                self.appendCodexRecord(CodexCorrectionRecord(id: run.uuidString, requested_at: requested,
                    model: result.model, effort: settings.effort, elapsed_seconds: result.elapsed,
                    status: staleCount > 0 ? "partially_stale" : (reviewCount > 0 ? "review_required" : "applied"),
                    message: "확인 필요 \(reviewCount)개 · 초안 변경으로 보류 \(staleCount)개", inputs: inputs, outputs: result.response.segments,reference_materials:references))
                self.codexRetryCount = 0; self.codexAuthStatus = settings.provider.title + " 연결됨"
                self.correctionResumeAfter = Date().addingTimeInterval(2)
                self.persistCurrentTranscript()
            } catch {
                guard let self else { return }
                defer { self.finishCorrectionRun(run) }
                guard !Task.isCancelled, !self.closing, self.session == sessionID, self.contextRevision == revision else { return }
                let failure = (error as? CodexFailure) ?? CodexFailure(kind: .process)
                self.appendCodexRecord(CodexCorrectionRecord(id: run.uuidString, requested_at: requested,
                    model: settings.model, effort: settings.effort, elapsed_seconds: Date().timeIntervalSince(started),
                    status: "waiting_retry", message: failure.localizedDescription, inputs: inputs, outputs: []))
                self.codexRetryCount += 1
                if failure.retryable && self.codexRetryCount <= 2 {
                    self.correctionResumeAfter = Date().addingTimeInterval(Double(15 * self.codexRetryCount))
                    self.correctionStatus = "연결 확인 후 AI 교정 자동 재시도 대기"
                } else { self.correctionFailure = failure.localizedDescription }
                self.persistCurrentTranscript()
            }
        }
    }
}

extension AppModel {
    func updateEngineSettings(_ settings: EngineTuningSettings) {
        guard canStart, settings.valid else { return }
        engineSettings = settings; lowLatency = settings.rightContext == 3
        if let data = try? JSONEncoder().encode(settings) { preferences.set(data, forKey: "engineTuning.v1") }
    }
}

extension AppModel {
    func effectiveSpeaker(_ segment: TranscriptSegment) -> Int {
        if manualProjection.lockedIDs.contains(segment.id) { return segment.speaker }
        guard let value = speakerOverrides[segment.id], value.original_fingerprint == fingerprint(segment) else { return segment.speaker }
        return value.speaker
    }
    var canReviewSpeakers: Bool {
        !closing && !isBusy && canExport && !speakerReviewRunning && correctionTask == nil &&
        (remainingCorrections.isEmpty || codexSettings.mode == .off || correctionFailure != nil ||
         (sessionProvider == .gemini && codexSettings.mode != .codex && !isReprocessing))
    }
    private func speakerReviewFingerprint(_ segment: TranscriptSegment) -> String {
        fingerprint(segment) + "|" + displayedText(for: segment) + "|speaker=" + String(effectiveSpeaker(segment)) + "|" + speakerName(for: effectiveSpeaker(segment))
    }
    private func speakerReviewInput(_ segment: TranscriptSegment) -> SpeakerReviewInput {
        SpeakerReviewInput(id: segment.id, original_speaker: segment.speaker, speaker: effectiveSpeaker(segment),
            speaker_name: speakerName(for: effectiveSpeaker(segment)), start: segment.startTime, end: segment.endTime,
            text: displayedText(for: segment), fingerprint: speakerReviewFingerprint(segment))
    }
    private func saveSpeakerReviewRecord(_ record: SpeakerReviewRecord) {
        if let index = speakerReviewRecords.firstIndex(where: { $0.id == record.id }) { speakerReviewRecords[index] = record }
        else { speakerReviewRecords.append(record) }
        debugRecorder?.recordSpeakerReview(record)
        finishDebugRecording()
        persistCurrentTranscript()
        if let recorder = debugRecorder { try? recorder.flush() }
    }
    func cancelSpeakerReview() {
        guard speakerReviewTask != nil || speakerReviewRunning else { return }
        speakerReviewRun = UUID()
        speakerReviewTask?.cancel(); speakerReviewTask = nil; speakerReviewRunning = false
        for var record in speakerReviewRecords where record.status == "running" {
            record.status = "cancelled"; record.message = "검토 취소 · 기존 화자 유지"
            saveSpeakerReviewRecord(record)
        }
        speakerReviewStatus = "검토를 취소했습니다. 완료한 구간의 기록은 보존됩니다."
    }
    func startSpeakerReview() {
        guard canReviewSpeakers else { return }
        stopReviewAudio()
        let provider = speakerReviewProvider, settings = codexSettings, topic = contextSettings.topic
        preferences.set(provider.rawValue, forKey: "speakerReviewProvider.v1")
        let batches = SpeakerReviewer.batches(visibleSegments.filter { !manualProjection.lockedIDs.contains($0.id) }.map(speakerReviewInput), provider: provider)
        let run = UUID(), sessionID = session
        for var record in speakerReviewRecords {
            var changed = false
            for index in record.suggestions.indices where record.suggestions[index].status == "pending" {
                record.suggestions[index].status = "superseded"; changed = true
            }
            if changed { saveSpeakerReviewRecord(record) }
        }
        speakerReviewRun = run; speakerReviewRunning = true
        speakerReviewStatus = "앞뒤 발언을 함께 검토합니다 · \(batches.count)개 구간"
        speakerReviewTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.speakerReviewRun == run {
                    self.speakerReviewTask = nil; self.speakerReviewRunning = false
                    self.persistCurrentTranscript()
                }
            }
            for (index, batch) in batches.enumerated() {
                guard !Task.isCancelled, self.session == sessionID, self.speakerReviewRun == run else { return }
                var record = SpeakerReviewRecord(id: UUID().uuidString, requested_at: Date().ISO8601Format(),
                    provider: provider.rawValue, model: settings.modelLabel,
                    inputs: batch.inputs, target_ids: batch.targets)
                self.saveSpeakerReviewRecord(record)
                self.speakerReviewStatus = "\(provider.title) 화자 검토 \(index + 1)/\(batches.count)"
                let started = Date()
                do {
                    let response = try await SpeakerReviewer.codex(batch, topic: topic, settings: settings)
                    guard !Task.isCancelled, self.session == sessionID, self.speakerReviewRun == run else { return }
                    record.elapsed_seconds = Date().timeIntervalSince(started)
                    let current = batch.inputs.allSatisfy { input in
                        self.segments.first(where: { $0.id == input.id }).map { self.speakerReviewFingerprint($0) == input.fingerprint } ?? false
                    }
                    record.status = current ? "completed" : "stale"
                    record.message = current ? (response.changes.isEmpty ? "이 구간은 현재 화자 유지 권고" : "원음 확인 후 제안을 적용할 수 있습니다.") : "검토 중 본문·화자·이름이 변경되어 응답 보류"
                    if current {
                        record.suggestions = response.changes.compactMap { change in
                            guard let input = batch.inputs.first(where: { $0.id == change.segment_id }) else { return nil }
                            return SpeakerSuggestion(id: UUID().uuidString, input: input, proposed_speaker: change.proposed_speaker,
                                confidence: change.confidence, reason: change.reason, evidence_segment_ids: change.evidence_segment_ids)
                        }
                    }
                    self.saveSpeakerReviewRecord(record)
                } catch {
                    guard !Task.isCancelled, self.session == sessionID, self.speakerReviewRun == run else { return }
                    record.elapsed_seconds = Date().timeIntervalSince(started); record.status = "failed"
                    record.message = (error is CodexFailure || error is SpeakerReviewError) ? error.localizedDescription : "화자 검토를 완료하지 못했습니다. 기존 화자를 유지하며 다시 검토할 수 있습니다."
                    self.saveSpeakerReviewRecord(record)
                    self.speakerReviewStatus = record.message ?? "검토 대기"; return
                }
            }
            let pending = self.speakerReviewRecords.flatMap(\.suggestions).filter { $0.status == "pending" }.count
            self.speakerReviewStatus = "화자 검토 완료 · 확인할 제안 \(pending)개 · 적용 전 원음 대조"
        }
    }
    func canApplySpeakerSuggestion(_ suggestion: SpeakerSuggestion, record: SpeakerReviewRecord) -> Bool {
        guard !closing, !isBusy, !speakerReviewRunning, suggestion.status == "pending" else { return false }
        let evidence = Set(suggestion.evidence_segment_ids + [suggestion.input.id])
        return record.inputs.filter { evidence.contains($0.id) }.allSatisfy { input in
            segments.first(where: { $0.id == input.id }).map { speakerReviewFingerprint($0) == input.fingerprint } ?? false
        }
    }
    func decideSpeakerSuggestion(recordID: String, suggestionID: String, apply: Bool) {
        guard !speakerReviewRunning, let r = speakerReviewRecords.firstIndex(where: { $0.id == recordID }),
              let s = speakerReviewRecords[r].suggestions.firstIndex(where: { $0.id == suggestionID }) else { return }
        var record = speakerReviewRecords[r]
        let proposal = record.suggestions[s]
        guard proposal.status == "pending" else { return }
        if apply {
            guard canApplySpeakerSuggestion(proposal, record: record), let segment = segments.first(where: { $0.id == proposal.input.id }) else {
                record.suggestions[s].status = "stale"; saveSpeakerReviewRecord(record); return
            }
            speakerOverrides[segment.id] = SpeakerOverride(speaker: proposal.proposed_speaker,
                original_fingerprint: fingerprint(segment), proposal_id: proposal.id)
            refreshVoiceCandidates()
            speakerIDs = Set(speakerIDs + [proposal.proposed_speaker]).sorted()
            record.suggestions[s].status = "accepted"
        } else { record.suggestions[s].status = "rejected" }
        saveSpeakerReviewRecord(record)
        speakerReviewStatus = apply ? "확인한 화자를 적용했습니다. 최초 화자와 근거는 기록에 보존됩니다." : "기존 화자를 유지했습니다."
    }
    func canRevertSpeakerSuggestion(_ proposal: SpeakerSuggestion) -> Bool {
        !isBusy && !speakerReviewRunning && speakerOverrides[proposal.input.id]?.proposal_id == proposal.id
    }
    func revertSpeakerSuggestion(recordID: String, suggestionID: String) {
        guard let r = speakerReviewRecords.firstIndex(where: { $0.id == recordID }),
              let s = speakerReviewRecords[r].suggestions.firstIndex(where: { $0.id == suggestionID }) else { return }
        var record = speakerReviewRecords[r]
        guard canRevertSpeakerSuggestion(record.suggestions[s]) else { return }
        speakerOverrides[record.suggestions[s].input.id] = nil
        refreshVoiceCandidates()
        record.suggestions[s].status = "reverted"
        saveSpeakerReviewRecord(record)
        speakerReviewStatus = "최초 음성 화자로 되돌렸습니다."
    }
    func playReviewAudio(start: Double, end: Double) {
        stopReviewAudio()
        guard let url = savedAudioURL ?? audioArtifactURL else { speakerReviewStatus = "저장한 M4A 경로를 확인해 주세요."; return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let from = max(0, start - 1.5), to = min(player.duration, end + 1.5)
            guard from < to else { return }
            player.currentTime = from
            guard player.play() else { speakerReviewStatus = "원음 재생을 시작할 수 없습니다."; return }
            reviewPlayer = player; playingReviewAudio = true
            reviewAudioStop = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((to - from) * 1_000_000_000))
                if !Task.isCancelled { self?.stopReviewAudio() }
            }
        } catch { speakerReviewStatus = "원음 파일을 열 수 없습니다. M4A 저장 위치를 확인해 주세요." }
    }
    func stopReviewAudio() {
        reviewAudioStop?.cancel(); reviewAudioStop = nil
        reviewPlayer?.stop(); reviewPlayer = nil; playingReviewAudio = false
    }
}


extension AppModel {
    func syncMeetingMinutes(force: Bool = false) {
        guard !loadingHistory else { return }
        let folderKey = "\(codexSettings.provider.rawValue)|\(meeting.provider.rawValue)|\(codexSettings.model)|\(codexSettings.effort)|\(codexSettings.executablePath)"
        if !closing && folderSettingsKey != folderKey {
            folderSettingsKey = folderKey
            materials.resumeFolderWatching(provider: meeting.provider, settings: codexSettings)
        }
        meeting.usesLiveAssistant = assistant.enabled
        meeting.materialContext=materials.context
        let appendixKey = "\(meeting.sessionID ?? session)|\(assistant.state.revision)"
        if appendixKey != assistantAppendixKey {
            meeting.assistantAppendix = assistant.appendixMarkdown(sessionID: meeting.sessionID ?? session)
            assistantAppendixKey = appendixKey
        }
        defer {
            if !closing, let record = meeting.metadata {
                let key = "\(record.id)|\(record.revision)|\(record.ended)|\(savedAudioURL?.path ?? "")"
                if assistantSyncKey != key {
                    assistantSyncKey = key
                    assistant.receive(record: record, audioURL: savedAudioURL)
                }
            }
        }
        guard !segments.isEmpty || meetingPrepared else { meeting.updateRecovered(settings: codexSettings); return }
        meeting.receive(id: session, title: sessionTitle, date: startedAt,
            segments: visibleSegments.map { MeetingUtterance(id: $0.id, speaker: effectiveSpeaker($0), start: $0.startTime, end: $0.endTime, text: displayedText(for: $0)) },
            names: speakerNames, ended: closing || phase == .completed || phase == .failed,
            settings: codexSettings, force: force)
    }
    func bindMeetingContact(_ person: MeetingPerson, speaker: Int) {
        guard speakerIDs.contains(speaker) else { return }
        confirmEnteredSpeakerName(person.name, for: speaker)
        meeting.bind(person, speaker: speaker)
        persistCurrentTranscript()
    }
    func removeMeetingPerson(_ id: String) {
        let speakers = meeting.bindings.speakers.filter { $0.value.id == id }.map(\.key)
        meeting.remove(personID: id)
        for speaker in speakers { setSpeakerName("", for: speaker) }
        persistCurrentTranscript()
    }
}

// Voice identity follows confirmed speaker reassignments on the original audio clock.
extension AppModel {
    func voiceNamePresentation(for speaker: Int) -> VoiceNamePresentation {
        if let match = voiceNameAssignments.automatic[speaker], speakerNames[speaker] == match.name {
            return .init(kind: .automatic, name: match.name, detail: voiceMatchDetail(match))
        }
        if let name = speakerNames[speaker] {
            return .init(kind: .manual, name: name, detail: "직접 지정한 이름을 유지합니다.")
        }
        if voice.mappingMode != .off, !voiceNameAssignments.userControlled.contains(speaker),
           !voice.rejectedSpeakers.contains(speaker), let match = voice.suggestions[speaker] {
            return .init(kind: .suggested, name: match.name, detail: voiceMatchDetail(match))
        }
        let detail: String
        if voice.rejectedSpeakers.contains(speaker) { detail = "이 회의에서 후보를 제외했습니다. 다시 비교로 검토할 수 있습니다." }
        else if voice.matchingSpeakers.contains(speaker) { detail = "학습한 목소리와 비교 중입니다." }
        else if voice.mappingMode == .off { detail = "목소리 연결을 켜면 등록한 목소리와 비교합니다." }
        else if voice.vault.profiles.isEmpty { detail = "목소리를 등록하면 이름을 연결할 수 있습니다." }
        else { detail = "선명한 발언 구간을 모아 이름을 비교합니다." }
        return .init(kind: .none, name: "화자 \(speaker)", detail: detail)
    }

    private func voiceMatchDetail(_ match: VoiceSuggestion) -> String {
        var detail = String(format: "유사도 %.2f · %d개 구간 · %.1f초", match.similarity, match.evidenceCount, match.evidenceSeconds)
        if !match.automaticEligible {
            detail += match.enrolledClipCount < 2 || match.enrolledSeconds < 6
                ? " · 등록 목소리를 2개 구간·6초 이상 보강하면 자동 연결을 검토합니다."
                : " · 후보를 확인하거나 다음 발언의 일치를 기다립니다."
        }
        return detail
    }

    private func reconcileVoiceNames() {
        guard !closing, !reconcilingVoiceNames else { return }
        reconcilingVoiceNames = true
        defer { reconcilingVoiceNames = false }
        let changes = voiceNameAssignments.reconcile(suggestions: voice.suggestions, mode: voice.mappingMode,
            speakers: Set(speakerIDs), names: speakerNames, rejected: voice.rejectedSpeakers)
        for change in changes {
            speakerNames[change.speaker] = change.name
            let match = change.suggestion
            voice.record(speaker: change.speaker,
                candidate: .init(speaker: change.speaker, start: match.evidenceStart, end: match.evidenceEnd, text: ""),
                name: match.name, score: match.similarity, action: change.action)
        }
        if !changes.isEmpty {
            debugRecorder?.recordSpeakerNames(speakerNames)
            syncMeetingMinutes(force: true)
        }
    }

    func dismissVoiceSuggestion(_ speaker: Int) {
        guard !closing, speakerIDs.contains(speaker) else { return }
        voice.rejectSuggestion(speaker: speaker)
        reconcileVoiceNames()
        persistCurrentTranscript()
    }

    func undoAutomaticVoiceName(_ speaker: Int) {
        guard !closing, speakerIDs.contains(speaker), let match = voiceNameAssignments.automatic[speaker] else { return }
        voice.record(speaker: speaker, name: match.name, score: match.similarity, action: "automatic_mapping_undone")
        voice.rejectSuggestion(speaker: speaker)
        reconcileVoiceNames()
        persistCurrentTranscript()
    }

    func recheckVoiceNames() {
        guard !closing else { return }
        voice.requestRematch(savedAudio: savedAudioURL)
        reconcileVoiceNames()
        persistCurrentTranscript()
    }

    func confirmVoiceName(_ speaker: Int) {
        guard !closing, speakerIDs.contains(speaker), let match = voice.suggestions[speaker],
              let name = voice.confirm(speaker: speaker) else { return }
        setSpeakerName(name, for: speaker)
        startConfirmedVoiceLearning(speaker: speaker, profileID: match.profileID, name: name)
        syncMeetingMinutes(force: true)
    }

    func confirmEnteredSpeakerName(_ name: String, for speaker: Int) {
        guard !closing, speakerIDs.contains(speaker) else { return }
        setSpeakerName(name, for: speaker)
        guard let cleaned = speakerNames[speaker], !cleaned.isEmpty else { return }
        let profiles = voice.vault.profiles.filter { $0.name.compare(cleaned, options: .caseInsensitive) == .orderedSame }
        guard profiles.count == 1 else { return }
        startConfirmedVoiceLearning(speaker: speaker, profileID: profiles[0].id, name: cleaned)
    }

    private func startConfirmedVoiceLearning(speaker: Int, profileID: UUID, name: String) {
        guard voice.vault.continuousLearningEnabled else { return }
        let confirmedSession = session
        Task { [weak self] in
            guard let self, !self.closing, self.session == confirmedSession,
                  self.speakerNames[speaker] == name else { return }
            await self.voice.learnConfirmedSpeaker(speaker: speaker, profileID: profileID, savedAudio: self.savedAudioURL)
        }
    }
    private func voiceSnapshot(_ snapshot: EngineSnapshot) -> EngineSnapshot {
        if snapshot.words.isEmpty, snapshot.isFinal {
            let projected = visibleSegments.map { segment in
                TranscriptSegment(id:segment.id,speaker:effectiveSpeaker(segment),startTime:segment.startTime,
                    endTime:segment.endTime,text:displayedText(for:segment))
            }
            return EngineSnapshot(revision:snapshot.revision,audioSeconds:snapshot.audioSeconds,
                processedSeconds:snapshot.processedSeconds,isFinal:true,text:snapshot.text,
                words:[],segments:projected,speakerActivity:snapshot.speakerActivity)
        }
        let changed = visibleSegments.filter { effectiveSpeaker($0) != (manualProjection.acousticSpeakers[$0.id] ?? $0.speaker) }
        guard !changed.isEmpty else { return snapshot }
        let words = snapshot.words.map { word -> TranscriptWord in
            let overlaps = changed.filter { (manualProjection.acousticSpeakers[$0.id] ?? $0.speaker) == word.speaker && $0.startTime < word.end && $0.endTime > word.start }
            guard !overlaps.isEmpty else { return word }
            let containing = overlaps.filter { word.start >= $0.startTime - 0.02 && word.end <= $0.endTime + 0.02 }
            let labels = Set(containing.map(effectiveSpeaker))
            // Boundary words stay out of training until their label is unambiguous.
            let speaker = labels.count == 1 ? labels.first! : 0
            return TranscriptWord(text: word.text, start: word.start, end: word.end, speaker: speaker)
        }
        return EngineSnapshot(revision: snapshot.revision, audioSeconds: snapshot.audioSeconds,
            processedSeconds: snapshot.processedSeconds, isFinal: snapshot.isFinal, text: snapshot.text,
            words: words, segments: snapshot.segments, speakerActivity: snapshot.speakerActivity)
    }
    private func refreshVoiceCandidates() {
        if let snapshot = localSnapshot { voice.receive(voiceSnapshot(snapshot)) }
    }
}

extension AppModel {
    var canPrepareMeeting: Bool { canStart && !materials.busy }
    var isReprocessing: Bool { reprocessingOrigin != nil }
    var canOpenHistoryForReprocessing: Bool {
        canPrepareMeeting && !meeting.busy && !assistant.busy && correctionTask == nil
            && !speakerReviewRunning && !voice.learningBusy
    }
    @discardableResult func openHistoryForReprocessing(_ snapshot: MeetingHistorySnapshot) -> Bool {
        guard canOpenHistoryForReprocessing, !snapshot.segments.isEmpty else {
            errorMessage="현재 녹음과 분석을 마친 뒤 발언이 있는 회의를 재가공해 주세요."
            return false
        }
        guard resetSession(title:snapshot.title + " · 재가공", source:"history:" + snapshot.id.uuidString, prepareOnly:true) else { return false }
        loadingHistory=true
        defer { loadingHistory=false }
        do { try materials.restoreMeetingContext(snapshot.materials) }
        catch { errorMessage="저장 회의의 자료 연결을 확인해 주세요. " + error.localizedDescription;return false }
        let source=snapshot.record
        var bindings=MeetingSpeakerBindings(sessionID:session)
        for person in source?.bindings.confirmedParticipants ?? [] { bindings.confirmAttendance(person) }
        for (speaker,person) in source?.bindings.speakers ?? [:] where snapshot.names[speaker]==person.name {
            bindings.bind(person,to:speaker)
        }
        let dateFormat=DateFormatter();dateFormat.dateFormat="yyyy-MM-dd HH:mm:ss zzz"
        let record=MeetingWorkRecord(id:session,revision:1,savedRevision:-1,
            date:dateFormat.string(from:snapshot.date),title:sessionTitle,purpose:source?.purpose ?? snapshot.context.topic,
            template:source?.template ?? meeting.selectedTemplate,bindings:bindings,names:snapshot.names,
            segments:snapshot.segments,ended:true,provider:source?.provider ?? meeting.provider,
            settings:codexSettings,output:nil,error:nil,updatedAt:Date(),materials:materials.context)
        guard meeting.openReprocessing(record:record) else {
            errorMessage="재가공본의 저장 위치를 확인해 주세요.";return false
        }
        startedAt=snapshot.date
        reprocessingOrigin=MeetingReprocessingOrigin(sourceSessionID:snapshot.id,sourceTitle:snapshot.title,
            sourceTranscriptPath:snapshot.transcriptURL?.path,sourceRecordPath:snapshot.recordURL?.path,
            sourceMinutesPath:snapshot.minutesURL?.path,createdAt:Date())
        segments=snapshot.segments.map { TranscriptSegment(id:$0.id,speaker:$0.speaker,startTime:$0.start,endTime:$0.end,text:$0.text) }
        audioSeconds=snapshot.duration;liveText="";speakerNames=snapshot.names
        speakerIDs=Set(segments.map(\.speaker).filter { $0>0 }).sorted()
        for speaker in speakerNames.keys { voiceNameAssignments.userEdited(speaker) }
        nextManualPartID=min(-1,(segments.map(\.id).min() ?? 0)-1)
        contextSettings=snapshot.context
        savedAudioURL=snapshot.audioURL;audioFileStatus=savedAudioURL == nil ? "missing" : "referenced"
        audioSaveStatus=savedAudioURL == nil ? "원음 경로 확인 필요" : "저장된 M4A 연결"
        lastDebugURL=snapshot.diagnosticsURL;comparisonURL=snapshot.comparisonURL
        debugStatus=comparisonURL == nil ? "원본 비교 기록 경로 확인 필요" : "원본 인식 비교 기록 연결"
        correctionAttempts=Dictionary(uniqueKeysWithValues:segments.map { ($0.id,fingerprint($0)) })
        correctionInputFinal=true;cloudInputFinal=true
        correctionStatus="저장된 전사 불러옴 · 문맥 다시 교정 가능"
        meetingPrepared=false;processingFile=false;fileProgress=nil;phase = .completed;finalStatus="reprocessed"
        statusMessage="재가공본 준비 · 발언·화자·자료를 편집한 뒤 회의록 다시 생성을 누르세요."
        localSnapshot=EngineSnapshot(revision:0,audioSeconds:audioSeconds,processedSeconds:audioSeconds,
            isFinal:true,text:segments.map(\.text).joined(separator:" "),words:[],segments:segments,speakerActivity:nil)
        refreshVoiceCandidates()
        loadingHistory=false
        persistCurrentTranscript()
        Task { await history.refresh() }
        return errorMessage == nil
    }
    func regenerateHistoryMinutes() {
        guard isReprocessing,!closing,!isBusy,!meeting.busy else { return }
        syncMeetingMinutes(force:true);meeting.generateNow()
        statusMessage="재가공본의 회의록을 생성하고 있습니다. 회의자료·회의록에서 결과를 확인하세요."
    }
    func recorrectHistoryTranscript() {
        guard isReprocessing,!closing,!isBusy,!speakerReviewRunning,correctionTask == nil else { return }
        guard codexSettings.mode != .off else { errorMessage="문맥 교정 설정에서 사용할 모델을 선택해 주세요.";return }
        contextSettings.enabled=true;corrections=[:];correctionAttempts=[:];correctionFailure=nil
        codexRetryCount=0;correctionResumeAfter = .distantPast;correctionInputFinal=true
        persistCurrentTranscript();scheduleCorrection()
    }
    var referenceTerms:[String] {
        var seen=Set<String>()
        return Array((contextSettings.phrases+materials.context.terms).filter { seen.insert($0).inserted }.prefix(64))
    }
    func newMeeting() {
        guard canPrepareMeeting else { return }
        guard resetSession(title:"새 회의",source:"microphone",prepareOnly:true) else { return }
        materials.clearSelection()
        materials.resumeFolderWatching(provider: meeting.provider, settings: codexSettings)
        meeting.purpose=""
        statusMessage="회의 준비 · 자료·목적·참석자를 설정한 뒤 녹음을 시작하세요."
        syncMeetingMinutes(force:true)
    }
}


extension AppModel {
    func editRequest(for turn: ConversationTurn, includeRelatedParts: Bool = true) -> TranscriptEditRequest {
        var captured:[TranscriptSegment]=[],texts:[Int:String]=[:],speakers:[Int:Int]=[:]
        var initial:[Int:[ManualTranscriptDraft]]=[:],groups:[Int:UUID]=[:],seen=Set<UUID>()
        for segment in turn.segments {
            if includeRelatedParts,let owner=manualTranscriptEdits.first(where:{$0.parts.contains(where:{$0.id==segment.id})}) {
                guard seen.insert(owner.id).inserted,let first=owner.parts.first else { continue }
                let id=first.id
                captured.append(TranscriptSegment(id:id,speaker:owner.sourceSpeaker,startTime:owner.start,endTime:owner.end,text:owner.sourceText))
                initial[id]=owner.parts.map { ManualTranscriptDraft(start:$0.start,end:$0.end,speaker:$0.speaker,text:$0.text) }
                texts[id]=owner.parts.map(\.text).joined(separator:" ");speakers[id]=first.speaker;groups[id]=owner.id
            } else {
                captured.append(segment);texts[segment.id]=displayedText(for:segment);speakers[segment.id]=effectiveSpeaker(segment)
                initial[segment.id]=[ManualTranscriptDraft(start:segment.startTime,end:segment.endTime,speaker:effectiveSpeaker(segment),text:displayedText(for:segment))]
            }
        }
        return TranscriptEditRequest(sessionID:session,revision:manualEditRevision,segments:captured.sorted {$0.startTime<$1.startTime},
            texts:texts,speakers:speakers,initialParts:initial,manualGroups:groups)
    }
    func deleteRecognizedTurn(_ turn: ConversationTurn) {
        let request=editRequest(for:turn,includeRelatedParts:false)
        applyTranscriptEdits(request:request,texts:Dictionary(uniqueKeysWithValues:turn.segments.map {($0.id,"")}))
    }
    func applyTranscriptEdits(request: TranscriptEditRequest,texts: [Int:String]) {
        let drafts=Dictionary(uniqueKeysWithValues:request.segments.map { segment in
            (segment.id,[ManualTranscriptDraft(start:segment.startTime,end:segment.endTime,
                speaker:request.speakers[segment.id] ?? segment.speaker,text:texts[segment.id] ?? request.texts[segment.id] ?? "")])
        })
        _=applyManualTranscriptEdits(request:request,drafts:drafts)
    }
    @discardableResult
    func applyManualTranscriptEdits(request: TranscriptEditRequest,drafts: [Int:[ManualTranscriptDraft]]) -> Bool {
        guard !closing,request.sessionID==session,request.revision==manualEditRevision else {
            errorMessage="회의 또는 편집 내용이 갱신되었습니다. 발언 편집창을 다시 열어 주세요."; return false
        }
        guard request.segments.allSatisfy({ ManualTranscriptDraft.valid(drafts[$0.id] ?? [], within:$0) }) else {
            errorMessage="분리 시각과 화자를 확인해 주세요. 각 구간은 시간 순서로 이어져야 합니다."; return false
        }
        let changes=request.segments.filter { segment in
            let parts=drafts[segment.id] ?? [], original=request.initialParts[segment.id] ?? []
            guard parts.count==original.count else { return true }
            return zip(parts,original).contains { a,b in
                abs(a.start-b.start)>0.001 || abs(a.end-b.end)>0.001 || a.speaker != b.speaker ||
                a.text.trimmingCharacters(in:.whitespacesAndNewlines) != b.text.trimmingCharacters(in:.whitespacesAndNewlines)
            }
        }
        guard !changes.isEmpty else { return true }
        transcriptUndo.append(TranscriptUndoState(text:transcriptEdits,manual:manualTranscriptEdits))
        if transcriptUndo.count>50 { transcriptUndo.removeFirst() }
        for segment in changes {
            let parts=(drafts[segment.id] ?? []).map { draft -> ManualTranscriptPart in
                defer { nextManualPartID -= 1 }
                return ManualTranscriptPart(id:nextManualPartID,start:draft.start,end:draft.end,speaker:draft.speaker,text:draft.text.trimmingCharacters(in:.whitespacesAndNewlines))
            }
            if let group=request.manualGroups[segment.id],let index=manualTranscriptEdits.firstIndex(where:{$0.id==group}) {
                manualTranscriptEdits[index].parts=parts;manualTranscriptEdits[index].editedAt=Date()
            } else if let index=manualTranscriptEdits.firstIndex(where:{$0.parts.contains(where:{$0.id==segment.id})}),
               let partIndex=manualTranscriptEdits[index].parts.firstIndex(where:{$0.id==segment.id}) {
                manualTranscriptEdits[index].parts.replaceSubrange(partIndex...partIndex,with:parts)
                manualTranscriptEdits[index].editedAt=Date()
            } else {
                manualTranscriptEdits.append(ManualTranscriptEdit(id:UUID(),sourceID:segment.id,sourceSpeaker:segment.speaker,
                    start:segment.startTime,end:segment.endTime,sourceText:segment.text,parts:parts,editedAt:Date()))
            }
        }
        speakerIDs=Set(speakerIDs + manualTranscriptEdits.flatMap { $0.parts.map(\.speaker) }.filter {$0>0}).sorted()
        transcriptUndoCount=transcriptUndo.count
        transcriptTextChanged()
        return true
    }
    func undoTranscriptEdit() {
        guard !closing,let previous=transcriptUndo.popLast() else { return }
        transcriptEdits=previous.text;manualTranscriptEdits=previous.manual;transcriptUndoCount=transcriptUndo.count
        transcriptTextChanged()
    }
    private func transcriptTextChanged() {
        manualEditRevision=UUID()
        cancelCorrections()
        refreshVoiceCandidates()
        syncMeetingMinutes(force:true)
        meeting.invalidateTranscriptAfterEdit()
        persistCurrentTranscript()
        scheduleCorrection()
    }
    var canPlayTranscriptAudio: Bool { !isBusy && (savedAudioURL ?? audioArtifactURL) != nil }
}


extension AppModel {
    func editingSnapshot() -> EditingSnapshot {
        var documents=visibleSegments.map { segment in
            EditingDocument(id:"utterance.\(segment.id)",kind:.transcript,
                title:"\(Self.time(segment.startTime))–\(Self.time(segment.endTime)) · \(speakerName(for:effectiveSpeaker(segment)))",
                text:displayedText(for:segment),speaker:effectiveSpeaker(segment),sourceID:String(segment.id))
        }
        documents += speakerIDs.map { EditingDocument(id:"speaker.\($0)",kind:.speaker,title:"화자 \($0)",text:speakerName(for:$0),speaker:$0,sourceID:String($0)) }
        if meeting.sessionID==session {
            documents.append(EditingDocument(id:"minutes",kind:.minutes,title:"현재 회의록",text:meeting.preview))
        }
        for document in materials.context.documents {
            documents += document.chunks.map {
                EditingDocument(id:"material.\(document.id.uuidString).\($0.id)",kind:.material,title:document.title+" · "+$0.location,
                    text:$0.text,sourceID:document.id.uuidString)
            }
        }
        return EditingSnapshot(sessionID:session,documents:documents)
    }
    func applyEditingPlan(_ plan: EditingPlan, capture: EditingSnapshot) throws -> EditingReceipt {
        guard !closing, !plan.changes.isEmpty else { throw EditingError.unavailable }
        try plan.validateCurrent(captured:capture,current:editingSnapshot())
        let pairs=plan.changes.compactMap { change -> (EditingChange,EditingDocument)? in
            capture.documents.first(where:{$0.id==change.targetID}).map { (change,$0) }
        }
        if let (change,document)=pairs.first, document.kind == .minutes {
            return try meeting.applyChatDraft(change.after,expected:change.before)
        }
        if let (_,document)=pairs.first, document.kind == .material,
           let source=document.sourceID, let id=UUID(uuidString:source),
           let material=materials.context.documents.first(where:{$0.id==id}) {
            var replacements:[String:String]=[:]
            for (change,_) in pairs {
                guard let chunk=material.chunks.first(where:{"material.\(id.uuidString).\($0.id)"==change.targetID}) else { throw EditingError.stale }
                replacements[chunk.id]=change.after
            }
            return try materials.applyChatEdits(documentID:id,replacements:replacements)
        }
        let beforeText=transcriptEdits, beforeManual=manualTranscriptEdits, beforeNames=speakerNames
        let beforeBindings=meeting.bindings, beforeVoiceNames=voiceNameAssignments
        let targetIDs=Set(pairs.filter{$0.1.kind == .transcript}.compactMap{Int($0.1.sourceID ?? "")})
        let selected=visibleSegments.filter{targetIDs.contains($0.id)}
        guard selected.count==targetIDs.count else { throw EditingError.stale }
        if !selected.isEmpty {
            let request=editRequest(for:ConversationTurn(id:UUID().uuidString,speaker:0,segments:selected),includeRelatedParts:false)
            var drafts=request.initialParts
            for (change,doc) in pairs where doc.kind == .transcript {
                guard let id=Int(doc.sourceID ?? ""), let segment=selected.first(where:{$0.id==id}) else { throw EditingError.stale }
                drafts[id]=[ManualTranscriptDraft(start:segment.startTime,end:segment.endTime,
                    speaker:change.speaker<0 ? effectiveSpeaker(segment) : change.speaker,text:change.after)]
            }
            guard applyManualTranscriptEdits(request:request,drafts:drafts) else { throw EditingError.stale }
        }
        for (change,doc) in pairs where doc.kind == .speaker {
            if let speaker=doc.speaker { setSpeakerName(change.after,for:speaker) }
        }
        let changedRevision=manualEditRevision, changedNames=speakerNames, sessionID=session
        let bindingEncoder=JSONEncoder();bindingEncoder.outputFormatting=[.sortedKeys]
        let changedBindings=try bindingEncoder.encode(meeting.bindings)
        return EditingReceipt(note:"발언·화자 \(pairs.count)개 변경을 적용했습니다.") { [weak self] in
            guard let self, !self.closing, self.session==sessionID,
                  self.manualEditRevision==changedRevision, self.speakerNames==changedNames,
                  try bindingEncoder.encode(self.meeting.bindings)==changedBindings else { throw EditingError.stale }
            self.transcriptEdits=beforeText;self.manualTranscriptEdits=beforeManual
            if !selected.isEmpty { _=self.transcriptUndo.popLast();self.transcriptUndoCount=self.transcriptUndo.count }
            self.speakerNames=beforeNames;self.voiceNameAssignments=beforeVoiceNames
            self.meeting.restoreEditingBindings(beforeBindings)
            self.transcriptTextChanged()
        }
    }
}
