import SwiftUI
import AppKit

struct TranscriptEditRequest: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let revision: UUID
    let segments: [TranscriptSegment]
    let texts: [Int:String]
    let speakers: [Int:Int]
    let initialParts: [Int:[ManualTranscriptDraft]]
    let manualGroups: [Int:UUID]
}

struct TranscriptTextEditor: View {
    @ObservedObject var model: AppModel
    let request: TranscriptEditRequest
    let dismiss: () -> Void
    @State private var drafts: [Int:[ManualTranscriptDraft]]
    @State private var selections: [UUID:NSRange] = [:]
    @State private var editError: String?

    init(model: AppModel,request: TranscriptEditRequest,dismiss: @escaping () -> Void) {
        self.model=model;self.request=request;self.dismiss=dismiss
        _drafts=State(initialValue:request.initialParts)
    }
    private func partBinding(_ source: Int,_ index:Int)->Binding<ManualTranscriptDraft> {
        let original=drafts[source]![index]
        return Binding(get:{drafts[source]?.first(where:{$0.id==original.id}) ?? original},set:{ value in
            if let current=drafts[source]?.firstIndex(where:{$0.id==original.id}) { drafts[source]![current]=value }
        })
    }
    private func split(_ source:Int,_ index:Int) {
        guard let parts=drafts[source],parts.indices.contains(index) else { return }
        let part=parts[index]
        guard let pieces=part.split(atUTF16:selections[part.id]?.location ?? 0) else { return }
        drafts[source]!.replaceSubrange(index...index,with:pieces)
        editError=nil
    }
    private func merge(_ source:Int,_ index:Int) {
        guard let parts=drafts[source],index+1<parts.count else { return }
        let first=parts[index],next=parts[index+1]
        let joined=ManualTranscriptDraft(start:first.start,end:next.end,speaker:first.speaker,
            text:[first.text,next.text].filter{!$0.isEmpty}.joined(separator:" "))
        drafts[source]!.replaceSubrange(index...(index+1),with:[joined])
    }
    private func boundaryBinding(_ source:Int,_ index:Int)->Binding<Double> {
        let fallback=drafts[source]![index].end
        return Binding(get:{ drafts[source].flatMap { $0.indices.contains(index) ? $0[index].end : nil } ?? fallback },set:{ proposed in
            guard proposed.isFinite,let parts=drafts[source],index+1<parts.count else { return }
            let value=min(parts[index+1].end-0.01,max(parts[index].start+0.01,proposed))
            drafts[source]![index].end=value;drafts[source]![index+1].start=value
        })
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text("발언 분리 · 화자 · 문장 수정").font(.title2.bold())
                    Text("화자가 바뀌는 글자 앞에 커서를 놓고 분리한 뒤, 각 구간의 화자를 선택하세요.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName:"person.2.wave.2").font(.title).foregroundStyle(AppTheme.violet)
            }
            HStack(spacing:7) {
                Image(systemName:"lock.fill")
                Text("저장한 구간의 문장과 화자를 확정합니다. 재편집 시 함께 나눈 구간을 불러옵니다.")
            }.font(.caption).foregroundStyle(AppTheme.violet).padding(10)
                .frame(maxWidth:.infinity,alignment:.leading).background(AppTheme.lavender,in:RoundedRectangle(cornerRadius:9))
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    ForEach(request.segments) { source in
                        VStack(alignment:.leading,spacing:10) {
                            ForEach(Array((drafts[source.id] ?? []).enumerated()),id:\.element.id) { index,part in
                                ManualPartEditor(part:partBinding(source.id,index),
                                    selection:Binding(get:{selections[part.id] ?? NSRange(location:0,length:0)},set:{selections[part.id]=$0}),
                                    speakerName:model.speakerName,canPlay:model.canPlayTranscriptAudio,
                                    playing:model.playingReviewAudio,
                                    onPlay:{model.playReviewAudio(start:part.start,end:part.end)},onStop:model.stopReviewAudio,
                                    onSplit:{split(source.id,index)},
                                    onMerge:index+1<(drafts[source.id]?.count ?? 0) ? {merge(source.id,index)} : nil)
                                if index+1<(drafts[source.id]?.count ?? 0),let parts=drafts[source.id],parts[index+1].end-part.start>0.02 {
                                    HStack(spacing:10) {
                                        Image(systemName:"scissors").foregroundStyle(AppTheme.violet)
                                        Text("다음 구간 시작").font(.caption)
                                        Slider(value:boundaryBinding(source.id,index),in:(part.start+0.01)...(parts[index+1].end-0.01))
                                            .accessibilityLabel("화자 분리 시각")
                                        TextField("초",value:boundaryBinding(source.id,index),format:.number.precision(.fractionLength(2)))
                                            .frame(width:72).textFieldStyle(.roundedBorder)
                                        Text("초").font(.caption)
                                    }.padding(.horizontal,8)
                                }
                            }
                        }
                    }
                }.padding(4)
            }
            VStack(alignment:.leading,spacing:3) {
                Text("분리 시각은 글자 위치로 추정합니다. 원음을 듣고 슬라이더 또는 초 단위 입력으로 맞추세요.")
                Text(model.canPlayTranscriptAudio ? "원음 M4A와 교정 이력은 보존됩니다. 빈 구간은 전사와 회의록에서 제외됩니다." : "원음 듣기는 녹음·파일 처리를 마치고 M4A가 저장되면 사용할 수 있습니다.")
            }.font(.caption).foregroundStyle(.secondary)
            if let editError { Text(editError).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("발언 전체 비우기") {
                    for key in drafts.keys { for index in drafts[key]!.indices { drafts[key]![index].text="" } }
                }
                Spacer()
                Button("취소",action:dismiss).keyboardShortcut(.cancelAction)
                Button("교정 저장") {
                    if model.applyManualTranscriptEdits(request:request,drafts:drafts) { dismiss() }
                    else { editError=model.errorMessage }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width:820,height:690).onDisappear { model.stopReviewAudio() }
    }
}

