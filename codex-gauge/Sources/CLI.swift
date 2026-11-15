import Foundation

enum CLIError: Error, LocalizedError {
    case badUsage(String)
    case missingCredentials(String)

    var errorDescription: String? {
        switch self {
        case .badUsage(let m): return m
        case .missingCredentials(let m): return m
        }
    }
}

struct CLIOptions {
    var command: String = ""
    var accessToken: String?
    var apiKey: String?
    var accountId: String?
    var endpoint: String?
    var json = false
    var verbose = false
    var raw = false
}

enum CLI {
    static let helpText = """
    CodexGauge — CLI for ChatGPT / Codex usage and quota refresh

    USAGE:
      CodexGauge <command> [options]

    COMMANDS:
      usage      Fetch and print current ChatGPT/Codex rate-limit info
      refresh    Legacy: prime a detected 5-hour window with a tiny message
      help       Show this message

    OPTIONS:
      --access-token <v>    Bearer JWT (overrides auto-resolution)
      --api-key <v>         OPENAI_API_KEY (Bearer for api.openai.com mode)
      --account-id <v>      chatgpt-account-id header value
      --endpoint <path>     Override usage/refresh path (e.g. /backend-api/...)
      --json                Emit machine-readable JSON on stdout
      --raw                 Include raw API response body in output
      --verbose, -v         Mirror logs to stderr (default: silent)
      --help, -h            Show this message

    AUTH RESOLUTION (in order):
      1. --access-token / --api-key flags
      2. ~/.codex/auth.json                  (npm @openai/codex CLI)
      3. macOS Keychain svce="Codex Auth"    (Codex desktop app)
      4. OPENAI_API_KEY environment variable

    EXIT CODES:
      0  success
      2  bad usage / unknown argument
      3  missing credentials
      4  API or HTTP error

    EXAMPLES:
      CodexGauge usage --json
      CodexGauge usage --raw -v
      CodexGauge usage --endpoint /backend-api/codex/user_info --raw
      CodexGauge refresh --json
    """

    static func run(args: [String]) async -> Int32 {
        let opts: CLIOptions
        do { opts = try parse(args: args) }
        catch let CLIError.badUsage(msg) {
            fputs("error: \(msg)\n\n", stderr)
            fputs(helpText + "\n", stderr)
            return 2
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 2
        }

        if opts.verbose { Logger.consoleEnabled = true }

        switch opts.command {
        case "help": print(helpText); return 0
        case "usage": return await runUsage(opts: opts)
        case "refresh": return await runRefresh(opts: opts)
        default:
            fputs("error: unknown command '\(opts.command)'\n\n", stderr)
            fputs(helpText + "\n", stderr)
            return 2
        }
    }

    // MARK: - Parsing

