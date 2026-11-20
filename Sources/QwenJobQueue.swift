import Foundation

/// Keep one Python/model process alive. Cancellation holds the slot until it exits.
@MainActor final class QwenJobQueue {
    typealias Output = Result<[HybridTranscript.TimedChunk], Error>
    typealias Launcher = (URL, String, @escaping (Output) -> Void) throws -> (() -> Void)
    static let shared = QwenJobQueue()
    private struct Job {
        let id: UUID
        let audio: URL
        let context: String
        let onStart: () -> Void
        let completion: (Output) -> Void
    }
    private let launch: Launcher
    private var waiting: [Job] = []
    private var running: Job?
    private var cancelRunning: (() -> Void)?
    private var cancelled = Set<UUID>()
    init(launch: Launcher? = nil) {
        self.launch = launch ?? { audio, context, completion in
            let process = try QwenTranscriber.start(audio: audio, context: context, completion: completion)
            return {
                if process.isRunning { process.terminate() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }
    func enqueue(audio: URL, context: String, onStart: @escaping () -> Void = {},
                 completion: @escaping (Output) -> Void) -> UUID {
        let id = UUID()
        waiting.append(Job(id: id, audio: audio, context: context, onStart: onStart, completion: completion))
        // The caller installs its handle before a launch failure can complete.
        DispatchQueue.main.async { self.startNext() }
        return id
    }
    func cancel(_ id: UUID) {
        waiting.removeAll { $0.id == id }
        if running?.id == id, cancelled.insert(id).inserted { cancelRunning?() }
    }
    private func startNext() {
        guard running == nil, !waiting.isEmpty else { return }
        let job = waiting.removeFirst()
        running = job; job.onStart()
        do {
            cancelRunning = try launch(job.audio, job.context) { [weak self] result in
                DispatchQueue.main.async { self?.finish(job.id, result: result) }
            }
        } catch { finish(job.id, result: .failure(error)) }
    }
    private func finish(_ id: UUID, result: Output) {
        guard let job = running, job.id == id else { return }
        running = nil; cancelRunning = nil
        if cancelled.remove(id) == nil { job.completion(result) }
        startNext()
    }
}
