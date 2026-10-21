import SwiftUI

struct SpeakerReviewView: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("LLM 화자 재검토").font(.title2.bold())
                Spacer()
                Button("닫기") { model.stopReviewAudio(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("음성으로 구분한 화자를 앞뒤 발언으로 검토합니다. 제안은 원음과 대조한 뒤 적용하세요. 확신도는 모델의 자체 평가입니다.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Label("검토 모델 · \(model.codexSettings.provider.title)", systemImage: "sparkles").font(.callout)
                Spacer()
                if model.speakerReviewRunning { Button("검토 취소", action: model.cancelSpeakerReview) }
                else { Button("화자 검토 시작", action: model.startSpeakerReview).buttonStyle(.borderedProminent).disabled(!model.canReviewSpeakers) }
            }
            Text("\(model.codexSettings.provider.title) · \(model.codexSettings.model.isEmpty ? "기본 모델" : model.codexSettings.model) · \(model.codexSettings.effort.isEmpty ? "기본 추론" : model.codexSettings.effort) — 발언·화자 이름·회의 주제를 선택한 AI CLI의 서비스로 전달합니다. 모델은 ‘AI 설정’에서 변경할 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.speakerReviewStatus).font(.callout)
            if !model.canReviewSpeakers && !model.speakerReviewRunning {
                Text("녹음과 본문 교정을 마친 뒤 시작할 수 있습니다. 교정 오류로 대기 중인 전사도 검토할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            }
            if model.playingReviewAudio { Button("원음 재생 중지", action: model.stopReviewAudio) }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.speakerReviewRecords.isEmpty {
                        Text("검토 결과에 최초 화자 → 제안 화자, 이유, 확신도, 원음 확인 시각을 표시합니다. 새 화자 후보도 사용자가 확인해 적용합니다.")
                            .foregroundStyle(.secondary).padding()
                    }
                    ForEach(model.speakerReviewRecords.reversed()) { record in
                        VStack(alignment: .leading, spacing: 12) {
                            SpeakerReviewHistoryView(record: record)
                            ForEach(record.suggestions) { proposal in
                                HStack {
                                    Text("발언 \(proposal.input.id) · \(SpeakerReviewHistoryView.status(proposal.status))").font(.caption)
                                    Button("원음 듣기") { model.playReviewAudio(start: proposal.input.start, end: proposal.input.end) }
                                        .disabled(model.savedAudioURL == nil)
                                    Spacer()
                                    if proposal.status == "pending" {
                                        Button("기존 화자 유지") { model.decideSpeakerSuggestion(recordID: record.id, suggestionID: proposal.id, apply: false) }
                                            .disabled(model.speakerReviewRunning)
                                        Button("확인한 화자 적용") { model.decideSpeakerSuggestion(recordID: record.id, suggestionID: proposal.id, apply: true) }
                                            .disabled(!model.canApplySpeakerSuggestion(proposal, record: record))
                                    } else if proposal.status == "accepted" {
                                        Button("최초 화자로 되돌리기") { model.revertSpeakerSuggestion(recordID: record.id, suggestionID: proposal.id) }
                                            .disabled(!model.canRevertSpeakerSuggestion(proposal))
                                    }
                                }.font(.caption)
                                if proposal.status == "pending" && !model.speakerReviewRunning && !model.canApplySpeakerSuggestion(proposal, record: record) {
                                    Text("본문·화자·이름 또는 근거 발언이 변경되었습니다. 다시 검토해 최신 제안을 받으세요.").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }.padding(24).frame(width: 850, height: 650).background(Color.gray.opacity(0.06))
            .onDisappear { model.stopReviewAudio() }
    }
}

struct SpeakerReviewHistoryView: View {
    let record: SpeakerReviewRecord
    static func status(_ value: String) -> String {
        ["pending": "확인 필요", "accepted": "사용자 적용", "rejected": "기존 화자 유지", "reverted": "최초 화자로 복원",
         "superseded": "재검토로 이전 제안 보관", "stale": "내용 변경으로 보류", "completed": "검토 완료",
         "running": "검토 중", "failed": "검토 오류", "cancelled": "검토 취소"][value] ?? value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("화자 검토 · \(Self.status(record.status))", systemImage: "person.2.badge.gearshape")
                Spacer()
                Text(String(format: "%.1f초", record.elapsed_seconds)).monospacedDigit()
            }.font(.headline)
            Text("\(record.model) · \(record.requested_at)").font(.caption).foregroundStyle(.secondary)
            if let message = record.message { Text(message).font(.callout) }
            ForEach(record.suggestions) { proposal in
                VStack(alignment: .leading, spacing: 6) {
                    Text("발언 \(proposal.input.id) · \(AppModel.time(proposal.input.start))–\(AppModel.time(proposal.input.end)) · 화자 \(proposal.input.speaker) → 화자 \(proposal.proposed_speaker)").font(.headline)
                    Text("최초 음성 화자 \(proposal.input.original_speaker) · 모델 확신도 \(Int((proposal.confidence * 100).rounded()))% · \(Self.status(proposal.status))").font(.caption).foregroundStyle(.secondary)
                    Text(proposal.input.text).textSelection(.enabled)
                    Text(proposal.reason).font(.callout)
                    Text("근거 발언: \(proposal.evidence_segment_ids.map(String.init).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }.padding(12).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            DisclosureGroup("검토에 사용한 앞뒤 발언") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(record.inputs) { input in
                        Text("#\(input.id) · \(AppModel.time(input.start)) · \(input.speaker_name)\n\(input.text)")
                            .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 8)
            }.font(.caption)
        }
    }
}
