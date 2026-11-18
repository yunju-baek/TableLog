import Foundation
import Combine

/// Frequently changing meters have their own observation scope, outside the transcript model.
@MainActor final class CaptureMetrics: ObservableObject {
    private(set) var seconds: Double = 0
    private(set) var queuedSeconds: Double = 0
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var backlog: String?
    func setSeconds(_ value: Double) {
        seconds=value
        let elapsed=Int(max(0,value))
        if elapsedSeconds != elapsed { elapsedSeconds=elapsed }
    }
    func setLevel(_ value: Double) {
        if level != value { level=value }
    }
    func setQueue(_ value: Double) {
        queuedSeconds=value
        let label=value>1 ? String(format:"처리 대기 %.1f초",value) : nil
        if backlog != label { backlog=label }
    }
}

/// Keep one pending UI delivery even while the main thread is busy.
final class LatestMainDelivery<Value>: @unchecked Sendable {
    private let lock=NSLock()
    private var pending: Value?
    private var scheduled=false
    private let interval: TimeInterval
    private let deliver: (Value) -> Void
    init(interval:TimeInterval=0,deliver:@escaping (Value)->Void) {
        self.interval=interval;self.deliver=deliver
    }
    func publish(_ value:Value) {
        lock.lock();pending=value
        let enqueue = !scheduled;scheduled=true;lock.unlock()
        guard enqueue else { return }
        DispatchQueue.main.asyncAfter(deadline:.now()+interval) { [self] in
            lock.lock();let latest=pending;pending=nil;scheduled=false;lock.unlock()
            if let latest { deliver(latest) }
        }
    }
    func cancelPending() {
        lock.lock();pending=nil;lock.unlock()
    }
}
