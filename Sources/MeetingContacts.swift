import Foundation
import Contacts

public struct MeetingContactSource: Identifiable {
    public let id: String
    public let name: String
}
public enum MeetingContactError: LocalizedError {
    case permissionRequired
    public var errorDescription: String? { "연락처 접근을 허용한 뒤 연락처가 동기화된 계정을 선택해 주세요." }
}
/// Invoke requestAccess from the app's explicit Connect Contacts action.
/// Google account authentication and synchronization are managed by macOS.
public enum MeetingContacts {
    public static var hasAccess: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return status == .authorized
    }
    public static func defaultSourceID() async -> String {
        await Task.detached(priority: .userInitiated) { CNContactStore().defaultContainerIdentifier() }.value
    }
    public static func requestAccess() async throws {
        let store = CNContactStore()
        let granted = try await store.requestAccess(for: .contacts)
        guard granted else { throw MeetingContactError.permissionRequired }
    }
    public static func sources() async throws -> [MeetingContactSource] {
        try await Task.detached(priority: .userInitiated) {
            try CNContactStore().containers(matching: nil).map { MeetingContactSource(id: $0.identifier, name: $0.name) }
        }.value
    }
    public static func search(_ query: String, sourceID: String) async throws -> [MeetingPerson] {
        try await Task.detached(priority: .userInitiated) {
            let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor,
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactOrganizationNameKey as CNKeyDescriptor]
            let predicate = CNContact.predicateForContactsInContainer(withIdentifier: sourceID)
            let contacts = try CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys)
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return contacts.compactMap { contact -> MeetingPerson? in
                let name = CNContactFormatter.string(from: contact, style: .fullName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty else { return nil }
                guard needle.isEmpty || name.localizedCaseInsensitiveContains(needle) || contact.organizationName.localizedCaseInsensitiveContains(needle) else { return nil }
                return MeetingPerson(id: contact.identifier, name: name, organization: contact.organizationName)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }
}


/// Persist account and preferred contact IDs only. Resolve names afresh from Contacts.
public struct MeetingContactPreferences {
    private let defaults: UserDefaults
    private let sourceKey = "meetingContacts.defaultSource.v1"
    private let peopleKey = "meetingContacts.defaultPeople.v1"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var sourceID: String { defaults.string(forKey: sourceKey) ?? "" }
    public func rememberSource(_ id: String) {
        guard !id.isEmpty else { return }
        defaults.set(id, forKey: sourceKey)
    }
    public func preferredPersonID(sourceID: String) -> String? {
        (defaults.dictionary(forKey: peopleKey) as? [String: String])?[sourceID]
    }
    public func rememberPerson(_ id: String, sourceID: String) {
        guard !id.isEmpty, !sourceID.isEmpty else { return }
        var people = defaults.dictionary(forKey: peopleKey) as? [String: String] ?? [:]
        people[sourceID] = id
        defaults.set(people, forKey: peopleKey)
        rememberSource(sourceID)
    }
    public func resolveSource(available: [String], systemDefault: String) -> String {
        if !sourceID.isEmpty { return available.contains(sourceID) ? sourceID : "" }
        if available.contains(systemDefault) { return systemDefault }
        return available.count == 1 ? available[0] : ""
    }
}
