import Foundation
import Darwin

/// Owns one POSIX child and reaps its exit on the same worker that launched it.
/// Completion and cancellation are independent of Foundation Process/run-loop notifications.
final class ManagedChildProcess: @unchecked Sendable {
    enum Failure: LocalizedError {
        case timeout, termination
        var errorDescription: String? {
            switch self {
            case .timeout: return "외부 프로그램의 실행 제한 시간이 지났어요. 저장된 초안을 확인해 주세요."
            case .termination: return "외부 프로그램의 종료 확인 시간이 지났어요. 저장된 초안을 확인해 주세요."
            }
        }
    }
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func run(executable: URL, arguments: [String], environment: [String: String], directory: URL,
             input: URL, output: URL, diagnostics: URL, timeout: TimeInterval,
             inspectOutput: (() throws -> Void)? = nil) throws -> Int32 {
        if isCancelled { throw CancellationError() }
        let read = try FileHandle(forReadingFrom: input)
        let out = try FileHandle(forWritingTo: output)
        let err = try FileHandle(forWritingTo: diagnostics)
        defer { try? read.close(); try? out.close(); try? err.close() }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func checked(_ code: Int32) throws {
            if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawn_file_actions_adddup2(&actions, read.fileDescriptor, STDIN_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, out.fileDescriptor, STDOUT_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, err.fileDescriptor, STDERR_FILENO))
        try checked(posix_spawn_file_actions_addchdir(&actions, directory.path))
        // A private group lets cancellation stop the CLI and helpers it creates.
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        var env = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        if isCancelled { throw CancellationError() }
        let spawned = argv.withUnsafeMutableBufferPointer { a in
            env.withUnsafeMutableBufferPointer { e in
                posix_spawn(&pid, executable.path, &actions, &attributes, a.baseAddress!, e.baseAddress!)
            }
        }
        try checked(spawned)
        let started = ProcessInfo.processInfo.systemUptime
        var failure: Error?
        var stoppingAt: TimeInterval?
        var killed = false
        while true {
            var status: Int32 = 0
            let exited = waitpid(pid, &status, WNOHANG)
            if exited == pid {
                if let failure { throw failure }
                if isCancelled { throw CancellationError() }
                // WIFEXITED/WEXITSTATUS are C macros unavailable to Swift.
                return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            }
            if exited < 0 && errno != EINTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil {
                if isCancelled { failure = CancellationError() }
                else if now - started >= timeout { failure = Failure.timeout }
                else {
                    do { try inspectOutput?() }
                    catch { failure = error }
                }
                if failure != nil { stoppingAt = now; kill(-pid, SIGTERM) }
            }
            if let stoppingAt {
                if !killed && now - stoppingAt >= 2 { kill(-pid, SIGKILL); killed = true }
                if now - stoppingAt >= 5 {
                    // Keep ownership of the eventual reap even if the kernel delays termination.
                    let ownedPID = pid
                    DispatchQueue.global(qos: .utility).async {
                        var status: Int32 = 0
                        while waitpid(ownedPID, &status, 0) < 0 && errno == EINTR {}
                    }
                    throw failure ?? Failure.termination
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
