import XCTest
import SQLite3
import CommonCrypto
import Darwin
@testable import MistralGauge

final class UsageTests: XCTestCase {
    private let budget = #"{"budget":{"api_budget":{"usage_percentage":0,"initial_budget":30,"currency":"USD","reset_at":"2026-12-01T00:00:00Z"},"vibe_budget":{"usage_percentage":64,"initial_budget":75,"currency":"USD","reset_at":"2026-12-01T00:00:00.000Z"}}}"#

    private func page(_ records: String, splitAt: Int? = nil) throws -> String {
        let chunks: [String]
        if let splitAt {
            let i = records.index(records.startIndex, offsetBy: splitAt)
            chunks = [String(records[..<i]), String(records[i...])]
        } else { chunks = [records] }
        return try chunks.map { chunk in
            let argument = try JSONSerialization.data(withJSONObject: [1, chunk])
            return "<script>self.__next_f.push(\(String(decoding: argument, as: UTF8.self)))</script>"
        }.joined()
    }

    func testSubscriptionIncludesZeroUsageAndSeparateAllowances() throws {
        let usage = try SubscriptionParser.parse(html: page("a:[\"$\",\"component\",null,\(budget)]\n"))
        XCTAssertEqual(usage.api?.usedPercent, 0)
        XCTAssertEqual(usage.api?.remaining, 30)
        XCTAssertEqual(try XCTUnwrap(usage.vibe?.used), 48.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(usage.vibe?.remaining), 27.0, accuracy: 0.0001)
        XCTAssertNotNil(usage.vibe?.resetsAt.flatMap(MistralAllowance.parseDate))
    }

    func testFlightChunksMaySplitWithinEscapedJSON() throws {
        let record = "f:[\"quoted \\\"text\\\" and \\n newline\",\(budget)]\n"
        let usage = try SubscriptionParser.parse(html: page(record, splitAt: 47))
        XCTAssertEqual(usage.vibe?.total, 75)
    }

    func testTextRecordsCannotInjectBudgetProps() throws {
        let spoof = "quoted text\na:\(budget)\n"
        let flight = "1:T\(String(spoof.utf8.count, radix: 16)),\(spoof)\n2:{\"notBudget\":true}\n"
        XCTAssertThrowsError(try SubscriptionParser.parse(html: page(flight)))
        let real = try SubscriptionParser.parse(html: page(flight + "3:\(budget)\n"))
        XCTAssertEqual(real.api?.total, 30)
    }

    func testIgnoresBudgetLikeStringsAndNonFlightScripts() throws {
        XCTAssertThrowsError(try SubscriptionParser.parse(html: "<script>let x = \(budget)</script>"))
        let quoted = String(decoding: try JSONSerialization.data(withJSONObject: ["text": budget]), as: UTF8.self)
        XCTAssertThrowsError(try SubscriptionParser.parse(html: page("2:\(quoted)\n")))
        XCTAssertThrowsError(try SubscriptionParser.parse(html: "<html>Sign in</html>"))
    }

