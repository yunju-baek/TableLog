import Foundation

/// One blocking read at a time. A timeout or cancellation releases the caller,
/// while the occupied slot stays reserved until the actual filesystem call returns.
final class BoundedFileRead: @unchecked Sendable {
    struct Delayed: LocalizedError {
        let label: String
        let alreadyRunning: Bool
        var errorDescription: String? {
            alreadyRunning
                ? "\(label)의 앞선 파일 읽기가 응답을 기다리고 있어요. 잠시 후 다시 시도해 주세요."
                : "\(label) 파일 읽기가 지연되고 있어요. 불러온 기록과 원본은 보관돼 있어요. 잠시 후 다시 시도해 주세요."
        }
    }

    private let lock = NSLock()
    private var occupied = false

    private func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !occupied else { return false }
        occupied = true; return true
    }
    private func release() {
        lock.lock(); occupied = false; lock.unlock()
    }

    func load<Value>(label: String, timeout: TimeInterval = 5,
                     operation: @escaping (@escaping () -> Bool) throws -> Value) async throws -> Value {
        let request = Request<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                guard !request.isFinished else { return }
                guard reserve() else {
                    request.finish(.failure(Delayed(label: label, alreadyRunning: true))); return
                }
                DispatchQueue.global(qos: .utility).async {
                    guard !request.isFinished else { self.release(); return }
                    let result = Result { try operation { request.isFinished } }
                    self.release()
                    request.finish(result)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    request.finish(.failure(Delayed(label: label, alreadyRunning: false)))
                }
            }
        } onCancel: {
            request.finish(.failure(CancellationError()))
        }
    }

    private final class Request<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var result: Result<Value, Error>?
        private var finished = false
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
        func install(_ continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            let completed = result
            result = nil
            if !finished { self.continuation = continuation }
            lock.unlock()
            if let completed { continuation.resume(with: completed) }
        }
        func finish(_ result: Result<Value, Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let pending = continuation; continuation = nil
            if pending == nil { self.result = result }
            lock.unlock()
            pending?.resume(with: result)
        }
    }
}
