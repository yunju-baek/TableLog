import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if !CommandLine.arguments.contains("--test-exit") { NSApp.activate(ignoringOtherApps: true) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.prepareToQuit { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main struct TableLogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel

    init() {
        AppIdentityMigration.preparePreferences()
        _ = StorageLocations.active
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        Window("테이블로그", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 940, minHeight: 650)
                .preferredColorScheme(.light)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1440, height: 850)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("음성 파일 열기…", action: model.importAudio).keyboardShortcut("o").disabled(!model.canStart)
                Button("지난 회의…") { NotificationCenter.default.post(name: MeetingHistoryPresentation.show, object: nil) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("JSON 저장…", action: model.saveJSON).keyboardShortcut("s").disabled(!model.canExport)
            }
            CommandGroup(replacing: .help) {
                Button("테이블로그 사용법·도움말", action: AppHelp.openGuide)
                    .keyboardShortcut("?", modifiers: [.command])
                Button("AI CLI 연결 안내", action: AppHelp.openCLISetup)
                Button("GitHub 저장소", action: AppHelp.openRepository)
            }
            CommandMenu("AI") {
                Button("AI CLI 설정…") { NotificationCenter.default.post(name: AppHelp.showAISettings, object: nil) }
            }
            CommandMenu("전사") {
                Button("새 회의", action: model.newMeeting).keyboardShortcut("n", modifiers: [.command]).disabled(!model.canPrepareMeeting)
                Button("녹음 시작", action: model.start).keyboardShortcut("r", modifiers: [.command]).disabled(!model.canStart || !model.meetingPrepared)
                Button("종료 · 저장", action: model.stop).keyboardShortcut(".", modifiers: [.command]).disabled(!model.canStop)
                Divider()
                Button("발언 복사", action: model.copyTranscript).disabled(!model.canExport)
                Button("저장 위치 열기", action: model.revealLastSave).disabled(model.lastSavedURL == nil)
            }
        }
        Settings {
            StorageSettingsView()
        }
    }
}
