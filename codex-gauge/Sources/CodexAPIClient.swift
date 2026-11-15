import Foundation

/// HTTP client for ChatGPT / Codex.
///
/// Auth is a Bearer JWT (from ~/.codex/auth.json or Keychain "Codex Auth").
/// For `auth_mode == "chatgpt"` the request goes to chatgpt.com's backend-api
/// and includes the chatgpt-account-id header. For `auth_mode == "apikey"` it
/// goes to api.openai.com.
///
/// IMPORTANT: The exact "usage" and "refresh" paths on chatgpt.com are not
/// publicly documented and may move. The defaults below are the best-known
/// candidates at the time of writing. Use `--endpoint` to override at runtime
/// while iterating, and `--raw -v` to see the unparsed response + log noise.
class CodexAPIClient {
    private let settings: CodexSettings
    private let logger = Logger.shared
    private let userAgent = "CodexGauge/0.1 (macOS)"

    // Default endpoint paths (override with --endpoint).
    static let defaultUsagePath = "/backend-api/wham/usage"
    static let defaultResetCreditsPath = "/backend-api/wham/rate-limit-reset-credits"
    static let defaultRefreshPath = "/backend-api/codex/responses"

    /// Response headers we surface in --raw output.
    static let interestingHeaders: [String] = [
        "x-ratelimit-limit-requests",
        "x-ratelimit-remaining-requests",
        "x-ratelimit-reset-requests",
        "x-ratelimit-limit-tokens",
        "x-ratelimit-remaining-tokens",
        "x-ratelimit-reset-tokens",
        "x-ratelimit-limit",
        "x-ratelimit-remaining",
        "x-ratelimit-reset",
        "retry-after",
        "x-account-id",
        "x-conversation-id",
        "x-request-id"
    ]

    let chatgptBase = "https://chatgpt.com"
    let openaiBase = "https://api.openai.com"

    init(settings: CodexSettings) {
        self.settings = settings
        Task { await logger.log("CodexAPIClient init (mode=\(settings.authMode ?? "unknown"), src=\(settings.source ?? "?"))", level: .debug) }
    }

    private var base: String {
        // apikey mode → api.openai.com; chatgpt mode → chatgpt.com
        settings.authMode == "apikey" ? openaiBase : chatgptBase
    }

    private func authorizedRequest(url: URL, method: String) throws -> URLRequest {
        guard let bearer = settings.bearer else { throw APIError.missingBearer }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let accountId = settings.accountId, settings.authMode != "apikey" {
            r.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        }
        return r
    }

    // MARK: - Usage

    struct UsageResult {
        let parsed: CodexUsageResponse
        let raw: String
        let status: Int
        let headers: [String: String]
    }

    func fetchUsage(endpointOverride: String?) async throws -> UsageResult {
        let path = endpointOverride ?? Self.defaultUsagePath
        let urlString = path.hasPrefix("http") ? path : "\(base)\(path)"
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }

        await logger.log("GET \(urlString)", level: .debug)
        let request = try authorizedRequest(url: url, method: "GET")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        let raw = String(data: data, encoding: .utf8) ?? ""
        let headers = interestingHeaderValues(from: http)
        await logger.log("Usage HTTP \(http.statusCode), \(data.count) bytes, headers=\(headers)", level: .debug)
        if http.statusCode != 200 {
            await logger.log("Usage body excerpt: \(raw.prefix(500))", level: .debug)
            throw APIError.httpError(statusCode: http.statusCode, body: raw)
        }

        let decoded = (try? JSONDecoder().decode(CodexUsageResponse.self, from: data))
            ?? CodexUsageResponse(userId: nil, accountId: nil, email: nil,
                                   planType: nil, rateLimit: nil, credits: nil,
                                   rateLimitResetCredits: nil)
        return UsageResult(parsed: decoded, raw: raw, status: http.statusCode, headers: headers)
    }

    /// Fetch individual banked reset grants, including their expiration times.
    /// This is optional enrichment: any HTTP, transport, or decoding failure is
    /// logged and returned as nil so the main usage refresh still succeeds.
    func fetchRateLimitResetCredits() async -> RateLimitResetCreditsResponse? {
        guard settings.authMode != "apikey",
              let url = URL(string: "\(chatgptBase)\(Self.defaultResetCreditsPath)") else {
            return nil
        }

        do {
            await logger.log("GET \(url.absoluteString)", level: .debug)
            let request = try authorizedRequest(url: url, method: "GET")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                await logger.log("Reset credits response was not HTTP", level: .warning)
                return nil
            }
            guard http.statusCode == 200 else {
                await logger.log("Reset credits HTTP \(http.statusCode); using usage summary", level: .warning)
                return nil
            }
            guard let decoded = try? JSONDecoder().decode(RateLimitResetCreditsResponse.self, from: data) else {
                await logger.log("Could not decode reset-credit details; using usage summary", level: .warning)
                return nil
            }
            return decoded
        } catch {
            await logger.log("Reset credits fetch failed: \(error.localizedDescription); using usage summary", level: .warning)
            return nil
        }
    }

    private func interestingHeaderValues(from http: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for name in Self.interestingHeaders {
            if let v = http.value(forHTTPHeaderField: name) {
                out[name] = v
            }
        }
        return out
    }

    // MARK: - Refresh

    func triggerQuotaPeriod(endpointOverride: String?) async throws -> (String, Int) {
        let path = endpointOverride ?? Self.defaultRefreshPath
        let urlString = path.hasPrefix("http") ? path : "\(base)\(path)"
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }

        await logger.log("POST \(urlString)", level: .info)
        var request = try authorizedRequest(url: url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Minimal Responses-API payload — mirrors what the Codex CLI's
        // build_responses_request() in codex-rs/core/src/client.rs sends, just
        // stripped to the bare minimum that should start the 5h window.
        let payload: [String: Any] = [
            "model": "gpt-5.2",
            "instructions": "Reply with only the digit 2.",
            "input": [[
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "1+1=?"]]
            ]],
            "tools": [],
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "store": false,
            "stream": true,
            "include": []
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        let raw = String(data: data, encoding: .utf8) ?? ""
        await logger.log("Refresh HTTP \(http.statusCode), \(data.count) bytes", level: .debug)
        guard (200..<300).contains(http.statusCode) else {
            await logger.log("Refresh body excerpt: \(raw.prefix(500))", level: .debug)
            throw APIError.httpError(statusCode: http.statusCode, body: raw)
        }
        return (raw, http.statusCode)
    }

    enum APIError: Error, LocalizedError {
        case invalidURL
        case invalidResponse
        case missingBearer
        case httpError(statusCode: Int, body: String)
        case parseError(message: String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .invalidResponse: return "Invalid response from server"
            case .missingBearer: return "No access token or API key available"
            case .httpError(let s, let body):
                let excerpt = body.isEmpty ? "" : " — \(body.prefix(200))"
                return "HTTP \(s)\(excerpt)"
            case .parseError(let m): return "Parse error: \(m)"
            }
        }
    }
}
