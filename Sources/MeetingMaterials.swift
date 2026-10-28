import Foundation
import Combine
import AppKit
import CryptoKit
import UniformTypeIdentifiers

struct MaterialChunk: Codable, Equatable, Identifiable {
    let id: String
    let location: String
    let text: String
    var summary: String? = nil
    var terms: [String]? = nil
}
struct MeetingMaterial: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    let origin: String
    let importedAt: Date
    let hash: String
    let originalPath: String
    let extractedPath: String
    var chunks: [MaterialChunk]
    var warnings: [String]
    var analysisModel: String? = nil
    var enabled = true
    var folderID: UUID? = nil
    var relativePath: String? = nil
    var version: Int? = nil
    var supersedesID: UUID? = nil
    var isCurrentVersion: Bool? = nil
    var analyzed: Bool { !chunks.isEmpty && chunks.allSatisfy { $0.summary != nil } }
    var currentVersion: Bool { isCurrentVersion ?? true }
}
struct MaterialExcerpt: Codable, Equatable {
    let id: String
    let title: String
    let location: String
    let text: String
}
struct MaterialReview: Codable {
    let sourceID: String
    let status: String
    let text: String
    let evidenceIDs: [Int]
}
struct MaterialContext: Codable, Equatable {
    var documents: [MeetingMaterial] = []
    var chunks: [MaterialChunk] { documents.flatMap(\.chunks) }
    var terms: [String] {
        var seen=Set<String>()
        return chunks.flatMap { $0.terms ?? [] }.filter { !$0.isEmpty && $0.count<=80 && seen.insert($0).inserted }
    }
    static func tokens(_ text: String) -> Set<String> {
        let words=text.lowercased().components(separatedBy:CharacterSet.alphanumerics.inverted).filter { $0.count>=2 }
        var tokens=Set(words)
        for word in words { let chars=Array(word);if chars.count>=2 { for i in 0..<(chars.count-1) { tokens.insert(String(chars[i...i+1])) } } }
        return tokens
    }
    func excerpts(query: String, limit: Int = 4, characters: Int = 4000) -> [MaterialExcerpt] {
        let q=Self.tokens(query)
        let all=documents.flatMap { doc in doc.chunks.map { (doc,$0) } }
        var ranked:[(offset:Int,element:(MeetingMaterial,MaterialChunk),score:Int)]=[]
        for (index,entry) in all.enumerated() {
            let (doc,chunk)=entry
            let content=doc.title+" "+chunk.text+" "+(chunk.summary ?? "")
            let score=Self.tokens(content).intersection(q).count
            ranked.append((offset:index,element:entry,score:score))
        }
        ranked.sort { a,b in a.score==b.score ? a.offset<b.offset : a.score>b.score }
        var result:[MaterialExcerpt]=[],used=0
        for entry in ranked.prefix(limit) {
            let (doc,chunk)=entry.element
            let text=String(chunk.text.prefix(max(0,characters-used)))
            guard !text.isEmpty else { break }
            result.append(.init(id:chunk.id,title:doc.title,location:chunk.location,text:text));used+=text.count
        }
        return result
    }
    func appendix(reviews: [MaterialReview], segments: [MeetingUtterance]) -> String {
        guard !documents.isEmpty else { return "" }
        let names=Dictionary(uniqueKeysWithValues:documents.flatMap { doc in doc.chunks.map { ($0.id,doc.title+" · "+$0.location) } })
        let times=Dictionary(uniqueKeysWithValues:segments.map { ($0.id,MeetingMinutesRenderer.time($0.start)+" · "+String($0.text.prefix(240))) })
        func safe(_ s:String)->String { s.replacingOccurrences(of:"|",with:"\\|").replacingOccurrences(of:"\n",with:" ") }
        var lines=["\n\n# 회의자료 반영", "", "자료의 배경·계획과 실제 회의 발언을 대조한 AI 초안입니다. 날짜·금액·담당 업무는 아래 근거 발언과 원문을 함께 확인합니다.", "", "| 자료·위치 | 구분 | 맥락·회의와의 관계 | 근거 발언 |", "| --- | --- | --- | --- |"]
        for review in reviews {
            let label=["discussed":"논의됨","background":"배경 자료","conflict":"차이 확인","unresolved":"확인 필요"][review.status] ?? "확인 필요"
            lines.append("| \(safe(names[review.sourceID] ?? review.sourceID)) | \(label) | \(safe(review.text)) | \(review.evidenceIDs.compactMap { times[$0].map(safe) }.joined(separator:", ")) |")
        }
        let covered=Set(reviews.map(\.sourceID))
        for chunk in chunks where !covered.contains(chunk.id) {
            lines.append("| \(safe(names[chunk.id] ?? chunk.id)) | 검토 대기 | 원문·추출문 보관 완료 | — |")
        }
        lines += ["", "## 자료 원본과 추출 기록", ""]
        for doc in documents {
            lines.append("- **\(safe(doc.title))** · \(doc.chunks.count)개 구간 · SHA-256 `\(doc.hash)`")
            lines.append("  - 출처: \(safe(doc.origin))")
            lines.append("  - [보관 원본](\(URL(fileURLWithPath:doc.originalPath).absoluteString)) · [전체 추출문](\(URL(fileURLWithPath:doc.extractedPath).absoluteString))")
            for warning in doc.warnings { lines.append("  - \(safe(warning))") }
        }
        return lines.joined(separator:"\n")+"\n"
    }
}

