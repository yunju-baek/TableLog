import Foundation
import PDFKit
import Vision
import AppKit
import CryptoKit

enum MaterialError: LocalizedError {
    case message(String)
    var errorDescription:String? { if case .message(let text)=self { return text };return nil }
}
enum MaterialExtractor {
    static let maxBytes=50*1024*1024
    static func pieces(_ text:String, id:UUID, location:String, offset:Int) -> [MaterialChunk] {
        let chars=Array(text)
        return stride(from:0,to:chars.count,by:1000).enumerated().map { n,start in
            .init(id:id.uuidString+"-"+String(offset+n+1),location:location+" · 구간 \(n+1)",text:String(chars[start..<min(chars.count,start+1000)]))
        }
    }
    static func decode(_ data:Data) throws -> String {
        for encoding in [String.Encoding.utf8,.utf16,.utf16LittleEndian,.utf16BigEndian] {
            if let value=String(data:data,encoding:encoding),!value.contains("\0") { return value }
        }
        throw MaterialError.message("텍스트 인코딩을 UTF-8 또는 UTF-16으로 저장한 뒤 추가해 주세요.")
    }
    static func html(_ text:String) -> String {
        var s=text.replacingOccurrences(of:"(?is)<(script|style|nav|noscript)[^>]*>.*?</\\1>",with:" ",options:.regularExpression)
        s=s.replacingOccurrences(of:"(?i)</?(p|div|h[1-6]|li|tr|br|article|section)[^>]*>",with:"\n",options:.regularExpression)
        s=s.replacingOccurrences(of:"<[^>]+>",with:" ",options:.regularExpression)
        for (a,b) in [("&nbsp;"," "),("&amp;","&"),("&lt;","<"),("&gt;",">"),("&quot;","\""),("&#39;","'")] { s=s.replacingOccurrences(of:a,with:b) }
        let regex=try! NSRegularExpression(pattern:"&#(x[0-9a-fA-F]+|[0-9]+);")
        for match in regex.matches(in:s,range:NSRange(s.startIndex...,in:s)).reversed() {
            guard let range=Range(match.range,in:s),let digits=Range(match.range(at:1),in:s) else {continue}
            let value=String(s[digits]);let n=value.hasPrefix("x") ? UInt32(value.dropFirst(),radix:16) : UInt32(value)
            if let n,let scalar=UnicodeScalar(n) { s.replaceSubrange(range,with:String(scalar)) }
        }
        return s.components(separatedBy:.newlines).map { $0.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ") }.filter {!$0.isEmpty}.joined(separator:"\n")
    }
    static func extract(_ url:URL,remote:Bool,root:URL) async throws -> MeetingMaterial {
        let id=UUID(),folder=root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var committed=false
        defer { if !committed { try? FileManager.default.removeItem(at:folder) } }
        var file=url,ext=url.pathExtension.lowercased(),origin=url.path,title=url.lastPathComponent
        var notes:[String]=[]
        if remote {
            let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=45;config.timeoutIntervalForResource=90
            let session=URLSession(configuration:config);defer { session.invalidateAndCancel() }
            let (temp,response)=try await session.download(from:url)
            defer { try? FileManager.default.removeItem(at:temp) }
            guard let http=response as? HTTPURLResponse,(200...299).contains(http.statusCode),let final=response.url,["http","https"].contains(final.scheme ?? "") else { throw MaterialError.message("자료 URL 응답을 확인해 주세요.") }
            let bytes=(try temp.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
            guard bytes>0,bytes<=maxBytes else { throw MaterialError.message("자료는 파일당 50MB까지 추가할 수 있습니다.") }
            let mime=(response.mimeType ?? "").lowercased()
            if mime.contains("pdf") { ext="pdf" } else if mime.contains("png") { ext="png" } else if mime.contains("jpeg") { ext="jpg" } else if mime.contains("html") { ext="html" } else if ext.isEmpty { ext="txt" }
            file=folder.appendingPathComponent("download."+ext);try FileManager.default.copyItem(at:temp,to:file)
            origin=final.absoluteString;title=final.host.map { $0+" · "+(final.lastPathComponent.isEmpty ? "웹 자료" : final.lastPathComponent) } ?? "URL 자료"
            notes.append("URL을 가져온 시점의 내용을 보관합니다. 로그인·동적 화면은 PDF 또는 텍스트로 추가해 주세요.")
        }
        guard ["pdf","png","jpg","jpeg","txt","md","markdown","html","htm"].contains(ext) else { throw MaterialError.message("지원 형식: URL, PDF, PNG/JPG, TXT, MD") }
        let scoped=file.startAccessingSecurityScopedResource();defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let size=(try file.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
        guard size>0,size<=maxBytes else { throw MaterialError.message("자료는 파일당 50MB까지 추가할 수 있습니다.") }
        let original=folder.appendingPathComponent("original."+ext)
        try FileManager.default.copyItem(at:file,to:original)
        let data=try Data(contentsOf:original),hash=SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
        var chunks:[MaterialChunk]=[]
        let extractionTask=Task.detached(priority:.utility) { () throws -> ([(String,String)],[String]) in
            try Task.checkCancellation()
            if ext=="pdf" { return try pdf(original,folder:folder) }
            if ["png","jpg","jpeg"].contains(ext) {
                let result=try ocr(original)
                return ([("이미지",result)], ["이미지 OCR 추출 · 표·도식·작은 글자는 원본 대조 필요"])
            }
            let text=try decode(data)
            return ([(ext=="html" || ext=="htm" ? "웹 본문" : "본문",["html","htm"].contains(ext) ? html(text) : text)],[])
        }
        let extracted=try await withTaskCancellationHandler(operation:{ try await extractionTask.value },onCancel:{ extractionTask.cancel() })
        try Task.checkCancellation()
        notes+=extracted.1
        for (location,text) in extracted.0 { chunks+=pieces(text,id:id,location:location,offset:chunks.count) }
        guard chunks.contains(where:{$0.text.trimmingCharacters(in:.whitespacesAndNewlines).count>=2}) else { throw MaterialError.message("추출 가능한 본문이 없습니다. 텍스트가 선명한 PDF·이미지 또는 TXT로 추가해 주세요.") }
        guard chunks.reduce(0,{$0+$1.text.count})<=2_000_000 else { throw MaterialError.message("자료 본문은 파일당 200만 자까지 처리합니다. 문서를 나누어 추가해 주세요.") }
        let extractedURL=folder.appendingPathComponent("extracted.md")
        let content="# \(title)\n\n출처: \(origin)\n\n"+notes.joined(separator:"\n")+"\n\n"+chunks.map { "## \($0.location) · \($0.id)\n\n\($0.text)" }.joined(separator:"\n\n")
        try Data(content.utf8).write(to:extractedURL,options:.atomic)
        for path in [original,extractedURL] { try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path) }
        committed=true
        return MeetingMaterial(id:id,title:title,origin:origin,importedAt:Date(),hash:hash,originalPath:original.path,extractedPath:extractedURL.path,chunks:chunks,warnings:notes)
    }
    static func ocr(_ url:URL) throws -> String {
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.recognitionLanguages=["ko-KR","en-US"];request.usesLanguageCorrection=true
        try VNImageRequestHandler(url:url).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator:"\n")
    }
    static func pdf(_ url:URL,folder:URL) throws -> ([(String,String)],[String]) {
        guard let doc=PDFDocument(url:url),!doc.isLocked else { throw MaterialError.message("PDF를 열 수 없습니다. 암호 해제본을 추가해 주세요.") }
        guard doc.pageCount<=300 else { throw MaterialError.message("PDF는 300쪽씩 나누어 추가해 주세요.") }
        var notes:[String]=[],primary:String?
        let paths=["/opt/homebrew/bin/opendataloader-pdf","/usr/local/bin/opendataloader-pdf",FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/opendataloader-pdf").path]
        if let path=paths.first(where:{FileManager.default.isExecutableFile(atPath:$0)}) {
            let process=Process();process.executableURL=URL(fileURLWithPath:path)
            let output=folder.appendingPathComponent("structure");try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            process.arguments=["-f","markdown,json","--markdown-page-separator","\n[PAGE]\n",url.path,"-o",output.path]
            let log=folder.appendingPathComponent("extraction.log");FileManager.default.createFile(atPath:log.path,contents:nil)
            let handle=try FileHandle(forWritingTo:log);defer {try? handle.close()};process.standardOutput=handle;process.standardError=handle
            do {
                try process.run();let until=Date().addingTimeInterval(90)
                while process.isRunning && Date()<until && !Task.isCancelled { Thread.sleep(forTimeInterval:0.1) }
                if process.isRunning { process.terminate();notes.append("기본 PDF 추출 시간 초과 · PDFKit·OCR로 보완") }
                else if process.terminationStatus==0,let md=try FileManager.default.contentsOfDirectory(at:output,includingPropertiesForKeys:nil).first(where:{$0.pathExtension=="md"}) { primary=try String(contentsOf:md,encoding:.utf8) }
                else { notes.append("opendataloader-pdf 처리 실패 · PDFKit·OCR로 보완 · extraction.log 확인") }
            } catch { notes.append("기본 PDF 도구 실행 오류 · PDFKit·OCR로 보완") }
        } else { notes.append("opendataloader-pdf 설치 경로 확인 필요 · 내장 PDFKit·OCR 사용") }
        if primary?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == true {
            primary=nil;notes.append("기본 PDF 추출문이 비어 있어 PDFKit·OCR로 보완")
        }
        notes.append("표·도식의 의미와 작은 글자는 원본 대조 필요")
        try Task.checkCancellation()
        var pages:[(String,String)]=[]
        if let primary,!primary.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            pages.append(("구조 추출 본문 (페이지 구분 [PAGE])",primary));notes.append("opendataloader-pdf Markdown·JSON 구조 보관")
        }
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page=doc.page(at:i) else { continue }
            let text=page.string ?? ""
            if primary==nil && text.count>=30 { pages.append(("\(i+1)쪽",text)) }
            if text.count<80 {
                let image=page.thumbnail(of:NSSize(width:1600,height:2200),for:.mediaBox)
                guard let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let png=rep.representation(using:.png,properties:[:]) else {notes.append("\(i+1)쪽 렌더링 실패 · 원본 대조 필요");continue}
                let file=folder.appendingPathComponent("page-\(i+1).png");try png.write(to:file)
                let result=try ocr(file)
                if !result.isEmpty { pages.append(("\(i+1)쪽 OCR",result)) }
                notes.append("\(i+1)쪽 이미지 렌더링·OCR · 표·도식 원본 대조 필요")
            }
        }
        if primary != nil { notes.append("구조 추출과 OCR 보완 구간에 같은 문장이 포함될 수 있습니다.") }
        return (pages,notes)
    }
}
