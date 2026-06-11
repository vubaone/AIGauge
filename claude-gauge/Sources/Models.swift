import Foundation

struct UsageResponse: Codable, Sendable {
    let fiveHour: UsagePeriod?
    let sevenDay: UsagePeriod?
    let sevenDayOauthApps: UsagePeriod?
    let sevenDayOpus: UsagePeriod?
    let iguanaNecktie: UsagePeriod?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case iguanaNecktie = "iguana_necktie"
    }
}

struct UsagePeriod: Codable, Sendable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? {
        guard let resetsAt = resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt)
    }

    var timeUntilReset: String {
        guard let resetDate = resetsAtDate else { return "N/A" }
        let now = Date()
        let interval = resetDate.timeIntervalSince(now)

        if interval < 0 {
            return "Expired"
        }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        } else {
            return "\(minutes) min"
        }
    }
}

struct ClaudeSettings: Codable, Sendable {
    var organizationId: String
    var sessionKey: String
    var autoTriggerQuota: Bool

    static let configDirectory: URL = {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let dir = homeDirectory.appendingPathComponent(".config/claude-gauge")
        // 0700: only the owner may traverse/read the dir holding session keys.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Tighten an already-existing dir created before this was enforced.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        // Tighten any pre-existing credential files (legacy world-readable ones)
        // so the fix applies without waiting for the next save.
        let fm = FileManager.default
        for name in ["accounts.json", "settings.json", "settings.json.aside"] {
            let path = dir.appendingPathComponent(name).path
            if fm.fileExists(atPath: path) {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
        return dir
    }()

    static let settingsURL: URL = configDirectory.appendingPathComponent("settings.json")

    init(organizationId: String, sessionKey: String, autoTriggerQuota: Bool = false) {
        self.organizationId = organizationId
        self.sessionKey = sessionKey
        self.autoTriggerQuota = autoTriggerQuota
    }

    static func load() -> ClaudeSettings? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }

        // Handle legacy settings without autoTriggerQuota field
        if let settings = try? JSONDecoder().decode(ClaudeSettings.self, from: data) {
            return settings
        }

        // Try to decode without the new field
        struct LegacySettings: Codable {
            var organizationId: String
            var sessionKey: String
        }

        if let legacy = try? JSONDecoder().decode(LegacySettings.self, from: data) {
            return ClaudeSettings(organizationId: legacy.organizationId, sessionKey: legacy.sessionKey)
        }

        return nil
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        try Self.writeProtected(data, to: Self.settingsURL)
    }

    /// Write credential data so only the owner can read it (0600), and tighten
    /// the file if it already existed with looser permissions.
    static func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Multi-account model

/// One Claude account that ClaudeGauge monitors.
///
/// An account is a label plus a credential source. When `source` is set the
/// org/key are re-extracted from that cookie database on each run (so they stay
/// fresh as the session rotates). The cached `organizationId`/`sessionKey` are a
/// fallback used when the source is `.manual` or extraction fails.
struct ClaudeAccount: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var label: String
    /// `rawValue` of `CredentialExtractor.Source`, or "manual" for paste-only.
    var sourceRaw: String
    /// Last-known / manually-entered credentials (also the manual-source store).
    var organizationId: String
    var sessionKey: String

    init(id: UUID = UUID(),
         label: String,
         source: CredentialExtractor.Source?,
         organizationId: String = "",
         sessionKey: String = "") {
        self.id = id
        self.label = label
        self.sourceRaw = source?.rawValue ?? "manual"
        self.organizationId = organizationId
        self.sessionKey = sessionKey
    }

    /// The cookie source backing this account, or nil if it's manual-only.
    var source: CredentialExtractor.Source? {
        CredentialExtractor.Source(rawValue: sourceRaw)
    }

    var sourceDisplayName: String {
        source?.displayName ?? "Manual"
    }
}

/// Persisted set of Claude accounts. Lives next to the legacy `settings.json`
/// as `accounts.json`, and migrates the old single-account file on first load.
struct ClaudeAccountsConfig: Codable, Sendable {
    var accounts: [ClaudeAccount]
    var autoTriggerQuota: Bool

    static let configURL: URL =
        ClaudeSettings.configDirectory.appendingPathComponent("accounts.json")

    init(accounts: [ClaudeAccount] = [], autoTriggerQuota: Bool = false) {
        self.accounts = accounts
        self.autoTriggerQuota = autoTriggerQuota
    }

    /// Loads accounts.json. If absent, migrates the legacy single-account
    /// settings.json into a one-element config (without rewriting it — the
    /// migration is materialised only when `save()` is next called).
    static func load() -> ClaudeAccountsConfig {
        if let data = try? Data(contentsOf: configURL),
           let cfg = try? JSONDecoder().decode(ClaudeAccountsConfig.self, from: data) {
            return cfg
        }

        // Migrate legacy single-account settings.json, if present.
        if let legacy = ClaudeSettings.load(), !legacy.organizationId.isEmpty {
            let account = ClaudeAccount(
                label: "Default",
                source: nil, // unknown which source it came from; treat as manual
                organizationId: legacy.organizationId,
                sessionKey: legacy.sessionKey
            )
            return ClaudeAccountsConfig(accounts: [account],
                                        autoTriggerQuota: legacy.autoTriggerQuota)
        }

        return ClaudeAccountsConfig()
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try ClaudeSettings.writeProtected(data, to: Self.configURL)
    }
}

// MARK: - Quota Period Trigger Models

struct ConversationResponse: Codable, Sendable {
    let uuid: String
    let name: String
}

struct MessageLimitEvent: Codable, Sendable {
    let type: String
    let messageLimit: MessageLimit

    enum CodingKeys: String, CodingKey {
        case type
        case messageLimit = "message_limit"
    }
}

struct MessageLimit: Codable, Sendable {
    let type: String
    let windows: Windows
}

struct Windows: Codable, Sendable {
    let fiveHour: WindowDetail

    enum CodingKeys: String, CodingKey {
        case fiveHour = "5h"
    }
}

struct WindowDetail: Codable, Sendable {
    let status: String
    let resetsAt: Int

    enum CodingKeys: String, CodingKey {
        case status
        case resetsAt = "resets_at"
    }
}
