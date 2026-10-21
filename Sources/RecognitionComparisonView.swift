import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RecognitionComparisonView: View {
    @ObservedObject var model: AppModel
    let turnID: String?
    let dismiss: () -> Void
    @State private var document: RecognitionComparison?
    @State private var selectedFile: URL?
    @State private var loadError: String?
    @State private var loaded = false
    @State private var allChunks = false

    private var file: URL? { selectedFile ?? model.comparisonURL }
    private var turn: ConversationTurn? {
        guard selectedFile == nil, let turnID else { return nil }
        return model.conversationTurns.first { $0.id == turnID }
    }
    private var chunks: [RecognitionComparison.Chunk] {
        let values = document?.chunks ?? []
        guard let turn, !allChunks else { return values }
        return values.filter { $0.end_time >= turn.start && $0.start_time <= turn.end }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("인식 차이와 변경 기록").font(.title2.bold())
                    Text(selectedFile == nil ? "녹음 중에도 결과가 도착하면 자동으로 갱신됩니다." : "저장한 대화의 인식 기록")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기", action: dismiss).keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 16) {
                Label("삭제·교체된 글자", systemImage: "minus.circle").foregroundStyle(.red)
                Label("추가·교체된 글자", systemImage: "plus.circle").foregroundStyle(AppTheme.violet)
                Spacer()
                Button("저장한 기록 열기…", action: openSavedRecord)
                if let file {
                    Button("파일 위치") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            }.font(.caption)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let turn {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("\(model.speakerName(for: turn.speaker)) · \(AppModel.time(turn.start))–\(AppModel.time(turn.end))")
                                .font(.headline)
                            Text("현재 발언 · 같은 화자의 연속 발언을 함께 표시합니다.")
                                .font(.caption).foregroundStyle(.secondary)
                            TextComparisonView(before: model.localDraftText(for: turn), after: model.displayedText(for: turn),
                                               beforeTitle: "현재 로컬 초안 · 해당 화자·시간 기준",
                                               afterTitle: model.recognitionLabel(for: turn))
                        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 12))
                        Toggle("전체 처리 구간 보기", isOn: $allChunks).toggleStyle(.checkbox)
                        Text("아래 기록은 각 교정·전송 구간 전체를 비교합니다. 여러 화자의 발언이 포함될 수 있습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if selectedFile == nil {
                        ForEach(model.segments.filter { segment in
                            model.corrections[segment.id]?.proposedText != nil &&
                            (turn == nil || turn!.segments.contains { $0.id == segment.id })
                        }) { segment in
                            if let correction = model.corrections[segment.id], let proposal = correction.proposedText {
                                VStack(alignment: .leading, spacing: 10) {
                                    Label("확인 필요 · \(model.speakerName(for: segment.speaker))", systemImage: "exclamationmark.circle")
                                    Text(correction.rejectionReason ?? "원문 대조 필요").font(.caption).foregroundStyle(.secondary)
                                    TextComparisonView(before: correction.originalText, after: proposal,
                                        beforeTitle: "유지 중인 원문", afterTitle: "AI 교정 제안")
                                    Button("확인한 교정문 적용") { model.acceptCodexProposal(segmentID: segment.id) }
                                }.padding(16).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    if let document {
                        ForEach((document.speaker_reviews ?? []).filter { record in
                            turn == nil || allChunks || record.inputs.contains { $0.end >= turn!.start && $0.start <= turn!.end }
                        }) { record in
                            SpeakerReviewHistoryView(record: record).padding(16)
                                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                        Text("AI 교정 \((document.codex_corrections ?? []).count)회 · Gemini 응답 \(document.chunks.count)개 · 로컬 갱신 \(document.local_update_count)회")
                            .font(.subheadline.weight(.medium))
                        ForEach((document.codex_corrections ?? []).filter { record in
                            turn == nil || allChunks || (record.end >= turn!.start && record.start <= turn!.end)
                        }) { record in
                            CodexRecordView(record: record)
                        }
                        ForEach(chunks) { chunk in
                            ChunkComparisonView(chunk: chunk)
                        }
                        if chunks.isEmpty && (document.codex_corrections ?? []).isEmpty && (document.speaker_reviews ?? []).isEmpty {
                            Label("처리 기록 대기 중 · 로컬 초안을 먼저 표시합니다.", systemImage: "clock")
                                .foregroundStyle(.secondary).padding(.vertical, 20)
                        }
                        ForEach(Array(document.failures.enumerated()), id: \.offset) { _, failure in
                            VStack(alignment: .leading, spacing: 4) {
                                Label("로컬 결과 유지", systemImage: "exclamationmark.circle")
                                Text(failure.message).textSelection(.enabled)
                                Text(failure.timestamp).font(.caption).foregroundStyle(.secondary)
                            }.font(.callout).padding(12).background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                        }
                    } else if file == nil {
                        Text("녹음을 시작하면 비교 기록이 생성됩니다. ‘저장한 기록 열기’로 이전 대화의 .comparison.json 파일을 볼 수 있습니다.")
                            .foregroundStyle(.secondary).padding(.vertical, 25)
                    } else if !loaded {
                        ProgressView("비교 기록을 읽고 있습니다.")
                    }
                    if let loadError {
                        Text(loadError).font(.callout).foregroundStyle(.orange)
                    }
                }.padding(.trailing, 8)
            }
        }
        .padding(24)
        .frame(width: 820, height: 640)
        .background(AppTheme.paper)
        .environment(\.colorScheme, .light)
        .task(id: file) {
            document = nil; loadError = nil; loaded = false
            guard let file else { loaded = true; return }
            // Read off the main actor; the recorder atomically replaces this file.
            while !Task.isCancelled {
                do {
                    let next = try await Task.detached(priority: .utility) {
                        try JSONDecoder().decode(RecognitionComparison.self, from: Data(contentsOf: file))
                    }.value
                    guard !Task.isCancelled else { return }
                    document = next; loadError = nil; loaded = true
                } catch {
                    guard !Task.isCancelled else { return }
                    loadError = "비교 기록을 읽을 수 없습니다. .comparison.json 파일과 저장 위치를 확인해 주세요."
                    loaded = true
                }
                if selectedFile != nil { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func openSavedRecord() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.directoryURL = StorageLocations.diagnostics
        panel.message = "대화의 .comparison.json 파일을 선택하세요."
        panel.begin { response in
            if response == .OK, let url = panel.url { selectedFile = url }
        }
    }
}

private struct ChunkComparisonView: View {
    let chunk: RecognitionComparison.Chunk
    @State private var baseline = "response"
    private var before: String {
        switch baseline {
        case "submission": return chunk.local_at_submission
        case "final": return chunk.final_local_text ?? chunk.local_at_response
        default: return chunk.local_at_response
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(AppModel.time(chunk.start_time))–\(AppModel.time(chunk.end_time))").font(.headline.monospacedDigit())
                Spacer()
                Text(String(format: "Gemini 응답 %.1f초", chunk.request_seconds)).font(.caption).foregroundStyle(.secondary)
            }
            Picker("비교할 로컬 시점", selection: $baseline) {
                Text("전송 시점").tag("submission")
                Text("응답 시점").tag("response")
                if chunk.final_local_text != nil { Text("최종 로컬").tag("final") }
            }.pickerStyle(.segmented)
            TextComparisonView(before: before, after: chunk.gemini_text,
                               beforeTitle: "로컬 인식", afterTitle: "Gemini 인식")
            DisclosureGroup("로컬 초안이 바뀐 과정") {
                VStack(alignment: .leading, spacing: 14) {
                    TextComparisonView(before: chunk.local_at_submission, after: chunk.local_at_response,
                                       beforeTitle: "Gemini 전송 당시", afterTitle: "Gemini 응답 당시")
                    if let final = chunk.final_local_text {
                        TextComparisonView(before: chunk.local_at_response, after: final,
                                           beforeTitle: "응답 당시 로컬", afterTitle: "최종 로컬")
                    }
                }.padding(.top, 10)
            }.font(.callout)
        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct TextComparisonView: View {
    let before: String
    let after: String
    let beforeTitle: String
    let afterTitle: String

    var body: some View {
        let diff = TranscriptTextDifference.between(before, after)
        VStack(alignment: .leading, spacing: 10) {
            Text(diff.inserted_characters == 0 && diff.deleted_characters == 0
                 ? "두 결과가 같습니다."
                 : "추가 \(diff.inserted_characters)자 · 삭제 \(diff.deleted_characters)자")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                column(beforeTitle, text: highlighted(diff, side: "before"), empty: before.isEmpty)
                column(afterTitle, text: highlighted(diff, side: "after"), empty: after.isEmpty)
            }
            if diff.truncated {
                Text("변경량이 큰 구간은 문단 범위로 강조합니다.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func column(_ title: String, text: AttributedString, empty: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Text(empty ? AttributedString("(인식된 텍스트 없음)") : text)
                .font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func highlighted(_ diff: TranscriptTextDifference, side: String) -> AttributedString {
        var result = AttributedString()
        for operation in diff.operations {
            if side == "before" && operation.operation == "insert" { continue }
            if side == "after" && operation.operation == "delete" { continue }
            var value = AttributedString(operation.text)
            if operation.operation == "delete" {
                value.foregroundColor = Color(red: 0.65, green: 0.16, blue: 0.14)
                value.backgroundColor = Color.red.opacity(0.10)
                value.strikethroughStyle = .single
            } else if operation.operation == "insert" {
                value.foregroundColor = AppTheme.violet
                value.backgroundColor = AppTheme.violet.opacity(0.12)
                value.underlineStyle = .single
            }
            result.append(value)
        }
        return result
    }
}

private struct CodexRecordView: View {
    let record: CodexCorrectionRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AI 교정 · \(AppModel.time(record.start))–\(AppModel.time(record.end))", systemImage: "text.badge.checkmark").font(.headline)
                Spacer()
                Text(String(format: "%.1f초", record.elapsed_seconds)).font(.caption)
            }
            Text("\(record.model) · \(record.effort) · \(record.requested_at)").font(.caption).foregroundStyle(.secondary)
            if let message = record.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if record.status == "waiting_retry" {
                Label("교정 대기 · 원문 보존", systemImage: "clock").font(.callout)
            } else {
                TextComparisonView(before: record.inputs.map(\.text).joined(separator: " "),
                    after: record.inputs.map { input in record.outputs.first { $0.id == input.id }?.corrected_text ?? input.text }.joined(separator: " "),
                    beforeTitle: "교정 요청 원문", afterTitle: record.status == "user_accepted" ? "사용자가 적용한 결과" : "AI 응답 · 확인 필요 항목 포함")
            }
        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 12))
    }
}
