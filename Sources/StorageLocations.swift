import Foundation
import CryptoKit

/// One immutable set of locations per process. A changed preference takes effect at the next launch.
struct StorageSnapshot {
    let root: URL
    let legacyLayout: Bool
    let startupError: String?
    let migrationSummary: String?
    var transcripts: URL { root.appendingPathComponent("Transcripts", isDirectory: true) }
    var recordings: URL { legacyLayout ? transcripts.appendingPathComponent("Audio") : root.appendingPathComponent("Recordings") }
    var materials: URL { root.appendingPathComponent("MeetingMaterials") }
    var minutes: URL { legacyLayout ? transcripts.appendingPathComponent("Minutes") : root.appendingPathComponent("Minutes") }
    var assistant: URL { legacyLayout ? minutes.appendingPathComponent("Assistant") : root.appendingPathComponent("Assistant") }
    var voiceProfiles: URL { root.appendingPathComponent("VoiceProfiles") }
    var diagnostics: URL { legacyLayout ? transcripts.appendingPathComponent("Debug") : root.appendingPathComponent("Diagnostics") }
    var categories: [URL] { [transcripts, recordings, materials, minutes, assistant, voiceProfiles, diagnostics] }
}

enum StorageLocations {
    private static let coordinator = StorageCoordinator(
        defaults: UserDefaults(suiteName: "local.TableLog.storage")!,
        defaultRoot: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("TableLog", isDirectory: true),
        legacyRoot: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HwajaNote", isDirectory: true))
    static let active = coordinator.bootstrap()
    static var defaultRoot: URL { coordinator.defaultRoot }
    static var currentRoot: URL { active.root }
    static var pendingRoot: URL? { coordinator.pendingRoot }
    static var transcripts: URL { active.transcripts }
    static var recordings: URL { active.recordings }
    static var materials: URL { active.materials }
    static var minutes: URL { active.minutes }
    static var assistant: URL { active.assistant }
    static var voiceProfiles: URL { active.voiceProfiles }
    static var diagnostics: URL { active.diagnostics }
    static var contextExcludedRoots: [URL] { _ = active; return coordinator.contextExcludedRoots }
    static var startupError: String? { active.startupError }
    static var status: String {
        if let error = active.startupError { return error }
        if pendingRoot != nil { return "새 저장 위치는 앱을 다시 실행할 때 적용됩니다. 현재 회의는 현재 위치에 저장됩니다." }
        return active.migrationSummary ?? "회의 자료와 음성을 이 폴더에 보관합니다."
    }
    static func requestRoot(_ url: URL) throws { _ = active; try coordinator.requestRoot(url) }
    static func cancelPending() { _ = active; coordinator.cancelPending() }
}

struct StorageLocationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Dependencies are injectable so migration tests operate entirely in disposable directories.
final class StorageCoordinator {
    let defaultRoot: URL
    private let legacyRoot: URL
    private let defaults: UserDefaults
    private let fm: FileManager
    private let beforeCommit: (() throws -> Void)?
    private let afterDestinationBackup: (() throws -> Void)?
    private let lock = NSRecursiveLock()
    private var snapshot: StorageSnapshot?
    private var completedBackup: URL?
    private static let activeKey = "activeRoot"
    private static let pendingKey = "pendingRoot"
    private static let receiptName = ".tablelog-storage.json"
    private static let identityKey = "storageIdentity"
    private static let managedRootsKey = "managedRoots"
    private static let backupRootsKey = "backupRoots"
    private struct Entry: Codable, Equatable {
        let relativePath: String
        let directory: Bool
        let size: UInt64
        let sha256: String
    }
    private struct Receipt: Codable {
        let version: Int
        let storageIdentity: String
        let sourceRoot: String
        let legacyLayout: Bool
        let destinationRoot: String
        let sourceEntries: [Entry]
        let destinationEntries: [Entry]
    }

