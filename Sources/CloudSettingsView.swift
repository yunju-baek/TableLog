import SwiftUI

struct CloudSettingsView: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void
    @State private var provider: RecognitionProvider
    @State private var apiKey = ""
    @State private var saveError: String?
    @FocusState private var keyFocused: Bool

    private let ink = AppTheme.ink
    private let accent = AppTheme.violet

    init(model: AppModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        _provider = State(initialValue: model.recognitionProvider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Label("인식 엔진", systemImage: "waveform.badge.mic")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ink)
                Text("음성 인식 방식을 선택하세요. 화자와 이름은 Mac에서 관리합니다.")
                    .font(.system(size: 12))
                    .lineSpacing(4)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("인식 엔진", selection: $provider) {
                ForEach(RecognitionProvider.allCases, id: \.rawValue) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.canChangeRecognitionProvider)
            .accessibilityLabel("사용할 인식 엔진")

            if provider == .gemini {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Google에서 음성을 전사합니다", systemImage: "cloud")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ink)
                    Text("약 45초 문맥을 모아 Google로 보내고, 30~60초 범위에서 쉼 구간을 우선해 나눕니다. 로컬 초안은 바로 표시하며, Gemini 결과는 구간 수집과 응답 후에 반영됩니다. 종료하면 남은 음성도 전송합니다.")
                    Text("무료 사용 한도에 도달하면 로컬 초안을 유지합니다.")
                }
                .font(.system(size: 11))
                .lineSpacing(4)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Gemini API 키")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ink)
                        Spacer()
                        if model.hasGeminiKey {
                            Label("등록됨", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(accent)
                        }
                    }
                    SecureField(model.hasGeminiKey ? "새 키를 입력하면 교체됩니다" : "AI Studio의 API 키 붙여넣기", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .focused($keyFocused)
                        .disabled(!model.canChangeRecognitionProvider)
                        .accessibilityLabel("Gemini API 키 입력")
                        .onSubmit(apply)
                    Text(model.hasGeminiKey ? "입력란을 비워 두면 저장한 키를 사용합니다. 키는 이 Mac의 키체인에 보관합니다." : "키는 이 Mac의 키체인에 보관합니다.")
                        .font(.system(size: 10))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .top) {
                        Link("AI Studio에서 키·요금제 확인", destination: URL(string: "https://aistudio.google.com/api-keys")!)
                            .font(.system(size: 11))
                        Spacer(minLength: 8)
                        if model.hasGeminiKey {
                            Button("저장한 키 삭제") {
                                model.removeGeminiKey()
                                apiKey = ""
                                provider = model.recognitionProvider
                                saveError = model.hasGeminiKey ? model.errorMessage : nil
                            }
                            .font(.system(size: 11))
                            .disabled(!model.canChangeRecognitionProvider)
                        }
                    }
                    Text("계정의 무료 사용 한도와 데이터 처리 조건을 확인하세요.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Label("이 Mac에서 음성을 전사합니다", systemImage: "desktopcomputer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ink)
                    Text("NVIDIA Nemotron으로 한국어를 인식하고, 문맥 교정 설정에 따라 최근 발언과 용어를 참고합니다.")
                        .font(.system(size: 11))
                        .lineSpacing(4)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let saveError {
                Text(saveError)
                    .font(.system(size: 11))
                    .lineSpacing(3)
                    .foregroundStyle(Color(red: 0.65, green: 0.32, blue: 0.16))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Text(model.canChangeRecognitionProvider ? "다음 녹음·파일 전사부터 적용됩니다." : "녹음을 마친 뒤 설정을 변경할 수 있어요.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("취소", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("적용", action: apply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canChangeRecognitionProvider || (provider == .gemini && !model.hasGeminiKey && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(22)
        .frame(width: 448)
        .background(AppTheme.paper)
        .tint(accent)
        .environment(\.colorScheme, .light)
        .onChange(of: provider) { _, value in
            saveError = nil
            if value == .gemini && !model.hasGeminiKey { keyFocused = true }
        }
    }

    private func apply() {
        guard model.canChangeRecognitionProvider else { return }
        if model.updateCloudSettings(provider: provider, apiKey: apiKey) {
            apiKey = ""
            dismiss()
        } else {
            saveError = model.errorMessage ?? "API 키와 설정을 확인해 주세요."
        }
    }
}
