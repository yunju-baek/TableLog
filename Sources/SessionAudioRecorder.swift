import AVFoundation
import AudioToolbox
import Darwin
import Foundation

enum SessionAudioRecorderError: LocalizedError {
    case fileAlreadyExists(String)
    case fileCreationFailed(String)
    case invalidSamples
    case backlogExceeded
    case writeFailed(String)
    case finalizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileAlreadyExists(let path):
            return "같은 녹음 파일이 이미 존재합니다. 새 회의로 녹음을 시작해 주세요. \(path)"
        case .fileCreationFailed(let detail):
            return "M4A 녹음 파일 생성에 실패했습니다. \(detail)"
        case .invalidSamples:
            return "M4A 녹음 입력에 유효한 범위를 벗어난 음성 값이 포함되어 있습니다."
        case .backlogExceeded:
            return "M4A 저장 대기 음성이 30초를 초과했습니다. 저장 공간과 디스크 상태를 확인해 주세요."
        case .writeFailed(let detail):
            return "M4A 음성 저장 중 오류가 발생했습니다. \(detail)"
        case .finalizationFailed(let detail):
            return "M4A 녹음 파일 마무리 중 오류가 발생했습니다. \(detail)"
        }
    }
}

/// Writes the exact mono 16 kHz PCM supplied to recognition as an AAC M4A sidecar.
/// append performs no disk I/O. finish drains accepted packets and closes the
/// encoder before publishing the final URL. Call finish after the audio producer
/// has stopped, preferably from its existing background queue.
final class SessionAudioRecorder: @unchecked Sendable {
    static let sampleRate = 16_000.0
    // Apple's mono AAC encoder accepts up to 48 kbps at this sample rate.
    static let bitRate = 48_000
    static let maximumPendingSamples = 16_000 * 30

    let url: URL
    let recordingURL: URL

    private let queue = DispatchQueue(label: "kr.hwajanote.audio.m4a", qos: .utility)
    private let lock = NSLock()
    private var accepting = true
    private var pendingSamples = 0
    private var writtenSamples: Int64 = 0
    private var firstError: Error?

    // Accessed only on queue after init. Releasing AVAudioFile closes its encoder.
    private var writer: AVAudioFile?
    private var finishResult: Result<URL?, Error>?

    var capturedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(writtenSamples) / Self.sampleRate
    }

    init(directory: URL, sessionID: UUID) throws {
        url = directory.appendingPathComponent(sessionID.uuidString).appendingPathExtension("m4a")
        recordingURL = directory.appendingPathComponent(sessionID.uuidString + ".recording.m4a")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw SessionAudioRecorderError.fileCreationFailed(error.localizedDescription)
        }
        // lstat also recognizes a dangling symlink as an occupied destination.
        var finalInfo = stat()
        guard lstat(url.path, &finalInfo) != 0 else {
            throw SessionAudioRecorderError.fileAlreadyExists(url.path)
        }
        let descriptor = open(recordingURL.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else {
            if errno == EEXIST { throw SessionAudioRecorderError.fileAlreadyExists(recordingURL.path) }
            throw SessionAudioRecorderError.fileCreationFailed(String(cString: strerror(errno)))
        }
        close(descriptor)
        do {
            writer = try AVAudioFile(forWriting: recordingURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: Self.bitRate,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordingURL.path)
        } catch {
            writer = nil
            try? FileManager.default.removeItem(at: recordingURL)
            throw SessionAudioRecorderError.fileCreationFailed(error.localizedDescription)
        }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard accepting, firstError == nil else { return }
        guard samples.allSatisfy(\.isFinite) else {
            firstError = SessionAudioRecorderError.invalidSamples
            accepting = false
            return
        }
        guard samples.count <= Self.maximumPendingSamples - pendingSamples else {
            firstError = SessionAudioRecorderError.backlogExceeded
            accepting = false
            return
        }
        pendingSamples += samples.count
        // Enqueue under lock, so finish's barrier follows every accepted packet.
        queue.async { [self] in
            defer {
                lock.lock()
                pendingSamples -= samples.count
                lock.unlock()
            }
            lock.lock()
            let failed = firstError != nil
            lock.unlock()
            guard !failed else { return }
            autoreleasepool {
                guard let writer,
                      let buffer = AVAudioPCMBuffer(pcmFormat: writer.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(samples.count)),
                      let destination = buffer.floatChannelData?[0] else {
                    recordFailure(SessionAudioRecorderError.writeFailed("음성 버퍼 할당에 실패했습니다."))
                    return
                }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { pointer in
                    destination.update(from: pointer.baseAddress!, count: pointer.count)
                }
                do {
                    try writer.write(from: buffer)
                    lock.lock()
                    writtenSamples += Int64(samples.count)
                    lock.unlock()
                } catch {
                    recordFailure(SessionAudioRecorderError.writeFailed(error.localizedDescription))
                }
            }
        }
    }

    func checkError() throws {
        lock.lock()
        let error = firstError
        lock.unlock()
        if let error { throw error }
    }

    /// Idempotent, including failure. A failed recording retains any partial M4A
    /// at recordingURL; the error names that path when it exists.
    @discardableResult
    func finish() throws -> URL? {
        lock.lock()
        accepting = false
        lock.unlock()
        return try queue.sync {
            if let finishResult { return try finishResult.get() }
            writer = nil
            let result = Result<URL?, Error> {
                do {
                    try checkError()
                    lock.lock()
                    let count = writtenSamples
                    lock.unlock()
                    if count == 0 {
                        try FileManager.default.removeItem(at: recordingURL)
                        return nil
                    }
                    try FileManager.default.moveItem(at: recordingURL, to: url)
                    return url
                } catch {
                    let partial = FileManager.default.fileExists(atPath: recordingURL.path)
                        ? " 저장된 부분 파일: \(recordingURL.path)" : ""
                    let failure = SessionAudioRecorderError.finalizationFailed(error.localizedDescription + partial)
                    recordFailure(failure)
                    throw failure
                }
            }
            finishResult = result
            return try result.get()
        }
    }

    private func recordFailure(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if firstError == nil { firstError = error }
        accepting = false
    }
}