@MainActor final class MeetingMaterials: ObservableObject {
    @Published private(set) var documents: [MeetingMaterial] = []
    @Published private(set) var busy = false
    @Published private(set) var status = "회의자료를 추가하세요."
    @Published private(set) var error: String?
    @Published private(set) var folders: [MaterialFolder] = []
    @Published private(set) var watchingFolders = false
    @Published private(set) var scanningFolders = false
    var didChange: (() -> Void)?
    let root: URL
    private var task: Task<Void,Never>?
    private var panel: NSOpenPanel?
    private struct ImportSource {
        let url: URL
        let remote: Bool
        var folderID: UUID? = nil
        var relativePath: String? = nil
        var stamp: String? = nil
    }
    private var pendingImports: [([ImportSource],MinutesProvider,CodexCorrectionSettings)] = []
    private var watcherTask: Task<Void,Never>?
    private var scanTask: Task<Void,Never>?
    private var queuedFolderFiles: Set<String> = []
    private var folderLoadFailed = false
    private var importGeneration = UUID()
    private var scanGeneration = UUID()
    @Published private(set) var queuedFiles=0
    private func nextImport() -> Bool {
        guard !pendingImports.isEmpty else { return false }
        let next=pendingImports.removeFirst();queuedFiles=pendingImports.reduce(0,{$0+$1.0.count})
        startImport(next.0,provider:next.1,settings:next.2);return true
    }
    private let analyzer = MaterialAnalyzer()
    private var loadFailed = false
    var context: MaterialContext { .init(documents:documents.filter { $0.enabled && $0.currentVersion }) }
    var currentDocuments: [MeetingMaterial] { documents.filter(\.currentVersion) }
    init(root: URL = StorageLocations.materials) {
        self.root=root
        let manifest=root.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath:manifest.path) {
            do { documents=try JSONDecoder().decode([MeetingMaterial].self,from:Data(contentsOf:manifest)) }
            catch { loadFailed=true;self.error="자료 목록을 읽을 수 없습니다. 저장 폴더의 library.json을 확인해 주세요." }
        }
        let folderManifest=root.appendingPathComponent("folders.json")
        if FileManager.default.fileExists(atPath:folderManifest.path) {
            do { folders=try JSONDecoder().decode([MaterialFolder].self,from:Data(contentsOf:folderManifest)) }
            catch { folderLoadFailed=true;self.error="폴더 연결 기록을 확인해 주세요. folders.json 원본을 보관했습니다." }
        }
    }
    private func save() throws {
        guard !loadFailed else { throw MaterialError.message("기존 자료 목록을 확인한 뒤 앱을 다시 실행해 주세요.") }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(documents).write(to:root.appendingPathComponent("library.json"),options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:root.appendingPathComponent("library.json").path)
    }
    private func saveFolders() throws {
        guard !folderLoadFailed else { throw MaterialError.message("folders.json 기록을 확인한 뒤 폴더 연결을 재개해 주세요.") }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let file=root.appendingPathComponent("folders.json")
        try encoder.encode(folders).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func clearSelection() {
        guard !busy else { return }
        let old=documents,oldFolders=folders
        for i in documents.indices { documents[i].enabled=false }
        for i in folders.indices { folders[i].enabled=false }
        do { try save();try saveFolders();didChange?() } catch { documents=old;folders=oldFolders;self.error=error.localizedDescription }
    }
    func restoreMeetingContext(_ context: MaterialContext) throws {
        guard !busy, !loadFailed, !folderLoadFailed else {
            throw MaterialError.message("자료 작업을 마치고 저장된 자료 목록을 확인한 뒤 회의를 열어 주세요.")
        }
        cancel()
        let oldDocuments=documents, oldFolders=folders
        documents=MeetingMaterialRestoration.documents(existing:documents,context:context)
        for index in folders.indices { folders[index].enabled=false }
        do {
            try save(); try saveFolders()
            status="저장 회의의 자료 \(self.context.documents.count)개를 재가공본에 연결했습니다."
            error=nil; didChange?()
        } catch {
            documents=oldDocuments;folders=oldFolders
            try? save();try? saveFolders()
            throw error
        }
    }
    func select(_ id:UUID,enabled:Bool) {
        guard !busy,let i=documents.firstIndex(where:{$0.id==id && $0.currentVersion}) else { return }
        let previous=documents;documents[i].enabled=enabled
        do { try save();didChange?() } catch { documents=previous;self.error=error.localizedDescription }
    }
    func pickFiles(provider:MinutesProvider,settings:CodexCorrectionSettings) {
        guard panel==nil else { return }
        let panel=NSOpenPanel();panel.allowsMultipleSelection=true;panel.canChooseDirectories=false
        panel.allowedContentTypes=[.pdf,.png,.jpeg,.plainText, .init(filenameExtension:"md") ?? .plainText]
        self.panel=panel
        panel.begin { [weak self] response in
            guard let self else { return };self.panel=nil
            if response == .OK { self.importFiles(panel.urls,provider:provider,settings:settings) }
        }
    }
    func importFiles(_ urls:[URL],provider:MinutesProvider,settings:CodexCorrectionSettings) {
        startImport(urls.map { .init(url:$0,remote:false) },provider:provider,settings:settings)
    }
    func importURL(_ text:String,provider:MinutesProvider,settings:CodexCorrectionSettings) {
        guard let url=URL(string:text.trimmingCharacters(in:.whitespacesAndNewlines)),["http","https"].contains(url.scheme?.lowercased() ?? ""),url.host != nil,url.user==nil,url.password==nil else {
            error="HTTP 또는 HTTPS 자료 주소를 입력하세요.";return
        }
        startImport([.init(url:url,remote:true)],provider:provider,settings:settings)
    }
    private func startImport(_ sources:[ImportSource],provider:MinutesProvider,settings:CodexCorrectionSettings) {
        guard !loadFailed else { return }
        if busy { pendingImports.append((sources,provider,settings));queuedFiles+=sources.count;return }
        busy=true;error=nil
        let generation=importGeneration
        task=Task {
            var failures:[String]=[]
            for (index,source) in sources.enumerated() {
                let queueKey=source.folderID.map { $0.uuidString+":"+(source.relativePath ?? "") }
                defer { if let queueKey { queuedFolderFiles.remove(queueKey) } }
                do {
                    try Task.checkCancellation()
                    status="자료 추출 · \(index+1)/\(sources.count)"
                    let root=self.root
                    var input=source.url
                    let staging=root.appendingPathComponent(".folder-staging").appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at:staging) }
                    if let folderID=source.folderID,let path=source.relativePath,let stamp=source.stamp {
                        guard let folder=folders.first(where:{$0.id==folderID}) else { continue }
                        let folderURL=try resolvedURL(folder)
                        let scoped=folderURL.startAccessingSecurityScopedResource()
                        defer { if scoped { folderURL.stopAccessingSecurityScopedResource() } }
                        let copyTask=Task.detached(priority:.utility) { try FolderContextScanner.capture(root:folderURL,relativePath:path,expectedStamp:stamp,staging:staging) }
                        input=try await withTaskCancellationHandler(operation:{try await copyTask.value},onCancel:{copyTask.cancel()})
                    }
                    let extractionInput=input
                    let extractionTask=Task.detached(priority:.utility) { try await MaterialExtractor.extract(extractionInput,remote:source.remote,root:root) }
                    var document=try await withTaskCancellationHandler(operation:{try await extractionTask.value},onCancel:{extractionTask.cancel()})
                    guard !Task.isCancelled,generation==importGeneration else {
                        try? FileManager.default.removeItem(at:root.appendingPathComponent(document.id.uuidString))
                        throw CancellationError()
                    }
                    if let folderID=source.folderID,let path=source.relativePath {
                        guard folders.contains(where:{$0.id==folderID}) else { try? FileManager.default.removeItem(at:root.appendingPathComponent(document.id.uuidString));continue }
                        // Each folder path owns its version chain, including identical content at distinct paths.
                        let previous=documents.last(where:{$0.folderID==folderID && $0.relativePath==path && $0.currentVersion})
                        if let previous,previous.hash==document.hash {
                            try? FileManager.default.removeItem(at:root.appendingPathComponent(document.id.uuidString))
                            updateFolderFile(folderID,path:path,materialID:previous.id,stamp:source.stamp,status:"검색 가능 · 기존 내용 유지")
                            try saveFolders();continue
                        }
                        let original=document
                        document=MeetingMaterial(id:original.id,title:source.url.lastPathComponent,origin:source.url.path,importedAt:original.importedAt,hash:original.hash,originalPath:original.originalPath,extractedPath:original.extractedPath,chunks:original.chunks,warnings:original.warnings,analysisModel:original.analysisModel,enabled:previous?.enabled ?? (folders.first(where:{$0.id==folderID})?.enabled ?? false),folderID:folderID,relativePath:path,version:(previous?.version ?? 0)+1,supersedesID:previous?.id,isCurrentVersion:true)
                        let extractedPath=document.extractedPath,sourcePath=source.url.path,temporaryPath=input.path
                        let provenanceTask=Task.detached(priority:.utility) {
                            let file=URL(fileURLWithPath:extractedPath)
                            let text=try String(contentsOf:file,encoding:.utf8).replacingOccurrences(of:temporaryPath,with:sourcePath)
                            try Data(text.utf8).write(to:file,options:.atomic)
                            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                        }
                        try await provenanceTask.value
                        let before=documents
                        for i in documents.indices where documents[i].folderID==folderID && documents[i].relativePath==path && documents[i].currentVersion { documents[i].isCurrentVersion=false;documents[i].enabled=false }
                        documents.append(document)
                        do { try save() } catch { documents=before;throw error }
                        updateFolderFile(folderID,path:path,materialID:document.id,stamp:source.stamp,status:"검색 가능 · 버전 \(document.version ?? 1)")
                        try saveFolders();didChange?();continue
                    }
                    if let existing=documents.firstIndex(where:{$0.hash==document.hash && $0.folderID==nil && $0.currentVersion}) {
                        try? FileManager.default.removeItem(at:root.appendingPathComponent(document.id.uuidString))
                        let previous=documents[existing].enabled;documents[existing].enabled=true
                        do { try save();didChange?() } catch { documents[existing].enabled=previous;throw error }
                        status="보관 중인 원본을 이번 회의에 선택했습니다.";continue
                    }
                    documents.append(document)
                    do { try save() } catch { documents.removeLast();throw error }
                    didChange?()
                } catch {
                    if let folderID=source.folderID,let path=source.relativePath {
                        updateFolderFile(folderID,path:path,materialID:nil,stamp:nil,status:error is CancellationError ? "수집 대기" : error.localizedDescription)
                        if let i=folders.firstIndex(where:{$0.id==folderID}),let j=folders[i].files.firstIndex(where:{$0.relativePath==path}) {
                            folders[i].files[j].retryAfter=Date().addingTimeInterval(error is FolderCaptureError ? 3 : 60)
                        }
                        try? saveFolders()
                    }
                    if error is CancellationError { break }
                    failures.append(error.localizedDescription)
                }
            }
            busy=false;task=nil
            if !failures.isEmpty { error=failures.joined(separator:"\n") }
            status="자료 보관 완료 · \(context.documents.count)개 선택"
            if !Task.isCancelled,!nextImport() { analyze(provider:provider,settings:settings) }
        }
    }
    func analyze(provider:MinutesProvider,settings:CodexCorrectionSettings) {
        guard !busy,!loadFailed else { return }
        guard provider.isAvailable else {
            status="추출문 보관 완료 · 회의록 설정에서 선택한 AI CLI를 사용하세요."
            return
        }
        let ids=context.documents.filter { !$0.analyzed }.map(\.id)
        guard !ids.isEmpty else { return }
        busy=true
        task=Task {
            do {
                for id in ids {
                    guard let i=documents.firstIndex(where:{$0.id==id}) else { continue }
                    for j in documents[i].chunks.indices where documents[i].chunks[j].summary==nil {
                        try Task.checkCancellation()
                        status="맥락 분석 · \(documents[i].title) · \(j+1)/\(documents[i].chunks.count)"
                        let digest=try await analyzer.digest(documents[i].chunks[j],provider:provider,settings:settings)
                        try Task.checkCancellation()
                        documents[i].chunks[j].summary=digest.summary;documents[i].chunks[j].terms=digest.terms
                        documents[i].analysisModel=settings.model
                        do { try save() } catch { documents[i].chunks[j].summary=nil;documents[i].chunks[j].terms=nil;throw error }
                    }
                    didChange?()
                }
                status="맥락 준비 완료 · \(context.documents.count)개 자료 · \(context.chunks.count)개 구간"
            } catch { self.error=error.localizedDescription;status="추출문 보관 완료 · 맥락 분석 재시도 가능" }
            await analyzer.close()
            busy=false;task=nil;didChange?()
            if !Task.isCancelled { _ = nextImport() }
        }
    }
    func pickFolders(provider:MinutesProvider,settings:CodexCorrectionSettings) {
        guard panel==nil,!folderLoadFailed else { return }
        let panel=NSOpenPanel();panel.allowsMultipleSelection=true;panel.canChooseDirectories=true;panel.canChooseFiles=false
        panel.prompt="폴더 연결";panel.message="하위 폴더의 PDF·이미지·TXT·MD를 연결합니다. 자료 선택과 하위 폴더 포함 여부는 연결 후 조정할 수 있습니다."
        self.panel=panel
        panel.begin { [weak self] response in
            guard let self else { return };self.panel=nil
            if response == .OK { self.attachFolders(panel.urls,provider:provider,settings:settings) }
        }
    }
    func attachFolders(_ urls:[URL],provider:MinutesProvider,settings:CodexCorrectionSettings,recursive:Bool=true) {
        guard !folderLoadFailed else { return }
        let before=folders
        do {
            for url in urls {
                let scoped=url.startAccessingSecurityScopedResource();defer {if scoped {url.stopAccessingSecurityScopedResource()} }
                let canonical=url.standardizedFileURL.resolvingSymlinksInPath()
                guard (try canonical.resourceValues(forKeys:[.isDirectoryKey])).isDirectory==true else {continue}
                if folders.contains(where:{$0.path==canonical.path}) {continue}
                let bookmark=try? url.bookmarkData(options:[.withSecurityScope,.securityScopeAllowOnlyReadAccess],includingResourceValuesForKeys:nil,relativeTo:nil)
                folders.append(.init(id:UUID(),path:canonical.path,bookmark:bookmark,recursive:recursive,enabled:true,files:[],lastScan:nil,status:"파일 목록 확인 대기"))
            }
            try saveFolders();resumeFolderWatching(provider:provider,settings:settings)
        } catch {folders=before;self.error=error.localizedDescription}
    }
    func selectFolder(_ id:UUID,enabled:Bool) {
        guard !busy,let i=folders.firstIndex(where:{$0.id==id}) else {return}
        let oldDocuments=documents,oldFolders=folders
        folders[i].enabled=enabled
        for j in documents.indices where documents[j].folderID==id && documents[j].currentVersion {documents[j].enabled=enabled}
        do {try save();try saveFolders();didChange?()} catch {documents=oldDocuments;folders=oldFolders;self.error=error.localizedDescription}
    }
    func setRecursive(_ id:UUID,recursive:Bool,provider:MinutesProvider,settings:CodexCorrectionSettings) {
        guard !busy,let i=folders.firstIndex(where:{$0.id==id}) else {return}
        let previousFolders=folders,previousDocuments=documents
        folders[i].recursive=recursive
        if !recursive {
            for j in documents.indices where documents[j].folderID==id && documents[j].currentVersion && documents[j].relativePath?.contains("/")==true {documents[j].enabled=false}
        }
        do {try save();try saveFolders();didChange?();refreshFolders(provider:provider,settings:settings)} catch {folders=previousFolders;documents=previousDocuments;self.error=error.localizedDescription}
    }
    func disconnectFolder(_ id:UUID) {
        guard !busy else {return}
        let previous=folders;folders.removeAll {$0.id==id}
        do {try saveFolders()} catch {folders=previous;self.error=error.localizedDescription}
        if folders.isEmpty {watcherTask?.cancel();watcherTask=nil;watchingFolders=false}
    }
    private func resolvedURL(_ folder:MaterialFolder) throws -> URL {
        guard let bookmark=folder.bookmark else {return URL(fileURLWithPath:folder.path)}
        var stale=false
        let url=try URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
        if stale {throw MaterialError.message("폴더 접근 갱신 필요 · 폴더 연결을 해제한 뒤 다시 선택하세요. 보관 자료는 유지됩니다.")}
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
    private func updateFolderFile(_ id:UUID,path:String,materialID:UUID?,stamp:String?,status:String) {
        guard let i=folders.firstIndex(where:{$0.id==id}),let j=folders[i].files.firstIndex(where:{$0.relativePath==path}) else {return}
        if let materialID {folders[i].files[j].materialID=materialID}
        if let stamp {folders[i].files[j].importedStamp=stamp}
        if materialID != nil {folders[i].files[j].retryAfter=nil}
        folders[i].files[j].status=status
    }
    func resumeFolderWatching(provider:MinutesProvider,settings:CodexCorrectionSettings) {
        guard !folders.isEmpty,!folderLoadFailed else {return}
        watcherTask?.cancel();watchingFolders=true
        refreshFolders(provider:provider,settings:settings)
        watcherTask=Task { [weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(nanoseconds:15_000_000_000)} catch {break}
                guard let self else {break}
                self.refreshFolders(provider:provider,settings:settings)
            }
        }
    }
    func refreshFolders(provider:MinutesProvider,settings:CodexCorrectionSettings) {
        guard !folders.isEmpty,!scanningFolders,!folderLoadFailed,!loadFailed else {return}
        scanningFolders=true
        let generation=UUID();scanGeneration=generation
        let selectedFolders=folders
        scanTask=Task {
            var imports:[ImportSource]=[]
            for folder in selectedFolders {
                do {
                    try Task.checkCancellation()
                    let url=try resolvedURL(folder)
                    let scoped=url.startAccessingSecurityScopedResource();defer {if scoped {url.stopAccessingSecurityScopedResource()} }
                    let excludedRoots=[self.root] + StorageLocations.contextExcludedRoots
                    let worker=Task.detached(priority:.utility) {try FolderContextScanner.scan(root:url,recursive:folder.recursive,excluding:excludedRoots)}
                    let scan=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                    try Task.checkCancellation()
                    guard generation==scanGeneration else {break}
                    guard let i=folders.firstIndex(where:{$0.id==folder.id}),folders[i].recursive==folder.recursive else {continue}
                    let now=Date(),found=Set(scan.files.map(\.relativePath))
                    for j in folders[i].files.indices where !found.contains(folders[i].files[j].relativePath) {
                        folders[i].files[j].status=scan.truncated ? "수집 범위 확인 필요 · 보관 사본 유지" : "원본 경로 확인 필요 · 보관 사본 유지"
                    }
                    for observation in scan.files {
                        if let j=folders[i].files.firstIndex(where:{$0.relativePath==observation.relativePath}) {
                            if folders[i].files[j].observedStamp != observation.stamp {
                                folders[i].files[j].observedStamp=observation.stamp;folders[i].files[j].observedAt=now
                                folders[i].files[j].retryAfter=nil
                                folders[i].files[j].status="쓰기 안정화 확인 중"
                            }
                        } else {
                            folders[i].files.append(.init(relativePath:observation.relativePath,observedStamp:observation.stamp,observedAt:now,status:"쓰기 안정화 확인 중"))
                        }
                        guard let j=folders[i].files.firstIndex(where:{$0.relativePath==observation.relativePath}) else {continue}
                        if let warning=observation.warning {folders[i].files[j].status=warning;continue}
                        let state=folders[i].files[j]
                        if state.importedStamp==observation.stamp {
                            if let doc=documents.first(where:{$0.id==state.materialID}) {
                                folders[i].files[j].status=doc.analyzed ? "맥락 준비 · 버전 \(doc.version ?? 1)" : "검색 가능 · 버전 \(doc.version ?? 1)"
                            }
                            continue
                        }
                        guard now.timeIntervalSince(state.observedAt)>=FolderContextScanner.stabilitySeconds else {continue}
                        if let retryAfter=state.retryAfter,retryAfter>now {continue}
                        let key=folder.id.uuidString+":"+observation.relativePath
                        guard queuedFolderFiles.insert(key).inserted else {continue}
                        imports.append(.init(url:url.appendingPathComponent(observation.relativePath),remote:false,folderID:folder.id,relativePath:observation.relativePath,stamp:observation.stamp))
                        folders[i].files[j].status="수집 대기"
                    }
                    folders[i].lastScan=now
                    folders[i].status="\(scan.files.count)개 파일 · 15초마다 변경 확인"+(scan.truncated ? " · 수집 상한 도달 (1,000개 / 20,000항목)" : "")
                } catch {
                    if error is CancellationError {break}
                    if let i=folders.firstIndex(where:{$0.id==folder.id}) {folders[i].status="폴더 확인 필요 · "+error.localizedDescription}
                }
            }
            guard generation==scanGeneration else {return}
            scanningFolders=false;scanTask=nil
            do {try saveFolders()} catch {self.error=error.localizedDescription}
            if !Task.isCancelled,!imports.isEmpty {startImport(imports,provider:provider,settings:settings)}
        }
    }
    func cancel() {
        importGeneration=UUID();pendingImports=[];queuedFiles=0;queuedFolderFiles=[];task?.cancel()
        scanGeneration=UUID()
        watcherTask?.cancel();watcherTask=nil;scanTask?.cancel();scanTask=nil
        watchingFolders=false;scanningFolders=false
    }
    func open(_ doc:MeetingMaterial,original:Bool) { NSWorkspace.shared.open(URL(fileURLWithPath:original ? doc.originalPath : doc.extractedPath)) }
}


