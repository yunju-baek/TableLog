import SwiftUI
import AppKit

enum MeetingHistoryPresentation {
    static let show = Notification.Name("TableLog.showMeetingHistory")
}

struct MeetingHistoryView: View {
    let model: AppModel
    @ObservedObject var history: MeetingHistoryStore
    let dismiss: () -> Void
    @State private var search = ""
    @State private var selectedID: UUID?
    @State private var snapshot: MeetingHistorySnapshot?
    @State private var loadingDetail = false
    @State private var detailError: String?
    @State private var refreshRevision = 0
    @State private var detailRevision = 0
    @State private var tab = DetailTab.minutes
    @State private var actionError: String?

    private enum DetailTab: String, CaseIterable, Identifiable {
        case minutes = "회의록", transcript = "전사", materials = "자료·맥락", assistant = "도우미 기록"
        var id: Self { self }
    }
    private struct DetailRequest: Hashable { let id: UUID?; let revision: Int }
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy.MM.dd (E) HH:mm"
        return formatter
    }()
    private var filtered: [MeetingHistoryEntry] {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return history.items }
        return history.items.filter { entry in
            let searchable = entry.title + " " + Self.dateFormatter.string(from: entry.date) + " " + entry.date.formatted(.iso8601.year().month().day())
            return terms.allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 23, weight: .medium)).foregroundStyle(AppTheme.violet)
                    .frame(width: 46, height: 46).background(AppTheme.lavender, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text("지난 회의").font(.system(size: 22, weight: .bold))
                    Text("저장한 회의를 찾아보고, 재가공본으로 편집을 이어갑니다.")
                        .font(.system(size: 12)).foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Button("닫기", action: dismiss).keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            HStack(spacing: 0) {
                meetingList.frame(width: 294)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 1060, height: 740)
        .background(AppTheme.paper).foregroundStyle(AppTheme.ink).tint(AppTheme.violet)
        .preferredColorScheme(.light)
        .task(id: refreshRevision) {
            await history.refresh()
            guard !Task.isCancelled else { return }
            if !history.items.contains(where: { $0.id == selectedID }) { selectedID = filtered.first?.id }
            detailRevision += 1
        }
        .task(id: DetailRequest(id: selectedID, revision: detailRevision)) { await loadSelection() }
        .alert("지난 회의 확인", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("확인", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
    }

    private var meetingList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.muted)
                TextField("회의 제목·날짜 검색", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(AppTheme.muted).accessibilityLabel("검색어 지우기")
                }
            }.padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("\(filtered.count)개 회의").font(.system(size: 12, weight: .semibold))
                Spacer()
                if history.loading { ProgressView().controlSize(.small) }
                Button { refreshRevision += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(history.loading).help("회의 목록 새로 고침").accessibilityLabel("회의 목록 새로 고침")
            }
            if let error = history.error {
                Text(error).font(.system(size: 11)).foregroundStyle(AppTheme.rose).textSelection(.enabled)
            }
            if history.loading && history.items.isEmpty {
                emptyState("저장한 회의를 찾고 있습니다", icon: "doc.text.magnifyingglass")
            } else if filtered.isEmpty {
                emptyState(search.isEmpty ? "저장한 회의가 여기에 표시됩니다" : "검색어에 맞는 회의를 확인해 주세요", icon: "tray")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { entry in
                            Button { selectedID = entry.id } label: { listRow(entry) }.buttonStyle(.plain)
                        }
                    }
                }
            }
            Text(history.status).font(.system(size: 10)).foregroundStyle(AppTheme.muted).lineLimit(3)
        }
        .padding(16)
        .background(AppTheme.lavender.opacity(0.22))
    }

    private func listRow(_ entry: MeetingHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(entry.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            Text(Self.dateFormatter.string(from: entry.date)).font(.system(size: 10)).foregroundStyle(AppTheme.muted)
            HStack(spacing: 9) {
                Label(time(entry.duration), systemImage: "waveform")
                Text("발언 \(entry.segmentCount)")
                if entry.hasMinutes { Image(systemName: "doc.text") }
                if !entry.warnings.isEmpty { Image(systemName: "exclamationmark.circle").help(entry.warnings.joined(separator: "\n")) }
            }.font(.system(size: 10)).foregroundStyle(AppTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(selectedID == entry.id ? AppTheme.lavender : .white, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selectedID == entry.id ? AppTheme.violet.opacity(0.5) : .clear))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var detail: some View {
        if loadingDetail {
            VStack(spacing: 12) { ProgressView(); Text("회의 기록을 불러오고 있습니다").font(.system(size: 13)).foregroundStyle(AppTheme.muted) }
        } else if let detailError {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.doc").font(.system(size: 30)).foregroundStyle(AppTheme.rose)
                Text(detailError).font(.system(size: 13)).textSelection(.enabled).multilineTextAlignment(.center)
                Button("다시 불러오기") { detailRevision += 1 }
            }.padding(28)
        } else if let snapshot {
            snapshotDetail(snapshot)
        } else {
            emptyState("왼쪽에서 회의를 선택하세요", icon: "text.book.closed")
        }
    }

    private func snapshotDetail(_ value: MeetingHistorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(value.title).font(.system(size: 19, weight: .bold)).textSelection(.enabled)
                    Text(Self.dateFormatter.string(from: value.date) + " · " + time(value.duration) + " · 발언 \(value.segments.count)개")
                        .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                }
                Spacer()
                HistoryReprocessingControl(model: model, snapshot: value, dismiss: dismiss) { actionError = $0 }
            }
            Text("원본은 읽기 전용으로 보관합니다. 재가공본에서 전사를 편집하고 회의록을 다시 생성할 수 있습니다.")
                .font(.system(size: 11)).foregroundStyle(AppTheme.muted).lineSpacing(3)
            if !value.warnings.isEmpty {
                DisclosureGroup("기록 확인 사항 \(value.warnings.count)개") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(value.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).textSelection(.enabled) }
                    }.font(.system(size: 11)).padding(.top, 6)
                }.font(.system(size: 11)).foregroundStyle(AppTheme.rose)
            }
            Picker("지난 회의 내용", selection: $tab) {
                ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Group {
                switch tab {
                case .minutes: minutes(value)
                case .transcript: transcript(value)
                case .materials: materials(value)
                case .assistant: assistant(value)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack(spacing: 12) {
                if let audio = value.audioURL { Button { open(audio) } label: { Label("음성 열기", systemImage: "waveform") } }
                if let file = value.transcriptURL { Button("전사 JSON") { open(file) } }
                if let file = value.minutesURL { Button("회의록 파일") { open(file) } }
                Spacer()
                if let file = value.transcriptURL ?? value.recordURL ?? value.minutesURL {
                    Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            }.font(.system(size: 11))
        }.padding(21)
    }

    @ViewBuilder private func minutes(_ value: MeetingHistorySnapshot) -> some View {
        if value.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyState(value.segments.isEmpty ? "회의록 생성에 사용할 발언을 확인해 주세요." : "회의록 생성 대기 · 전사는 보관돼 있습니다. ‘재가공본 만들기’ 후 ‘회의록 생성’을 눌러 주세요.", icon: "doc.text")
        } else {
            VStack(alignment:.leading,spacing:8) {
                if let record=value.record,record.editedOutput == nil,record.savedRevision>=0,record.savedRevision<record.revision {
                    Label("이전 저장본 · 최신 편집 내용 반영 대기",systemImage:"clock").font(.caption).foregroundStyle(AppTheme.violet)
                }
                MinutesPreviewView(documentID: value.id, text: value.markdown)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func transcript(_ value: MeetingHistorySnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if value.segments.isEmpty { Text("이 기록의 전사 구간을 확인해 주세요.").font(.system(size: 12)).foregroundStyle(AppTheme.muted) }
                ForEach(value.segments) { segment in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(value.names[segment.speaker] ?? (segment.speaker > 0 ? "화자 \(segment.speaker)" : "화자 확인 중")).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.violet)
                            Spacer()
                            Text(time(segment.start) + " – " + time(segment.end)).font(.system(size: 10, design: .monospaced)).foregroundStyle(AppTheme.muted)
                        }
                        Text(segment.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(2)
        }
    }

    private func materials(_ value: MeetingHistorySnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 13) {
                if !value.context.topic.isEmpty { textCard("회의 주제", text: value.context.topic) }
                if !value.context.terms.isEmpty { textCard("인식 참고 용어", text: value.context.terms) }
                if let purpose = value.record?.purpose, !purpose.isEmpty { textCard("회의 목적", text: purpose) }
                if value.materials.documents.isEmpty {
                    Text("이 회의에 연결한 자료가 여기에 표시됩니다.").font(.system(size: 12)).foregroundStyle(AppTheme.muted).padding(12)
                }
                ForEach(value.materials.documents) { document in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(document.title).font(.system(size: 13, weight: .semibold))
                        Text(document.origin).font(.system(size: 10)).foregroundStyle(AppTheme.muted).textSelection(.enabled)
                        HStack {
                            Text("\(document.chunks.count)개 구간 · " + (document.enabled && document.currentVersion ? "회의 맥락에 반영" : "보관 자료"))
                                .font(.system(size: 10)).foregroundStyle(AppTheme.muted)
                            Spacer()
                            Button("보관 원본") { open(URL(fileURLWithPath: document.originalPath)) }
                            Button("추출문") { open(URL(fileURLWithPath: document.extractedPath)) }
                        }.font(.system(size: 11))
                        DisclosureGroup("자료 내용 보기") {
                            ForEach(document.chunks) { chunk in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(chunk.location).font(.system(size: 10, weight: .semibold)).foregroundStyle(AppTheme.violet)
                                    if let summary = chunk.summary, !summary.isEmpty { Text(summary).font(.system(size: 12, weight: .medium)).textSelection(.enabled) }
                                    Text(chunk.text).font(.system(size: 11)).lineSpacing(4).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7)
                            }
                        }.font(.system(size: 11))
                    }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(2)
        }
    }

    @ViewBuilder private func assistant(_ value: MeetingHistorySnapshot) -> some View {
        if let state = value.assistantState {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    if !state.currentAgenda.isEmpty { textCard("검토한 안건", text: state.currentAgenda) }
                    assistantItems("요약", items: state.summary)
                    assistantItems("결정 후보·확인한 결정", items: state.decisionCandidates)
                    assistantItems("열린 질문", items: state.openQuestions)
                    if !state.suggestions.isEmpty {
                        Text("회의 제안").font(.system(size: 13, weight: .semibold))
                        ForEach(state.suggestions) { item in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack { Text(item.title).font(.system(size: 13, weight: .semibold)); Spacer(); Text(item.status.title).font(.system(size: 10)).foregroundStyle(AppTheme.violet) }
                                Text(item.reason).font(.system(size: 12)).textSelection(.enabled)
                                if !item.premise.isEmpty { Text("확인할 점: " + item.premise).font(.system(size: 11)).foregroundStyle(AppTheme.muted).textSelection(.enabled) }
                                if item.stale { Text("근거 변경 확인 필요").font(.system(size: 10)).foregroundStyle(AppTheme.rose) }
                                evidence(item.evidence)
                            }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    if !state.questions.isEmpty {
                        Text("도우미와 나눈 질문").font(.system(size: 13, weight: .semibold))
                        ForEach(state.questions) { question in
                            VStack(alignment: .leading, spacing: 9) {
                                Text(question.text).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                                Text(question.answer ?? "저장된 답변을 확인해 주세요.").font(.system(size: 12)).lineSpacing(4).textSelection(.enabled)
                                if let error = question.error { Text(error).font(.system(size: 10)).foregroundStyle(AppTheme.rose) }
                                evidence(question.evidence)
                            }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    if state.summary.isEmpty && state.decisionCandidates.isEmpty && state.openQuestions.isEmpty && state.suggestions.isEmpty && state.questions.isEmpty {
                        Text("이 회의의 도우미 기록을 확인해 주세요.").font(.system(size: 12)).foregroundStyle(AppTheme.muted).padding(12)
                    }
                }.padding(2)
            }
        } else { emptyState("저장한 도우미 요약과 제안이 여기에 표시됩니다", icon: "sparkles") }
    }

    @ViewBuilder private func assistantItems(_ title: String, items: [AssistantItem]) -> some View {
        if !items.isEmpty {
            Text(title).font(.system(size: 13, weight: .semibold))
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.text).font(.system(size: 12)).lineSpacing(4).textSelection(.enabled)
                    if item.confirmed { Label("사용자가 확인한 결정", systemImage: "checkmark.circle").font(.system(size: 10)).foregroundStyle(AppTheme.violet) }
                    if item.stale { Text("근거 변경 확인 필요").font(.system(size: 10)).foregroundStyle(AppTheme.rose) }
                    evidence(item.evidence)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder private func evidence(_ items: [AssistantEvidence]) -> some View {
        if !items.isEmpty {
            DisclosureGroup("근거 \(items.count)개") {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title + " · " + item.location).font(.system(size: 10, weight: .semibold)).foregroundStyle(AppTheme.violet)
                        if !item.text.isEmpty { Text(item.text).font(.system(size: 11)).textSelection(.enabled) }
                        if let path = item.sourcePath ?? item.audioPath { Button("근거 파일 열기") { open(URL(fileURLWithPath: path)) }.font(.system(size: 10)) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }
            }.font(.system(size: 10))
        }
    }

    private func textCard(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.violet)
            Text(text).font(.system(size: 12)).lineSpacing(4).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.white, in: RoundedRectangle(cornerRadius: 12))
    }

    private func emptyState(_ title: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(AppTheme.violet.opacity(0.65))
            Text(title).font(.system(size: 12)).foregroundStyle(AppTheme.muted).multilineTextAlignment(.center).lineSpacing(4)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor private func loadSelection() async {
        guard let id = selectedID, let entry = history.items.first(where: { $0.id == id }) else {
            snapshot = nil; detailError = nil; loadingDetail = false; return
        }
        snapshot = nil; detailError = nil; loadingDetail = true
        do {
            let loaded = try await history.load(entry)
            guard !Task.isCancelled, selectedID == id else { return }
            snapshot = loaded
            tab = loaded.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .transcript : .minutes
            loadingDetail = false
        } catch {
            guard !Task.isCancelled, selectedID == id else { return }
            detailError = error.localizedDescription; loadingDetail = false
        }
    }

    private func open(_ url: URL) {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path), NSWorkspace.shared.open(url) else {
            actionError = "보관 파일의 위치와 접근 권한을 확인해 주세요.\n\(url.path)"; return
        }
    }

    private func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, min(seconds, Double(Int.max / 2))) : 0
        let total = Int(value)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Live recording and generation state only invalidate this small action area.
