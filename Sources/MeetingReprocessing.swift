import Foundation

struct MeetingReprocessingOrigin: Codable, Equatable {
    let sourceSessionID: UUID
    let sourceTitle: String
    let sourceTranscriptPath: String?
    let sourceRecordPath: String?
    let sourceMinutesPath: String?
    let createdAt: Date
}

/// Restore the recorded context independently of a watched folder's newer versions.
enum MeetingMaterialRestoration {
    static func documents(existing: [MeetingMaterial], context: MaterialContext) -> [MeetingMaterial] {
        var result = existing.map { value in var copy=value;copy.enabled=false;return copy }
        var seen = Set<UUID>()
        for material in context.documents where material.enabled && seen.insert(material.id).inserted {
            if let index = result.firstIndex(where: {
                $0.folderID == nil && $0.currentVersion && $0.hash == material.hash
                    && $0.originalPath == material.originalPath && $0.chunks == material.chunks
            }) {
                result[index].enabled = true
            } else {
                let id=UUID()
                let chunks=material.chunks.enumerated().map { offset,chunk in
                    MaterialChunk(id:id.uuidString+"-"+String(offset+1),location:chunk.location,
                        text:chunk.text,summary:chunk.summary,terms:chunk.terms)
                }
                result.append(MeetingMaterial(id:id,title:material.title,origin:material.origin,
                    importedAt:material.importedAt,hash:material.hash,originalPath:material.originalPath,
                    extractedPath:material.extractedPath,chunks:chunks,warnings:material.warnings,
                    analysisModel:material.analysisModel,enabled:true))
            }
        }
        return result
    }
}
