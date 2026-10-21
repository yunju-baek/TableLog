import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct MicrophoneDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}

enum MicrophoneCaptureError: LocalizedError {
    case permissionRequired
    case inputUnavailable
    case deviceSelectionFailed(OSStatus)
    case invalidInputFormat
    case conversionFailed(String)
    case captureBacklogExceeded
    case configurationChanged
    case engineRecoveryFailed(String)
    case sessionStillActive
    case deviceQueryFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "시스템 설정에서 테이블로그의 마이크 사용 권한을 허용해 주세요."
        case .inputUnavailable:
            return "사용 가능한 마이크 입력을 확인해 주세요."
        case .deviceSelectionFailed(let status):
            return "마이크 선택 중 오류가 발생했습니다. (Core Audio \(status))"
        case .invalidInputFormat:
            return "마이크 입력 형식을 확인한 뒤 녹음을 다시 시작해 주세요."
        case .conversionFailed(let detail):
            return "마이크 음성 변환 중 오류가 발생했습니다. \(detail)"
        case .captureBacklogExceeded:
            return "마이크 처리 대기 시간이 10초를 초과하여 녹음을 종료합니다. 다른 작업을 줄인 뒤 다시 시작해 주세요."
        case .configurationChanged:
            return "마이크 연결 또는 입력 설정이 변경되었습니다. 장치를 확인한 뒤 녹음을 다시 시작해 주세요."
        case .engineRecoveryFailed(let detail):
            return "마이크 입력 재개 중 오류가 발생했습니다. 장치를 확인한 뒤 다시 시작해 주세요. \(detail)"
        case .sessionStillActive:
            return "현재 녹음 종료가 완료된 뒤 새 녹음을 시작해 주세요."
        case .deviceQueryFailed(let status):
            return "마이크 목록을 가져오는 중 오류가 발생했습니다. (Core Audio \(status))"
        }
    }
}

