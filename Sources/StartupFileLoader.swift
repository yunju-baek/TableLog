import Foundation

/// A filesystem read can remain blocked inside the kernel. A dispatch deadline releases
/// the UI independently; late workers only return values and never mutate app state.
enum StartupFileLoader {
    struct TimedOut: LocalizedError {
        let label: String
        var errorDescription: String? { "\(label) 파일 읽기가 지연되고 있어요. 원본을 보관한 상태로 다른 기능을 준비해요. 저장 위치를 확인한 뒤 앱을 다시 실행해 주세요." }
    }

    static func load<Value>(label: String, timeout: TimeInterval = 5,
                            operation: @escaping () throws -> Value) async -> Result<Value, Error> {
        await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                completion.finish(Result { try operation() })
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                completion.finish(.failure(TimedOut(label: label)))
            }
        }
    }

    private final class Completion<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<Value, Error>, Never>?
        init(_ continuation: CheckedContinuation<Result<Value, Error>, Never>) { self.continuation = continuation }
        func finish(_ result: Result<Value, Error>) {
            lock.lock()
            let pending = continuation; continuation = nil
            lock.unlock()
            pending?.resume(returning: result)
        }
    }
}
