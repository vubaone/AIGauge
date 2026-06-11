import Foundation

enum CLIError: Error, LocalizedError {
    case badUsage(String)
    case missingCredentials
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .badUsage(let msg): return msg
        case .missingCredentials:
            return "Missing credentials. Pass --org-id and --session-key, or run with --auto-detect, or save them in ~/.config/claude-gauge/settings.json."
        case .extractionFailed(let msg): return "Credential auto-detection failed: \(msg)"
        }
    }
}

struct CLIOptions {
    var command: String = ""
    var subcommand: String?          // for `accounts <list|add|remove>`
    var orgId: String?
    var sessionKey: String?
    var autoDetect = false
    var json = false
    var verbose = false
    var source: String?              // --source <claude-desktop|edge|chrome|brave>
    var account: String?             // --account <label or uuid>
    var label: String?               // --label <name> (accounts add)
    var all = false                  // --all (usage: force array output)
}

enum CLI {
    static let helpText = """
    ClaudeGauge — CLI for Claude usage and quota refresh (multi-account)

    USAGE:
      ClaudeGauge <command> [options]

    COMMANDS:
      usage             Fetch and print Claude usage windows (5h / 7d / opus)
      refresh           Trigger a new 5-hour quota window via a private minimal prompt
      accounts list     List configured accounts (label, source, org id)
      accounts add      Add an account from a cookie source (--label, --source)
      accounts remove   Remove an account (--account <label|uuid>)
      sources           List available cookie sources detected on this machine
      help              Show this message

    OPTIONS:
      --org-id <id>           Override organization ID (one-shot, no account file)
      --session-key <key>     Override session key (sessionKey cookie value)
      --source <name>         Cookie source: claude-desktop | edge | chrome | brave
      --account <label|uuid>  Operate on one saved account (usage/refresh/remove)
      --label <name>          Name for the account being added
      --all                   usage: emit one entry per saved account (array)
      --auto-detect           Extract credentials from the first available source
      --json                  Emit machine-readable JSON on stdout
      --verbose, -v           Mirror logs to stderr (default: silent)
      --help, -h              Show this message

    CREDENTIAL RESOLUTION for `usage` / `refresh` (in order):
      1. --org-id + --session-key flags                  (one-shot)
      2. --source <name>                                 (live extraction)
      3. --account <label|uuid>                          (saved account)
      4. ~/.config/claude-gauge/accounts.json            (all saved accounts)
      5. legacy ~/.config/claude-gauge/settings.json     (migrated)
      6. --auto-detect / fallback cookie extraction

    OUTPUT (usage):
      • 0 or 1 account            → single JSON object (back-compatible)
      • 2+ accounts, or --all     → JSON array of {accountId,label,source,usage}

    EXIT CODES:
      0  success            3  missing credentials       5  extraction error
      2  bad usage          4  API or HTTP error

    EXAMPLES:
      ClaudeGauge usage --json
      ClaudeGauge usage --all --json
      ClaudeGauge usage --account "Team" --json
      ClaudeGauge accounts add --label "Personal" --source edge
      ClaudeGauge accounts add --label "Work" --source claude-desktop
      ClaudeGauge accounts list --json
      ClaudeGauge refresh --account "Team"
      ClaudeGauge sources --json
    """

    static func run(args: [String]) async -> Int32 {
        let opts: CLIOptions
        do {
            opts = try parse(args: args)
        } catch let CLIError.badUsage(msg) {
            fputs("error: \(msg)\n\n", stderr)
            fputs(helpText + "\n", stderr)
            return 2
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 2
        }

        if opts.verbose {
            Logger.consoleEnabled = true
        }

        switch opts.command {
        case "help":
            print(helpText)
            return 0
        case "usage":
            return await runUsage(opts: opts)
        case "refresh":
            return await runRefresh(opts: opts)
        case "accounts":
            return runAccounts(opts: opts)
        case "sources":
            return runSources(opts: opts)
        default:
            fputs("error: unknown command '\(opts.command)'\n\n", stderr)
            fputs(helpText + "\n", stderr)
            return 2
        }
    }

    // MARK: - Parsing

