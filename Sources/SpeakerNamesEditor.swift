import SwiftUI

@MainActor final class SpeakerNameEditingSession: ObservableObject, Identifiable {
    let id = UUID()
    let meetingID: UUID
    let preferredSpeaker: Int?
    @Published var values: [Int: String]
    var initialValues: [Int: String]

    init(model: AppModel, preferredSpeaker: Int?) {
        meetingID = model.editingSessionID
        self.preferredSpeaker = preferredSpeaker
        let initial = Dictionary(uniqueKeysWithValues: model.speakerIDs.map {
            ($0, model.enteredSpeakerName(for: $0))
        })
        values = initial
        initialValues = initial
    }
}

struct SpeakerNamesEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var edit: SpeakerNameEditingSession
    let dismiss: () -> Void
    @FocusState private var focusedSpeaker: Int?
    @State private var contactSpeaker: Int?
    @State private var showContact = false

    init(model: AppModel, edit: SpeakerNameEditingSession, dismiss: @escaping () -> Void) {
        self.model = model
        self.edit = edit
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Label("화자 이름", systemImage: "person.2.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                Text("추정된 이름은 ‘이름 확정’으로 바로 반영돼요. 직접 입력한 이름은 ‘적용’을 눌러 주세요.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 11) {
                        ForEach(model.speakerIDs, id: \.self) { speaker in
                            let presentation = model.voiceNamePresentation(for: speaker)
                            VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 11) {
                                Text("화자 \(speaker)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AppTheme.violet)
                                    .frame(width: 54, alignment: .leading)
                                TextField("이름 입력", text: Binding(
                                    get: { edit.values[speaker] ?? model.enteredSpeakerName(for: speaker) },
                                    set: { edit.values[speaker] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.large)
                                .focused($focusedSpeaker, equals: speaker)
                                .onSubmit(applyNames)
                                .accessibilityLabel("화자 \(speaker) 이름")
                                Button("연락처") { contactSpeaker = speaker; showContact = true }
                                Button {
                                    edit.values[speaker] = ""
                                    focusedSpeaker = speaker
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 11, weight: .medium))
                                        .frame(width: 23, height: 26)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("화자 \(speaker) 기본 이름으로 복원")
                                .accessibilityLabel("화자 \(speaker) 기본 이름으로 복원")
                            }
                            if presentation.kind == .suggested || presentation.kind == .automatic {
                                HStack(spacing: 8) {
                                    Text(presentation.name + (presentation.kind == .automatic ? " · 자동 연결" : " · 추정"))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(AppTheme.violet).lineLimit(1)
                                    Spacer(minLength: 4)
                                    VoiceNameConfirmButton(speaker: speaker, name: presentation.name,
                                        continuousLearningEnabled: model.voice.vault.continuousLearningEnabled) {
                                            confirmSuggestion(speaker, name: presentation.name)
                                        }
                                }.padding(.leading, 65)
                            }
                            }
                            .id(speaker)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: .infinity)
                .onAppear {
                    let target = edit.preferredSpeaker ?? model.speakerIDs.first
                    if let target { proxy.scrollTo(target, anchor: .center) }
                    DispatchQueue.main.async { focusedSpeaker = target }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("빈 이름을 적용하면 ‘화자 N’으로 표시돼요.")
                Text("이름은 64자까지 저장돼요.")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Divider()
            HStack {
                Text("녹음 중에도 수정할 수 있어요.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("닫기", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("적용", action: applyNames)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.speakerIDs.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480, height: 560)
        .background(AppTheme.paper)
        .tint(AppTheme.violet)
        .environment(\.colorScheme, .light)
        .sheet(isPresented: $showContact) {
            MeetingContactsPicker(onSelect: { person in
                if let speaker = contactSpeaker { model.bindMeetingContact(person, speaker: speaker); edit.values[speaker] = person.name }
            }, onClose: { showContact = false })
        }
        .onChange(of: model.speakerIDs) { _, speakers in
            if speakers.isEmpty {
                edit.values = [:]
                edit.initialValues = [:]
                dismiss()
                return
            }
            // New detections join the editor while each existing text field keeps
            // its local draft and focus throughout streaming transcript revisions.
            for speaker in speakers where edit.values[speaker] == nil {
                let initial = model.enteredSpeakerName(for: speaker)
                edit.initialValues[speaker] = initial
                edit.values[speaker] = initial
            }
        }
    }

    private func confirmSuggestion(_ speaker: Int, name: String) {
        guard model.editingSessionID == edit.meetingID,
              model.confirmVoiceName(speaker, expectedName: name) else { return }
        // This action is immediate; a later Apply keeps the confirmation and other rows' edit.values.
        let confirmed = model.enteredSpeakerName(for: speaker)
        edit.values[speaker] = confirmed
        edit.initialValues[speaker] = confirmed
    }

    private func applyNames() {
        guard model.editingSessionID == edit.meetingID, !model.speakerIDs.isEmpty else { dismiss(); return }
        for speaker in model.speakerIDs {
            guard let draft = edit.values[speaker], let initial = edit.initialValues[speaker], draft != initial else { continue }
            model.confirmEnteredSpeakerName(draft, for: speaker)
        }
        dismiss()
    }
}
