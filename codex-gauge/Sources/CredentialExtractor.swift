import Foundation
import Security

/// Resolves Codex/ChatGPT credentials in priority order:
///   1. ~/.codex/auth.json       (npm `@openai/codex` CLI's auth file)
///   2. Keychain svce="Codex Auth"  (macOS Codex desktop app)
///   3. OPENAI_API_KEY environment variable
///
/// All three paths surface the same JSON shape (CodexAuthFile). No cookie
/// extraction or AES decryption is needed — the desktop app stores its OAuth
/// tokens as plaintext JSON in the Keychain entry, and the CLI mirrors them to
/// ~/.codex/auth.json.
class CredentialExtractor {
    private let logger = Logger.shared

    struct ExtractedCredentials {
        let accessToken: String?
        let apiKey: String?
        let accountId: String?
        let authMode: String?
        let source: String
    }

    func extractCredentials() -> ExtractedCredentials? {
        Task { await logger.log("Resolving Codex credentials", level: .info) }

        if let c = readFromAuthFile() { return c }
        if let c = readFromKeychain()  { return c }
        if let c = readFromEnv()        { return c }

        Task { await logger.log("No Codex credentials found", level: .warning) }
        return nil
    }

    // MARK: - ~/.codex/auth.json

    private func readFromAuthFile() -> ExtractedCredentials? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard let data = try? Data(contentsOf: path) else {
            Task { await logger.log("Could not read ~/.codex/auth.json", level: .warning) }
            return nil
        }
        return decode(data: data, source: "~/.codex/auth.json")
    }

    // MARK: - Keychain "Codex Auth"

    private func readFromKeychain() -> ExtractedCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Codex Auth",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Task { await self.logger.log("Keychain query for 'Codex Auth' failed: \(status)", level: .warning) }
            }
            return nil
        }
        return decode(data: data, source: "Keychain: Codex Auth")
    }

    // MARK: - Env

    private func readFromEnv() -> ExtractedCredentials? {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
            return nil
        }
        return ExtractedCredentials(
            accessToken: nil,
            apiKey: key,
            accountId: nil,
            authMode: "apikey",
            source: "env:OPENAI_API_KEY"
        )
    }

    // MARK: - JSON decoding

    private func decode(data: Data, source: String) -> ExtractedCredentials? {
        do {
            let auth = try JSONDecoder().decode(CodexAuthFile.self, from: data)
            let accessToken = auth.tokens?.accessToken
            let apiKey = auth.openaiApiKey
            guard (accessToken != nil && !(accessToken?.isEmpty ?? true))
                  || (apiKey != nil && !(apiKey?.isEmpty ?? true)) else {
                Task { await logger.log("\(source) had no access_token or OPENAI_API_KEY", level: .warning) }
                return nil
            }
            Task { await logger.log("Loaded credentials from \(source) (mode=\(auth.authMode ?? "unknown"))", level: .info) }
            return ExtractedCredentials(
                accessToken: accessToken,
                apiKey: apiKey,
                accountId: auth.tokens?.accountId,
                authMode: auth.authMode,
                source: source
            )
        } catch {
            Task { await logger.log("Failed to decode \(source): \(error.localizedDescription)", level: .warning) }
            return nil
        }
    }
}