extension MeetingMaterials {
    @discardableResult
    func addText(title: String, text: String) throws -> UUID {
        let value = EditingMaterialAddition.pasted(title: title, text: text)
        _ = try applyMaterialChanges(replacements: [:], additions: [value])
        return documents.last!.id
    }

    func applyChatEdits(documentID: UUID, replacements: [String: String]) throws -> EditingReceipt {
        try applyMaterialChanges(replacements: [documentID: replacements], additions: [])
    }

    /// Commit all material changes together so a multi-document proposal has one apply/undo boundary.
    func applyMaterialChanges(replacements: [UUID: [String: String]], additions: [EditingMaterialAddition]) throws -> EditingReceipt {
        guard !busy, !loadFailed, !replacements.isEmpty || !additions.isEmpty else { throw EditingError.unavailable }
        for addition in additions { try addition.validate() }
        let previous = documents
        var next = documents
        var originals: [MeetingMaterial] = [], created: [MeetingMaterial] = [], folders: [URL] = []
        var committed = false
        defer { if !committed { for folder in folders { try? FileManager.default.removeItem(at: folder) } } }
        for documentID in replacements.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let edits = replacements[documentID], !edits.isEmpty,
                  let index = next.firstIndex(where: { $0.id == documentID && $0.enabled && $0.currentVersion }) else { throw EditingError.unavailable }
            let original = next[index], id = UUID()
            guard Set(edits.keys).isSubset(of: Set(original.chunks.map(\.id))),
                  edits.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 200_000 }) else { throw EditingError.stale }
            let folder = root.appendingPathComponent(id.uuidString), url = folder.appendingPathComponent("edited.md")
            folders.append(folder)
            let chunks = original.chunks.enumerated().map { index, chunk in
                MaterialChunk(id: id.uuidString + "-" + String(index), location: chunk.location, text: edits[chunk.id] ?? chunk.text)
            }
            let markdown = chunks.map { "## " + $0.location + "\n\n" + $0.text }.joined(separator: "\n\n")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(markdown.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let copy = MeetingMaterial(id: id, title: original.title.hasSuffix(" · 편집본") ? original.title : original.title + " · 편집본",
                origin: original.origin, importedAt: Date(), hash: AssistantFiles.hash(markdown), originalPath: original.originalPath,
                extractedPath: url.path, chunks: chunks, warnings: ["채팅으로 수정한 텍스트 편집본 · 원본 파일 별도 보관"],
                version: (original.version ?? 1) + 1, supersedesID: original.id, isCurrentVersion: true)
            originals.append(original)
            next[index].enabled = false; next[index].isCurrentVersion = false
            next.append(copy); created.append(copy)
        }
        for addition in additions {
            let id = UUID()
            folders.append(root.appendingPathComponent(id.uuidString))
            let document = try addition.write(id: id, root: root)
            next.append(document); created.append(document)
        }
        documents = next
        do { try save() } catch { documents = previous; throw error }
        committed = true
        error = nil; status = "회의자료 \(replacements.count)개 수정 · \(additions.count)개 추가 · \(context.documents.count)개 선택"
        didChange?()
        let changedIDs = Set(originals.map(\.id) + created.map(\.id))
        let expected = next.filter { changedIDs.contains($0.id) }
        let createdIDs = Set(created.map(\.id))
        return EditingReceipt(note: status, url: created.count == 1 ? URL(fileURLWithPath: created[0].extractedPath) : nil) { [weak self] in
            guard let self, !self.busy,
                  self.documents.filter({ changedIDs.contains($0.id) }) == expected else { throw EditingError.stale }
            let current = self.documents
            self.documents.removeAll { createdIDs.contains($0.id) }
            for original in originals {
                guard let index = self.documents.firstIndex(where: { $0.id == original.id }) else { self.documents = current; throw EditingError.stale }
                self.documents[index] = original
            }
            do { try self.save() } catch { self.documents = current; throw error }
            self.didChange?(); self.status = "자료 변경을 되돌렸습니다. 저장 파일은 보관합니다."
        }
    }
}
