import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var shutdownWindow: AppShutdownWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if !CommandLine.arguments.contains("--test-exit") { NSApp.activate(ignoringOtherApps: true) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard shutdownWindow == nil else { return .terminateLater }
        let window = AppShutdownWindow(model: model)
        shutdownWindow = window
        window.show()
        DispatchQueue.main.async {
            model.prepareToQuit { [weak self] in
                self?.shutdownWindow?.close()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

@main struct TableLogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var startup = AppStartup()
    private var model: AppModel? { startup.model }

    var body: some Scene {
        Window("테이블로그", id: "main") {
            Group {
                if startup.isReady, let model {
                    ContentView(model: model)
                        .frame(minWidth: 940, minHeight: 650)
                } else {
                    AppStartupView(startup: startup)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.paper)
            .preferredColorScheme(.light)
            .onAppear {
                DispatchQueue.main.async {
                    guard !startup.isReady,
                          let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.mainWindow,
                          !window.styleMask.contains(.fullScreen) else { return }
                    window.setContentSize(NSSize(width: 520, height: 590))
                    window.center()
                }
            }
            .task { await startup.start() }
            .onReceive(startup.$model) { delegate.model = $0 }
            .onChange(of: startup.isReady) { _, ready in
                guard ready, let window = NSApp.mainWindow else { return }
                window.setContentSize(NSSize(width: 1440, height: 850))
                window.center()
            }
        }
        .defaultSize(width: 520, height: 590)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("음성 파일 열기…") { model?.importAudio() }.keyboardShortcut("o").disabled(!startup.isReady || model?.canStart != true)
                Button("지난 회의…") { NotificationCenter.default.post(name: MeetingHistoryPresentation.show, object: nil) }
                    .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(!startup.isReady)
                Button("JSON 저장…") { model?.saveJSON() }.keyboardShortcut("s").disabled(!startup.isReady || model?.canExport != true)
            }
            CommandGroup(replacing: .help) {
                Button("테이블로그 사용법·도움말", action: AppHelp.openGuide)
                    .keyboardShortcut("?", modifiers: [.command])
                Button("AI CLI 연결 안내", action: AppHelp.openCLISetup)
                Button("GitHub 저장소", action: AppHelp.openRepository)
            }
            CommandMenu("AI") {
                Button("AI CLI 설정…") { NotificationCenter.default.post(name: AppHelp.showAISettings, object: nil) }.disabled(!startup.isReady)
            }
            CommandMenu("전사") {
                Button("새 회의") { model?.newMeeting() }.keyboardShortcut("n", modifiers: [.command]).disabled(!startup.isReady || model?.canPrepareMeeting != true)
                Button("녹음 시작") { model?.start() }.keyboardShortcut("r", modifiers: [.command]).disabled(!startup.isReady || model?.canStartRecording != true)
                Button(model?.pauseTitle ?? "일시정지") { model?.togglePause() }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!startup.isReady || model?.canPause != true)
                Button("종료 · 저장") { model?.stop() }.keyboardShortcut(".", modifiers: [.command]).disabled(!startup.isReady || model?.canStop != true)
                Divider()
                Button("발언 복사") { model?.copyTranscript() }.disabled(!startup.isReady || model?.canExport != true)
                Button("저장 위치 열기") { model?.revealLastSave() }.disabled(!startup.isReady || model?.lastSavedURL == nil)
            }
        }
        Window("강의 메모·자료", id: "lecture-input") {
            if let model, startup.isReady { LectureInputWindow(model: model) }
            else { AppStartupView(startup: startup) }
        }.defaultSize(width:900,height:720)
        Settings {
            if model != nil { StorageSettingsView() }
            else { Text("저장 위치를 확인하고 있어요.").padding(32) }
        }
    }
}

struct LectureInputWindow: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        MeetingWorkspaceView(model:model,workspace:model.meeting,dismiss:{ dismissWindow(id:"lecture-input") },initialTab:3)
    }
}
