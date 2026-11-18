import Foundation
import Combine

enum CodexJobPriority: Int, Sendable {
    case material = 20, minutes = 40, assistant = 60, correction = 80, userQuestion = 100
}
enum CodexJobContext {
    @TaskLocal static var priority: CodexJobPriority = .correction
}

@MainActor final class AIUsageStatus: ObservableObject {
    static let shared = AIUsageStatus()
    static let preferenceKey = "ai.quotaPausedProviders.v1"
    @Published private(set) var paused: Set<AITextProvider>
    private init() {
        paused = Set((UserDefaults.standard.stringArray(forKey: Self.preferenceKey) ?? []).compactMap(AITextProvider.init(rawValue:)))
    }
    func isPaused(_ provider: AITextProvider) -> Bool { paused.contains(provider) }
    func update(_ value: Set<AITextProvider>) { if paused != value { paused = value } }
}

/// A provider's quota failure drains its queue and persists until an explicit connection test succeeds.
actor CodexJobScheduler {
    static let shared = CodexJobScheduler()
    private struct Job {
        let id: UUID
        let provider: AITextProvider
        let probe: Bool
    }
    private struct Waiting {
        let job: Job
        let priority: CodexJobPriority
        let enqueued: Date
        let continuation: CheckedContinuation<UUID, Error>
    }
    private var active: Job?
    private var waiting: [Waiting] = []
    private var paused: Set<AITextProvider>
    private let now: @Sendable () -> Date
    private let defaults: UserDefaults?
    private let changed: @Sendable (Set<AITextProvider>) async -> Void
    private static let preferenceKey = "ai.quotaPausedProviders.v1"
    init(now: @escaping @Sendable () -> Date = { Date() }, defaults: UserDefaults? = .standard,
         changed: @escaping @Sendable (Set<AITextProvider>) async -> Void = { value in await MainActor.run { AIUsageStatus.shared.update(value) } }) {
        self.now = now; self.defaults = defaults; self.changed = changed
        paused = Set((defaults?.stringArray(forKey: Self.preferenceKey) ?? []).compactMap(AITextProvider.init(rawValue:)))
    }
    func acquire(priority: CodexJobPriority, provider: AITextProvider = .codex, probe: Bool = false) async throws -> UUID {
        let job = Job(id: UUID(), provider: provider, probe: probe)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if paused.contains(provider) && !probe { throw CodexFailure(kind: .quota) }
            if probe && (active.map { $0.provider == provider && $0.probe } == true || waiting.contains { $0.job.provider == provider && $0.job.probe }) {
                throw CodexFailure(kind: .busy)
            }
            guard waiting.count < 32 else { throw CodexFailure(kind: .busy) }
            return try await withCheckedThrowingContinuation { continuation in
                if active == nil { active = job; continuation.resume(returning: job.id) }
                else { waiting.append(Waiting(job: job, priority: priority, enqueued: now(), continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiting(job.id) }
        }
    }
    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.job.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    func release(_ id: UUID, failure: CodexFailure.Kind? = nil) async {
        guard let job = active, job.id == id else { return }
        if failure == .quota {
            paused.insert(job.provider)
            defaults?.set(paused.map(\.rawValue).sorted(), forKey: Self.preferenceKey)
            let rejected = waiting.filter { $0.job.provider == job.provider }
            waiting.removeAll { $0.job.provider == job.provider }
            rejected.forEach { $0.continuation.resume(throwing: CodexFailure(kind: .quota)) }
        }
        active = nil
        if !waiting.isEmpty {
            let time = now()
            func score(_ item: Waiting) -> Double { Double(item.priority.rawValue) + max(0, time.timeIntervalSince(item.enqueued)) / 2 }
            var selected = 0
            for index in waiting.indices.dropFirst() where score(waiting[index]) > score(waiting[selected]) { selected = index }
            let item = waiting.remove(at: selected)
            active = item.job; item.continuation.resume(returning: item.job.id)
        }
        if failure == .quota { await changed(paused) }
    }
    func resumeAfterConnectionTest(_ provider: AITextProvider) async {
        paused.remove(provider)
        defaults?.set(paused.map(\.rawValue).sorted(), forKey: Self.preferenceKey)
        await changed(paused)
    }
    func isPaused(_ provider: AITextProvider) -> Bool { paused.contains(provider) }
    var pendingCount: Int { waiting.count }
}
