import Foundation

struct EngineTuningSettings: Codable, Equatable {
    var rightContext = 13
    // 0: upstream v3-streaming; 1: existing app geometry with longer FIFO.
    var diarProfile = 1
    var vocabularyBoost: Float = 1.0
    var automaticPunctuation = true
    var valid: Bool { [3, 13].contains(rightContext) && [0, 1].contains(diarProfile) && vocabularyBoost.isFinite && (0.1...3.0).contains(vocabularyBoost) }
    var diarDescription: String { diarProfile == 0 ? "빠른 반영 · NVIDIA v3-streaming" : "긴 기억 범위 · 기존 앱 설정" }
}
