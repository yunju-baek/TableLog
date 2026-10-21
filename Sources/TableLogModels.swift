import Foundation

/// Weights belong to the user data directory and survive replacement of the app bundle.
enum TableLogModels {
    enum Model: String, CaseIterable {
        case asr = "nemotron-3.5-asr-streaming-0.6b.q8_0.gguf"
        case diarization = "Nemotron-3-Diarization.q8_0.gguf"
        case voice = "nemo_en_titanet_large.onnx"
        var title: String {
            switch self {
            case .asr: return "한국어 음성 인식"
            case .diarization: return "화자 분리"
            case .voice: return "목소리 비교"
            }
        }
    }
    static let directory = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        .appendingPathComponent("TableLog/Models",isDirectory:true)
    static func location(_ model:Model, directory:URL = directory)->URL { directory.appendingPathComponent(model.rawValue) }
    static func require(_ model:Model, directory:URL = directory) throws -> URL {
        let url=location(model,directory:directory)
        let values=try? url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard values?.isRegularFile==true,(values?.fileSize ?? 0)>1_000_000,
              FileManager.default.isReadableFile(atPath:url.path) else {
            throw MissingModel(message:"\(model.title) 모델을 확인해 주세요.\n\(url.path)\nNVIDIA 음성·화자 설정에서 모델 폴더를 열 수 있습니다.")
        }
        if model != .voice {
            let handle=try FileHandle(forReadingFrom:url);defer { try? handle.close() }
            guard try handle.read(upToCount:4)==Data("GGUF".utf8) else {
                throw MissingModel(message:"\(model.title) 모델 파일의 형식을 확인해 주세요.\n\(url.path)")
            }
        }
        return url
    }
    struct MissingModel: LocalizedError {
        let message:String
        var errorDescription:String? { message }
    }
}
