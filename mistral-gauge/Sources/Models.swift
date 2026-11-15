import Foundation

enum MistralAuthMethod: String {
    case keychain, browser
}

struct MistralCredentials {
    enum Value {
        case apiKey(String)
        case cookie(String)
    }
    let value: Value
    let source: String
}

struct MistralAllowance: Codable, Equatable, Sendable {
    let usedPercent: Double
    let total: Double
    let currency: String
    let resetsAt: String?

    var used: Double { total * (usedPercent / 100) }
    var remaining: Double { max(0, total - used) }

    var resetLabel: String {
        guard let resetsAt, let date = Self.parseDate(resetsAt) else { return "unknown" }
        let seconds = max(0, date.timeIntervalSinceNow)
        if seconds == 0 { return "now" }
        if seconds >= 86_400 { return "\(Int(ceil(seconds / 86_400))) days" }
        if seconds >= 3_600 { return "\(Int(ceil(seconds / 3_600))) hr" }
        return "\(Int(ceil(seconds / 60))) min"
    }

    static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    enum CodingKeys: String, CodingKey {
        case usedPercent, total, currency, resetsAt, used, remaining, resetLabel
    }

    init(usedPercent: Double, total: Double, currency: String, resetsAt: String?) {
        self.usedPercent = usedPercent
        self.total = total
        self.currency = currency
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try c.decode(Double.self, forKey: .usedPercent)
        total = try c.decode(Double.self, forKey: .total)
        currency = try c.decode(String.self, forKey: .currency)
        resetsAt = try c.decodeIfPresent(String.self, forKey: .resetsAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(usedPercent, forKey: .usedPercent)
        try c.encode(total, forKey: .total)
        try c.encode(currency, forKey: .currency)
        try c.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try c.encode(used, forKey: .used)
        try c.encode(remaining, forKey: .remaining)
        try c.encode(resetLabel, forKey: .resetLabel)
    }
}

struct MistralUsageResponse: Codable, Equatable, Sendable {
    let api: MistralAllowance?
    let vibe: MistralAllowance?
}

struct MistralUsageOutput: Encodable {
    let httpStatus: Int
    let source: String
    let observedAt: String
    let api: MistralAllowance?
    let vibe: MistralAllowance?
}

enum MistralError: Error, LocalizedError {
    case credentials(String)
    case browserAccessDenied
    case http(Int)
    case billingHTTP(Int)
    case invalidResponse
    case missingAllowance
    case ambiguousAllowance

    var errorDescription: String? {
        switch self {
        case .credentials(let message): return message
        case .browserAccessDenied:
            return "Browser cookie access denied by macOS. Grant Full Disk Access to AIGauge in System Settings → Privacy & Security, then quit and reopen AIGauge. For the standalone CLI, authorize your terminal app. Keychain access is separate."
        case .http(let status):
            if [301, 302, 303, 307, 308, 401, 403].contains(status) {
                return "HTTP \(status): Mistral session expired or access blocked. Sign in at admin.mistral.ai in the selected browser and check again."
            }
            return "Mistral returned HTTP \(status)."
        case .billingHTTP(let status):
            switch status {
            case 401: return "Mistral rejected the API key (HTTP 401). Reconnect with a current Mistral key."
            case 403: return "Mistral denied quota access (HTTP 403). This key needs the see_org_inference_usage permission."
            default: return "Mistral billing API returned HTTP \(status)."
            }
        case .invalidResponse: return "Invalid Mistral subscription response."
        case .missingAllowance:
            return "No included Mistral allowance is available for this account."
        case .ambiguousAllowance:
            return "Multiple different Mistral allowances found; refusing to choose an account automatically."
        }
    }
}