    func testDuplicatePropsAreFineButConflictingAccountsFail() throws {
        XCTAssertNoThrow(try SubscriptionParser.parse(html: page("1:\(budget)\n2:\(budget)\n")))
        let other = budget.replacingOccurrences(of: "\"initial_budget\":75", with: "\"initial_budget\":300")
        XCTAssertThrowsError(try SubscriptionParser.parse(html: page("1:\(budget)\n2:\(other)\n"))) { error in
            guard case MistralError.ambiguousAllowance = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    func testMalformedAndMissingAllowancesNeverBecomeZero() throws {
        for replacement in ["0", "-10", "\"not-a-number\"", "true"] {
            let partial = budget.replacingOccurrences(of: "\"initial_budget\":75", with: "\"initial_budget\":\(replacement)")
            let usage = try SubscriptionParser.parse(html: page("1:\(partial)\n"))
            XCTAssertNotNil(usage.api)
            XCTAssertNil(usage.vibe)
        }
        XCTAssertThrowsError(try SubscriptionParser.parse(html: page("1:{\"budget\":{}}\n")))
        XCTAssertThrowsError(try SubscriptionParser.parse(html: page("1:{\"budget\":\n")))
        XCTAssertThrowsError(try SubscriptionParser.parse(html: page("1:Tffff,short")))
    }

    func testOverLimitUsageAndUnknownResetRemainExplicit() throws {
        let usage = try SubscriptionParser.parse(html: page("1:\(budget.replacingOccurrences(of: "\"usage_percentage\":64", with: "\"usage_percentage\":125"))\n"))
        XCTAssertEqual(usage.vibe?.usedPercent, 125)
        XCTAssertEqual(usage.vibe?.remaining, 0)
        XCTAssertEqual(MistralAllowance(usedPercent: 10, total: 100, currency: "EUR", resetsAt: nil).resetLabel, "unknown")
    }

    func testJSONAndHumanOutputPreserveCurrencyAndAmounts() throws {
        let usage = try SubscriptionParser.parse(html: page("1:\(budget)\n"))
        let output = MistralUsageOutput(httpStatus: 200, source: "fixture", observedAt: "2026-11-15T00:00:00Z",
                                        api: usage.api, vibe: usage.vibe)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any])
        let vibe = try XCTUnwrap(object["vibe"] as? [String: Any])
        XCTAssertEqual(vibe["used"] as? Double, 48.0)
        XCTAssertEqual(vibe["currency"] as? String, "USD")
        XCTAssertTrue(CLI.usageHuman(usage).contains("48.00 / 75.00 USD"))
        XCTAssertTrue(CLI.usageHuman(MistralUsageResponse(api: nil, vibe: nil)).contains("unavailable"))
    }

    func testArgumentsAndCookieValidation() throws {
        let defaults = try CLI.parse(args: ["usage", "--json"])
        XCTAssertEqual(defaults.auth, .keychain)
        XCTAssertEqual(defaults.source, .edge)
        XCTAssertEqual(defaults.profile, "Default")
        XCTAssertFalse(defaults.allowKeychainPrompt)
        let options = try CLI.parse(args: ["usage", "--source", "chrome", "--profile", "Profile 1", "--allow-keychain-prompt"])
        XCTAssertEqual(options.source, .chrome)
        XCTAssertEqual(options.auth, .browser)
        XCTAssertTrue(options.allowKeychainPrompt)
        for args in [["usage", "--profile", "../Default"], ["usage", "--source", "unknown"],
                     ["usage", "--cookie-file"], ["usage", "--source", "--json"], ["refresh"], ["usage", "--raw"]] {
            XCTAssertThrowsError(try CLI.parse(args: args))
        }
        XCTAssertNoThrow(try CredentialExtractor.validatedHeader("csrftoken=csrf; ory_session_test=secret"))
        XCTAssertEqual(try CredentialExtractor.validatedHeader("Cookie: ory_session_test=secret"),
                       "ory_session_test=secret")
        for cookie in ["", "csrftoken=csrf", "ory_session_test=", "ory_session_test=token\r\nX-Evil: yes"] {
            XCTAssertThrowsError(try CredentialExtractor.validatedHeader(cookie))
        }
    }

    func testKeychainResolutionUsesVibeCredentialWithoutReadingBrowserFiles() throws {
        var locations: [String] = []
        let credentials = try VibeCredentialStore.resolve(environment: [:]) { service, account in
            locations.append("\(service):\(account)")
            return service == "ai.mistral.vibe" ? "synthetic-vibe-key" : nil
        }
        XCTAssertEqual(locations, ["com.aigauge.mistral:api-key", "ai.mistral.vibe:MISTRAL_API_KEY"])
        guard case .apiKey(let key) = credentials.value else { return XCTFail("Expected API credential") }
        XCTAssertEqual(key, "synthetic-vibe-key")
        XCTAssertEqual(credentials.source, "Keychain: Mistral Vibe")
        XCTAssertThrowsError(try VibeCredentialStore.resolve(environment: [:]) { _, _ in nil }) { error in
            XCTAssertTrue(error.localizedDescription.contains("No Mistral key found in Keychain"))
            XCTAssertFalse(error.localizedDescription.contains("Full Disk Access"))
        }
    }

