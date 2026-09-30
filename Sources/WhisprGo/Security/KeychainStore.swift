import Foundation
import Security

enum KeychainStore {
    private static let service = "com.whisprgo.credentials"
    private static let legacyService = "com.whisprflow.credentials"
    private static let openAIAccount = "openai-api-key"
    private static let googleAccount = "google-api-key"

    static func openAIAPIKey() -> String? {
        if let saved = read(account: openAIAccount, service: service) {
            return saved
        }
        if let legacy = read(account: openAIAccount, service: legacyService) {
            do {
                try save(legacy, account: openAIAccount, service: service)
                try delete(account: openAIAccount, service: legacyService)
            } catch {
                // The legacy value remains usable if Keychain migration is
                // temporarily unavailable (for example while locked).
            }
            return legacy
        }
        return ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }

    static func saveOpenAIAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(account: openAIAccount, service: service)
            try delete(account: openAIAccount, service: legacyService)
        } else {
            try save(trimmed, account: openAIAccount, service: service)
            try delete(account: openAIAccount, service: legacyService)
        }
    }

    static func googleAPIKey() -> String? {
        read(account: googleAccount, service: service)
            ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
            ?? ProcessInfo.processInfo.environment["GOOGLE_API_KEY"]
    }

    static func saveGoogleAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(account: googleAccount, service: service)
        } else {
            try save(trimmed, account: googleAccount, service: service)
        }
    }

    private static func read(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ value: String, account: String, service: String) throws {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = lookup
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    private static func delete(account: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound {
            try check(status)
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?)
            ?? "Keychain error \(status)"
    }
}
