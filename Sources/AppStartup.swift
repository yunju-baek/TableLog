import AppKit
import Combine
import SwiftUI

@MainActor final class AppStartup: ObservableObject {
    enum Step: String, CaseIterable, Identifiable {
        case preferences, storage, materials, voices, workspace, connections, engine
        var id: Self { self }
        var title: String {
            switch self {
            case .preferences: return "앱 설정"
            case .storage: return "저장 위치"
            case .materials: return "회의 자료"
            case .voices: return "학습한 목소리"
            case .workspace: return "회의록 서식"
            case .connections: return "마이크·AI 설정"
            case .engine: return "음성 인식·화자 분리 모델"
            }
        }
    }

    @Published private(set) var model: AppModel?
    @Published private(set) var current: Step = .preferences
    @Published private(set) var completed = Set<Step>()
    @Published private(set) var message = "테이블로그를 준비해요."
    @Published private(set) var failure: String?
    @Published private(set) var isReady = false
    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        await update(.preferences, "앱 설정을 불러와요.")
        await Task.detached(priority: .userInitiated) { AppIdentityMigration.preparePreferences() }.value

        await update(.storage, "회의와 녹음을 저장할 폴더를 확인해요.")
        let storage = await Task.detached(priority: .userInitiated) { StorageLocations.active }.value
        if let error = storage.startupError { message = error }

        await update(.materials, "회의 자료와 연결한 폴더를 불러와요.")
        let materials = MeetingMaterials()
        await update(.voices, "학습한 목소리와 이름을 불러와요.")
        let voice = VoiceIdentity()
        await update(.workspace, "회의록 서식과 작성 설정을 불러와요.")
        let meeting = MeetingWorkspace()
        await update(.connections, "마이크와 AI 설정을 준비해요.")
        let model = AppModel(materials: materials, meeting: meeting, loadEngine: false, voice: voice)
        self.model = model
        await loadEngine()
    }

    private func update(_ step: Step, _ message: String) async {
        if current != step { completed.insert(current) }
        current = step
        self.message = message
        // Give SwiftUI a render pass before the next main-actor initializer.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func loadEngine() async {
        guard let model else { return }
        failure = nil
        await update(.engine, "음성 인식 모델을 준비해요.")
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            model.prepareEngine(progress: { [weak self] message in self?.message = message }) {
                continuation.resume(returning: $0)
            }
        }
        switch result {
        case .success:
            completed.insert(.engine)
            message = "준비를 마쳤어요."
            isReady = true
        case .failure(let error):
            failure = error.localizedDescription
            message = "모델 준비가 멈췄어요. 파일과 설정을 확인해 주세요."
        }
    }

    func openSettings() { isReady = true }
}

struct AppStartupView: View {
    @ObservedObject var startup: AppStartup
    @State private var startedAt = Date()
    private static let logo = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                if let logo = Self.logo {
                    Image(nsImage: logo).resizable().interpolation(.high).frame(width: 76, height: 76)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("테이블로그").font(.system(size: 28, weight: .bold))
                    Text("회의를 함께 기록해요.").font(.system(size: 14)).foregroundStyle(AppTheme.muted)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(AppStartup.Step.allCases) { step in
                    HStack(spacing: 12) {
                        status(step).frame(width: 18, height: 18)
                        Text(step.title).font(.system(size: 13, weight: startup.current == step ? .semibold : .regular))
                        Spacer()
                        if startup.completed.contains(step) {
                            Text("완료").font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                        }
                    }
                    .foregroundStyle(startup.current == step || startup.completed.contains(step) ? AppTheme.ink : AppTheme.muted)
                }
            }
            .padding(20).background(.white, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 9) {
                Text(startup.message).font(.system(size: 13)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                if let failure = startup.failure {
                    ScrollView {
                        Text(failure).font(.system(size: 12)).foregroundStyle(AppTheme.rose).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 85)
                    HStack {
                        Button("다시 준비하기") { Task { await startup.loadEngine() } }
                            .buttonStyle(.borderedProminent)
                        Button("설정 확인하기", action: startup.openSettings)
                    }
                } else {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text("준비 중 · \(max(0, Int(context.date.timeIntervalSince(startedAt))))초")
                            .font(.system(size: 11)).foregroundStyle(AppTheme.muted).monospacedDigit()
                    }
                }
            }.frame(maxWidth: .infinity, minHeight: 65, alignment: .topLeading)
        }
        .padding(32)
        .frame(width: 520, alignment: .leading)
        .background(AppTheme.paper).foregroundStyle(AppTheme.ink).tint(AppTheme.violet)
        .preferredColorScheme(.light)
        .accessibilityIdentifier("TableLog.startup")
    }

    @ViewBuilder private func status(_ step: AppStartup.Step) -> some View {
        if startup.completed.contains(step) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.violet)
        } else if startup.current == step {
            if startup.failure != nil {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(AppTheme.rose)
            } else {
                ProgressView().controlSize(.small)
            }
        } else {
            Image(systemName: "circle").foregroundStyle(AppTheme.lavender)
        }
    }
}