    static func parse(args: [String]) throws -> CLIOptions {
        guard !args.isEmpty else { throw CLIError.badUsage("no command provided") }
        var opts = CLIOptions()

        let first = args[0]
        if first.hasPrefix("-") {
            if first == "-h" || first == "--help" { opts.command = "help"; return opts }
            throw CLIError.badUsage("expected a command (usage|refresh|help)")
        }
        opts.command = first

        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--access-token":
                i += 1; guard i < args.count else { throw CLIError.badUsage("--access-token requires a value") }
                opts.accessToken = args[i]
            case "--api-key":
                i += 1; guard i < args.count else { throw CLIError.badUsage("--api-key requires a value") }
                opts.apiKey = args[i]
            case "--account-id":
                i += 1; guard i < args.count else { throw CLIError.badUsage("--account-id requires a value") }
                opts.accountId = args[i]
            case "--endpoint":
                i += 1; guard i < args.count else { throw CLIError.badUsage("--endpoint requires a value") }
                opts.endpoint = args[i]
            case "--json": opts.json = true
            case "--raw":  opts.raw = true
            case "--verbose", "-v": opts.verbose = true
            case "--help", "-h": opts.command = "help"
            default: throw CLIError.badUsage("unknown argument: \(arg)")
            }
            i += 1
        }
        return opts
    }

    // MARK: - Settings resolution

    static func resolveSettings(opts: CLIOptions) throws -> CodexSettings {
        // 1. Flags fully override
        if opts.accessToken != nil || opts.apiKey != nil {
            return CodexSettings(
                accessToken: opts.accessToken,
                apiKey: opts.apiKey,
                accountId: opts.accountId,
                authMode: opts.apiKey != nil && opts.accessToken == nil ? "apikey" : "chatgpt",
                source: "flags"
            )
        }

        // 2. Extractor
        let extractor = CredentialExtractor()
        if let c = extractor.extractCredentials() {
            return CodexSettings(
                accessToken: c.accessToken,
                apiKey: c.apiKey,
                accountId: opts.accountId ?? c.accountId,
                authMode: c.authMode,
                source: c.source
            )
        }

        throw CLIError.missingCredentials("""
            No Codex credentials found. Try one of:
              • Log in via the Codex desktop app (keychain svce=Codex Auth), OR
              • Run `codex login` so ~/.codex/auth.json is written, OR
              • Export OPENAI_API_KEY, OR
              • Pass --access-token / --api-key
            """)
    }

    // MARK: - Commands

    static func runUsage(opts: CLIOptions) async -> Int32 {
        let settings: CodexSettings
        do { settings = try resolveSettings(opts: opts) }
        catch { fputs("error: \(error.localizedDescription)\n", stderr); return 3 }

        let client = CodexAPIClient(settings: settings)
        do {
            let r = try await client.fetchUsage(endpointOverride: opts.endpoint)
            // Only enrich responses that advertise banked resets. This keeps
            // the legacy 5-hour mechanism at one request if OpenAI restores it.
            // A custom --endpoint also remains a single, predictable request.
            let resetCredits: RateLimitResetCreditsResponse?
            if opts.endpoint == nil, r.parsed.rateLimitResetCredits != nil {
                resetCredits = await client.fetchRateLimitResetCredits()
            } else {
                resetCredits = nil
            }
            if opts.json {
                print(usageJSON(r.parsed, status: r.status, headers: r.headers,
                                resetCredits: resetCredits,
                                raw: opts.raw ? r.raw : nil, src: settings.source))
            } else {
                print("[\(settings.source ?? "?")] HTTP \(r.status)")
                print(usageHuman(r.parsed, resetCredits: resetCredits))
                if !r.headers.isEmpty {
                    print("\nRate-limit headers:")
                    for (k, v) in r.headers.sorted(by: { $0.key < $1.key }) {
                        print("  \(k): \(v)")
                    }
                }
                if opts.raw { print("\n--- raw ---\n\(r.raw)") }
            }
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 4
        }
    }

    static func runRefresh(opts: CLIOptions) async -> Int32 {
        let settings: CodexSettings
        do { settings = try resolveSettings(opts: opts) }
        catch { fputs("error: \(error.localizedDescription)\n", stderr); return 3 }

        let client = CodexAPIClient(settings: settings)
        do {
            // The default action spends tokens, so confirm that the live usage
            // response still exposes the legacy rolling 5-hour window. An
            // explicit endpoint override is an advanced escape hatch and keeps
            // its historical single-request behaviour.
            if opts.endpoint == nil {
                let usage = try await client.fetchUsage(endpointOverride: nil)
                guard usage.parsed.supportsLegacyWindowRefresh else {
                    fputs("error: Codex does not currently expose a 5-hour usage window; no message was sent\n", stderr)
                    return 4
                }
            }

            let (raw, status) = try await client.triggerQuotaPeriod(endpointOverride: opts.endpoint)
            if opts.json {
                var obj: [String: Any] = [
                    "status": "ok",
                    "httpStatus": status,
                    "responseBytes": raw.utf8.count
                ]
                if opts.raw { obj["raw"] = raw }
                print(jsonString(obj))
            } else {
                print("[\(settings.source ?? "?")] HTTP \(status)")
                print("Refresh triggered. Response bytes: \(raw.utf8.count)")
                if opts.raw { print("\n--- raw ---\n\(raw)") }
            }
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 4
        }
    }

    // MARK: - Output formatting

    static func usageHuman(_ u: CodexUsageResponse,
                           resetCredits: RateLimitResetCreditsResponse? = nil) -> String {
        var lines: [String] = []
        let plan = u.planType ?? "?"
        let who = u.email ?? u.userId ?? "?"
        lines.append("Plan      : \(plan)  (\(who))")

        if let rl = u.rateLimit {
            if rl.limitReached == true {
                lines.append("Status    : LIMIT REACHED")
            } else if rl.allowed == false {
                lines.append("Status    : not allowed")
            }
            if let w = rl.primaryWindow {
                lines.append(formatWindow(label: "Primary  (\(w.windowLabel))", w: w))
            }
            if let w = rl.secondaryWindow {
                lines.append(formatWindow(label: "Secondary(\(w.windowLabel))", w: w))
            }
        }

        if let c = u.credits, c.hasCredits == true || c.unlimited == true {
            let bal = c.balance ?? "?"
            lines.append("Credits   : \(bal)\(c.unlimited == true ? " (unlimited)" : "")")
        }

        let resetCount = resetCredits?.availableCount
            ?? u.rateLimitResetCredits?.availableCount
        if let resetCount {
            lines.append("Resets    : \(resetCount) available")
        }
        for credit in (resetCredits?.credits ?? []).filter({ $0.status == nil || $0.status == "available" }) {
            let title = credit.title ?? "Full reset"
            let expiry = credit.expiresAt.map(humanExpiration) ?? "unknown"
            lines.append("  \(title): expires \(expiry)")
        }

        if lines.count == 1 {
            lines.append("No rate-limit data in response. Use --raw to inspect.")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatWindow(label: String, w: RateLimitWindow) -> String {
        let pct = w.usedPercent.map { String(format: "%5.1f%%", $0) } ?? "    ?"
        return "\(label): \(pct)  (resets in \(w.resetLabel))"
    }

    static func usageJSON(_ u: CodexUsageResponse, status: Int,
                          headers: [String: String],
                          resetCredits: RateLimitResetCreditsResponse? = nil,
                          raw: String?, src: String?) -> String {
        var dict: [String: Any] = ["httpStatus": status]
        if let v = u.userId { dict["userId"] = v }
        if let v = u.accountId { dict["accountId"] = v }
        if let v = u.email { dict["email"] = v }
        if let v = u.planType { dict["planType"] = v }
        if let rl = u.rateLimit {
            var r: [String: Any] = [:]
            if let v = rl.allowed { r["allowed"] = v }
            if let v = rl.limitReached { r["limitReached"] = v }
            if let w = rl.primaryWindow { r["primaryWindow"] = windowDict(w) }
            if let w = rl.secondaryWindow { r["secondaryWindow"] = windowDict(w) }
            dict["rateLimit"] = r
        }
        if let c = u.credits {
            var cd: [String: Any] = [:]
            if let v = c.hasCredits { cd["hasCredits"] = v }
            if let v = c.unlimited { cd["unlimited"] = v }
            if let v = c.balance { cd["balance"] = v }
            dict["credits"] = cd
        }
        if resetCredits != nil || u.rateLimitResetCredits != nil {
            var rd: [String: Any] = [:]
            if let v = resetCredits?.availableCount ?? u.rateLimitResetCredits?.availableCount {
                rd["availableCount"] = v
            }
            if let v = u.rateLimitResetCredits?.applicableAvailableCount {
                rd["applicableAvailableCount"] = v
            }
            if let credits = resetCredits?.credits {
                rd["credits"] = credits.map(resetCreditDict)
            }
            dict["rateLimitResetCredits"] = rd
        }
        if let src = src { dict["source"] = src }
        if !headers.isEmpty { dict["headers"] = headers }
        if let raw = raw { dict["raw"] = raw }
        return jsonString(dict)
    }

    private static func windowDict(_ w: RateLimitWindow) -> [String: Any] {
        var d: [String: Any] = ["window": w.windowLabel, "resetLabel": w.resetLabel]
        if let v = w.usedPercent { d["usedPercent"] = v }
        if let v = w.limitWindowSeconds { d["limitWindowSeconds"] = v }
        if let v = w.resetAfterSeconds { d["resetAfterSeconds"] = v }
        if let v = w.resetAt { d["resetAt"] = v }
        return d
    }

    private static func resetCreditDict(_ c: RateLimitResetCredit) -> [String: Any] {
        var d: [String: Any] = [:]
        if let v = c.id { d["id"] = v }
        if let v = c.resetType { d["resetType"] = v }
        if let v = c.status { d["status"] = v }
        if let v = c.grantedAt { d["grantedAt"] = v }
        if let v = c.expiresAt { d["expiresAt"] = v }
        if let v = c.title { d["title"] = v }
        return d
    }

    private static func humanExpiration(_ raw: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: raw) ?? standard.date(from: raw) else {
            return raw
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func jsonString(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
