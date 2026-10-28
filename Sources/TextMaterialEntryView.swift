import SwiftUI

struct TextMaterialEntryView: View {
    @ObservedObject var materials: MeetingMaterials
    let added: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var error: String?
    @State private var notice: String?
    @FocusState private var focused: Field?
    private enum Field { case title, text }
    private var canAdd: Bool {
        !materials.busy && (try? EditingMaterialAddition.pasted(title: title, text: text).validate()) != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("텍스트 자료 추가").font(.title2.bold())
            Text("회의 안건·배경·참고 내용을 붙여넣으세요. 추가할 때마다 별도 자료로 저장하고 이번 회의에 함께 선택합니다.")
                .font(.callout).foregroundStyle(AppTheme.muted)
            TextField("자료 제목 · 생략하면 본문 첫 줄 사용", text: $title)
                .textFieldStyle(.roundedBorder).focused($focused, equals: .title).accessibilityLabel("텍스트 자료 제목")
            TextEditor(text: $text).font(.system(size: 15)).lineSpacing(4)
                .scrollContentBackground(.hidden).padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.muted.opacity(0.25)))
                .focused($focused, equals: .text).accessibilityLabel("회의자료 본문 붙여넣기")
            HStack {
                Text("\(text.count.formatted()) / 200,000자").font(.caption).foregroundStyle(text.count > EditingMaterialAddition.maximumCharacters ? AppTheme.rose : AppTheme.muted)
                Spacer()
                Text("저장 후 바로 검색·참조 · AI 맥락 분석은 자료 창에서 실행").font(.caption).foregroundStyle(AppTheme.muted)
            }
            if title.count > 160 || title.contains(where: \.isNewline) { Text("제목은 한 줄로 160자까지 입력하세요.").font(.caption).foregroundStyle(AppTheme.rose) }
            if materials.busy { Text("진행 중인 자료 작업이 끝나면 추가할 수 있습니다. 입력 내용은 이 창에 유지됩니다.").font(.caption).foregroundStyle(AppTheme.muted) }
            if let error { Text(error).font(.callout).foregroundStyle(AppTheme.rose).textSelection(.enabled) }
            if let notice { Text(notice).font(.callout).foregroundStyle(AppTheme.violet) }
            HStack {
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("추가하고 계속") { save(continueEditing: true) }.disabled(!canAdd)
                Button("추가") { save(continueEditing: false) }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command).disabled(!canAdd)
            }
        }.padding(24).frame(width: 680, height: 530).background(AppTheme.paper).tint(AppTheme.violet)
            .onAppear { focused = .text }
            .interactiveDismissDisabled(!text.isEmpty || !title.isEmpty)
    }
    private func save(continueEditing: Bool) {
        do {
            let id = try materials.addText(title: title, text: text)
            added(id); error = nil
            if continueEditing {
                title = ""; text = ""; focused = .text
                notice = "자료를 추가했습니다. 다음 자료를 이어서 입력하세요. 현재 \(materials.context.documents.count)개 선택."
            } else { dismiss() }
        } catch { self.error = error.localizedDescription }
    }
}