    init(defaults: UserDefaults, defaultRoot: URL, legacyRoot: URL, fileManager: FileManager = .default, beforeCommit: (() throws -> Void)? = nil, afterDestinationBackup: (() throws -> Void)? = nil) {
        self.defaults = defaults; self.fm = fileManager
        self.defaultRoot = Self.normalized(defaultRoot); self.legacyRoot = Self.normalized(legacyRoot)
        self.beforeCommit = beforeCommit
        self.afterDestinationBackup = afterDestinationBackup
    }

    private var storageIdentity: String {
        if let value = defaults.string(forKey: Self.identityKey) { return value }
        let value = UUID().uuidString; defaults.set(value, forKey: Self.identityKey); defaults.synchronize(); return value
    }

    var pendingRoot: URL? {
        lock.lock(); defer { lock.unlock() }
        return defaults.string(forKey: Self.pendingKey).map { Self.normalized(URL(fileURLWithPath: $0)) }
    }
    var contextExcludedRoots: [URL] {
        lock.lock(); defer { lock.unlock() }
        let saved = (defaults.stringArray(forKey: Self.managedRootsKey) ?? []) + (defaults.stringArray(forKey: Self.backupRootsKey) ?? [])
        let paths = Set(saved + [legacyRoot.path] + (snapshot.map { [$0.root.path] } ?? []))
        return paths.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func bootstrap() -> StorageSnapshot {
        lock.lock(); defer { lock.unlock() }
        if let snapshot { return snapshot }
        let savedRoot = defaults.string(forKey: Self.activeKey).map { Self.normalized(URL(fileURLWithPath: $0)) }
        let source = savedRoot ?? legacyRoot
        let legacy = savedRoot == nil
        let target = pendingRoot ?? savedRoot ?? defaultRoot
        do {
            if let savedRoot, !fm.fileExists(atPath: savedRoot.path) {
                throw StorageLocationError(message: "기존 저장 폴더에 연결한 뒤 앱을 다시 실행해 주세요: \(savedRoot.path)")
            }
            var summary: String?
            if source != target {
                try validateRelationship(target, source: source)
                let count = try migrate(source: source, legacy: legacy, target: target)
                summary = count == 0 ? nil : "\(count)개 파일을 새 저장 위치에 복사했습니다. 기존 원본은 이전 위치에 보관되어 있습니다."
                if let completedBackup { summary = (summary ?? "저장 위치를 적용했습니다.") + " 이전 목적지 자료 백업: " + completedBackup.path }
            } else {
                try ensureCategories(root: target)
            }
            defaults.set(target.path, forKey: Self.activeKey)
            var managedRoots = defaults.stringArray(forKey: Self.managedRootsKey) ?? []
            if !managedRoots.contains(target.path) { managedRoots.append(target.path) }
            defaults.set(managedRoots, forKey: Self.managedRootsKey)
            defaults.removeObject(forKey: Self.pendingKey)
            defaults.synchronize()
            let result = StorageSnapshot(root: target, legacyLayout: false, startupError: nil, migrationSummary: summary)
            snapshot = result; return result
        } catch {
            let result = StorageSnapshot(root: source, legacyLayout: legacy,
                startupError: "저장 위치 적용을 보류했습니다. 기존 저장 위치를 사용합니다. \(error.localizedDescription)", migrationSummary: nil)
            snapshot = result; return result
        }
    }

    func requestRoot(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard url.isFileURL else { throw StorageLocationError(message: "Finder에서 저장할 폴더를 선택해 주세요.") }
        let active = bootstrap(), target = Self.normalized(url)
        if target == active.root { cancelPending(); return }
        try validateRelationship(target, source: active.root)
        try validateRelationship(target, source: legacyRoot)
        try requireUsableDestination(target)
        try probeWritable(target)
        defaults.set(target.path, forKey: Self.pendingKey)
        defaults.synchronize()
    }

    func cancelPending() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Self.pendingKey); defaults.synchronize()
    }

