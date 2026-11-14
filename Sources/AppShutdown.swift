import AppKit
import SwiftUI

enum AppShutdownStage: Equatable {
    case tasks, audio, transcript, minutes, engines, finished

    var message: String {
        switch self {
        case .tasks: return "AI와 자료 작업을 정리해요."
        case .audio: return "녹음을 저장하고 남은 발언을 정리해요."
        case .transcript: return "전사록과 편집 내용을 저장해요."
        case .minutes: return "AI 회의록 저장을 기다려요."
        case .engines: return "음성 모델과 백그라운드 엔진을 정리해요."
        case .finished: return "저장을 마쳤어요. 앱을 닫아요."
        }
    }
}

@MainActor final class AppShutdownWindow {
    private let panel: NSPanel

    init(model: AppModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "테이블로그 종료"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentView = NSHostingView(rootView: AppShutdownView(model: model, meeting: model.meeting))
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() { panel.close() }
}

private struct AppShutdownView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meeting: MeetingWorkspace
    @State private var startedAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                   let logo = NSImage(contentsOf: url) {
                    Image(nsImage: logo).resizable().frame(width: 58, height: 58)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("테이블로그를 닫고 있어요").font(.system(size: 21, weight: .bold))
                    Text("진행 중인 작업을 마무리해요.").font(.system(size: 13)).foregroundStyle(AppTheme.muted)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 8) {
                    Text((model.shutdownStage ?? .tasks).message).font(.system(size: 14, weight: .medium))
                    if model.shutdownStage == .minutes, meeting.busy {
                        Text(meeting.displayStatus).font(.system(size: 12)).foregroundStyle(AppTheme.muted)
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text("마무리 중 · \(max(0, Int(context.date.timeIntervalSince(startedAt))))초")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.muted).monospacedDigit()
            }
        }
        .padding(30).frame(width: 480).frame(minHeight: 280, alignment: .leading)
        .background(AppTheme.paper).foregroundStyle(AppTheme.ink)
        .preferredColorScheme(.light)
    }
}
