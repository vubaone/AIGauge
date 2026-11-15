import Foundation
import SQLite3
import Security
import LocalAuthentication
import CommonCrypto
import Darwin

/// Reads only cookies applicable to Mistral's subscription URL. Browser databases
/// are opened read-only (including their WAL); no cookie or token cache is saved.
enum CredentialExtractor {
    enum Source: String, CaseIterable {
        case edge, chrome, brave

        var directory: String {
            switch self {
            case .edge: return "Microsoft Edge"
            case .chrome: return "Google/Chrome"
            case .brave: return "BraveSoftware/Brave-Browser"
            }
        }

        var keychainService: String {
            switch self {
            case .edge: return "Microsoft Edge Safe Storage"
            case .chrome: return "Chrome Safe Storage"
            case .brave: return "Brave Safe Storage"
            }
        }

        var keychainAccount: String {
            switch self {
            case .edge: return "Microsoft Edge"
            case .chrome: return "Chrome"
            case .brave: return "Brave"
            }
        }
    }

    static func validProfile(_ profile: String) -> Bool {
        !profile.isEmpty && profile != "." && profile != ".."
            && !profile.contains("/") && !profile.contains("\\")
            && !profile.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func validatedHeader(_ header: String) throws -> String {
        var value = header.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        guard !value.isEmpty, value.utf8.count <= 32_768,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              value.split(separator: ";").contains(where: { part in
                  let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                  return pair.count == 2 && pair[0].hasPrefix("ory_session_") && !pair[1].isEmpty
              }) else {
            throw MistralError.credentials("Missing or invalid Mistral session cookie. Expected a Cookie header containing ory_session_*. API keys cannot read this subscription page.")
        }
        return value
    }

    static func extract(source: Source, profile: String, allowKeychainPrompt: Bool) throws -> String {
        guard validProfile(profile) else { throw MistralError.credentials("Invalid browser profile directory.") }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(source.directory)/\(profile)")
        let candidates = [base.appendingPathComponent("Cookies"), base.appendingPathComponent("Network/Cookies")]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw MistralError.credentials("No \(source.rawValue) cookie database for profile ‘\(profile)’. Sign in to admin.mistral.ai in that profile, or select another profile in Settings → Mistral.")
        }
        var key: Data?
        return try readDatabase(url: url) {
            if let key { return key }
            let derived = try storageKey(source: source, allowPrompt: allowKeychainPrompt)
            key = derived
            return derived
        }
    }