private struct ManualPartEditor: View {
    @Binding var part:ManualTranscriptDraft
    @Binding var selection:NSRange
    let speakerName:(Int)->String
    let canPlay:Bool
    let playing:Bool
    let onPlay:()->Void
    let onStop:()->Void
    let onSplit:()->Void
    var onMerge:(()->Void)?
    var body:some View {
        VStack(alignment:.leading,spacing:9) {
            HStack {
                Text("\(AppModel.time(part.start)) – \(AppModel.time(part.end))").font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary)
                Spacer()
                Picker("화자",selection:$part.speaker) {
                    Text("화자 확인 필요").tag(0)
                    ForEach(1...8,id:\.self) { speaker in Text(speakerName(speaker)).tag(speaker) }
                }.frame(width:210).accessibilityLabel("이 구간의 화자")
                Button(action:onPlay) { Label("원음 듣기",systemImage:"play.fill") }.disabled(!canPlay)
                if playing { Button("정지",action:onStop) }
            }
            CursorTranscriptEditor(text:$part.text,selection:$selection)
                .frame(height:100).overlay(RoundedRectangle(cornerRadius:5).stroke(.quaternary))
                .accessibilityLabel("인식 문장 수정")
            HStack {
                Button(action:onSplit) { Label("커서 위치에서 나누기",systemImage:"scissors") }
                    .disabled(part.split(atUTF16:selection.location)==nil)
                if let onMerge { Button("다음 구간과 합치기",action:onMerge).help("현재 구간의 화자로 합칩니다.") }
                Spacer()
                Button("이 구간 비우기") { part.text="" }
            }.font(.caption)
        }.padding(12).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
    }
}

/// Native selection tracking makes cursor-based splitting work for Korean IME input.
private struct CursorTranscriptEditor: NSViewRepresentable {
    @Binding var text:String
    @Binding var selection:NSRange
    func makeCoordinator()->Coordinator { Coordinator(self) }
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .noBorder
        let view=NSTextView();view.isRichText=false;view.allowsUndo=true
        view.isAutomaticQuoteSubstitutionEnabled=false;view.isAutomaticDashSubstitutionEnabled=false
        view.font = .systemFont(ofSize:15);view.textContainerInset=NSSize(width:8,height:8)
        view.isVerticallyResizable=true;view.isHorizontallyResizable=false;view.autoresizingMask=[.width]
        view.textContainer?.widthTracksTextView=true
        view.string=text;view.delegate=context.coordinator;view.setAccessibilityLabel("인식 문장 수정")
        scroll.documentView=view
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        context.coordinator.parent=self
        guard let view=scroll.documentView as? NSTextView else { return }
        context.coordinator.updating=true
        defer { context.coordinator.updating=false }
        if view.string != text { view.string=text }
        let count=(text as NSString).length
        let location=min(count,max(0,selection.location)),length=min(selection.length,count-location)
        let range=NSRange(location:location,length:length)
        if view.selectedRange() != range { view.setSelectedRange(range) }
    }
    final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:CursorTranscriptEditor
        var updating=false
        init(_ parent:CursorTranscriptEditor) { self.parent=parent }
        func textDidChange(_ notification:Notification) {
            guard !updating,let view=notification.object as? NSTextView else { return }
            parent.text=view.string;parent.selection=view.selectedRange()
        }
        func textViewDidChangeSelection(_ notification:Notification) {
            guard !updating,let view=notification.object as? NSTextView else { return }
            parent.selection=view.selectedRange()
        }
    }
}
