import SwiftUI
import AppKit

/// Present from the current meeting's speaker editor or template participant editor.
/// The caller receives only a contact explicitly selected by the user.
@MainActor public struct MeetingContactsPicker: View {
    private let title: String
    private let onSelect: (MeetingPerson) -> Void
    private let onClose: () -> Void
    private let preferences = MeetingContactPreferences()
    @State private var sources: [MeetingContactSource] = []
    @State private var sourceID = ""
    @State private var refreshRevision = 0
    @State private var query = ""
    @State private var people: [MeetingPerson] = []
    @State private var connected = false
    @State private var connecting = false
    @State private var searching = false
    @State private var message: String?
    @State private var preferredPerson: MeetingPerson?
    @State private var connectTask: Task<Void, Never>?

    public init(title: String = "화자에 연락처 연결", onSelect: @escaping (MeetingPerson) -> Void, onClose: @escaping () -> Void) {
        self.title = title; self.onSelect = onSelect; self.onClose = onClose
    }
    private var searchKey: String { connected ? String(refreshRevision) + "|" + sourceID + "\u{0}" + query : "" }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                Button("닫기", action: onClose).keyboardShortcut(.cancelAction)
            }
            Text("Mac 연락처에서 연락처가 동기화된 계정을 선택하세요. 계정과 기본 연락처를 기억해 다음에도 바로 불러옵니다. 별표 버튼으로 기본 연락처를 바꿀 수 있습니다.")
                .font(.callout).foregroundStyle(.secondary)
            if !connected {
                Button(connecting ? "연락처 연결 중…" : "Mac 연락처 연결") { connect() }
                    .buttonStyle(.borderedProminent).disabled(connecting)
            } else {
                HStack {
                    Picker("연락처 계정", selection: $sourceID) {
                        Text("계정 선택").tag("")
                        ForEach(sources) { source in Text(source.name.isEmpty ? "이름 없는 연락처 계정" : source.name).tag(source.id) }
                    }
                    Button("새로 고침") { connect() }.disabled(connecting)
                }
                TextField("이름 또는 소속 검색", text: $query).textFieldStyle(.roundedBorder)
                    .disabled(sourceID.isEmpty)
            }
            if let person = preferredPerson, query.isEmpty, connected, !sourceID.isEmpty {
                Button { select(person) } label: {
                    HStack {
                        Image(systemName: "star.fill")
                        VStack(alignment: .leading) {
                            Text("기본 연락처 · " + person.name).font(.headline)
                            if !person.organization.isEmpty { Text(person.organization).font(.caption) }
                        }
                        Spacer()
                        Text("연결")
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.bordered)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if searching { ProgressView("연락처 검색 중") }
            List(people) { person in
                HStack {
                    Button { select(person) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(person.name).font(.headline)
                                if !person.organization.isEmpty { Text(person.organization).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text("연결").font(.caption)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button {
                        preferences.rememberPerson(person.id, sourceID: sourceID)
                        preferredPerson = person
                    } label: {
                        Image(systemName: preferences.preferredPersonID(sourceID: sourceID) == person.id ? "star.fill" : "star")
                    }.buttonStyle(.borderless)
                        .help("기본 연락처로 저장")
                        .accessibilityLabel(person.name + " 기본 연락처로 저장")
                }
            }
            Text("템플릿의 참석자 후보는 다음 회의에서도 재사용할 수 있습니다. 실제 화자와 참석 여부는 회의마다 확인합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 550, height: 570)
            .task(id: searchKey) {
                people = []; preferredPerson = nil; searching = false
                guard connected, !sourceID.isEmpty else { return }
                let source = sourceID, term = query
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    searching = true
                    let results = try await MeetingContacts.search(term, sourceID: source)
                    try Task.checkCancellation()
                    guard source == sourceID, term == query else { return }
                    people = results; searching = false
                    preferredPerson = results.first { $0.id == preferences.preferredPersonID(sourceID: source) }
                    message = results.isEmpty ? "검색 결과가 없습니다. 이름·소속 또는 선택한 계정을 확인하세요." : "\(results.count)명 · 연결할 사람을 선택하세요."
                } catch {
                    if !Task.isCancelled {
                        searching = false
                        message = "연락처를 읽을 수 없습니다. 시스템 설정의 연락처 접근 권한과 계정 동기화를 확인하세요."
                    }
                }
            }
            .onChange(of: sourceID) { _, value in
                people = []; preferredPerson = nil
                preferences.rememberSource(value)
            }
            .onAppear {
                if MeetingContacts.hasAccess { connect(requestPermission: false) }
            }
            .onDisappear { connectTask?.cancel() }
    }
    private func select(_ person: MeetingPerson) {
        if preferences.preferredPersonID(sourceID: sourceID) == nil {
            preferences.rememberPerson(person.id, sourceID: sourceID)
        }
        onSelect(person); onClose()
    }
    private func connect(requestPermission: Bool = true) {
        connectTask?.cancel(); connecting = true; message = nil
        connectTask = Task { @MainActor in
            defer { connecting = false }
            do {
                if !MeetingContacts.hasAccess {
                    guard requestPermission else { return }
                    try await MeetingContacts.requestAccess()
                }
                let available = try await MeetingContacts.sources()
                let systemDefault = await MeetingContacts.defaultSourceID()
                try Task.checkCancellation()
                sources = available; connected = true
                sourceID = preferences.resolveSource(available: available.map(\.id), systemDefault: systemDefault)
                refreshRevision += 1
                message = available.isEmpty ? "연락처 계정이 없습니다. Mac 인터넷 계정에서 연락처 동기화를 켜 주세요." :
                    (sourceID.isEmpty ? "저장한 연락처 계정을 확인해 주세요. 사용할 계정을 선택하면 새 기본값으로 기억합니다." : "기본 연락처 계정을 연결했습니다. 계정을 바꾸면 다음에도 해당 계정을 사용합니다.")
            } catch {
                if !Task.isCancelled { message = "시스템 설정 → 개인정보 보호 및 보안 → 연락처에서 테이블로그의 접근을 허용해 주세요." }
            }
        }
    }
}