    func testExplicitEnvironmentKeyAndOwnSavedKeyTakePriority() throws {
        let environment = try VibeCredentialStore.resolve(environment: ["MISTRAL_API_KEY": "env-key"]) { _, _ in
            XCTFail("An explicit environment key should not access Keychain")
            return nil
        }
        XCTAssertEqual(environment.source, "env:MISTRAL_API_KEY")
        var calls = 0
        let own = try VibeCredentialStore.resolve(environment: [:]) { service, _ in
            calls += 1
            return service == VibeCredentialStore.ownService ? "own-key" : nil
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(own.source, "Keychain: AIGauge")
        let legacy = try VibeCredentialStore.resolve(environment: [:]) { service, _ in
            service == "vibe" ? "legacy-key" : nil
        }
        XCTAssertEqual(legacy.source, "Keychain: Mistral Vibe")
    }

    func testKeychainFailureDoesNotSilentlySwitchAccountsOrReadCookies() {
        var calls = 0
        XCTAssertThrowsError(try VibeCredentialStore.resolve(environment: [:]) { _, _ in
            calls += 1
            throw MistralError.credentials("Keychain is locked")
        })
        XCTAssertEqual(calls, 1)
        for invalid in ["", " \n", "key\r\nInjected: value", String(repeating: "x", count: 4_097)] {
            XCTAssertThrowsError(try VibeCredentialStore.validatedKey(invalid))
        }
        XCTAssertThrowsError(try VibeCredentialStore.validatedKey("vibe-cli-oidc")) { error in
            XCTAssertTrue(error.localizedDescription.contains("SSO session"))
        }
    }

    func testNativeAndBrowserArgumentsCannotBeMixed() throws {
        XCTAssertEqual(try CLI.parse(args: ["usage", "--auth", "browser"]).auth, .browser)
        XCTAssertEqual(try CLI.parse(args: ["connect", "--api-key-stdin", "--json"]).auth, .keychain)
        for args in [["connect"], ["connect", "--auth", "browser"],
                     ["usage", "--auth", "keychain", "--source", "edge"],
                     ["usage", "--source", "edge", "--api-key-stdin"],
                     ["usage", "--api-key-file", "key.txt", "--api-key-stdin"],
                     ["usage", "--auth", "unknown"]] {
            XCTAssertThrowsError(try CLI.parse(args: args))
        }
    }

    func testPublicBillingJSONUsesTheSameAllowanceModelAsBrowserProps() throws {
        let data = Data(#"{"api_budget":{"usage_percentage":0,"initial_budget":30,"currency":"USD"},"vibe_budget":{"usage_percentage":64,"initial_budget":75,"currency":"USD","reset_at":"2026-12-01T00:00:00Z"}}"#.utf8)
        let usage = try SubscriptionParser.parseBudgetJSON(data)
        XCTAssertEqual(usage.vibe?.used, 48.0)
        XCTAssertEqual(usage.api?.usedPercent, 0)
        XCTAssertEqual(usage.vibe?.currency, "USD")
        XCTAssertThrowsError(try SubscriptionParser.parseBudgetJSON(Data("{}".utf8)))
        XCTAssertThrowsError(try SubscriptionParser.parseBudgetJSON(Data("<html>Forbidden</html>".utf8)))
    }

    func testCookieDatabaseReadsOnlyCurrentAdminCookies() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mistral-test-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB,
                              path TEXT, expires_utc INTEGER, creation_utc INTEGER);
        INSERT INTO cookies VALUES ('.mistral.ai','ory_session_test','valid',X'','/',0,1);
        INSERT INTO cookies VALUES ('evil-mistral.ai','ory_session_evil','secret',X'','/',0,1);
        INSERT INTO cookies VALUES ('.other.ai','other','secret',X'','/',0,1);
        INSERT INTO cookies VALUES ('.mistral.ai','expired','secret',X'','/',1,1);
        INSERT INTO cookies VALUES ('chat.mistral.ai','chatonly','secret',X'','/',0,1);
        INSERT INTO cookies VALUES ('admin.mistral.ai','otherpath','secret',X'','/api',0,1);
        INSERT INTO cookies VALUES ('admin.mistral.ai','csrftoken','csrf',X'','/',0,1);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let header = try CredentialExtractor.readDatabase(url: url) {
            XCTFail("Plaintext fixture must not read Keychain")
            return Data()
        }
        XCTAssertTrue(header.contains("ory_session_test=valid"))
        XCTAssertTrue(header.contains("csrftoken=csrf"))
        XCTAssertFalse(header.contains("secret"))
    }

