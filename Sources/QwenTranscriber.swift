import Foundation

enum QwenTranscriber {
    static let modelName = "qwen3-asr-1.7b"
    private static let directory = TableLogModels.directory.appendingPathComponent("Qwen3-ASR", isDirectory: true)
    private static let python = directory.appendingPathComponent("runtime/bin/python")

    static func requireInstallation() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: python.path),
              ["model/config.json", "model/weights.safetensors",
               "aligner/config.json", "aligner/model.safetensors"].allSatisfy({
                   fm.isReadableFile(atPath: directory.appendingPathComponent($0).path)
               }),
              Bundle.main.url(forResource: "qwen_transcribe", withExtension: "py") != nil else {
            throw AppFailure(message: "Qwen 실행 도구와 모델 설치 상태를 확인해 주세요.\n\(directory.path)")
        }
    }

    static func start(audio: URL, context: String,
                      completion: @escaping (Result<[HybridTranscript.TimedChunk], Error>) -> Void) throws -> Process {
        try requireInstallation()
        guard let bridge = Bundle.main.url(forResource: "qwen_transcribe", withExtension: "py") else {
            throw AppFailure(message: "테이블로그의 Qwen 실행 파일을 확인해 주세요.")
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("TableLog-Qwen-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let output = work.appendingPathComponent("transcript.json")
        let diagnostics = work.appendingPathComponent("stderr.txt")
        do {
            try Data().write(to: diagnostics, options: .withoutOverwriting)
            let errorFile = try FileHandle(forWritingTo: diagnostics)
            defer { try? errorFile.close() }
            let process = Process()
            process.executableURL = python
            process.arguments = [bridge.path, directory.path, audio.path, output.path, context]
            var environment = ProcessInfo.processInfo.environment
            environment["HF_HUB_OFFLINE"] = "1"
            environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
            environment["PYTHONNOUSERSITE"] = "1"
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorFile
            process.terminationHandler = { process in
                let result = Result {
                    guard process.terminationStatus == 0 else {
                        let detail = (try? String(contentsOf: diagnostics, encoding: .utf8))?
                            .split(whereSeparator: \.isNewline).last.map { String($0.prefix(240)) } ?? ""
                        throw AppFailure(message: "Qwen 전사 실행 오류 (\(process.terminationStatus)). \(detail)")
                    }
                    return try JSONDecoder().decode([HybridTranscript.TimedChunk].self, from: Data(contentsOf: output))
                }
                try? fm.removeItem(at: work)
                DispatchQueue.main.async { completion(result) }
            }
            try process.run()
            return process
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }
}