    /// Injectable key provider keeps fixture tests independent of real Keychain.
    static func readDatabase(url: URL, keyProvider: () throws -> Data) throws -> String {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK else {
            let systemError = database.map { sqlite3_system_errno($0) } ?? 0
            sqlite3_close(database)
            throw databaseError(code: openResult, systemError: systemError)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)
        var versionStatement: OpaquePointer?
        var version = 0
        if sqlite3_prepare_v2(database, "SELECT value FROM meta WHERE key = 'version'", -1, &versionStatement, nil) == SQLITE_OK,
           sqlite3_step(versionStatement) == SQLITE_ROW {
            version = Int(sqlite3_column_int(versionStatement, 0))
        }
        sqlite3_finalize(versionStatement)

        let sql = """
        SELECT host_key, name, value, encrypted_value FROM cookies
        WHERE host_key IN ('admin.mistral.ai', '.admin.mistral.ai', '.mistral.ai', 'mistral.ai')
          AND path IN ('/', '/subscription')
          AND (expires_utc = 0 OR expires_utc > ?)
        ORDER BY length(path) DESC, length(host_key) DESC, creation_utc DESC
        """
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepareResult == SQLITE_OK else {
            throw databaseError(code: prepareResult, systemError: sqlite3_system_errno(database))
        }
        let chromeNow = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        sqlite3_bind_int64(statement, 1, chromeNow)
        var cookies: [(String, String)] = []
        var names = Set<String>()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let hostPointer = sqlite3_column_text(statement, 0),
                  let namePointer = sqlite3_column_text(statement, 1) else {
                step = sqlite3_step(statement)
                continue
            }
            let host = String(cString: hostPointer)
            let name = String(cString: namePointer)
            if !names.contains(name) {
                var value = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
                if value.isEmpty, let pointer = sqlite3_column_blob(statement, 3) {
                    let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 3)))
                    if !data.isEmpty {
                        value = try decrypt(data, host: host, databaseVersion: version, key: keyProvider())
                    }
                }
                if !value.isEmpty, !name.contains(";"), !name.contains("="), !value.contains(";") {
                    cookies.append((name, value))
                    names.insert(name)
                }
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else {
            throw databaseError(code: step, systemError: sqlite3_system_errno(database))
        }
        return try validatedHeader(cookies.map { "\($0.0)=\($0.1)" }.joined(separator: "; "))
    }

    /// Keep macOS privacy failures distinct from missing files, locks, and schema
    /// changes. Include only numeric diagnostics, never database/cookie contents.
    static func databaseError(code: Int32, systemError: Int32) -> MistralError {
        if systemError == EPERM || systemError == EACCES { return .browserAccessDenied }
        switch code & 0xff {
        case SQLITE_AUTH, SQLITE_PERM:
            // Apple's SQLite can report protected-file denial as SQLITE_AUTH
            // without a POSIX errno. We do not install a SQL authorizer here.
            return .browserAccessDenied
        case SQLITE_BUSY, SQLITE_LOCKED:
            return .credentials("Browser cookie database is busy. Try checking usage again shortly.")
        case SQLITE_CANTOPEN:
            return .credentials("Cannot open browser cookie database (SQLite \(code), OS \(systemError)). Check the selected browser profile and file access permissions.")
        default:
            return .credentials("Cannot read browser cookie database (SQLite \(code), OS \(systemError)). The database may be unavailable or its schema unsupported.")
        }
    }

    private static func storageKey(source: Source, allowPrompt: Bool) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: source.keychainService,
            kSecAttrAccount as String: source.keychainAccount,
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
        guard status == errSecSuccess, let password = result as? Data else {
            throw MistralError.credentials("Cannot access \(source.keychainService) (Keychain \(status)). Use Connect Mistral in Settings → Mistral, or run usage --allow-keychain-prompt once. Background checks never show Keychain prompts.")
        }
        let salt = Array("saltysalt".utf8)
        var key = Data(count: 16)
        let statusCode = key.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { input in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     input.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                     output.baseAddress?.assumingMemoryBound(to: UInt8.self), 16)
            }
        }
        guard statusCode == kCCSuccess else { throw MistralError.credentials("Could not derive browser cookie key.") }
        return key
    }

    static func decrypt(_ encrypted: Data, host: String, databaseVersion: Int, key: Data) throws -> String {
        guard encrypted.count > 3, encrypted.prefix(3) == Data("v10".utf8) else {
            throw MistralError.credentials("Unsupported browser cookie encryption format.")
        }
        let cipher = encrypted.dropFirst(3)
        let capacity = cipher.count + kCCBlockSizeAES128
        var plain = Data(count: capacity)
        var count = 0
        let iv = [UInt8](repeating: 32, count: 16)
        let status = plain.withUnsafeMutableBytes { output in
            cipher.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, iv, input.baseAddress, cipher.count,
                            output.baseAddress, capacity, &count)
                }
            }
        }
        guard status == kCCSuccess else { throw MistralError.credentials("Could not decrypt browser cookies.") }
        plain.count = count
        // Chromium DB v24 binds encrypted cookies to their exact host using a
        // SHA-256 prefix. Validate it rather than guessing from UTF-8 content.
        if databaseVersion >= 24 {
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            let hostData = Data(host.utf8)
            _ = hostData.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(hostData.count), &hash) }
            guard plain.count >= hash.count, plain.prefix(hash.count) == Data(hash) else {
                throw MistralError.credentials("Browser cookie host validation failed.")
            }
            plain = Data(plain.dropFirst(hash.count))
        }
        guard let value = String(data: plain, encoding: .utf8) else {
            throw MistralError.credentials("Invalid decrypted browser cookie.")
        }
        return value
    }
}
