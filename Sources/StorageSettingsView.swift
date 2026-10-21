import SwiftUI
import AppKit

struct StorageSettingsView: View {
    var dismiss: (() -> Void)? = nil
    @State private var currentRoot = StorageLocations.currentRoot
    @State private var pendingRoot = StorageLocations.pendingRoot
    @State private var storageStatus = StorageLocations.status
    @State private var startupError = StorageLocations.startupError
    @State private var errorMessage = ""
    @State private var showingError = false

    private static let changeNotification = Notification.Name("TableLog.storageLocationChanged")

    private var categories: [(title: String, detail: String, icon: String, url: URL)] {
        [
            ("회의자료", "추가한 자료와 회의 맥락", "doc.on.doc", StorageLocations.materials),
            ("M4A 녹음", "회의에서 녹음한 음성", "waveform", StorageLocations.recordings),
            ("전사 JSON", "화자·시간·발언 기록", "text.bubble", StorageLocations.transcripts),
            ("회의록", "회의록과 정리한 결과", "doc.text", StorageLocations.minutes),
            ("도우미 기록", "회의 요약과 제안", "sparkles", StorageLocations.assistant),
            ("목소리 학습", "등록한 목소리와 학습 모델", "person.wave.2", StorageLocations.voiceProfiles),
            ("디버그", "전사 비교와 진단 기록", "ladybug", StorageLocations.diagnostics)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(AppTheme.violet)
                    .frame(width: 50, height: 50)
                    .background(AppTheme.lavender, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text("저장 위치 설정").font(.system(size: 22, weight: .bold))
                    Text("회의자료와 음성, 학습 기록을 한 폴더에 모아 관리합니다.")
                        .font(.system(size: 12)).foregroundStyle(AppTheme.muted)
                }
                Spacer()
                if let dismiss {
                    Button("닫기", action: dismiss).keyboardShortcut(.cancelAction)
                }
            }
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let startupError, !startupError.isEmpty {
                        Label {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("저장 위치 확인이 필요합니다").font(.system(size: 13, weight: .semibold))
                                Text(startupError).font(.system(size: 12)).textSelection(.enabled)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(AppTheme.rose)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.blush, in: RoundedRectangle(cornerRadius: 12))
                    }

                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Text("현재 저장 위치").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button { openFolder(currentRoot) } label: {
                                Label("Finder에서 열기", systemImage: "arrow.up.right.square")
                            }.buttonStyle(.borderless)
                        }
                        Text(displayPath(currentRoot))
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 10) {
                            Button("저장 폴더 변경…", action: chooseRoot)
                                .buttonStyle(.borderedProminent)
                            Button("기본 위치로 설정") { requestRoot(StorageLocations.defaultRoot) }
                                .disabled(currentRoot.standardizedFileURL == StorageLocations.defaultRoot.standardizedFileURL && pendingRoot == nil)
                        }
                        Text("기본 위치: 문서 > TableLog")
                            .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                        Text("위치를 변경할 때는 TableLog 전용 빈 폴더를 선택하거나 새로 만드세요.")
                            .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                        if !storageStatus.isEmpty {
                            Text(storageStatus).font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                        }
                    }
                    .padding(17)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))

                    if let pendingRoot {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("다음 실행부터 사용할 위치", systemImage: "arrow.right.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text(displayPath(pendingRoot))
                                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            Text("앱을 종료한 뒤 다시 열면 기존 자료를 새 위치로 복사합니다. 원본은 현재 위치에 보관됩니다.")
                                .font(.system(size: 12)).lineSpacing(4)
                            Text("현재 회의는 현재 저장 위치에 계속 저장됩니다.")
                                .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                            Button("변경 예약 취소") {
                                StorageLocations.cancelPending()
                                publishChange()
                            }.buttonStyle(.bordered)
                        }
                        .foregroundStyle(AppTheme.violet)
                        .padding(17)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.lavender.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text("항목별 저장 폴더")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.bottom, 12)
                        ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: category.icon)
                                    .font(.system(size: 16)).foregroundStyle(AppTheme.violet)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(category.title).font(.system(size: 12, weight: .semibold))
                                        Text(category.detail).font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                                    }
                                    Text(displayPath(category.url))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(AppTheme.muted)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 10)
                                Button { openFolder(category.url) } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("\(category.title) 폴더 열기")
                                .help("Finder에서 \(category.title) 폴더 열기")
                            }
                            .padding(.vertical, 11)
                            if index < categories.count - 1 {
                                Divider().overlay(AppTheme.violet.opacity(0.06))
                            }
                        }
                    }
                    .padding(17)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 760, height: 690)
        .background(AppTheme.paper)
        .foregroundStyle(AppTheme.ink)
        .tint(AppTheme.violet)
        .preferredColorScheme(.light)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: Self.changeNotification)) { _ in refresh() }
        .alert("저장 위치 확인", isPresented: $showingError) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.title = "테이블로그 저장 폴더 선택"
        panel.message = "TableLog 전용 빈 폴더를 선택하거나 새로 만드세요. 그 안에 회의자료와 녹음 등 항목별 폴더를 만듭니다."
        panel.prompt = "이 폴더 사용"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = pendingRoot ?? currentRoot
        panel.begin { result in
            if result == .OK, let url = panel.url { requestRoot(url) }
        }
    }

    private func requestRoot(_ url: URL) {
        do {
            try StorageLocations.requestRoot(url)
            publishChange()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func publishChange() {
        refresh()
        NotificationCenter.default.post(name: Self.changeNotification, object: nil)
    }

    private func refresh() {
        currentRoot = StorageLocations.currentRoot
        pendingRoot = StorageLocations.pendingRoot
        storageStatus = StorageLocations.status
        startupError = StorageLocations.startupError
    }

    private func openFolder(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path), NSWorkspace.shared.open(url) else {
            errorMessage = "폴더 접근 권한과 저장 장치 연결을 확인해 주세요.\n\(url.path)"
            showingError = true
            return
        }
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