    func testFilePermissionDeniedExplainsFullDiskAccessSeparatelyFromKeychain() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root can read mode-000 fixtures") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mistral-denied-\(UUID()).sqlite")
        try Data().write(to: url)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        XCTAssertThrowsError(try CredentialExtractor.readDatabase(url: url) {
            XCTFail("A file-access failure must not query Keychain")
            return Data()
        }) { error in
            guard case MistralError.browserAccessDenied = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("Full Disk Access to AIGauge"))
            XCTAssertTrue(error.localizedDescription.contains("quit and reopen"))
            XCTAssertTrue(error.localizedDescription.contains("Keychain access is separate"))
        }
    }

    func testMissingDatabaseDoesNotSuggestGrantingFullDiskAccess() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mistral-missing-\(UUID()).sqlite")
        XCTAssertThrowsError(try CredentialExtractor.readDatabase(url: url) {
            XCTFail("A missing database must not query Keychain")
            return Data()
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("selected browser profile"))
            XCTAssertFalse(error.localizedDescription.contains("Full Disk Access"))
        }
    }

    func testPrivacyErrorsAndLocksHaveDifferentRecoveryInstructions() {
        let privacy = CredentialExtractor.databaseError(code: SQLITE_CANTOPEN, systemError: EPERM)
        XCTAssertTrue(privacy.localizedDescription.contains("Full Disk Access"))
        let permission = CredentialExtractor.databaseError(code: SQLITE_CANTOPEN, systemError: EACCES)
        XCTAssertTrue(permission.localizedDescription.contains("Full Disk Access"))
        // Observed with Apple's SQLite on the actual protected Edge database:
        // authorization failure may arrive without a POSIX errno.
        let authorization = CredentialExtractor.databaseError(code: SQLITE_AUTH, systemError: 0)
        XCTAssertTrue(authorization.localizedDescription.contains("Full Disk Access"))
        let locked = CredentialExtractor.databaseError(code: SQLITE_BUSY, systemError: 0)
        XCTAssertTrue(locked.localizedDescription.contains("busy"))
        XCTAssertFalse(locked.localizedDescription.contains("Full Disk Access"))
    }

    func testChromiumHostDigestAndLegacyCookies() throws {
        let key = Data(repeating: 7, count: 16)
        let host = ".mistral.ai"
        let text = "ory-session-value-longer-than-thirty-two-characters"
        let legacy = try encrypt(Data(text.utf8), key: key)
        XCTAssertEqual(try CredentialExtractor.decrypt(legacy, host: host, databaseVersion: 23, key: key), text)
        var digest = [UInt8](repeating: 0, count: 32)
        let hostData = Data(host.utf8)
        _ = hostData.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(hostData.count), &digest) }
        let modern = try encrypt(Data(digest) + Data(text.utf8), key: key)
        XCTAssertEqual(try CredentialExtractor.decrypt(modern, host: host, databaseVersion: 24, key: key), text)
        XCTAssertThrowsError(try CredentialExtractor.decrypt(modern, host: "evil.example", databaseVersion: 24, key: key))
        XCTAssertThrowsError(try CredentialExtractor.decrypt(Data("v20unsupported".utf8), host: host, databaseVersion: 24, key: key))
    }

    private func encrypt(_ data: Data, key: Data) throws -> Data {
        var output = Data(count: data.count + 16)
        let capacity = output.count
        var count = 0
        let iv = [UInt8](repeating: 32, count: 16)
        let status = output.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, iv, source.baseAddress, data.count,
                            target.baseAddress, capacity, &count)
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        output.count = count
        return Data("v10".utf8) + output
    }
}
