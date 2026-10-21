import SwiftUI

struct MeetingMaterialsView: View {
    @ObservedObject var materials: MeetingMaterials
    @ObservedObject var model: AppModel
    @State private var url=""
    @State private var selected: UUID?
    @State private var showVersions=false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Button("파일 추가 · PDF / 이미지 / TXT / MD") { materials.pickFiles(provider:model.meeting.provider,settings:model.codexSettings) }
                Button("폴더 연결",systemImage:"folder.badge.plus") { materials.pickFolders(provider:model.meeting.provider,settings:model.codexSettings) }
                Spacer()
                Button("맥락 분석 재시도") { materials.analyze(provider:model.meeting.provider,settings:model.codexSettings) }.disabled(materials.busy || materials.context.documents.isEmpty)
                if materials.busy { Button("작업 취소",action:materials.cancel) }
            }
            HStack {
                TextField("자료 URL · https://…",text:$url).textFieldStyle(.roundedBorder)
                Button("URL 추가") { materials.importURL(url,provider:model.meeting.provider,settings:model.codexSettings) }.disabled(url.isEmpty)
            }
            Text("선택한 자료를 이번 회의에 사용합니다. 녹음 중 추가한 자료는 이후 교정과 회의록에 반영됩니다. 자료 용어의 음성 엔진 반영은 녹음 시작 시 적용됩니다.")
                .font(.caption).foregroundStyle(AppTheme.muted)
            Text(model.meeting.provider == .codex ? "맥락 분석·회의록 작성: \(model.codexSettings.provider.title) · 선택 자료의 추출문과 발언을 \(model.codexSettings.provider.destination)로 전달합니다." : "맥락 분석을 사용하려면 ‘회의 설정·참석자’에서 ‘선택한 AI CLI’를 선택하세요.")
                .font(.caption).foregroundStyle(AppTheme.muted)
            HStack { if materials.busy {ProgressView().controlSize(.small)};Text(materials.status).font(.caption) }
            if materials.queuedFiles>0 { Text("추가 대기 중 · \(materials.queuedFiles)개 자료").font(.caption).foregroundStyle(AppTheme.violet) }
            if let error=materials.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if !materials.folders.isEmpty {
                DisclosureGroup("연결한 폴더 · \(materials.folders.count)개") {
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Text("15초마다 변경을 확인합니다. 안정화된 파일의 새 버전을 보관하며, 이전 버전의 근거도 계속 열 수 있습니다.").font(.caption).foregroundStyle(AppTheme.muted)
                            Spacer()
                            Button(materials.watchingFolders ? "지금 확인" : "자동 확인 재개") {
                                if materials.watchingFolders {materials.refreshFolders(provider:model.meeting.provider,settings:model.codexSettings)}
                                else {materials.resumeFolderWatching(provider:model.meeting.provider,settings:model.codexSettings)}
                            }.disabled(materials.scanningFolders)
                        }
                        Text("폴더당 최대 1,000개 자료를 수집합니다. 숨김 항목·개발 산출물·앱 패키지·심볼릭 링크는 수집 대상에서 제외됩니다.").font(.caption2).foregroundStyle(AppTheme.muted)
                        ForEach(materials.folders) { folder in
                            VStack(alignment:.leading,spacing:5) {
                                HStack {
                                    Toggle(folder.title+" · 자료 선택",isOn:Binding(get:{folder.enabled},set:{materials.selectFolder(folder.id,enabled:$0)})).disabled(materials.busy).help("현재 자료와 새로 추가되는 자료를 이번 회의에 선택합니다. 파일별 선택은 아래 목록에서 조정합니다.")
                                    Toggle("하위 폴더",isOn:Binding(get:{folder.recursive},set:{materials.setRecursive(folder.id,recursive:$0,provider:model.meeting.provider,settings:model.codexSettings)})).disabled(materials.busy)
                                    Button("연결 해제") {materials.disconnectFolder(folder.id)}.disabled(materials.busy).help("보관한 자료와 이전 버전은 유지합니다.")
                                }
                                Text(folder.path).font(.caption2).foregroundStyle(AppTheme.muted).textSelection(.enabled)
                                Text(folder.status).font(.caption)
                                DisclosureGroup("파일별 상태 · \(folder.files.count)개") {
                                    ScrollView {
                                        LazyVStack(alignment:.leading,spacing:4) {
                                            ForEach(folder.files) { file in
                                                HStack(alignment:.top) {
                                                    Text(file.relativePath).lineLimit(2)
                                                    Spacer()
                                                    Text(file.status).foregroundStyle(AppTheme.muted).lineLimit(2)
                                                }.font(.caption2)
                                            }
                                        }
                                    }.frame(maxHeight:130)
                                }.font(.caption)
                            }.padding(8).background(AppTheme.lavender,in:RoundedRectangle(cornerRadius:8))
                        }
                    }
                }
            }
            Divider()
            Toggle("이전 자료 버전 함께 보기",isOn:$showVersions).font(.caption)
            HSplitView {
                ScrollView {
                    VStack(alignment:.leading,spacing:10) {
                        if materials.documents.isEmpty { Text("회의 안건, 제안서, 참고 이미지와 웹 자료를 추가하세요.").foregroundStyle(.secondary).padding() }
                        ForEach(showVersions ? materials.documents : materials.currentDocuments) { doc in
                            VStack(alignment:.leading,spacing:6) {
                                Toggle(doc.title,isOn:Binding(get:{doc.enabled},set:{materials.select(doc.id,enabled:$0)})).disabled(materials.busy || !doc.currentVersion)
                                Text("\(doc.chunks.count)개 구간 · \(doc.analyzed ? "맥락 준비" : "추출문 보관")").font(.caption).foregroundStyle(AppTheme.muted)
                                if let path=doc.relativePath {Text(path+" · 버전 \(doc.version ?? 1)"+(doc.currentVersion ? "" : " · 이전 근거 보관")).font(.caption2).foregroundStyle(AppTheme.violet)}
                                Button("내용·맥락 보기") { selected=doc.id }.font(.caption)
                            }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
                                .background(selected==doc.id ? AppTheme.lavender : Color.white,in:RoundedRectangle(cornerRadius:10))
                        }
                    }.padding(.trailing,6)
                }.frame(minWidth:220,idealWidth:270)
                ScrollView {
                    if let doc=materials.documents.first(where:{$0.id==selected}) ?? materials.documents.last {
                        VStack(alignment:.leading,spacing:12) {
                            Text(doc.title).font(.headline)
                            Text(doc.origin).font(.caption).textSelection(.enabled)
                            if let version=doc.version {Text("자료 버전 \(version) · SHA-256 "+doc.hash.prefix(12)).font(.caption).foregroundStyle(AppTheme.muted)}
                            HStack {Button("원본 열기") {materials.open(doc,original:true)};Button("전체 추출문") {materials.open(doc,original:false)}}
                            ForEach(doc.warnings,id:\.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                            ForEach(doc.chunks) { chunk in
                                VStack(alignment:.leading,spacing:6) {
                                    Text(chunk.location).font(.subheadline.bold())
                                    Text(chunk.summary ?? "맥락 분석 대기 · 추출문으로 검색·참조 가능").font(.callout)
                                    if let terms=chunk.terms,!terms.isEmpty {Text("용어: "+terms.joined(separator:", ")).font(.caption).foregroundStyle(AppTheme.violet)}
                                    DisclosureGroup("추출 원문 · "+chunk.id.suffix(8)) {Text(chunk.text).font(.caption).textSelection(.enabled)}
                                }.padding(10).background(Color.white,in:RoundedRectangle(cornerRadius:10))
                            }
                        }.padding(.leading,8).textSelection(.enabled)
                    }
                }.frame(minWidth:330)
            }
        }.tint(AppTheme.violet)
    }
}
