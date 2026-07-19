import Foundation

// MARK: - Auth blob (matches ~/.codex/auth.json and Keychain "Codex Auth")

struct CodexAuthFile: Codable, Sendable {
    var authMode: String?              // "chatgpt" or "apikey"
    var openaiApiKey: String?          // fallback when auth_mode == "apikey"
    var tokens: CodexAuthTokens?
    var lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openaiApiKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }
}

struct CodexAuthTokens: Codable, Sendable {
    var idToken: String?
    var accessToken: String?
    var refreshToken: String?
    var accountId: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountId = "account_id"
    }
}

// MARK: - Resolved settings used by the API client

struct CodexSettings: Codable, Sendable {
    var accessToken: String?       // Bearer for chatgpt-subscription mode
    var apiKey: String?            // OPENAI_API_KEY (apikey mode)
    var accountId: String?         // chatgpt_account_id
    var authMode: String?
    var source: String?            // for logging only

    static let settingsURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/codex-gauge")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }()

    static func load() -> CodexSettings? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? JSONDecoder().decode(CodexSettings.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.settingsURL)
    }

    /// Bearer string for the Authorization header — access_token wins; API key falls back.
    var bearer: String? {
        if let t = accessToken, !t.isEmpty { return t }
        if let k = apiKey, !k.isEmpty { return k }
        return nil
    }
}

// MARK: - Usage / rate-limit response  (/backend-api/wham/usage)

struct CodexUsageResponse: Codable, Sendable {
    let userId: String?
    let accountId: String?
    let email: String?
    let planType: String?
    let rateLimit: RateLimit?
    let credits: Credits?
    /// Summary embedded in `/wham/usage`. The individual grant records (and
    /// their expiration timestamps) come from a separate details endpoint.
    let rateLimitResetCredits: RateLimitResetCreditsSummary?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case accountId = "account_id"
        case email
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }

    /// The tiny-prompt refresh is meaningful only for the legacy rolling
    /// 5-hour quota mechanism. Detect it from the live response instead of
    /// assuming OpenAI's current quota model.
    var supportsLegacyWindowRefresh: Bool {
        [rateLimit?.primaryWindow, rateLimit?.secondaryWindow]
            .compactMap { $0 }
            .contains { $0.limitWindowSeconds == 18_000 }
    }
}

// MARK: - Banked rate-limit resets

/// Count-only summary returned inline by `/backend-api/wham/usage`.
struct RateLimitResetCreditsSummary: Codable, Sendable {
    let availableCount: Int?
    let applicableAvailableCount: Int?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case applicableAvailableCount = "applicable_available_count"
    }
}

/// Detailed response from the internal, read-only
/// `/backend-api/wham/rate-limit-reset-credits` endpoint.
struct RateLimitResetCreditsResponse: Codable, Sendable {
    let availableCount: Int?
    let credits: [RateLimitResetCredit]?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case credits
    }
}

/// One banked Codex reset. All fields remain optional because this is an
/// undocumented product endpoint and its response may evolve independently.
struct RateLimitResetCredit: Codable, Sendable {
    let id: String?
    let resetType: String?
    let status: String?
    let grantedAt: String?
    let expiresAt: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case id
        case resetType = "reset_type"
        case status
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
        case title
    }
}

struct RateLimit: Codable, Sendable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: RateLimitWindow?
    let secondaryWindow: RateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct RateLimitWindow: Codable, Sendable {
    let usedPercent: Double?
    let limitWindowSeconds: Int?
    let resetAfterSeconds: Int?
    let resetAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }

    var windowLabel: String {
        guard let s = limitWindowSeconds else { return "?" }
        if s >= 86400 { return "\(s / 86400)d" }
        return "\(s / 3600)h"
    }

    var resetLabel: String {
        guard let s = resetAfterSeconds else { return "?" }
        if s <= 0 { return "now" }
        let h = s / 3600
        let m = (s % 3600) / 60
        return h > 0 ? "\(h) hr \(m) min" : "\(m) min"
    }
}

struct Credits: Codable, Sendable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }
}
