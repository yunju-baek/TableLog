import SwiftUI
import AppKit

struct EditingConversationView: View {
    @ObservedObject var chat: MeetingEditingChat
    @State private var showHistory = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if chat.entries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("말하듯 요청하면, 기록을 다듬어요.").font(.system(size: 14, weight: .semibold))
                    Text("“예산을 설명한 발언을 화자 2로 바꿔 줘”\n“녹취의 오타를 다듬어 줘”\n“회의록을 결정 사항 중심으로 정리해 줘”")
                        .font(.caption).lineSpacing(6).foregroundStyle(AppTheme.muted)
                    Text("수정안을 확인하고 적용하면 기록에 반영됩니다.")
                        .font(.caption2).foregroundStyle(AppTheme.muted)
                }.padding(.vertical, 10)
            }
            if chat.entries.count > 6 {
                DisclosureGroup("이전 대화 \(chat.entries.count - 6)개", isExpanded: $showHistory) {
                    ForEach(Array(chat.entries.dropLast(6))) { entry in row(entry) }
                }.font(.caption)
            }
            ForEach(Array(chat.entries.suffix(6))) { entry in row(entry) }
            if let error = chat.storageError { Text(error).font(.caption).foregroundStyle(AppTheme.rose) }
        }
    }
    private func row(_ entry: EditingChatEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.request).font(.callout.weight(.medium)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(AppTheme.lavender, in: RoundedRectangle(cornerRadius: 10))
            if entry.status == "working" {
                HStack(spacing: 7) { ProgressView().controlSize(.small); Text("자료를 살펴보고 있어요…").font(.caption) }
            }
            if !entry.answer.isEmpty { Text(entry.answer).font(.callout).textSelection(.enabled).lineSpacing(3) }
            if let plan = entry.plan, !plan.changes.isEmpty {
                DisclosureGroup("변경 \(plan.changes.count)개 · 전후 비교") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(plan.changes) { change in
                            changeRow(change, snapshot: entry.snapshot)
                        }
                    }.padding(.top, 8)
                }.font(.caption)
            }
            if let snapshot = entry.snapshot, snapshot.omittedCount > 0 {
                Text("관련 구간 \(snapshot.documents.count)개 참조 · 전체에서 \(snapshot.omittedCount)개 제외")
                    .font(.caption2).foregroundStyle(AppTheme.muted)
            }
            HStack {
                if entry.status == "ready" {
                    Button("변경 적용") { chat.apply(entry.id) }.buttonStyle(.borderedProminent).controlSize(.small)
                } else if entry.status == "applied" {
                    Label("적용 완료", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(AppTheme.violet)
                    if chat.canUndo(entry.id) { Button("되돌리기") { chat.undo(entry.id) }.controlSize(.small) }
                } else if entry.status == "undone" { Text("되돌림 완료").font(.caption).foregroundStyle(AppTheme.muted) }
                else if entry.status == "expired" { Text("현재 내용을 기준으로 다시 요청할 수 있습니다.").font(.caption2).foregroundStyle(AppTheme.muted) }
                if let url=entry.outputURL, entry.status == "applied" {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName:"doc.text") }
                        .help("편집본 열기").accessibilityLabel("편집본 열기")
                }
            }
            if let error=entry.error { Text(error).font(.caption).foregroundStyle(AppTheme.rose).textSelection(.enabled) }
            if entry.status == "failed" || (entry.status == "ready" && entry.error != nil) {
                Button("현재 내용으로 다시 요청") { chat.send(entry.request) }.font(.caption).disabled(chat.busy)
            }
        }.padding(.vertical, 5)
    }
    private func changeRow(_ change: EditingChange, snapshot: EditingSnapshot?) -> some View {
        let doc=snapshot?.documents.first(where: { $0.id==change.targetID })
        return VStack(alignment: .leading, spacing: 5) {
            Text(doc?.title ?? change.targetID).font(.caption.weight(.semibold))
            if change.speaker >= 0, change.speaker != doc?.speaker {
                Text("화자 \(doc?.speaker ?? 0) → 화자 \(change.speaker)").foregroundStyle(AppTheme.violet)
            }
            if change.before != change.after {
                Text("수정 전").font(.caption2).foregroundStyle(AppTheme.muted)
                Text(change.before).textSelection(.enabled)
                Text("수정 후").font(.caption2).foregroundStyle(AppTheme.violet)
                Text(change.after.isEmpty ? "발언 삭제" : change.after).textSelection(.enabled)
            }
        }.padding(9).frame(maxWidth:.infinity,alignment:.leading)
            .background(.white,in:RoundedRectangle(cornerRadius:8))
    }
}
