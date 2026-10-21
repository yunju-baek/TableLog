import Foundation

enum CodexJobPriority: Int, Sendable {
    case material = 20, minutes = 40, assistant = 60, correction = 80, userQuestion = 100
}

enum CodexJobContext {
    @TaskLocal static var priority: CodexJobPriority = .correction
}

/// One permit covers one CLI invocation. Long workflows return to this queue at each call.
actor CodexJobScheduler {
    static let shared = CodexJobScheduler()
    struct Waiting {
        let id: UUID
        let priority: CodexJobPriority
        let enqueued: Date
        let continuation: CheckedContinuation<UUID, Error>
    }
    private var active: UUID?
    private var waiting: [Waiting] = []
    private let now: @Sendable () -> Date
    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    func acquire(priority: CodexJobPriority) async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if active == nil {
                    active = id
                    continuation.resume(returning: id)
                } else {
                    waiting.append(Waiting(id: id, priority: priority, enqueued: now(), continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func release(_ id: UUID) {
        guard active == id else { return }
        active = nil
        guard !waiting.isEmpty else { return }
        let time = now()
        // Aging lets background work overtake fresh requests after a bounded wait.
        func score(_ item: Waiting) -> Double {
            Double(item.priority.rawValue) + max(0, time.timeIntervalSince(item.enqueued)) / 2
        }
        var selected = 0
        for index in waiting.indices.dropFirst() where score(waiting[index]) > score(waiting[selected]) { selected = index }
        let item = waiting.remove(at: selected)
        active = item.id
        item.continuation.resume(returning: item.id)
    }

    var pendingCount: Int { waiting.count }
}
