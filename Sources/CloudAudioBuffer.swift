import Foundation

/// Mono 16 kHz audio with its exact position in the local recognition session.
struct CloudAudioChunk {
    let id: Int
    let startTime: Double
    let samples: [Float]
    var endTime: Double { startTime + Double(samples.count) / 16_000 }
}

/// A bounded handoff between the serial recognition queue and cloud requests.
/// On overflow the caller switches the session to its retained local transcript.
final class CloudAudioBuffer {
    public static let minimumSeconds = 30.0
    public static let targetSeconds = 45.0
    public static let maximumSeconds = 60.0
    public static let capacitySeconds = 120.0
    public static let filePauseSeconds = 90.0

    private let lock = NSLock()
    private var session: UUID?
    private var samples: [Float] = []
    private var readIndex = 0
    private var consumedSamples: Int64 = 0
    private var nextID = 0
    private var finished = false
    private var storedFailure: String?
    private let sampleRate = 16_000
    private let capacity = 16_000 * Int(CloudAudioBuffer.capacitySeconds)

    var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count - readIndex) / Double(sampleRate)
    }

    var failure: String? {
        lock.lock(); defer { lock.unlock() }
        return storedFailure
    }

    func begin(session id: UUID) {
        lock.lock(); defer { lock.unlock() }
        reset()
        session = id
    }

    func append(session id: UUID, samples incoming: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard session == id, !finished, storedFailure == nil, !incoming.isEmpty else { return }
        guard incoming.count <= capacity - (samples.count - readIndex) else {
            storedFailure = "클라우드 전사 대기 음성이 \(Int(Self.capacitySeconds))초를 넘었습니다. 이 회의는 로컬 전사 결과로 계속됩니다."
            return
        }
        guard incoming.allSatisfy(\.isFinite) else {
            storedFailure = "클라우드 음성 입력 형식을 확인해 주세요. 이 회의는 로컬 전사 결과로 계속됩니다."
            return
        }
        // Compact before appending so allocation stays within the same bound.
        if readIndex > 0 && (readIndex >= sampleRate * Int(Self.maximumSeconds) || samples.count + incoming.count > capacity) {
            samples.removeFirst(readIndex)
            readIndex = 0
        }
        samples.append(contentsOf: incoming)
    }

    func finish(session id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard session == id else { return }
        finished = true
    }

    func takeNext(session id: UUID) -> CloudAudioChunk? {
        lock.lock(); defer { lock.unlock() }
        guard session == id, storedFailure == nil else { return nil }
        let available = samples.count - readIndex
        guard available > 0 else { return nil }
        let minimum = sampleRate * Int(Self.minimumSeconds)
        let target = sampleRate * Int(Self.targetSeconds)
        let maximum = sampleRate * Int(Self.maximumSeconds)
        // Preserve every sample of a short final tail, including <100 ms.
        if finished && available <= maximum { return consume(available) }
        guard available >= target else { return nil }

        let limit = min(available, maximum)
        let frame = sampleRate / 50 // 20 ms, independent of incoming packet sizes.
        let requiredQuietFrames = 25 // 500 ms.
        var quietFrames = 0
        var bestCut: Int?
        var bestDistance = Int.max
        for offset in stride(from: 0, through: limit - frame, by: frame) {
            var sumSquares: Double = 0
            var peak: Float = 0
            for index in (readIndex + offset)..<(readIndex + offset + frame) {
                let value = samples[index]
                sumSquares += Double(value) * Double(value)
                peak = max(peak, abs(value))
            }
            // Conservative silence gate (-50 dBFS RMS plus a peak guard).
            let quiet = sumSquares / Double(frame) <= 0.000_01 && peak <= 0.012
            quietFrames = quiet ? quietFrames + 1 : 0
            let cut = offset + frame
            if quietFrames >= requiredQuietFrames && cut >= minimum {
                let distance = abs(cut - target)
                if distance < bestDistance { bestCut = cut; bestDistance = distance }
            }
        }
        if let bestCut { return consume(bestCut) }
        if available >= maximum { return consume(maximum) }
        return nil
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        reset()
    }

    private func consume(_ count: Int) -> CloudAudioChunk {
        let chunk = CloudAudioChunk(id: nextID, startTime: Double(consumedSamples) / Double(sampleRate),
                                    samples: Array(samples[readIndex..<(readIndex + count)]))
        nextID += 1
        readIndex += count
        consumedSamples += Int64(count)
        if readIndex == samples.count { samples.removeAll(keepingCapacity: true); readIndex = 0 }
        return chunk
    }

    private func reset() {
        session = nil
        samples.removeAll(keepingCapacity: false)
        readIndex = 0
        consumedSamples = 0
        nextID = 0
        finished = false
        storedFailure = nil
    }
}
