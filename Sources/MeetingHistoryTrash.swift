import Foundation

/// A reversible list operation. Shared recordings, reference material and session files stay in place.
struct MeetingHistoryTrash {
    let url: URL
    private struct State: Codable {
        var version = 1
        var deletedSessionIDs: [UUID] = []
    }

    func read() throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        guard state.version == 1 else {
            throw MeetingHistoryError(message: "삭제 기록의 버전을 확인해 주세요. " + url.path)
        }
        return Set(state.deletedSessionIDs)
    }

    func setDeleted(_ id: UUID, deleted: Bool) throws -> Set<UUID> {
        // Read before every write so an unreadable index remains intact.
        var ids = try read()
        if deleted { ids.insert(id) } else { ids.remove(id) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(State(deletedSessionIDs: ids.sorted { $0.uuidString < $1.uuidString }))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return ids
    }
}
