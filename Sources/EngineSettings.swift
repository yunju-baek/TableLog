import SwiftUI
import AppKit

struct EngineSettingsView: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void
    @State private var settings: EngineTuningSettings
    init(model: AppModel, dismiss: @escaping () -> Void) {
        self.model = model; self.dismiss = dismiss
        _settings = State(initialValue: model.engineSettings)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("NVIDIA 음성·화자 설정").font(.title3.bold())
            Text("NeMo-Speech.cpp 0.2.0 · 발언 경계의 문맥 유지 · Metal")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Text("음성 인식 · Nemotron 3.5 ASR 0.6B").font(.headline)
                Picker("인식 문맥", selection: $settings.rightContext) {
                    Text("빠른 반영 · 짧은 문맥").tag(3)
                    Text("문맥 우선 · 긴 문맥").tag(13)
                }.pickerStyle(.segmented)
                Text("긴 문맥은 뒤에 이어지는 음성을 더 기다려 인식합니다. 실제 정확도는 녹음 조건과 발언에 따라 달라집니다.").font(.caption).foregroundStyle(.secondary)
                Toggle("자동 구두점", isOn: $settings.automaticPunctuation)
                HStack {
                    Text("등록 용어 강조")
                    Slider(value: $settings.vocabularyBoost, in: 0.1...3.0, step: 0.1)
                    Text(String(format: "%.1f", settings.vocabularyBoost)).monospacedDigit().frame(width: 30)
                }
                Text("기본 1.0. 이름·전문용어는 문맥 교정 설정에 입력합니다. 강조가 높으면 등록 용어를 더 선호하므로 비교 기록으로 결과를 확인하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("화자 분리 · Nemotron 3 Diarization").font(.headline)
                Picker("화자 판정", selection: $settings.diarProfile) {
                    Text("빠른 반영").tag(0)
                    Text("긴 기억 범위").tag(1)
                }.pickerStyle(.segmented)
                Text(settings.diarProfile == 0
                     ? "NVIDIA v3-streaming 프리셋 · 처리 구간 1.04초 · 최근 기억 6.4초 · 화자 캐시 21.12초"
                     : "기존 앱 설정 · 처리 구간 1.12초 · 최근 기억 21.12초 · 화자 캐시 21.12초")
                    .font(.caption).foregroundStyle(.secondary)
                Text("엔진은 최대 8개 화자 채널을 사용합니다. 겹친 발언의 단어에는 대표 화자를 붙이며, 녹음 중 판정이 갱신됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text("모델은 TableLog/Models에서 별도로 불러옵니다.").font(.caption)
                    Text("앱 업데이트 시 기존 모델을 재사용합니다.").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("모델 폴더 열기") {
                    do {
                        try FileManager.default.createDirectory(at:TableLogModels.directory,withIntermediateDirectories:true)
                        NSWorkspace.shared.open(TableLogModels.directory)
                    } catch { model.errorMessage=error.localizedDescription }
                }
            }
            HStack {
                Button("기본값") { settings = EngineTuningSettings() }
                Spacer()
                Button("취소", action: dismiss).keyboardShortcut(.cancelAction)
                Button("적용") { model.updateEngineSettings(settings); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart || !settings.valid)
            }
            Text(model.canStart ? "다음 녹음·파일 전사부터 적용됩니다. 한국어 ko-KR · Metal · Q8 모델을 사용합니다." : "녹음과 처리를 마친 뒤 설정을 적용할 수 있습니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(22).frame(width: 520).environment(\.colorScheme, .light)
    }
}
