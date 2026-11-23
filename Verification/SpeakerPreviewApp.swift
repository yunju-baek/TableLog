import AppKit
import CoreAudio
import SwiftUI

/// Use the same SwiftUI scene lifecycle and Edit menu as the shipping app.
/// The old NSApplication.run fixture only installed a bare menu bar.
@main struct SpeakerPreviewApp: App {
    @NSApplicationDelegateAdaptor(SpeakerPreviewDelegate.self) private var delegate
    @StateObject private var state = SpeakerPreviewState()

    var body: some Scene {
        Window("화자 편집 검증 · 가상 회의", id: "speaker-preview") {
            ContentView(model: state.model)
                .defaultAppStorage(state.preferences)
                .onAppear { delegate.model = state.model }
        }
        .defaultSize(width: 1440, height: 850)
        .windowResizability(.contentMinSize)
    }
}

@MainActor final class SpeakerPreviewState: ObservableObject {
    let model: AppModel
    let preferences: UserDefaults
    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TableLogSpeakerPreview-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        preferences = UserDefaults(suiteName: "local.TableLog.SpeakerPreview." + UUID().uuidString)!
        preferences.set(false, forKey: "assistant.enabled")
        preferences.set(false, forKey: "minutes.automatic")
        preferences.set(false, forKey: "minutes.onFinish")
        var settings = CodexCorrectionSettings(); settings.mode = .off
        preferences.set(try! JSONEncoder().encode(settings), forKey: "codexCorrection.v1")
        model = AppModel(materials: MeetingMaterials(root: root.appendingPathComponent("Materials")),
            meeting: MeetingWorkspace(directory: root.appendingPathComponent("Minutes"), defaults: preferences),
            assistant: MeetingAssistant(directory: root.appendingPathComponent("Assistant"), defaults: preferences),
            loadEngine: false, voice: VoiceIdentity(root: root.appendingPathComponent("Voice")),
            history: MeetingHistoryStore(transcripts: root.appendingPathComponent("Transcripts"), minutes: root.appendingPathComponent("Minutes")),
            transcriptDirectory: root.appendingPathComponent("Transcripts"), startBackgroundServices: false,
            preferences: preferences, microphone: PreviewMicrophone())
        model.loadVoiceNameFixture()
    }
}

private final class PreviewMicrophone: MicrophoneCapturing {
    func start(deviceID: AudioDeviceID?, onAudio: @escaping ([Float]) -> Void,
               onLevel: @escaping (Float) -> Void, onError: @escaping (Error) -> Void) throws {
        throw AppFailure(message: "가상 회의의 화자 편집을 확인하는 화면입니다.")
    }
    func stop(completion: @escaping () -> Void) { completion() }
}

@MainActor final class SpeakerPreviewDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var quitting = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !quitting else { return .terminateLater }
        quitting = true
        DispatchQueue.main.async {
            model.prepareToQuit { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
