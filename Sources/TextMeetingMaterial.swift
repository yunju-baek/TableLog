import Foundation

struct EditingMaterialAddition: Codable, Equatable {
    static let maximumCharacters = 200_000
    let title: String
    let text: String

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 160, !title.contains(where: \.isNewline),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= Self.maximumCharacters else {
            throw MaterialError.message("자료 제목은 한 줄로 160자까지, 본문은 1자부터 20만 자까지 입력하세요.")
        }
    }

    static func pasted(title: String, text: String) -> Self {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { !$0.isEmpty }) ?? "텍스트 자료"
        return Self(title: name.isEmpty ? String(firstLine.prefix(80)) : name, text: text)
    }

    func write(id: UUID, root: URL) throws -> MeetingMaterial {
        try validate()
        let folder = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let original = folder.appendingPathComponent("original.md")
        let extracted = folder.appendingPathComponent("extracted.md")
        let chunks = MaterialExtractor.pieces(text, id: id, location: "텍스트 본문", offset: 0)
        try Data(text.utf8).write(to: original, options: .atomic)
        let markdown = "# \(title)\n\n출처: 직접 입력한 회의자료\n\n" + chunks.map { "## \($0.location)\n\n\($0.text)" }.joined(separator: "\n\n")
        try Data(markdown.utf8).write(to: extracted, options: .atomic)
        for url in [original, extracted] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return MeetingMaterial(id: id, title: title, origin: "직접 입력한 회의자료", importedAt: Date(),
            hash: AssistantFiles.hash(text), originalPath: original.path, extractedPath: extracted.path,
            chunks: chunks, warnings: [], version: 1, isCurrentVersion: true)
    }
}