private struct HistoryReprocessingControl: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var meeting: MeetingWorkspace
    @ObservedObject private var assistant: MeetingAssistant
    let snapshot: MeetingHistorySnapshot
    let dismiss: () -> Void
    let onError: (String) -> Void

    init(model: AppModel, snapshot: MeetingHistorySnapshot, dismiss: @escaping () -> Void, onError: @escaping (String) -> Void) {
        self.model = model
        self.meeting = model.meeting
        self.assistant = model.assistant
        self.snapshot = snapshot
        self.dismiss = dismiss
        self.onError = onError
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            Button("재가공본 만들기") {
                if model.openHistoryForReprocessing(snapshot) { dismiss() }
                else { onError(model.errorMessage ?? "현재 작업의 저장을 마친 뒤 재가공본 만들기를 다시 시도해 주세요.") }
            }.buttonStyle(.borderedProminent)
                .disabled(!model.canOpenHistoryForReprocessing || snapshot.segments.isEmpty)
            if !model.canOpenHistoryForReprocessing {
                Text("현재 작업을 마친 뒤 재가공본을 만들 수 있습니다.")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.rose)
            } else if snapshot.segments.isEmpty {
                Text("회의록 열람용 기록입니다. 전사 구간이 있는 회의에서 재가공본을 만들 수 있습니다.")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
            }
        }.frame(maxWidth: 240, alignment: .trailing)
    }
}
