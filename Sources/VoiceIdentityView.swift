import SwiftUI

struct VoiceIdentityView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: VoiceIdentity
    var initialSpeaker: Int? = nil
    let dismiss: () -> Void
    @State private var name=""
    @State private var selected:UUID?
    @State private var confirmed=false
    @State private var fileStart="0"
    @State private var fileDuration="30"
    @State private var learningSpeaker: Int?
    @State private var rebuild=false
    private var meetingFinished: Bool { model.savedAudioURL != nil }
    private var meetingSpeakers: [Int] {
        Set(voice.trainingCandidates.map(\.speaker)).sorted()
    }
    private func selectSpeaker(_ speaker: Int) {
        learningSpeaker=speaker;confirmed=false;rebuild=false
        let entered=model.enteredSpeakerName(for:speaker)
        let profile=voice.vault.profiles.first(where: { $0.name==entered })
            ?? voice.vault.profiles.first(where: { $0.id==voice.suggestions[speaker]?.profileID })
        selected=profile?.id;name=profile?.name ?? entered
        voice.prepareMeeting(speaker:speaker,savedAudio:model.savedAudioURL)
    }
    private var meetingSelection: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(meetingFinished ? "1. 회의 발언으로 학습 데이터 추가" : "1. 학습할 화자와 발언 선택").font(.headline)
            Text(meetingFinished ? "저장된 M4A에서 화자별 발언을 모읍니다. 각 화자의 이름을 확인하면 기존 학습 데이터에 추가하고 개인별 분류기를 갱신합니다." : "화자가 명확한 발언을 골라 이름을 확인하세요. 확인한 음성은 기존 데이터와 함께 개인별 목소리 분류기 학습에 사용합니다.")
                .font(.caption).foregroundStyle(.secondary)
            if meetingSpeakers.isEmpty {
                Text(model.isReprocessing ? "저장된 발언 중 화자가 구분된 3초 이상의 구간을 확인해 주세요." : "회의를 시작하면 3초 이상 이어진 발언이 여기에 표시됩니다.").font(.callout).foregroundStyle(.secondary)
            }
            if model.isReprocessing {
                Text("저장된 발언의 시작·종료 시각으로 원음 구간을 준비합니다. 선택 음성을 듣고 화자를 확인한 뒤 학습하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(meetingSpeakers,id:\.self) { speaker in
                let clips=voice.availableCandidates(speaker:speaker,savedAudio:model.savedAudioURL)
                HStack {
                    Image(systemName:learningSpeaker==speaker ? "checkmark.circle.fill" : "person.wave.2")
                    Text(model.speakerName(for:speaker))
                    Spacer()
                    Text("\(clips.count)개 후보").font(.caption).foregroundStyle(.secondary)
                    Button("학습할 발언 선택") { selectSpeaker(speaker) }
                        .disabled(clips.isEmpty || voice.busy || voice.recording)
                }
            }
            if let learningSpeaker {
                DisclosureGroup("발언을 직접 골라 학습") {
                    ForEach(voice.availableCandidates(speaker:learningSpeaker,savedAudio:model.savedAudioURL)) { candidate in
                        HStack {
                            VStack(alignment:.leading) {
                                Text("\(AppModel.time(candidate.start))–\(AppModel.time(candidate.end))").font(.caption.bold())
                                Text(candidate.text).font(.caption).lineLimit(2)
                            }
                            Spacer()
                            Button("이 발언 선택") { confirmed=false;voice.prepare(candidate,savedAudio:model.savedAudioURL) }
                                .disabled(voice.busy || voice.recording)
                        }.padding(.vertical,4)
                    }
                }
            }
        }
    }
    private var additionalMethods: some View {
        DisclosureGroup("추가 방법 · 별도 녹음·음성 파일") {
            VStack(alignment:.leading,spacing:10) {
                HStack {
                    Button(voice.recording ? "등록 녹음 종료" : "마이크로 30초 등록") {
                        confirmed=false
                        if voice.recording { voice.stopRecording() } else { voice.startRecording(device:model.selectedDeviceID) }
                    }.disabled(!voice.recording && (!model.canStart || voice.busy))
                    if voice.recording { Text(String(format:"%.1f초",voice.recordingSeconds)).monospacedDigit() }
                }
                HStack {
                    Text("파일 시작(초)");TextField("0",text:$fileStart).frame(width:55)
                    Text("길이(초)");TextField("30",text:$fileDuration).frame(width:55)
                    Button("M4A·음성 파일 선택") { confirmed=false;voice.pickAudio(start:Double(fileStart) ?? -1,duration:Double(fileDuration) ?? -1) }.disabled(voice.busy || voice.recording)
                }.textFieldStyle(.roundedBorder)
            }.padding(.top,8)
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text("목소리 누적 학습 · 이름 연결").font(.title2.bold())
                    Text("이름을 확인한 음성이 쌓일 때마다 개인별 목소리 분류기를 학습합니다.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer();Button("닫기") { voice.stopRecording();dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    mappingSettings
                    learningSettings
                    currentNames
                    Divider()
                    meetingSelection
                    Text("2. 이름 확인").font(.headline)
                    Picker("프로필",selection:$selected) {
                        Text("새 목소리 등록").tag(UUID?.none)
                        ForEach(voice.vault.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(voice.busy)
                    TextField("이름",text:$name).textFieldStyle(.roundedBorder).disabled(selected != nil || voice.busy)
                    if selected != nil {
                        Toggle("선택한 발언으로 학습 데이터 다시 구성",isOn:$rebuild).disabled(voice.busy || voice.learningBusy)
                        Text(rebuild ? "기존 구간은 제외 목록에 보관하고 선택한 발언으로 분류기를 다시 학습합니다. 학습 기록에서 되돌릴 수 있습니다." : "이전 회의의 학습 데이터를 유지하며 확인한 발언을 추가합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if voice.pendingSeconds > 0 {
                        HStack {
                            Text(String(format:"준비된 음성 %.1f초 · %d개 구간",voice.pendingSeconds,max(1,voice.pendingClipCount)))
                            Button("선택 음성 듣기",action:voice.playPending)
                            Button("선택 해제") { voice.clearPending();confirmed=false }.disabled(voice.busy)
                        }
                        Toggle("선택한 발언의 화자와 이름을 확인했습니다",isOn:$confirmed).disabled(voice.busy)
                        Button(selected == nil ? "확인한 이름으로 학습 시작" : (rebuild ? "선택한 데이터로 다시 학습" : "기존 데이터에 추가 학습")) { voice.enroll(name:name,existing:selected,rebuild:rebuild);confirmed=false }
                            .buttonStyle(.borderedProminent).disabled(!confirmed || name.trimmingCharacters(in:.whitespaces).isEmpty || voice.busy || voice.learningBusy)
                    }
                    additionalMethods
                    Text(voice.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if voice.busy { ProgressView("목소리 특징 처리 중") }
                    Divider()
                    Text("개인별 목소리 분류기 · \(voice.vault.profiles.count)명").font(.headline)
                    ForEach(voice.vault.profiles) { profile in
                        profileLearning(profile)
                    }
                    if !voice.vault.archived.isEmpty {
                        DisclosureGroup("보관함 · 복원 가능") {
                            ForEach(voice.vault.archived) { profile in HStack { Text(profile.name);Spacer();Button("복원") { voice.restore(profile.id) }.disabled(voice.busy) } }
                        }
                    }
                    DisclosureGroup("이름 인식·확인 기록 · \(voice.events.count)건") {
                        ForEach(voice.events.reversed()) { event in
                            Text("화자 \(event.speaker) · \(AppModel.time(event.start))–\(AppModel.time(event.end)) · \(event.name ?? "미등록·판정 보류") · \(event.action)")
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                    Text("확인한 음성(M4A), 목소리 특징, 학습한 분류기와 변경 이력은 이 Mac에 저장됩니다. 회의가 바뀌어도 학습 데이터를 이어서 사용합니다. 잡음·겹친 발언·다른 마이크가 포함된 구간은 듣기로 확인한 뒤 학습에서 제외할 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.trailing,8)
            }
        }.padding(22).frame(width:660,height:690)
        .foregroundStyle(AppTheme.ink)
        .background(AppTheme.paper)
        .tint(AppTheme.violet)
        .buttonStyle(.bordered)
        .environment(\.colorScheme,.light)
        .onChange(of:selected) { _,id in
            name=voice.vault.profiles.first(where:{$0.id==id})?.name ?? learningSpeaker.map { model.enteredSpeakerName(for:$0) } ?? ""
            confirmed=false;rebuild=false
        }
        .onChange(of:voice.pendingRevision) { _,_ in confirmed=false }
        .onChange(of:name) { _,_ in confirmed=false }
        .onChange(of:rebuild) { _,_ in confirmed=false }
        .onAppear {
            if let initialSpeaker { selectSpeaker(initialSpeaker) }
        }
        .onDisappear { voice.stopRecording() }
    }

    private var mappingSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            if voice.vault.profiles.isEmpty {
                VStack(alignment:.leading,spacing:8) {
                    Label("비교에 사용할 목소리 등록이 필요합니다",systemImage:"person.crop.circle.badge.exclamationmark").font(.headline)
                    Text(voice.vault.archived.isEmpty ? "아래에서 음성과 이름을 확인해 새 목소리를 등록하세요." : "기존 목소리 \(voice.vault.archived.count)명이 보관함에 있습니다. 사용할 목소리를 복원하면 다음 발언부터 이름을 비교합니다.")
                        .font(.callout)
                    ForEach(voice.vault.archived) { profile in
                        Button("\(profile.name) · 목소리 복원") { voice.restore(profile.id) }.disabled(voice.busy || voice.learningBusy)
                    }
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                    .background(AppTheme.lavender,in:RoundedRectangle(cornerRadius:10))
            }
            HStack {
                Label("학습된 목소리 \(voice.vault.profiles.count)명", systemImage: "person.wave.2.fill")
                    .font(.headline)
                Spacer()
                Button("지금 다시 비교", action: model.recheckVoiceNames)
                    .disabled(voice.mappingMode == .off || voice.vault.profiles.isEmpty || model.speakerIDs.isEmpty || voice.busy || voice.recording)
                    .help("현재 발언을 등록 목소리와 다시 비교합니다. 직접 확인한 이름은 유지됩니다.")
            }
            Picker("이름 연결 방식", selection: Binding(
                get: { voice.mappingMode },
                set: { voice.configure(mode: $0, threshold: voice.vault.threshold) }
            )) {
                ForEach([VoiceMappingMode.automatic, .suggest, .off], id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            Text(mappingExplanation)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("이름 제안 기준")
                Slider(value: Binding(
                    get: { voice.vault.threshold },
                    set: { voice.configure(mode: voice.mappingMode, threshold: $0) }
                ), in: 0.45...0.90, step: 0.05)
                Text(String(format: "%.2f", voice.vault.threshold)).monospacedDigit()
            }.disabled(voice.mappingMode == .off)
            Text("기본 0.65. 값을 높이면 이름 제안 기준이 엄격해집니다. 자동 연결은 여러 발언과 학습 음성의 일치를 함께 확인합니다. 유사도는 목소리 특징의 점수입니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var learningSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("개인별 목소리 분류기 누적 학습", systemImage: "waveform.badge.plus")
                    .font(.headline).foregroundStyle(AppTheme.violet)
                Toggle("이름을 확인한 화자의 새 발언으로 계속 학습", isOn: Binding(
                    get: { voice.vault.continuousLearningEnabled },
                    set: { voice.configureLearning(enabled: $0) }
                ))
                Text(voice.vault.continuousLearningEnabled
                     ? "등록된 목소리의 이름을 직접 입력해 확인하거나 ‘이름 확정’을 누르면, 해당 화자의 확인된 발언과 이어지는 새 발언이 학습 데이터에 쌓입니다. 새 목소리는 아래에서 등록하세요. 자동 연결·이름 후보는 사용자의 이름 확인을 기다립니다."
                     : "새 발언의 자동 학습을 쉬고 현재 분류기를 유지합니다. 아래에서 발언을 직접 골라 추가 학습할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if voice.learningBusy { ProgressView("추가 음성으로 개인별 분류기 학습 중").controlSize(.small) }
                if !voice.learningStatus.isEmpty {
                    Text(voice.learningStatus).font(.caption).foregroundStyle(AppTheme.violet).textSelection(.enabled)
                }
                Text("NVIDIA TitaNet은 고정된 음성 특징 추출기로 사용합니다. 추가 데이터로 이 Mac의 개인별 분류기와 판정 기준을 학습하며, 별도 녹음 구간의 검증 결과를 아래에 기록합니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
        }
    }

    private func profileLearning(_ profile: VoiceProfile) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("음성 보관 \(profile.samples.count + profile.removedSamples.count)개 구간 · 학습 변경 \(profile.learningHistory.count)회")
                    .font(.caption).foregroundStyle(.secondary)
                if let learned = profile.learnedModel {
                    learnedModelStatus(learned)
                } else {
                    Text("분류기 학습 대기 · 이름을 확인한 발언으로 학습을 시작하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("현재 데이터로 학습") { voice.retrainProfile(profileID: profile.id) }
                        .disabled(profile.samples.isEmpty || voice.busy || voice.learningBusy)
                    Button("추가 학습 대상 선택") { selected=profile.id;name=profile.name }
                    Spacer()
                    Button("프로필 보관함으로 이동") { voice.archive(profile.id);if selected==profile.id { selected=nil;name="" } }
                        .disabled(voice.busy || voice.learningBusy)
                }
                if voice.canRollbackLearning(profileID: profile.id) {
                    Button("마지막 학습 되돌리기") { voice.rollbackLastLearning(profileID: profile.id) }
                        .disabled(voice.busy || voice.learningBusy)
                        .help("직전 학습의 데이터 구성과 분류기로 돌아갑니다. 추가 음성은 제외 목록에 보관합니다.")
                }
                if !profile.learningHistory.isEmpty {
                    DisclosureGroup("학습 변화 기록 · \(profile.learningHistory.count)회") {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(profile.learningHistory.reversed()) { batch in
                                learningBatch(batch)
                            }
                        }.padding(.vertical, 6)
                    }
                }
                DisclosureGroup("현재 학습 음성 · \(profile.samples.count)개 구간") {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(profile.samples.reversed()) { sample in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sample.created, format: .dateTime.year().month().day().hour().minute()).font(.caption)
                                    Text(String(format: "%.1f초", sample.seconds)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("듣기") { voice.play(sample) }
                                Button("학습에서 제외") { voice.removeSample(profile: profile.id, sample: sample.id) }
                                    .disabled(voice.busy || voice.learningBusy)
                                    .help("이 음성을 제외하고 개인별 분류기를 다시 계산합니다.")
                            }.padding(.vertical, 3)
                        }
                    }
                }
                if profile.beforeRebuild != nil && profile.learningHistory.isEmpty {
                    Button("이전 버전의 재학습 되돌리기") { voice.undoRebuild(profile.id) }
                        .disabled(voice.busy || voice.learningBusy)
                }
                if !profile.removedSamples.isEmpty {
                    Button("제외한 \(profile.removedSamples.count)개 구간 복원") { voice.restoreSamples(profile.id) }
                        .disabled(voice.busy || voice.learningBusy)
                }
            }.padding(.vertical, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.callout.bold())
                Text("학습 \(profile.samples.count)개 구간 · \(Int(profile.samples.map(\.seconds).reduce(0,+)))초 · 판정 모델 \(profile.learnedModel.map { "v\($0.parameterRevision)" } ?? "학습 대기")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func learnedModelStatus(_ learned: VoiceLearnedModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(learningStateTitle(learned.state)).font(.caption.bold()).foregroundStyle(AppTheme.violet)
            Text("학습 \(learned.revision)회차 · 판정 모델 v\(learned.parameterRevision)")
                .font(.caption).foregroundStyle(.secondary)
            Text("학습 \(learned.sampleCount)개 구간 · 중복 반영 조정 후 \(learned.effectiveSampleCount)개 · 음성 출처 \(learned.sourceCount)개")
                .font(.caption).foregroundStyle(.secondary)
            Text(learned.trainedAt, format: .dateTime.year().month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
            if !learned.validation.note.isEmpty {
                Text(learned.validation.note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if learned.validation.heldOutPositiveCount > 0 || learned.validation.heldOutNegativeCount > 0 {
                Text("별도 녹음 검증 · 본인 \(learned.validation.heldOutPositiveCount)개 / 다른 사람 \(learned.validation.heldOutNegativeCount)개 구간 · \(learned.validation.sourceFoldCount)개 출처 묶음")
                    .font(.caption).foregroundStyle(.secondary)
                if let recall = learned.validation.positiveRecall {
                    Text("본인 음성 수용률 \(percent(recall))\(baselineText(learned.validation.baselinePositiveRecall))")
                        .font(.caption).monospacedDigit()
                }
                if let falseAccept = learned.validation.falseAcceptRate {
                    Text("다른 사람 음성 오수용률 \(percent(falseAccept))\(baselineText(learned.validation.baselineFalseAcceptRate))")
                        .font(.caption).monospacedDigit()
                }
                Text("표시된 비율은 저장한 검증 구간의 결과입니다. 실제 회의의 마이크·잡음·발화 조건에 따라 이름 판정 결과가 달라집니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.violet.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func learningBatch(_ batch: VoiceLearningBatch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("학습 \(batch.revision)회차 · \(learningAction(batch.action))").font(.caption.bold())
                Spacer()
                Text(batch.created, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
            }
            Text("학습 데이터 \(batch.priorActiveIDs.count) → \(batch.resultingSampleCount)개 · 추가 \(batch.addedSampleIDs.count)개 구간")
                .font(.caption).foregroundStyle(.secondary)
            if let rolledBackAt = batch.rolledBackAt {
                Text("되돌림 · \(rolledBackAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(AppTheme.violet)
            }
        }.padding(8).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
    }

    private func learningStateTitle(_ state: VoiceLearningState) -> String {
        switch state {
        case .validationPending: return "분류기 학습됨 · 별도 녹음 검증 대기"
        case .validated: return "분류기 학습됨 · 별도 녹음 검증 통과"
        case .retainedPrevious: return "추가 데이터 보관 · 이전 분류기 유지"
        }
    }

    private func learningAction(_ action: String) -> String {
        switch action {
        case "confirmed_enrollment": return "이름 확인 후 추가 학습"
        case "confirmed_followup": return "확인한 화자의 새 발언 학습"
        case "rebuild": return "선택한 발언으로 다시 학습"
        case "excluded": return "음성 제외 후 다시 학습"
        case "restored": return "제외 음성 복원 후 학습"
        case "retrained": return "현재 데이터로 다시 학습"
        case "evidence_revised": return "참고 음성 변경으로 재검토"
        case "quarantined": return "학습 후보 보관 · 검토 대기"
        default: return "학습 데이터 갱신"
        }
    }

    private func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
    private func baselineText(_ value: Double?) -> String { value.map { " · 갱신 전 \(percent($0))" } ?? "" }

    private var mappingExplanation: String {
        switch voice.mappingMode {
        case .automatic:
            return "등록 목소리가 충분히 일치하면 이름을 자동으로 연결합니다. 발언 카드에서 ‘이름 확정’을 누르면 사람이 확인한 이름으로 유지됩니다."
        case .suggest:
            return "등록 목소리와 닮은 이름을 발언 카드에 제안합니다. ‘이름 확정’을 누르면 현재 대화에 연결됩니다."
        case .off:
            return "목소리 비교를 쉬고 화자 번호와 직접 확인한 이름을 표시합니다. 등록 목소리는 다음 사용을 위해 보관됩니다."
        }
    }

    @ViewBuilder private var currentNames: some View {
        if !model.speakerIDs.isEmpty {
            GroupBox("현재 대화의 화자 연결") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.speakerIDs, id: \.self) { speaker in
                        let presentation = model.voiceNamePresentation(for: speaker)
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("화자 \(speaker)").font(.caption.bold()).foregroundStyle(AppTheme.violet)
                                if presentation.kind == .manual {
                                    Text(presentation.name).font(.callout.bold())
                                    Text("직접 확인한 이름").font(.caption).foregroundStyle(.secondary)
                                } else if presentation.kind == .none {
                                    Text(pendingNameStatus(speaker)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            if presentation.kind == .automatic || presentation.kind == .suggested {
                                VoiceNameStatusView(presentation: presentation,
                                                    confirm: { model.confirmVoiceName(speaker) },
                                                    dismiss: { model.dismissVoiceSuggestion(speaker) },
                                                    undo: { model.undoAutomaticVoiceName(speaker) },
                                                    continuousLearningEnabled: voice.vault.continuousLearningEnabled)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
    }

    private func pendingNameStatus(_ speaker: Int) -> String {
        if voice.mappingMode == .off { return "이름 연결 기능 꺼짐" }
        if voice.vault.profiles.isEmpty { return "목소리를 등록하면 이름을 비교합니다" }
        if voice.rejectedSpeakers.contains(speaker) { return "이번 회의에서는 직접 이름을 확인합니다" }
        if voice.matchingSpeakers.contains(speaker) { return "등록 목소리와 비교 중" }
        return "이름을 비교할 발언을 기다리는 중"
    }
}

/// A compact shared presentation keeps the evidence and actions identical in
/// transcript cards and the voice library sheet.
struct VoiceNameStatusView: View {
    let presentation: VoiceNamePresentation
    var confirm: (() -> Void)? = nil
    var dismiss: (() -> Void)? = nil
    var undo: (() -> Void)? = nil
    var continuousLearningEnabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(presentation.kind == .automatic ? "목소리 자동 연결 · \(presentation.name)" : "목소리 이름 후보 · \(presentation.name)",
                      systemImage: presentation.kind == .automatic ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.questionmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.violet)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if presentation.kind == .suggested {
                    if let confirm { Button("이름 확정", action: confirm).help(confirmationHelp) }
                    if let dismiss { Button("후보 제외", action: dismiss).help("이번 회의에서 이 화자의 목소리 후보 제안을 닫습니다") }
                } else if presentation.kind == .automatic {
                    if let confirm { Button("이름 확정", action: confirm).help(confirmationHelp) }
                    if let undo { Button("연결 해제", action: undo).help("자동 연결을 해제하고 현재 화자를 직접 확인합니다") }
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .medium))
            if !presentation.detail.isEmpty {
                Text(presentation.detail).font(.system(size: 10)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if continuousLearningEnabled && (presentation.kind == .automatic || presentation.kind == .suggested) {
                Text("이름을 확정하면 이 화자의 새 발언으로 계속 학습합니다.")
                    .font(.system(size: 10)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(AppTheme.violet.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }

    private var confirmationHelp: String {
        continuousLearningEnabled
            ? "이름을 확인하고 이 화자의 확인된 음성과 새 발언으로 개인별 분류기를 학습합니다."
            : "현재 이름을 직접 확인한 화자 이름으로 유지합니다."
    }
}

struct VoiceMappingSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: VoiceIdentity
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Label("목소리 학습 · 이름 연결", systemImage: "person.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                Text("학습된 목소리 \(voice.vault.profiles.count)명 · \(voice.mappingMode.title)")
                    .font(.system(size: 10)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(voice.learningBusy ? "새 발언으로 분류기 학습 중" : (voice.vault.continuousLearningEnabled ? "이름 확인 후 발언 누적 학습 켜짐" : "직접 선택한 발언으로 학습"))
                    .font(.system(size: 10)).foregroundStyle(AppTheme.violet)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.speakerIDs.isEmpty, voice.mappingMode != .off {
                    let automaticCount = model.speakerIDs.filter { model.voiceNamePresentation(for: $0).kind == .automatic }.count
                    let suggestedCount = model.speakerIDs.filter { model.voiceNamePresentation(for: $0).kind == .suggested }.count
                    if automaticCount > 0 || suggestedCount > 0 {
                        Text("현재 대화 · 자동 연결 \(automaticCount)명 · 후보 \(suggestedCount)명")
                            .font(.system(size: 10)).foregroundStyle(AppTheme.violet)
                    } else if !voice.matchingSpeakers.isEmpty {
                        Text("등록 목소리와 비교 중").font(.system(size: 10)).foregroundStyle(AppTheme.violet)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("회의를 이어가는 목소리 누적 학습 · 이름 연결 · 학습 변화와 되돌리기")
    }
}