/// Main-thread start/stop API. Audio, level and error callbacks use processingQueue.
/// stop's main-thread completion follows every audio callback, including the final tail.
final class MicrophoneCapture {
    private let processingQueue = DispatchQueue(label: "kr.hwajanote.microphone.convert", qos: .userInitiated)
    private var currentSession: Session?

    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr else { throw MicrophoneCaptureError.deviceQueryFailed(status) }
        guard deviceID != kAudioObjectUnknown else { throw MicrophoneCaptureError.inputUnavailable }
        return deviceID
    }

    static func devices() throws -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else { throw MicrophoneCaptureError.deviceQueryFailed(status) }
        guard size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { throw MicrophoneCaptureError.deviceQueryFailed(status) }
        return ids.compactMap { deviceID -> MicrophoneDevice? in
            guard inputChannelCount(deviceID: deviceID) > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>? = nil
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let result = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
            let displayName = result == noErr ? (name?.takeRetainedValue() as String? ?? "마이크 \(deviceID)") : "마이크 \(deviceID)"
            return MicrophoneDevice(id: deviceID, name: displayName)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func inputChannelCount(deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    func start(
        deviceID: AudioDeviceID? = nil,
        onAudio: @escaping ([Float]) -> Void,
        onLevel: @escaping (Float) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard currentSession == nil else { throw MicrophoneCaptureError.sessionStillActive }
        guard Self.authorizationStatus == .authorized else { throw MicrophoneCaptureError.permissionRequired }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var selectedDevice = try deviceID ?? Self.defaultInputDeviceID()
        guard Self.inputChannelCount(deviceID: selectedDevice) > 0 else { throw MicrophoneCaptureError.inputUnavailable }
        guard let audioUnit = input.audioUnit else { throw MicrophoneCaptureError.inputUnavailable }
        let status = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &selectedDevice, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw MicrophoneCaptureError.deviceSelectionFailed(status) }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MicrophoneCaptureError.invalidInputFormat
        }
        let session = Session(engine: engine, converter: converter, inputDeviceID: selectedDevice, inputFormat: inputFormat,
                              outputFormat: outputFormat, onAudio: onAudio, onLevel: onLevel, onError: onError)
        currentSession = session
        input.installTap(onBus: 0, bufferSize: 1_600, format: inputFormat) { [weak self, weak session] buffer, _ in
            guard let self, let session else { return }
            self.receive(buffer, session: session)
        }
        session.tapInstalled = true
        do {
            engine.prepare()
            try engine.start()
            session.configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self, weak session] _ in
                guard let self, let session else { return }
                self.handleConfigurationChange(session: session)
            }
        } catch {
            stop(completion: {})
            throw error
        }
    }

    private func handleConfigurationChange(session: Session) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard currentSession === session, !session.stopping else { return }
        session.lock.lock()
        let accepting = session.accepting
        session.lock.unlock()
        guard accepting else { return }

        // AudioUnit device selection can deliver a deferred configuration notification
        // after start(). Inspect the live route instead of treating every notification
        // as a microphone disconnect. Engine graph access stays on the main queue.
        let input = session.engine.inputNode
        guard let audioUnit = input.audioUnit else {
            enqueueFailure(MicrophoneCaptureError.configurationChanged, session: session)
            return
        }
        var actualDevice = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &actualDevice, &size)
        let actualFormat = input.outputFormat(forBus: 0)
        guard status == noErr, actualDevice == session.inputDeviceID,
              actualFormat.isEqual(session.inputFormat) else {
            enqueueFailure(MicrophoneCaptureError.configurationChanged, session: session)
            return
        }
        if session.engine.isRunning { return }
        // A graph reconfiguration can stop an otherwise unchanged input route.
        // Recover it once; repeated stops and every genuine device/format change
        // remain explicit errors. Reentrant notifications still validate the route.
        if session.recoveringEngine { return }
        guard !session.recoveredStoppedEngine else {
            enqueueFailure(MicrophoneCaptureError.configurationChanged, session: session)
            return
        }
        session.recoveredStoppedEngine = true
        session.recoveringEngine = true
        defer { session.recoveringEngine = false }
        do {
            session.engine.prepare()
            try session.engine.start()
            guard session.engine.isRunning else {
                enqueueFailure(MicrophoneCaptureError.configurationChanged, session: session)
                return
            }
        } catch {
            enqueueFailure(MicrophoneCaptureError.engineRecoveryFailed(error.localizedDescription), session: session)
        }
    }

    func stop(completion: @escaping () -> Void = {}) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let session = currentSession else {
            DispatchQueue.main.async(execute: completion)
            return
        }
        session.stopCompletions.append(completion)
        guard !session.stopping else { return }
        session.stopping = true
        session.lock.lock()
        session.accepting = false
        session.lock.unlock()
        if let observer = session.configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            session.configurationObserver = nil
        }
        if session.tapInstalled {
            session.engine.inputNode.removeTap(onBus: 0)
            session.tapInstalled = false
        }
        session.engine.stop()
        // receive enqueues under the same lock used above, so every accepted buffer
        // reaches the processing queue before this drain operation.
        processingQueue.async { [self, session] in
            if !session.conversionFailed {
                do { try convert(nil, session: session, endOfStream: true) }
                catch { reportFailure(error, session: session) }
            }
            emitPackets(session: session, flush: true)
            session.onLevel(0)
            DispatchQueue.main.async { [self, session] in
                if currentSession === session { currentSession = nil }
                let completions = session.stopCompletions
                session.stopCompletions.removeAll()
                completions.forEach { $0() }
            }
        }
    }

    private func receive(_ source: AVAudioPCMBuffer, session: Session) {
        session.lock.lock()
        defer { session.lock.unlock() }
        guard session.accepting else { return }
        let frames = Int64(source.frameLength)
        guard session.pendingInputFrames + frames <= session.maximumPendingInputFrames else {
            session.accepting = false
            processingQueue.async { [self, session] in
                reportFailure(MicrophoneCaptureError.captureBacklogExceeded, session: session)
            }
            return
        }
        guard source.frameLength > 0 else { return }
        guard let copy = Self.copyPCMBuffer(source) else {
            session.accepting = false
            processingQueue.async { [self, session] in
                reportFailure(MicrophoneCaptureError.conversionFailed("음성 버퍼 복사에 실패했습니다."), session: session)
            }
            return
        }
        session.pendingInputFrames += frames
        // The tap retains only the private copy; AVAudioEngine can reuse source immediately.
        processingQueue.async { [self, session, copy] in
            defer {
                session.lock.lock()
                session.pendingInputFrames -= frames
                session.lock.unlock()
            }
            guard !session.conversionFailed else { return }
            do {
                try convert(copy, session: session, endOfStream: false)
                emitPackets(session: session, flush: false)
            } catch {
                session.conversionFailed = true
                reportFailure(error, session: session)
            }
        }
    }

    private static func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard from.count == to.count else { return nil }
        for index in from.indices {
            guard let sourceData = from[index].mData, let destinationData = to[index].mData,
                  to[index].mDataByteSize >= from[index].mDataByteSize else { return nil }
            memcpy(destinationData, sourceData, Int(from[index].mDataByteSize))
        }
        return copy
    }

    private func convert(_ input: AVAudioPCMBuffer?, session: Session, endOfStream: Bool) throws {
        var suppliedInput = false
        var iterations = 0
        repeat {
            guard let output = AVAudioPCMBuffer(pcmFormat: session.outputFormat, frameCapacity: 4_096) else {
                throw MicrophoneCaptureError.conversionFailed("출력 버퍼를 할당할 수 없습니다.")
            }
            var conversionError: NSError?
            let status = session.converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if let input, !suppliedInput {
                    suppliedInput = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if let conversionError {
                throw MicrophoneCaptureError.conversionFailed(conversionError.localizedDescription)
            }
            if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                session.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            switch status {
            case .haveData:
                iterations += 1
            case .inputRanDry, .endOfStream:
                return
            case .error:
                throw MicrophoneCaptureError.conversionFailed("AVAudioConverter 오류가 발생했습니다.")
            @unknown default:
                throw MicrophoneCaptureError.conversionFailed("음성 변환 상태를 확인해 주세요.")
            }
            guard iterations < 128 else {
                throw MicrophoneCaptureError.conversionFailed("음성 변환 처리 한도를 초과했습니다.")
            }
        } while true
    }

    private func emitPackets(session: Session, flush: Bool) {
        let packetSize = 1_600
        while session.samples.count - session.sampleOffset >= packetSize {
            emit(Array(session.samples[session.sampleOffset ..< session.sampleOffset + packetSize]), session: session)
            session.sampleOffset += packetSize
        }
        if flush, session.sampleOffset < session.samples.count {
            emit(Array(session.samples[session.sampleOffset...]), session: session)
            session.sampleOffset = session.samples.count
        }
        if session.sampleOffset > 0 {
            session.samples.removeFirst(session.sampleOffset)
            session.sampleOffset = 0
        }
    }

    private func emit(_ samples: [Float], session: Session) {
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        session.onLevel(sqrt(sumSquares / Float(max(1, samples.count))))
        session.onAudio(samples)
    }

    private func enqueueFailure(_ error: Error, session: Session) {
        session.lock.lock()
        defer { session.lock.unlock() }
        guard session.accepting else { return }
        session.accepting = false
        processingQueue.async { [self, session] in reportFailure(error, session: session) }
    }

    private func reportFailure(_ error: Error, session: Session) {
        guard !session.failureReported else { return }
        session.failureReported = true
        session.lock.lock()
        session.accepting = false
        session.lock.unlock()
        session.onError(error)
        DispatchQueue.main.async { [weak self, weak session] in
            guard let self, let session, self.currentSession === session else { return }
            self.stop()
        }
    }

    private final class Session {
        let engine: AVAudioEngine
        let converter: AVAudioConverter
        let inputDeviceID: AudioDeviceID
        let inputFormat: AVAudioFormat
        let outputFormat: AVAudioFormat
        let onAudio: ([Float]) -> Void
        let onLevel: (Float) -> Void
        let onError: (Error) -> Void
        let lock = NSLock()
        let maximumPendingInputFrames: Int64
        // Access under lock from audio callback, processing queue and main thread.
        var accepting = true
        var pendingInputFrames: Int64 = 0
        // Processing queue ownership.
        var samples: [Float] = []
        var sampleOffset = 0
        var conversionFailed = false
        var failureReported = false
        // Main-thread ownership.
        var tapInstalled = false
        var stopping = false
        var configurationObserver: NSObjectProtocol?
        var stopCompletions: [() -> Void] = []
        var recoveringEngine = false
        var recoveredStoppedEngine = false

        init(engine: AVAudioEngine, converter: AVAudioConverter, inputDeviceID: AudioDeviceID, inputFormat: AVAudioFormat,
             outputFormat: AVAudioFormat, onAudio: @escaping ([Float]) -> Void,
             onLevel: @escaping (Float) -> Void, onError: @escaping (Error) -> Void) {
            self.engine = engine
            self.converter = converter
            self.inputDeviceID = inputDeviceID
            self.inputFormat = inputFormat
            // AVAudioConverter defaults to selecting a channel. Mix stereo/multichannel
            // microphones into mono so both sides of an audio interface reach ASR.
            self.converter.downmix = true
            self.outputFormat = outputFormat
            self.maximumPendingInputFrames = Int64(inputFormat.sampleRate * 10)
            self.onAudio = onAudio
            self.onLevel = onLevel
            self.onError = onError
        }
    }
}
