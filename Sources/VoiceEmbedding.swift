import Foundation
import AVFoundation
import SherpaVoice

struct VoiceFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Bounded rolling PCM, on the same 16kHz clock as the NVIDIA engine.
final class VoiceAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var session = UUID()
    private var samples: [Float] = []
    private var base = 0
    private let capacity = 16000 * 180
    func reset(_ session: UUID) { lock.lock(); defer { lock.unlock() }; self.session = session; samples = []; base = 0 }
    func append(_ input: [Float], session: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard self.session == session else { return }
        samples.append(contentsOf: input)
        if samples.count > capacity + 16000 { let count = samples.count - capacity; samples.removeFirst(count); base += count }
    }
    func read(session: UUID, start: Double, end: Double) -> [Float]? {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end - start <= 60 else { return nil }
        lock.lock(); defer { lock.unlock() }
        let a = Int(start * 16000) - base, b = Int(end * 16000) - base
        guard session == self.session, a >= 0, b <= samples.count, b > a else { return nil }
        return Array(samples[a..<b])
    }
}

final class VoiceEmbedding: @unchecked Sendable {
    static let modelID = "nvidia-titanet-large-sherpa-onnx-v1"
    private let queue = DispatchQueue(label: "TableLog.voiceEmbedding", qos: .utility)
    private var extractor: OpaquePointer?
    let modelURL: URL
    init(modelURL: URL = TableLogModels.location(.voice)) { self.modelURL = modelURL }
    deinit { if let extractor { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) } }
    static func normalized(_ values: [Float]) -> [Float]? {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else { return nil }
        let magnitude = sqrt(values.reduce(0.0) { $0 + Double($1 * $1) })
        guard magnitude > 1e-8 else { return nil }
        return values.map { Float(Double($0) / magnitude) }
    }
    static func quality(_ pcm: [Float]) throws {
        guard (48000...960000).contains(pcm.count), pcm.allSatisfy(\.isFinite) else { throw VoiceFailure(message: "한 사람이 말한 3~60초 음성을 선택해 주세요.") }
        let rms = sqrt(pcm.reduce(0.0) { $0 + Double($1 * $1) } / Double(pcm.count))
        let clipped = Double(pcm.filter { abs($0) >= 0.999 }.count) / Double(pcm.count)
        var active = 0, frames = 0
        for a in stride(from: 0, to: pcm.count - 320, by: 320) {
            frames += 1
            let power = pcm[a..<a+320].reduce(Float(0)) { $0 + $1 * $1 } / 320
            if power > 0.000025 { active += 1 }
        }
        guard rms > 0.008, clipped < 0.03, Double(active) / Double(max(1,frames)) > 0.35 else {
            throw VoiceFailure(message: "음성이 작거나 무음·과입력이 많습니다. 가까운 거리에서 깨끗하게 녹음해 주세요.")
        }
    }
    func extract(_ pcm: [Float]) async throws -> [Float] {
        try Self.quality(pcm)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if self.extractor == nil {
                        guard FileManager.default.fileExists(atPath:self.modelURL.path) else { throw VoiceFailure(message:"앱의 TitaNet 목소리 모델을 확인해 주세요.") }
                        self.extractor = self.modelURL.path.withCString { path in "cpu".withCString { provider in
                            var config = SherpaOnnxSpeakerEmbeddingExtractorConfig(model:path,num_threads:2,debug:0,provider:provider)
                            return SherpaOnnxCreateSpeakerEmbeddingExtractor(&config)
                        }}
                    }
                    guard let ex = self.extractor, let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(ex) else { throw VoiceFailure(message:"목소리 모델 준비 오류") }
                    defer { SherpaOnnxDestroyOnlineStream(stream) }
                    pcm.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream,16000,$0.baseAddress,Int32($0.count)) }
                    SherpaOnnxOnlineStreamInputFinished(stream)
                    guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(ex,stream) != 0,
                          let ptr = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(ex,stream) else { throw VoiceFailure(message:"목소리 특징을 계산할 음성을 더 등록해 주세요.") }
                    defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(ptr) }
                    let values = Array(UnsafeBufferPointer(start:ptr,count:Int(SherpaOnnxSpeakerEmbeddingExtractorDim(ex))))
                    guard let vector = Self.normalized(values) else { throw VoiceFailure(message:"목소리 특징 값 검증 오류") }
                    continuation.resume(returning:vector)
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    static func readAudio(_ url: URL, start: Double = 0, duration: Double = 30) throws -> [Float] {
        guard start.isFinite, duration.isFinite, start >= 0, duration >= 3, duration <= 60 else { throw VoiceFailure(message:"시작 시간과 3~60초 범위를 확인해 주세요.") }
        let file = try AVAudioFile(forReading:url)
        guard start < Double(file.length) / file.processingFormat.sampleRate else { throw VoiceFailure(message:"선택한 시작 시간이 음성 길이를 초과합니다.") }
        file.framePosition = AVAudioFramePosition(start * file.processingFormat.sampleRate)
        let end = min(file.length, file.framePosition + AVAudioFramePosition(duration * file.processingFormat.sampleRate))
        let format = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false)!
        guard let converter = AVAudioConverter(from:file.processingFormat,to:format),
              let input = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:8192),
              let output = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:8192) else { throw VoiceFailure(message:"음성 파일 형식을 확인해 주세요.") }
        var pcm: [Float] = []
        while pcm.count < Int(duration * 16000) {
            var readError: Error?, conversionError: NSError?
            let status = converter.convert(to:output,error:&conversionError) { requested,state in
                if file.framePosition >= end { state.pointee = .endOfStream; return nil }
                do {
                    try file.read(into:input,frameCount:AVAudioFrameCount(min(Int64(requested),min(8192,end-file.framePosition))))
                    state.pointee = input.frameLength == 0 ? .endOfStream : .haveData; return input.frameLength == 0 ? nil : input
                } catch { readError = error; state.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }; if let conversionError { throw conversionError }
            if output.frameLength > 0 { pcm += Array(UnsafeBufferPointer(start:output.floatChannelData![0],count:Int(output.frameLength))) }
            if status == .endOfStream || status == .error { break }
        }
        return Array(pcm.prefix(Int(duration * 16000)))
    }
    static func writeM4A(_ pcm: [Float], to url: URL) throws {
        let file = try AVAudioFile(forWriting:url,settings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVEncoderBitRateKey:48000],commonFormat:.pcmFormatFloat32,interleaved:false)
        let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(pcm.count))!
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        pcm.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from:$0.baseAddress!,count:$0.count) }
        try file.write(from:buffer)
    }
}
