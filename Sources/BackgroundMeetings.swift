import Foundation
import Combine
import SwiftUI

/// File inference yields only when microphone input needs to catch up.
final class RecordingPriority: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var backlog = 0.0
    func update(active: Bool, backlog: Double) {
        lock.lock(); self.active = active; self.backlog = backlog; lock.unlock()
    }
    var shouldYield: Bool { lock.lock(); defer { lock.unlock() }; return active && backlog >= 0.5 }
    var pacingDelay: Double { lock.lock(); defer { lock.unlock() }; return active ? 0.025 : 0 }
}

@MainActor final class BackgroundMeetings: ObservableObject {
    struct Item: Identifiable {
        let id: UUID
        let title: String
        var status: String
        var completed: Bool
        var canStop: Bool
    }
    @Published private(set) var items: [Item] = []
    private(set) var models: [UUID: AppModel] = [:]
    private var retiring = Set<UUID>()
    private let priority = RecordingPriority()
    private var timer: Timer?
    private var shuttingDown = false
    private var quitCompletion: (() -> Void)?
    private var quittingModels = 0
    var select: ((AppModel) -> Void)?
    var makeNext: ((AppModel) -> AppModel)?
    var prepare: ((AppModel, Bool) -> Void)?

    init(automaticTicks: Bool = true) {
        if automaticTicks {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }
    func connect(_ model: AppModel) {
        model.recordingPriority = priority
        model.requestNextMeeting = { [weak self, weak model] record in
            guard let self, let model else { return }
            self.continueWithNewMeeting(from: model, record: record)
        }
        model.canImportWhileBackground = { [weak self] in
            self?.models.values.contains(where: { $0.processingFile }) != true
        }
        model.backgroundProtectsHistory = { [weak self] id in self?.models[id] != nil }
    }
    func continueWithNewMeeting(from old: AppModel, record: Bool) {
        guard !shuttingDown, old.canContinueInBackground else { return }
        let next = makeNext?(old) ?? old.makeNextMeeting()
        guard old.moveToBackground(next: next) else {
            next.prepareToQuit {}
            return
        }
        let id = old.editingSessionID
        models[id] = old
        items.append(Item(id: id, title: old.sessionTitle, status: old.displayStatusMessage, completed: false, canStop: true))
        // Retain only a short list of finished summaries; live models have independent lifetimes.
        let finished = items.filter(\.completed)
        if finished.count > 4 { let removed = Set(finished.dropLast(4).map(\.id)); items.removeAll { removed.contains($0.id) } }
        connect(next)
        select?(next)
        if let prepare { prepare(next, record) }
        else {
            next.prepareEngine(completion: { [weak next] result in
                guard let next, case .success = result else { return }
                next.newMeeting()
                if record { next.start() }
            })
        }
    }
    func tick() {
        guard !shuttingDown else { return }
        for (id, model) in models where !retiring.contains(id) {
            model.runPeriodicTasks()
            if let index = items.firstIndex(where: { $0.id == id }) {
                let status = model.displayStatusMessage
                if items[index].status != status { items[index].status = status }
                items[index].canStop = model.canStop || model.canCancelQwen || model.phase == .finishing
            }
            guard !model.backgroundWorkPending else { continue }
            retiring.insert(id)
            // Drain saves and release native buffers after minutes/corrections settle.
            model.prepareToQuit { [weak self] in
                guard let self else { return }
                self.models[id] = nil; self.retiring.remove(id)
                if let index = self.items.firstIndex(where: { $0.id == id }) { self.items[index].completed = true; self.items[index].canStop = false }
                self.finishQuitIfDrained()
            }
        }
    }
    func stop(_ id: UUID) { models[id]?.stopBackgroundWork() }
    func prepareToQuit(foreground: AppModel, completion: @escaping () -> Void) {
        shuttingDown = true; timer?.invalidate(); timer = nil
        priority.update(active: false, backlog: 0)
        let pending = [foreground] + models.filter { !retiring.contains($0.key) }.map(\.value)
        quitCompletion = completion
        quittingModels = pending.count
        for model in pending {
            model.prepareToQuit {
                self.quittingModels -= 1
                self.finishQuitIfDrained()
            }
        }
    }
    private func finishQuitIfDrained() {
        guard quittingModels == 0, retiring.isEmpty, let completion = quitCompletion else { return }
        quitCompletion = nil
        completion()
    }
}

struct BackgroundMeetingsView: View {
    @ObservedObject var jobs: BackgroundMeetings
    var body: some View {
        if !jobs.items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("이전 회의 처리", systemImage: "waveform.badge.magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                ForEach(jobs.items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.completed ? "checkmark.circle" : "hourglass")
                            .foregroundStyle(AppTheme.violet)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            Text(item.status)
                                .font(.system(size: 11)).foregroundStyle(AppTheme.muted).lineLimit(3)
                        }
                        Spacer(minLength: 0)
                        if item.canStop {
                            Button { jobs.stop(item.id) } label: { Image(systemName: "stop.circle") }
                                .buttonStyle(.plain).help("이전 회의 전사 중지 · 현재까지 저장")
                                .accessibilityLabel(item.title + " 백그라운드 전사 중지")
                        }
                    }
                }
                Button("결과 보기 · 지난 회의") {
                    NotificationCenter.default.post(name: MeetingHistoryPresentation.show, object: nil)
                }.font(.system(size: 12))
            }.padding(12).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