    static func parse(args: [String]) throws -> CLIOptions {
        guard !args.isEmpty else {
            throw CLIError.badUsage("no command provided")
        }

        var opts = CLIOptions()
        var i = 0

        // First positional arg = command (unless it's a flag, in which case treat as help)
        let first = args[0]
        if first.hasPrefix("-") {
            if first == "-h" || first == "--help" {
                opts.command = "help"
                return opts
            }
            throw CLIError.badUsage("expected a command (usage|refresh|help) as the first argument")
        }
        opts.command = first
        i = 1

        // `accounts` takes a subcommand (list|add|remove) as its next positional.
        if opts.command == "accounts", i < args.count, !args[i].hasPrefix("-") {
            opts.subcommand = args[i]
            i += 1
        }

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--org-id":
                i += 1
                guard i < args.count else { throw CLIError.badUsage("--org-id requires a value") }
                opts.orgId = args[i]
            case "--session-key":
                i += 1
                guard i < args.count else { throw CLIError.badUsage("--session-key requires a value") }
                opts.sessionKey = args[i]
            case "--source":
                i += 1
                guard i < args.count else { throw CLIError.badUsage("--source requires a value") }
                opts.source = args[i]
            case "--account":
                i += 1
                guard i < args.count else { throw CLIError.badUsage("--account requires a value") }
                opts.account = args[i]
            case "--label":
                i += 1
                guard i < args.count else { throw CLIError.badUsage("--label requires a value") }
                opts.label = args[i]
            case "--all":
                opts.all = true
            case "--auto-detect":
                opts.autoDetect = true
            case "--json":
                opts.json = true
            case "--verbose", "-v":
                opts.verbose = true
            case "--help", "-h":
                opts.command = "help"
            default:
                throw CLIError.badUsage("unknown argument: \(arg)")
            }
            i += 1
        }

        return opts
    }

    // MARK: - Credential resolution

    /// Parse `--source` into a known cookie source, or throw.
    private static func parseSource(_ raw: String) throws -> CredentialExtractor.Source {
        guard let s = CredentialExtractor.Source(rawValue: raw) else {
            let valid = CredentialExtractor.Source.allCases
                .filter { $0 != .safari }.map(\.rawValue).joined(separator: " | ")
            throw CLIError.badUsage("unknown --source '\(raw)'. Valid: \(valid)")
        }
        return s
    }

    /// Extract fresh credentials from a specific cookie source.
    private static func extract(from source: CredentialExtractor.Source) throws -> ClaudeSettings {
        let extractor = CredentialExtractor()
        guard let creds = extractor.extractCredentials(from: source) else {
            throw CLIError.extractionFailed("no claude.ai cookies found in \(source.displayName)")
        }
        guard let org = creds.organizationId, let key = creds.sessionKey else {
            throw CLIError.extractionFailed("found cookies in \(source.displayName) but org-id or session-key is missing")
        }
        return ClaudeSettings(organizationId: org, sessionKey: key)
    }

    /// First-available-source auto-detect.
    private static func extract() throws -> ClaudeSettings {
        let extractor = CredentialExtractor()
        guard let creds = extractor.extractCredentials() else {
            throw CLIError.extractionFailed("no claude.ai cookies found in Claude Desktop / Edge / Chrome / Brave")
        }
        guard let org = creds.organizationId, let key = creds.sessionKey else {
            throw CLIError.extractionFailed("found cookies in \(creds.source) but org-id or session-key is missing")
        }
        let settings = ClaudeSettings(organizationId: org, sessionKey: key)
        try? settings.save()
        return settings
    }

    /// Resolve credentials for one saved account: re-extract from its cookie
    /// source if it has one (keeps the session fresh), else use the cached
    /// org/key. The freshly extracted org/key are written back so the GUI can
    /// display them without re-reading the Keychain.
    static func resolveAccount(_ account: ClaudeAccount, autoTrigger: Bool) -> ClaudeSettings {
        if let source = account.source {
            let extractor = CredentialExtractor()
            if let creds = extractor.extractCredentials(from: source),
               let org = creds.organizationId, let key = creds.sessionKey {
                return ClaudeSettings(organizationId: org, sessionKey: key, autoTriggerQuota: autoTrigger)
            }
        }
        // Manual account or extraction failed — use cached values.
        return ClaudeSettings(organizationId: account.organizationId,
                              sessionKey: account.sessionKey,
                              autoTriggerQuota: autoTrigger)
    }

    /// One-shot resolution for `--org-id/--session-key` or `--source` flags.
    /// Returns nil when neither was provided (caller falls back to accounts).
    static func resolveOneShot(opts: CLIOptions) throws -> ClaudeSettings? {
        if let org = opts.orgId, let key = opts.sessionKey {
            return ClaudeSettings(organizationId: org, sessionKey: key)
        }
        // Exactly one of the pair is a usage error — don't silently fall back to
        // saved accounts, which would mask the typo with someone else's data.
        if (opts.orgId == nil) != (opts.sessionKey == nil) {
            throw CLIError.badUsage("--org-id and --session-key must be supplied together")
        }
        if let raw = opts.source {
            return try extract(from: parseSource(raw))
        }
        if opts.autoDetect {
            return try extract()
        }
        return nil
    }

    /// The accounts a `usage`/`refresh` command should act on.
    /// Honors `--account`; otherwise returns every saved account.
    static func targetAccounts(opts: CLIOptions) throws -> (accounts: [ClaudeAccount], autoTrigger: Bool) {
        let cfg = ClaudeAccountsConfig.load()
        guard !cfg.accounts.isEmpty else {
            throw CLIError.missingCredentials
        }
        if let selector = opts.account {
            guard let match = findAccount(selector, in: cfg.accounts) else {
                throw CLIError.badUsage("no saved account matches '\(selector)'. Run `accounts list`.")
            }
            return ([match], cfg.autoTriggerQuota)
        }
        return (cfg.accounts, cfg.autoTriggerQuota)
    }

    /// Match an account by exact UUID or case-insensitive label.
    static func findAccount(_ selector: String, in accounts: [ClaudeAccount]) -> ClaudeAccount? {
        if let uuid = UUID(uuidString: selector) {
            if let m = accounts.first(where: { $0.id == uuid }) { return m }
        }
        return accounts.first { $0.label.caseInsensitiveCompare(selector) == .orderedSame }
    }

    // MARK: - Commands

    static func runUsage(opts: CLIOptions) async -> Int32 {
        // One-shot path (explicit creds / source / auto-detect): single object.
        do {
            if let settings = try resolveOneShot(opts: opts) {
                return await fetchAndPrintSingle(settings: settings, opts: opts)
            }
        } catch let CLIError.badUsage(msg) {
            fputs("error: \(msg)\n", stderr); return 2
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr); return 5
        }

        // Account-driven path.
        let targets: [ClaudeAccount]
        let autoTrigger: Bool
        do {
            (targets, autoTrigger) = try targetAccounts(opts: opts)
        } catch let CLIError.badUsage(msg) {
            fputs("error: \(msg)\n", stderr); return 2
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr); return 3
        }

        // Single saved account and not --all → keep the legacy single-object shape.
        if targets.count == 1 && !opts.all {
            let settings = resolveAccount(targets[0], autoTrigger: autoTrigger)
            return await fetchAndPrintSingle(settings: settings, opts: opts)
        }

        // Multiple accounts (or --all) → array of per-account results.
        var results: [[String: Any]] = []
        var humanBlocks: [String] = []
        var anySuccess = false

        for account in targets {
            let settings = resolveAccount(account, autoTrigger: autoTrigger)
            let client = ClaudeAPIClient(settings: settings)
            var entry: [String: Any] = [
                "accountId": account.id.uuidString,
                "label": account.label,
                "source": account.sourceRaw,
                "organizationId": settings.organizationId
            ]
            do {
                let usage = try await client.fetchUsage()
                entry["usage"] = usageDict(usage)
                results.append(entry)
                humanBlocks.append("[\(account.label) · \(account.sourceDisplayName)]\n" + usageHuman(usage))
                anySuccess = true
            } catch {
                entry["error"] = error.localizedDescription
                results.append(entry)
                humanBlocks.append("[\(account.label) · \(account.sourceDisplayName)]\n  error: \(error.localizedDescription)")
            }
        }

        if opts.json {
            print(jsonArrayString(results))
        } else {
            print(humanBlocks.joined(separator: "\n\n"))
        }
        return anySuccess ? 0 : 4
    }

    /// Fetch and print one account/credential as a single JSON object or human block.
    private static func fetchAndPrintSingle(settings: ClaudeSettings, opts: CLIOptions) async -> Int32 {
        let client = ClaudeAPIClient(settings: settings)
        do {
            let usage = try await client.fetchUsage()
            if opts.json {
                print(usageJSON(usage))
            } else {
                print(usageHuman(usage))
            }
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 4
        }
    }

    static func runRefresh(opts: CLIOptions) async -> Int32 {
        // One-shot path.
        do {
            if let settings = try resolveOneShot(opts: opts) {
                return await triggerAndPrint(settings: settings, label: nil, opts: opts)
            }
        } catch let CLIError.badUsage(msg) {
            fputs("error: \(msg)\n", stderr); return 2
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr); return 5
        }

        // Account-driven. Without --account on multiple accounts, require an explicit
        // choice — refresh spends tokens, so we never fan it out implicitly.
        let cfg = ClaudeAccountsConfig.load()
        guard !cfg.accounts.isEmpty else {
            fputs("error: \(CLIError.missingCredentials.localizedDescription)\n", stderr); return 3
        }
        let target: ClaudeAccount
        if let selector = opts.account {
            guard let m = findAccount(selector, in: cfg.accounts) else {
                fputs("error: no saved account matches '\(selector)'. Run `accounts list`.\n", stderr); return 2
            }
            target = m
        } else if cfg.accounts.count == 1 {
            target = cfg.accounts[0]
        } else {
            fputs("error: multiple accounts configured; pass --account <label|uuid> to choose which to refresh.\n", stderr)
            return 2
        }

        let settings = resolveAccount(target, autoTrigger: cfg.autoTriggerQuota)
        return await triggerAndPrint(settings: settings, label: target.label, opts: opts)
    }

    private static func triggerAndPrint(settings: ClaudeSettings, label: String?, opts: CLIOptions) async -> Int32 {
        let client = ClaudeAPIClient(settings: settings)
        do {
            let resetsAt = try await client.triggerQuotaPeriod()
            let resetDate = Date(timeIntervalSince1970: TimeInterval(resetsAt))
            let iso = ISO8601DateFormatter().string(from: resetDate)
            if opts.json {
                var obj: [String: Any] = [
                    "status": "ok",
                    "resetsAt": resetsAt,
                    "resetsAtISO": iso
                ]
                if let label = label { obj["label"] = label }
                print(jsonString(obj))
            } else {
                let who = label.map { "[\($0)] " } ?? ""
                print("\(who)Quota period triggered. Resets at: \(iso) (epoch \(resetsAt))")
            }
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 4
        }
    }

    // MARK: - accounts / sources commands

    static func runAccounts(opts: CLIOptions) -> Int32 {
        switch opts.subcommand {
        case "list", nil:
            return accountsList(opts: opts)
        case "add":
            return accountsAdd(opts: opts)
        case "remove", "rm":
            return accountsRemove(opts: opts)
        default:
            fputs("error: unknown accounts subcommand '\(opts.subcommand ?? "")'. Use list | add | remove.\n", stderr)
            return 2
        }
    }

    private static func accountsList(opts: CLIOptions) -> Int32 {
        let cfg = ClaudeAccountsConfig.load()
        if opts.json {
            let arr = cfg.accounts.map { a -> [String: Any] in
                ["id": a.id.uuidString, "label": a.label, "source": a.sourceRaw,
                 "organizationId": a.organizationId]
            }
            print(jsonArrayString(arr))
            return 0
        }
        if cfg.accounts.isEmpty {
            print("No accounts configured. Add one with: ClaudeGauge accounts add --label <name> --source <source>")
            return 0
        }
        for a in cfg.accounts {
            let org = a.organizationId.isEmpty ? "—" : a.organizationId
            print("• \(a.label)  [\(a.sourceDisplayName)]  org=\(org)  id=\(a.id.uuidString)")
        }
        return 0
    }

    private static func accountsAdd(opts: CLIOptions) -> Int32 {
        guard let label = opts.label, !label.trimmingCharacters(in: .whitespaces).isEmpty else {
            fputs("error: accounts add requires --label <name>\n", stderr); return 2
        }
        var cfg = ClaudeAccountsConfig.load()
        if cfg.accounts.contains(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) {
            fputs("error: an account labelled '\(label)' already exists.\n", stderr); return 2
        }

        var account: ClaudeAccount
        if let org = opts.orgId, let key = opts.sessionKey {
            account = ClaudeAccount(label: label, source: nil, organizationId: org, sessionKey: key)
        } else if let raw = opts.source {
            let source: CredentialExtractor.Source
            do { source = try parseSource(raw) } catch { fputs("error: \(error.localizedDescription)\n", stderr); return 2 }
            let extractor = CredentialExtractor()
            guard let creds = extractor.extractCredentials(from: source),
                  let org = creds.organizationId, let key = creds.sessionKey else {
                fputs("error: could not extract claude.ai credentials from \(source.displayName). Is it logged in?\n", stderr)
                return 5
            }
            account = ClaudeAccount(label: label, source: source, organizationId: org, sessionKey: key)
        } else {
            fputs("error: accounts add requires either --source <source> or both --org-id and --session-key.\n", stderr)
            return 2
        }

        cfg.accounts.append(account)
        do { try cfg.save() } catch {
            fputs("error: failed to save accounts: \(error.localizedDescription)\n", stderr); return 5
        }
        if opts.json {
            print(jsonString(["status": "ok", "id": account.id.uuidString, "label": account.label,
                              "source": account.sourceRaw, "organizationId": account.organizationId]))
        } else {
            print("Added '\(account.label)' [\(account.sourceDisplayName)] org=\(account.organizationId)")
        }
        return 0
    }

    private static func accountsRemove(opts: CLIOptions) -> Int32 {
        guard let selector = opts.account else {
            fputs("error: accounts remove requires --account <label|uuid>\n", stderr); return 2
        }
        var cfg = ClaudeAccountsConfig.load()
        guard let match = findAccount(selector, in: cfg.accounts) else {
            fputs("error: no saved account matches '\(selector)'.\n", stderr); return 2
        }
        cfg.accounts.removeAll { $0.id == match.id }
        do { try cfg.save() } catch {
            fputs("error: failed to save accounts: \(error.localizedDescription)\n", stderr); return 5
        }
        if opts.json {
            print(jsonString(["status": "ok", "removed": match.label]))
        } else {
            print("Removed '\(match.label)'.")
        }
        return 0
    }

    static func runSources(opts: CLIOptions) -> Int32 {
        let sources = CredentialExtractor.Source.allCases.filter { $0 != .safari }
        if opts.json {
            let arr = sources.map { s -> [String: Any] in
                ["id": s.rawValue, "name": s.displayName, "available": s.isAvailable]
            }
            print(jsonArrayString(arr))
            return 0
        }
        for s in sources {
            print("\(s.isAvailable ? "✓" : "·") \(s.displayName)  (--source \(s.rawValue))")
        }
        return 0
    }

    // MARK: - Output formatting

    static func usageHuman(_ u: UsageResponse) -> String {
        var lines: [String] = []
        lines.append(formatPeriod(label: "5-hour ", period: u.fiveHour))
        lines.append(formatPeriod(label: "7-day  ", period: u.sevenDay))
        lines.append(formatPeriod(label: "Opus 7d", period: u.sevenDayOpus))
        if let oauth = u.sevenDayOauthApps {
            lines.append(formatPeriod(label: "OAuth7d", period: oauth))
        }
        return lines.joined(separator: "\n")
    }

    private static func formatPeriod(label: String, period: UsagePeriod?) -> String {
        guard let p = period else { return "\(label): n/a" }
        let pct = String(format: "%5.1f%%", p.utilization)
        return "\(label): \(pct)  (resets in \(p.timeUntilReset))"
    }

    /// Build the usage dictionary (shared by single-object and per-account array output).
    static func usageDict(_ u: UsageResponse) -> [String: Any] {
        var dict: [String: Any] = [:]
        dict["fiveHour"] = periodDict(u.fiveHour) as Any
        dict["sevenDay"] = periodDict(u.sevenDay) as Any
        dict["sevenDayOpus"] = periodDict(u.sevenDayOpus) as Any
        dict["sevenDayOauthApps"] = periodDict(u.sevenDayOauthApps) as Any
        return dict
    }

    static func usageJSON(_ u: UsageResponse) -> String {
        return jsonString(usageDict(u))
    }

    private static func periodDict(_ p: UsagePeriod?) -> [String: Any]? {
        guard let p = p else { return nil }
        var d: [String: Any] = ["utilization": p.utilization, "timeUntilReset": p.timeUntilReset]
        if let r = p.resetsAt { d["resetsAt"] = r }
        return d
    }

    private static func jsonString(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    private static func jsonArrayString(_ arr: [Any]) -> String {
        guard JSONSerialization.isValidJSONObject(arr),
              let data = try? JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }
}
