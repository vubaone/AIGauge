import Foundation
import Security
import LocalAuthentication

/// AIGauge's own optional key, then the API key stored by the official Vibe CLI.
/// Existing Vibe entries are read only; saving never changes Vibe's credentials.
enum VibeCredentialStore {
    static let ownService = "com.aigauge.mistral"
    static let ownAccount = "api-key"
    static let readLocations = [
        (service: ownService, account: ownAccount),
        (service: "ai.mistral.vibe", account: "MISTRAL_API_KEY"),
        (service: "vibe", account: "MISTRAL_API_KEY")
    ]

    static func validatedKey(_ key: String) throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4_096,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0)
                  && !CharacterSet.controlCharacters.contains($0) }) else {
            throw MistralError.credentials("Missing or invalid Mistral API key.")
        }
        guard trimmed != "vibe-cli-oidc" else {
            throw MistralError.credentials("Vibe is using an SSO session rather than an API key. Use ‘Use an API key’ in Settings → Mistral to connect with a Mistral key.")
        }
        return trimmed
    }

    /// Injectable reader keeps tests independent of the user's real Keychain.
    static func resolve(environment: [String: String],
                        read: (String, String) throws -> String?) throws -> MistralCredentials {
        if let key = environment["MISTRAL_API_KEY"] {
            return MistralCredentials(value: .apiKey(try validatedKey(key)), source: "env:MISTRAL_API_KEY")
        }
        for location in readLocations {
            if let key = try read(location.service, location.account) {
                return MistralCredentials(value: .apiKey(try validatedKey(key)),
                    source: location.service == ownService ? "Keychain: AIGauge" : "Keychain: Mistral Vibe")
            }
        }
        throw MistralError.credentials("No Mistral key found in Keychain. Sign in with Mistral Vibe, or use ‘Use an API key’ in Settings → Mistral. Browser login is a separate connection method.")
    }

    static func read(service: String, account: String, allowPrompt: Bool) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !allowPrompt {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw MistralError.credentials("Mistral Keychain access requires approval (status \(status)). Click Connect Mistral to allow access. Background checks never show Keychain prompts.")
        }
        return key
    }

    static func save(_ value: String) throws {
        let key = try validatedKey(value)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: ownAccount
        ]
        let data = Data(key.utf8)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "AIGauge Mistral API key"
        let added = SecItemAdd(attributes as CFDictionary, nil)
        let status = added == errSecDuplicateItem
            ? SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            : added
        guard status == errSecSuccess else {
            throw MistralError.credentials("Could not save the Mistral key in Keychain (status \(status)). No key was saved to app preferences or a file.")
        }
    }
}
