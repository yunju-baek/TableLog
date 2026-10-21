import Foundation
import CryptoKit
import Darwin

struct MaterialFolderFile: Codable, Equatable, Identifiable {
    var id: String { relativePath }
    let relativePath: String
    var observedStamp: String
    var observedAt: Date
    var importedStamp: String? = nil
    var materialID: UUID? = nil
    var retryAfter: Date? = nil
    var status: String
}

struct MaterialFolder: Codable, Equatable, Identifiable {
    let id: UUID
    var path: String
    var bookmark: Data?
    var recursive: Bool
    var enabled: Bool
    var files: [MaterialFolderFile]
    var lastScan: Date?
    var status: String
    var title: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct FolderFileObservation: Equatable {
    let relativePath: String
    let stamp: String
    let warning: String?
}

struct MaterialFolderScan {
    let files: [FolderFileObservation]
    let truncated: Bool
}

/// Metadata polling runs on a utility task. Content is copied only after two stable observations.
enum FolderContextScanner {
    static let supportedExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "txt", "md", "markdown"]
    static let excludedDirectories: Set<String> = [".git", ".build", "build", "dist", "node_modules", "vendor", "DerivedData", "Pods", ".venv", "venv", "__pycache__"]
    static let packageExtensions: Set<String> = ["app", "bundle", "framework", "xcodeproj", "xcworkspace", "photoslibrary", "playground", "pkg", "rtfd"]
    static let maxFiles = 1000
    static let maxEntries = 20_000
    static let maximumBytes = 50 * 1024 * 1024
    static let stabilitySeconds: TimeInterval = 3

    static func isWithin(_ url: URL, root: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        return target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    static func stamp(_ values: URLResourceValues) -> String {
        "\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.creationDate?.timeIntervalSince1970 ?? 0)"
    }

    private static func readRootedFile(root:URL,components:[String]) throws -> Data {
        var descriptor=Darwin.open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor>=0 else {throw CocoaError(.fileReadNoPermission)}
        defer {Darwin.close(descriptor)}
        for (index,component) in components.enumerated() {
            let flags=O_RDONLY | O_NOFOLLOW | (index<components.count-1 ? O_DIRECTORY : 0)
            let next=Darwin.openat(descriptor,component,flags)
            guard next>=0 else {throw FolderCaptureError.changed}
            Darwin.close(descriptor);descriptor=next
        }
        var before=stat(),after=stat()
        guard Darwin.fstat(descriptor,&before)==0,(before.st_mode & S_IFMT)==S_IFREG,before.st_size>0,before.st_size<=maximumBytes else {throw FolderCaptureError.changed}
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:false)
        let data=try handle.read(upToCount:maximumBytes+1) ?? Data()
        guard Darwin.fstat(descriptor,&after)==0,before.st_ino==after.st_ino,before.st_size==after.st_size,
              before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec,before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec,
              data.count==Int(after.st_size) else {throw FolderCaptureError.changed}
        var path=[CChar](repeating:0,count:Int(MAXPATHLEN))
        guard Darwin.fcntl(descriptor,F_GETPATH,&path)==0,isWithin(URL(fileURLWithPath:String(cString:path)),root:root) else {throw FolderCaptureError.changed}
        return data
    }

    static func scan(root: URL, recursive: Bool, excluding: [URL] = []) throws -> MaterialFolderScan {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let excludedPaths=excluding.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        guard (try root.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
            enumerationError = error
            return true
        }) else { throw CocoaError(.fileReadNoPermission) }
        var files: [FolderFileObservation] = [], entries = 0, truncated = false
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            entries += 1
            if entries > maxEntries || files.count >= maxFiles { truncated = true; break }
            let values = try url.resourceValues(forKeys: keys)
            let canonicalURL=url.standardizedFileURL.resolvingSymlinksInPath()
            if excludedPaths.contains(where: { canonicalURL.path == $0 || canonicalURL.path.hasPrefix($0 + "/") }) {
                if values.isDirectory==true {enumerator.skipDescendants()};continue
            }
            if values.isSymbolicLink == true || values.isHidden == true || !isWithin(url, root: root) {
                if values.isDirectory==true {enumerator.skipDescendants()};continue
            }
            if values.isDirectory == true {
                if !recursive || values.isPackage == true || packageExtensions.contains(url.pathExtension.lowercased()) || excludedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let relative = String(canonicalURL.path.dropFirst(root.path.count + (root.path.hasSuffix("/") ? 0 : 1)))
            let bytes = values.fileSize ?? 0
            let warning = bytes == 0 ? "빈 파일 · 내용 저장 대기" : (bytes > maximumBytes ? "50MB 초과 · 파일 나누기 필요" : nil)
            files.append(.init(relativePath: relative, stamp: stamp(values), warning: warning))
        }
        if let enumerationError { throw enumerationError }
        return .init(files: files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }, truncated: truncated)
    }

    /// Root and every relative component are checked again at capture time; symlinks are excluded.
    static func capture(root: URL, relativePath: String, expectedStamp: String, staging: URL) throws -> URL {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty, !relativePath.hasPrefix("/"), !components.contains(".."), !components.contains(".") else { throw FolderCaptureError.changed }
        var file = root
        for component in components {
            file.appendPathComponent(component)
            let value = try file.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard value.isSymbolicLink != true, isWithin(file, root: root) else { throw FolderCaptureError.changed }
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isSymbolicLinkKey]
        let before = try file.resourceValues(forKeys: keys)
        guard before.isRegularFile == true, before.isSymbolicLink != true, stamp(before) == expectedStamp,
              let bytes = before.fileSize, bytes > 0, bytes <= maximumBytes else { throw FolderCaptureError.changed }
        try Task.checkCancellation()
        let data = try readRootedFile(root:root,components:components)
        file.removeAllCachedResourceValues()
        let after = try file.resourceValues(forKeys: keys)
        guard stamp(after) == expectedStamp, after.isSymbolicLink != true, data.count == bytes, isWithin(file, root: root) else { throw FolderCaptureError.changed }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let snapshot = staging.appendingPathComponent(file.lastPathComponent)
        try data.write(to: snapshot, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        return snapshot
    }
}

enum FolderCaptureError: LocalizedError {
    case changed
    var errorDescription: String? { "파일 변경 감지 · 쓰기 완료 후 다음 확인에서 다시 수집합니다." }
}
