import Foundation
import AVFoundation
import HwajaNative

/// The engine and each recognition stream stay on this serial queue.
/// The small lock protects submission accounting and file cancellation only.
final class EngineWorker {
    private let queue = DispatchQueue(label: "TableLog.inference", qos: .userInitiated)
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var loadedProfile: Int32?
    private var loadedContext: Int32?
    private var pendingSamples = 0
    private var submittedSession: UUID?
    private var acceptingAudio = false
    private var cancelled = false
    private var audioObserver: ((UUID, [Float]) -> Void)?
    private var queueSession: UUID?
    private var lastJSON = ""
    private var lastEmission = Date.distantPast
    private let maxPendingSamples = 16000 * 8

    var backlogSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(pendingSamples) / 16000
    }

    /// Called synchronously on the recognition queue after each accepted PCM packet.
    /// The observer should only append to a bounded buffer and notify its consumer.
    func setAudioObserver(_ observer: ((UUID, [Float]) -> Void)?) {
        lock.lock(); audioObserver = observer; lock.unlock()
    }

    func load(lowLatency: Bool, tuning: EngineTuningSettings = EngineTuningSettings(), completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                try self.ensureLoaded(context: lowLatency ? 3 : 13, profile: Int32(tuning.diarProfile))
                DispatchQueue.main.async { completion(.success(())) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    private func nativeError() -> AppFailure {
        let pointer = hn_engine_last_error(handle)
        return AppFailure(message: pointer.map { String(cString: $0) } ?? "음성 엔진 상태를 확인해 주세요.")
    }

    private func ensureLoaded(context: Int32, profile: Int32) throws {
        if handle != nil && loadedContext == context && loadedProfile == profile { return }
        if let handle { hn_engine_destroy(handle); self.handle = nil }
        let asr = try TableLogModels.require(.asr).path
        let diar = try TableLogModels.require(.diarization).path
        handle = asr.withCString { a in diar.withCString { d in hn_engine_create_configured(a, d, context, profile) } }
        guard handle != nil else { throw nativeError() }
        loadedContext = context; loadedProfile = profile
    }

    private func beginOnQueue(_ id: UUID, lowLatency: Bool, phrases: [String], tuning: EngineTuningSettings, resetCancellation: Bool = true) throws {
        try ensureLoaded(context: lowLatency ? 3 : 13, profile: Int32(tuning.diarProfile))
        let buffers = phrases.map { strdup($0) }
        defer { buffers.forEach { free($0) } }
        let pointers = buffers.map { $0.map { UnsafePointer<CChar>($0) } }
        let result = pointers.withUnsafeBufferPointer {
            hn_engine_start_configured(handle, $0.baseAddress, $0.count, tuning.vocabularyBoost, tuning.automaticPunctuation ? 1 : 0)
        }
        guard result == 0 else { throw nativeError() }
        queueSession = id
        lastJSON = ""
        lastEmission = .distantPast
        lock.lock()
        submittedSession = id; pendingSamples = 0; acceptingAudio = true
        if resetCancellation { cancelled = false }
        lock.unlock()
    }

    func begin(_ id: UUID, lowLatency: Bool, phrases: [String] = [], tuning: EngineTuningSettings = EngineTuningSettings(), completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                try self.beginOnQueue(id, lowLatency: lowLatency, phrases: phrases, tuning: tuning)
                DispatchQueue.main.async { completion(.success(())) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    /// false means explicit backpressure. Already accepted packets remain ordered.
    func submit(_ samples: [Float], session: UUID,
                onSnapshot: @escaping (EngineSnapshot) -> Void,
                onError: @escaping (Error) -> Void) -> Bool {
        lock.lock()
        guard submittedSession == session && acceptingAudio else { lock.unlock(); return true }
        if pendingSamples + samples.count > maxPendingSamples {
            acceptingAudio = false; lock.unlock(); return false
        }
        pendingSamples += samples.count
        lock.unlock()
        queue.async {
            defer {
                self.lock.lock(); self.pendingSamples -= samples.count; self.lock.unlock()
            }
            guard self.queueSession == session else { return }
            do {
                try self.pushOnQueue(samples)
                if let snapshot = try self.snapshotOnQueue(force: false) {
                    DispatchQueue.main.async { onSnapshot(snapshot) }
                }
            } catch {
                self.lock.lock(); self.acceptingAudio = false; self.lock.unlock()
                self.queueSession = nil
                DispatchQueue.main.async { onError(error) }
            }
        }
        return true
    }

    private func pushOnQueue(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for offset in stride(from: 0, to: buffer.count, by: 1600) {
                let count = min(1600, buffer.count - offset)
                guard hn_engine_push(handle, base.advanced(by: offset), count) == 0 else { throw nativeError() }
                if let session = queueSession {
                    lock.lock(); let observer = audioObserver; lock.unlock()
                    observer?(session, Array(UnsafeBufferPointer(start: base.advanced(by: offset), count: count)))
                }
            }
        }
    }

    private func snapshotOnQueue(force: Bool) throws -> EngineSnapshot? {
        if !force && Date().timeIntervalSince(lastEmission) < 0.12 { return nil }
        guard let pointer = hn_engine_snapshot_json(handle) else { throw nativeError() }
        let string = String(cString: pointer)
        if !force && string == lastJSON { return nil }
        let snapshot = try JSONDecoder().decode(EngineSnapshot.self, from: Data(string.utf8))
        lastJSON = string; lastEmission = Date()
        return snapshot
    }

    func finish(session: UUID, completion: @escaping (Result<EngineSnapshot, Error>) -> Void) {
        lock.lock(); acceptingAudio = false; lock.unlock()
        queue.async {
            do {
                guard self.handle != nil else { throw self.nativeError() }
                guard hn_engine_finish(self.handle) == 0 else { throw self.nativeError() }
                guard let snapshot = try self.snapshotOnQueue(force: true) else { throw self.nativeError() }
                self.queueSession = nil
                DispatchQueue.main.async { completion(.success(snapshot)) }
            } catch {
                self.queueSession = nil
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func cancelFile() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Release Metal buffers before the process-level ggml backend destructors.
    func shutdown(completion: @escaping () -> Void) {
        lock.lock(); acceptingAudio = false; cancelled = true; lock.unlock()
        queue.async {
            if let handle = self.handle { hn_engine_destroy(handle); self.handle = nil }
            self.loadedContext = nil; self.queueSession = nil
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Uses the same stream as the microphone, with bounded file decoding on the engine queue.
    func transcribeFile(_ url: URL, session: UUID, lowLatency: Bool, phrases: [String] = [], tuning: EngineTuningSettings = EngineTuningSettings(),
                        shouldPauseAudio: ((UUID) -> Bool)? = nil,
                        onProgress: ((AudioFileProgress) -> Void)? = nil,
                        onSnapshot: @escaping (EngineSnapshot) -> Void,
                        completion: @escaping (Result<(EngineSnapshot, Bool), Error>) -> Void) {
        lock.lock(); cancelled = false; lock.unlock()
        if let onProgress {
            let progress = AudioFileProgress(stage: .preparingEngine, processedSeconds: 0, totalSeconds: nil)
            DispatchQueue.main.async { onProgress(progress) }
        }
        queue.async {
            var fileSamples = 0
            var totalSeconds: Double?
            var lastProgressStage: AudioFileProgress.Stage = .preparingEngine
            var lastProgressAt = ProcessInfo.processInfo.systemUptime
            func emitProgress(_ stage: AudioFileProgress.Stage) {
                guard let onProgress else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard stage != lastProgressStage || now - lastProgressAt >= 0.25 else { return }
                lastProgressStage = stage
                lastProgressAt = now
                let progress = AudioFileProgress(stage: stage, processedSeconds: Double(fileSamples) / 16000,
                                                 totalSeconds: totalSeconds)
                DispatchQueue.main.async { onProgress(progress) }
            }
            do {
                try self.beginOnQueue(session, lowLatency: lowLatency, phrases: phrases, tuning: tuning, resetCancellation: false)
                emitProgress(.openingFile)
                let file = try AVAudioFile(forReading: url)
                let source = file.processingFormat
                if source.sampleRate.isFinite && source.sampleRate > 0 {
                    let duration = Double(file.length) / source.sampleRate
                    if duration.isFinite && duration > 0 { totalSeconds = duration }
                }
                guard let destination = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                      let converter = AVAudioConverter(from: source, to: destination),
                      let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 8192),
                      let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: 1600) else {
                    throw AppFailure(message: "이 음성 파일의 오디오 형식을 확인해 주세요.")
                }
                converter.downmix = true
                var reachedEOF = false
                let paced = CommandLine.arguments.contains("--test-paced")
                let fileStartedAt = ProcessInfo.processInfo.systemUptime
                emitProgress(.transcribing)
                while !self.isCancelled {
                    // File decoding can outrun the cloud service. Wait on this
                    // worker only; microphone ingress and the UI never use this gate.
                    while !self.isCancelled && shouldPauseAudio?(session) == true {
                        emitProgress(.waitingForCloud)
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                    if self.isCancelled { break }
                    if lastProgressStage == .waitingForCloud { emitProgress(.transcribing) }
                    var readError: Error?
                    var conversionError: NSError?
                    let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                        // AVAudioFile can throw nilError for a read at EOF. Signal EOF
                        // before reading and let AVAudioConverter emit its remaining tail.
                        let remaining = file.length - file.framePosition
                        if reachedEOF || remaining <= 0 {
                            reachedEOF = true; inputStatus.pointee = .endOfStream; return nil
                        }
                        do {
                            let count = AVAudioFrameCount(min(Int64(input.frameCapacity), Int64(requested), remaining))
                            try file.read(into: input, frameCount: count)
                            if input.frameLength == 0 {
                                reachedEOF = true; inputStatus.pointee = .endOfStream; return nil
                            }
                            inputStatus.pointee = .haveData
                            return input
                        } catch {
                            readError = error; inputStatus.pointee = .endOfStream; return nil
                        }
                    }
                    if let readError { throw readError }
                    if let conversionError { throw conversionError }
                    if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                        try self.pushOnQueue(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
                        fileSamples += Int(output.frameLength)
                        emitProgress(.transcribing)
                        if let snapshot = try self.snapshotOnQueue(force: false) {
                            DispatchQueue.main.async { onSnapshot(snapshot) }
                        }
                        if paced {
                            let remaining = Double(fileSamples) / 16000 - (ProcessInfo.processInfo.systemUptime - fileStartedAt)
                            if remaining > 0 { Thread.sleep(forTimeInterval: min(0.1, remaining)) }
                        }
                    }
                    if status == .endOfStream { break }
                    if status == .error { throw AppFailure(message: "음성 파일 변환 중 오류가 발생했습니다.") }
                    if output.frameLength == 0 && reachedEOF { break }
                }
                let stopped = self.isCancelled
                emitProgress(.finishing)
                guard hn_engine_finish(self.handle) == 0 else { throw self.nativeError() }
                guard let snapshot = try self.snapshotOnQueue(force: true) else { throw self.nativeError() }
                self.queueSession = nil
                self.lock.lock(); self.acceptingAudio = false; self.lock.unlock()
                DispatchQueue.main.async { completion(.success((snapshot, stopped))) }
            } catch {
                self.queueSession = nil
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
