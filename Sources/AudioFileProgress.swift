import Foundation

/// Progress follows audio accepted by the local engine, including partial runs.
struct AudioFileProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case preparingEngine
        case openingFile
        case transcribing
        case waitingForCloud
        case finishing
    }

    let stage: Stage
    let processedSeconds: Double
    let totalSeconds: Double?

    init(stage: Stage, processedSeconds: Double, totalSeconds: Double?) {
        self.stage = stage
        self.processedSeconds = processedSeconds.isFinite ? max(0, processedSeconds) : 0
        self.totalSeconds = totalSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    var progressFraction: Double? {
        switch stage {
        case .preparingEngine, .openingFile:
            return nil
        case .transcribing, .waitingForCloud, .finishing:
            guard let totalSeconds else { return nil }
            return min(1, max(0, processedSeconds / totalSeconds))
        }
    }

    var statusText: String {
        switch stage {
        case .preparingEngine:
            return "음성 엔진을 준비하고 있습니다."
        case .openingFile:
            return "음성 파일을 여는 중입니다."
        case .transcribing:
            return "음성을 전사하고 있습니다. \(durationText)"
        case .waitingForCloud:
            return "Gemini 전사를 기다리고 있습니다. \(durationText)"
        case .finishing:
            return "남은 전사 결과를 정리하고 있습니다. \(durationText)"
        }
    }

    private var durationText: String {
        let processed = Self.timeText(processedSeconds)
        guard let totalSeconds, let fraction = progressFraction else { return processed }
        return "\(processed) / \(Self.timeText(totalSeconds)) (\(Int((fraction * 100).rounded(.down)))%)"
    }

    private static func timeText(_ seconds: Double) -> String {
        String(format: "%02.0f:%02.0f", floor(seconds / 60), floor(seconds.truncatingRemainder(dividingBy: 60)))
    }
}
