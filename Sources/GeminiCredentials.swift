import Foundation
import Security
import LocalAuthentication

enum GeminiCredentialsError: LocalizedError {
    case invalidKey, read, save, delete

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "Google AI Studio에서 발급한 Gemini API 키 전체를 입력해 주세요."
        case .read: return "Gemini API 키를 읽으려면 Mac의 키체인 접근 상태를 확인해 주세요."
        case .save: return "Gemini API 키를 키체인에 저장하는 중 오류가 발생했습니다."
        case .delete: return "Gemini API 키를 키체인에서 삭제하는 중 오류가 발생했습니다."
        }
    }
}

/// The secret is stored in the login Keychain, separately from preferences and transcripts.
enum GeminiCredentials {
    private static let service = "local.TableLog.gemini"
    private static let legacyService = "local.HwajaNote.gemini"
    private static let account = "api-key"

    private static var query: [String: Any] {
        query(for: service)
    }

    private static func query(for service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    static var hasKey: Bool {
        [service, legacyService].contains { candidate in
            var request = query(for: candidate)
            request[kSecReturnAttributes as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            let context = LAContext()
            context.interactionNotAllowed = true
            request[kSecUseAuthenticationContext as String] = context
            return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
        }
    }

    static func read() throws -> String? {
        if let current = try read(service: service) { return current }
        guard let previous = try read(service: legacyService) else { return nil }
        // Retain the old item as a recovery copy; future saves use the TableLog service.
        try? save(previous)
        return previous
    }

    private static func read(service: String) throws -> String? {
        var request = query(for: service)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw GeminiCredentialsError.read }
        return try normalizedKey(key)
    }

    static func save(_ key: String) throws {
        let normalized = try normalizedKey(key)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(normalized.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw GeminiCredentialsError.save }
        var newItem = query
        newItem.merge(attributes) { _, new in new }
        newItem[kSecAttrLabel as String] = "테이블로그 Gemini API 키"
        guard SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess else { throw GeminiCredentialsError.save }
    }

    static func delete() throws {
        // Clear the compatibility item first so a failed deletion keeps the current key usable.
        for candidate in [legacyService, service] {
            let status = SecItemDelete(query(for: candidate) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw GeminiCredentialsError.delete }
        }
    }

    static func normalizedKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // New AI Studio auth keys can use the AQ prefix and periods. Validate the
        // transport-safe shape instead of requiring one historical key prefix.
        guard (20...256).contains(key.utf8.count), key.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 45 || byte == 95 || byte == 46
        }) else { throw GeminiCredentialsError.invalidKey }
        return key
    }
}
