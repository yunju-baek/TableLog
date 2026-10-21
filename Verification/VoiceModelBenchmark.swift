import Foundation

// Local-only diagnostic. A single person's samples measure consistency and speed;
// speaker error rates require independently labelled recordings from several people.
@main struct VoiceModelBenchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 5 else { fatalError("VoiceModelBenchmark SAMPLE_DIR OUTPUT.json MODEL.onnx MODEL.onnx ...") }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: args[1]), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let clips = try files.map { try VoiceEmbedding.readAudio($0, duration: 30) }
        guard !clips.isEmpty else { fatalError("No audio samples") }
        var reports: [[String: Any]] = []
        for path in args.dropFirst(3) {
            let extractor = VoiceEmbedding(modelURL: URL(fileURLWithPath: path))
            let coldStart = Date()
            _ = try await extractor.extract(clips[0])
            let cold = Date().timeIntervalSince(coldStart)
            var elapsed: [Double] = [], vectors: [[Float]] = []
            for iteration in 0..<3 {
                let start = Date()
                for clip in clips {
                    let vector = try await extractor.extract(clip)
                    if iteration == 0 { vectors.append(vector) }
                }
                elapsed.append(Date().timeIntervalSince(start))
            }
            var pairs: [Double] = []
            for a in vectors.indices {
                for b in vectors.indices where b > a {
                    pairs.append(zip(vectors[a], vectors[b]).reduce(0.0) { $0 + Double($1.0 * $1.1) })
                }
            }
            let duration = Double(clips.reduce(0) { $0 + $1.count }) / 16000
            let median = elapsed.sorted()[1]
            reports.append(["model": URL(fileURLWithPath:path).lastPathComponent,
                            "sample_count": clips.count, "audio_seconds": duration,
                            "embedding_dimension": vectors[0].count, "cold_first_sample_seconds": cold,
                            "warm_run_seconds": elapsed, "median_seconds": median,
                            "real_time_factor": median / duration,
                            "within_person_cosine_min": pairs.min() ?? 0,
                            "within_person_cosine_mean": pairs.reduce(0,+) / Double(max(1,pairs.count)),
                            "speaker_error_rate": NSNull()])
        }
        let result: [String:Any] = ["runtime":"sherpa-onnx v1.13.8 / CPU / 2 threads",
            "scope":"Five archived samples from one labelled person; speed and within-person consistency only.",
            "models":reports]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath:args[2]),options:.atomic)
        print("PASS: compared \(reports.count) models on \(clips.count) local samples")
    }
}