    private static func normalized(_ url: URL) -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        return URL(fileURLWithPath: resolved.path, isDirectory: true)
    }
    private func isWithin(_ child: URL, _ parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path == "/" ? "/" : parent.path + "/")
    }
    private func validateRelationship(_ target: URL, source: URL) throws {
        guard !isWithin(target, source), !isWithin(source, target) else {
            throw StorageLocationError(message: "현재 자료 폴더와 분리된 빈 폴더를 선택해 주세요.")
        }
    }
    private func isManagedDestination(_ target: URL) -> Bool {
        guard (defaults.stringArray(forKey: Self.managedRootsKey) ?? []).contains(target.path),
              let data = try? Data(contentsOf: target.appendingPathComponent(Self.receiptName)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return false }
        return receipt.version == 1 && receipt.storageIdentity == storageIdentity && receipt.destinationRoot == target.path
    }
    private func requireUsableDestination(_ target: URL) throws {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue, try fm.contentsOfDirectory(atPath: target.path).allSatisfy({ $0 == ".DS_Store" }) || isManagedDestination(target) else {
            throw StorageLocationError(message: "선택한 위치에 파일이 있습니다. TableLog 전용 빈 폴더를 선택해 주세요: \(target.path)")
        }
    }
    private func probeWritable(_ target: URL) throws {
        var parent = target
        while !fm.fileExists(atPath: parent.path) {
            let next = parent.deletingLastPathComponent()
            guard next != parent else { throw StorageLocationError(message: "저장 폴더의 연결 상태와 쓰기 권한을 확인해 주세요.") }
            parent = next
        }
        let probe = parent.appendingPathComponent(".tablelog-write-check-" + UUID().uuidString)
        do {
            try Data("TableLog".utf8).write(to: probe, options: .withoutOverwriting)
            try fm.removeItem(at: probe)
        } catch { throw StorageLocationError(message: "선택한 폴더의 쓰기 권한을 확인해 주세요. \(error.localizedDescription)") }
    }
    private func ensureCategories(root: URL) throws {
        for folder in StorageSnapshot(root: root, legacyLayout: false, startupError: nil, migrationSummary: nil).categories {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
    private func checksum(_ url: URL) throws -> (UInt64, String) {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(), size: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk); size += UInt64(chunk.count) }
        return (size, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private func entries(_ root: URL) throws -> [Entry] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        var result: [Entry] = []
        func walk(_ directory: URL, prefix: String) throws {
            for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let relative = prefix + url.lastPathComponent
                if prefix.isEmpty && relative == Self.receiptName { continue }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw StorageLocationError(message: "자료 폴더 안의 바로가기 연결을 확인해 주세요: \(relative)") }
                if values.isDirectory == true {
                    result.append(Entry(relativePath: relative, directory: true, size: 0, sha256: "")); try walk(url, prefix: relative + "/")
                } else if values.isRegularFile == true {
                    let (size, hash) = try checksum(url)
                    result.append(Entry(relativePath: relative, directory: false, size: size, sha256: hash))
                } else { throw StorageLocationError(message: "저장 자료의 파일 형식을 확인해 주세요: \(relative)") }
            }
        }
        try walk(root, prefix: ""); return result
    }
    private func mappedRelative(_ relative: String, legacy: Bool) -> String {
        guard legacy else { return relative }
        let mappings = [("Transcripts/Minutes/Assistant", "Assistant"), ("Transcripts/Minutes", "Minutes"), ("Transcripts/Audio", "Recordings"), ("Transcripts/Debug", "Diagnostics"), ("Transcripts", "Transcripts"), ("MeetingMaterials", "MeetingMaterials"), ("VoiceProfiles", "VoiceProfiles")]
        for (old, new) in mappings where relative == old || relative.hasPrefix(old + "/") {
            return new + relative.dropFirst(old.count)
        }
        return "LegacySupport/" + relative
    }
    private func migratedReference(_ value: String, source: URL, target: URL, legacy: Bool) -> String {
        let isFileURL = value.hasPrefix("file://")
        let url: URL
        if isFileURL, let parsed = URL(string: value), parsed.isFileURL { url = parsed.standardizedFileURL }
        else if value.hasPrefix("/") { url = URL(fileURLWithPath: value).standardizedFileURL }
        else { return value }
        guard isWithin(url, source) else { return value }
        let relative = String(url.path.dropFirst(source.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let replacement = relative.isEmpty ? target : target.appendingPathComponent(mappedRelative(relative, legacy: legacy))
        return isFileURL ? replacement.absoluteString : replacement.path
    }
    private func isPathKey(_ key: String) -> Bool {
        let compact = key.replacingOccurrences(of: "_", with: "").lowercased()
        return ["path", "url", "file", "folder", "directory", "eventlog", "comparison", "audiofile", "output"].contains(compact)
            || compact.hasSuffix("path") || compact.hasSuffix("url") || compact.hasSuffix("directory")
    }
    private func rewrite(_ object: Any, key: String? = nil, source: URL, target: URL, legacy: Bool) -> Any {
        if let dictionary = object as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, pair in result[pair.key] = rewrite(pair.value, key: pair.key, source: source, target: target, legacy: legacy) }
        }
        if let array = object as? [Any] { return array.map { rewrite($0, key: key, source: source, target: target, legacy: legacy) } }
        if let string = object as? String, let key, isPathKey(key) { return migratedReference(string, source: source, target: target, legacy: legacy) }
        if let string = object as? String, key == "assistantAppendix" { return rewriteMarkdown(string, source: source, target: target, legacy: legacy) }
        return object
    }
    private func rewriteMarkdown(_ value: String, source: URL, target: URL, legacy: Bool) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"\]\((file://[^\s)]+)\)"#) else { return value }
        let mutable = NSMutableString(string: value)
        let matches = expression.matches(in: value, range: NSRange(location: 0, length: mutable.length))
        for match in matches.reversed() {
            let range = match.range(at: 1), original = mutable.substring(with: range)
            mutable.replaceCharacters(in: range, with: migratedReference(original, source: source, target: target, legacy: legacy))
        }
        return String(mutable)
    }
    private func isOwnedJSON(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/")
        guard let first = parts.first else { return false }
        if first == "MeetingMaterials" { return parts.count == 2 && ["library.json", "folders.json"].contains(String(parts[1])) }
        return ["Transcripts", "Diagnostics", "Minutes", "Assistant", "VoiceProfiles"].contains(String(first))
    }
    private func rewriteJSON(_ data: Data, relative: String, source: URL, target: URL, legacy: Bool) throws -> Data {
        let suffix = (relative as NSString).pathExtension.lowercased()
        guard isOwnedJSON(relative), suffix == "json" || suffix == "jsonl" else { return data }
        func line(_ data: Data) throws -> Data {
            let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let updated = rewrite(parsed, source: source, target: target, legacy: legacy)
            if NSDictionary(dictionary: ["value": parsed]).isEqual(to: ["value": updated]) { return data }
            return try JSONSerialization.data(withJSONObject: updated, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        }
        // Some diagnostic files can contain a final incomplete line after an interrupted write.
        // Keep such bytes exactly as recorded; valid JSON lines still get their file references updated.
        if suffix == "jsonl" {
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            var output = Data()
            for (index, part) in lines.enumerated() {
                if index > 0 { output.append(10) }
                let bytes = Data(part); output.append((try? line(bytes)) ?? bytes)
            }
            return output
        }
        return (try? line(data)) ?? data
    }
    private func migrate(source: URL, legacy: Bool, target: URL) throws -> Int {
        let sourceEntries = try entries(source)
        let receiptURL = target.appendingPathComponent(Self.receiptName)
        // Resume safely after an interruption between the atomic folder move and preference commit.
        if let data = try? Data(contentsOf: receiptURL), let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
           receipt.version == 1, receipt.storageIdentity == storageIdentity, receipt.sourceRoot == source.path, receipt.legacyLayout == legacy,
           receipt.destinationRoot == target.path, receipt.sourceEntries == sourceEntries,
           try entries(target) == receipt.destinationEntries {
            return sourceEntries.filter { !$0.directory }.count
        }
        try requireUsableDestination(target); try probeWritable(target)
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = parent.appendingPathComponent(".TableLog-migration-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        try ensureCategories(root: stage)
        var destinations = Set<String>()
        for entry in sourceEntries {
            let relative = mappedRelative(entry.relativePath, legacy: legacy)
            guard destinations.insert(relative).inserted else { throw StorageLocationError(message: "저장 자료에 같은 목적지의 파일이 있습니다: \(relative)") }
            let original = source.appendingPathComponent(entry.relativePath), copied = stage.appendingPathComponent(relative)
            if entry.directory { try fm.createDirectory(at: copied, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); continue }
            try fm.createDirectory(at: copied.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: original, to: copied)
            let (copiedSize, copiedHash) = try checksum(copied)
            guard copiedSize == entry.size, copiedHash == entry.sha256 else { throw StorageLocationError(message: "복사한 자료의 무결성 확인이 필요합니다: \(relative)") }
            let suffix = copied.pathExtension.lowercased()
            if isOwnedJSON(relative), suffix == "json" || suffix == "jsonl" {
                let originalData = try Data(contentsOf: copied)
                let rewritten = try rewriteJSON(originalData, relative: relative, source: source, target: target, legacy: legacy)
                if rewritten != originalData {
                    let permissions = try fm.attributesOfItem(atPath: copied.path)[.posixPermissions] ?? 0o600
                    try rewritten.write(to: copied, options: .atomic)
                    try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: copied.path)
                    guard try Data(contentsOf: copied) == rewritten else { throw StorageLocationError(message: "저장 경로 기록의 무결성 확인이 필요합니다: \(relative)") }
                }
            }
            if suffix == "md", relative.hasPrefix("Minutes/") || relative.hasPrefix("Assistant/") {
                let data = try Data(contentsOf: copied)
                if let text = String(data: data, encoding: .utf8) {
                    let updated = rewriteMarkdown(text, source: source, target: target, legacy: legacy)
                    if updated != text {
                        let permissions = try fm.attributesOfItem(atPath: copied.path)[.posixPermissions] ?? 0o600
                        try Data(updated.utf8).write(to: copied, options: .atomic)
                        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: copied.path)
                        guard try Data(contentsOf: copied) == Data(updated.utf8) else { throw StorageLocationError(message: "회의록 경로 기록의 무결성 확인이 필요합니다: \(relative)") }
                    }
                }
            }
        }
        let receipt = Receipt(version: 1, storageIdentity: storageIdentity, sourceRoot: source.path, legacyLayout: legacy, destinationRoot: target.path,
            sourceEntries: sourceEntries, destinationEntries: try entries(stage))
        try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent(Self.receiptName), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent(Self.receiptName).path)
        try beforeCommit?()
        guard try entries(source) == sourceEntries else { throw StorageLocationError(message: "복사 중 원본 자료가 변경되었습니다. 회의 저장을 마친 뒤 앱을 다시 실행해 주세요.") }
        try requireUsableDestination(target)
        let existed = fm.fileExists(atPath: target.path)
        let backup = parent.appendingPathComponent("TableLog-저장백업-" + UUID().uuidString, isDirectory: true)
        if existed { try fm.moveItem(at: target, to: backup) }
        do { try afterDestinationBackup?(); try fm.moveItem(at: stage, to: target) }
        catch {
            if existed, !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: backup, to: target) }
            throw error
        }
        if existed {
            if (try? fm.contentsOfDirectory(atPath: backup.path).isEmpty) == true { try? fm.removeItem(at: backup) }
            else {
                completedBackup = backup
                var roots = defaults.stringArray(forKey: Self.backupRootsKey) ?? []
                roots.append(backup.path); defaults.set(roots, forKey: Self.backupRootsKey); defaults.synchronize()
            }
        }
        return sourceEntries.filter { !$0.directory }.count
    }
}
