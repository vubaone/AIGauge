import Foundation

struct CLIOptions {
    var command = ""
    var auth: MistralAuthMethod = .keychain
    var source: CredentialExtractor.Source = .edge
    var profile = "Default"
    var cookieFile: String?
    var apiKeyFile: String?
    var apiKeyStdin = false
    var json = false
    var verbose = false
    var allowKeychainPrompt = false
}

enum CLI {
    static let helpText = """
    MistralGauge — Mistral monthly allowance (Vibe & Studio; API-only fallback)

    USAGE:
      MistralGauge usage [options]
      MistralGauge connect --api-key-stdin [--json]
      MistralGauge help

    OPTIONS:
      --auth <keychain|browser>     Connection method (default: keychain)
      --api-key-file <path>         Read an API key from a file instead
      --api-key-stdin               Read an API key from stdin (never argv)
      --source <edge|chrome|brave>   Browser holding the session (default: edge)
      --profile <directory>        Browser profile directory (default: Default)
      --cookie-file <path>         Read a Cookie header from a file instead
      --allow-keychain-prompt       Permit a macOS Keychain prompt this time
      --json                        Emit machine-readable JSON on stdout
      --verbose, -v                 Print request status to stderr
      --help, -h                    Show help

    DEFAULT: API key from stdin/file, MISTRAL_API_KEY, AIGauge Keychain,
    then Mistral Vibe Keychain (ai.mistral.vibe or legacy vibe).
    Only GET https://api.mistral.ai/v1/billing/budget; no tokens are spent.
    connect validates quota access before saving the provided key in AIGauge's
    Keychain entry. It never changes Vibe's own credentials.

    BROWSER (explicit --auth browser, --source, --profile, or --cookie-file):
    --cookie-file, MISTRAL_COOKIE, then the selected browser's cookies.
    Only GET https://admin.mistral.ai/api/local-trpc/billing.budget with the
    dashboard's query input. This alternative can need file access permission
    and Safe Storage access. Cookies are never saved.
    Automatic checks never prompt for Keychain access.
    EXIT CODES: 0 success, 2 bad arguments, 3 missing credentials, 4 HTTP/parse error.
    """

    struct ArgumentError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func parse(args: [String]) throws -> CLIOptions {
        guard let first = args.first else { throw ArgumentError(message: "Expected usage or help.") }
        var options = CLIOptions()
        options.command = ["-h", "--help"].contains(first) ? "help" : first
        guard ["usage", "connect", "help"].contains(options.command) else {
            throw ArgumentError(message: "Unknown command. MistralGauge supports usage, connect, and help.")
        }
        var explicitAuth: MistralAuthMethod?
        var browserOptions = false
        var index = 1
        while index < args.count {
            let argument = args[index]
            switch argument {
            case "--auth", "--source", "--profile", "--cookie-file", "--api-key-file":
                index += 1
                guard index < args.count, !args[index].hasPrefix("--") else {
                    throw ArgumentError(message: "\(argument) requires a value.")
                }
                switch argument {
                case "--auth":
                    guard let auth = MistralAuthMethod(rawValue: args[index]) else {
                        throw ArgumentError(message: "Auth must be keychain or browser.")
                    }
                    explicitAuth = auth
                case "--source":
                    guard let source = CredentialExtractor.Source(rawValue: args[index]) else {
                        throw ArgumentError(message: "Source must be edge, chrome, or brave.")
                    }
                    options.source = source
                    browserOptions = true
                case "--profile": options.profile = args[index]; browserOptions = true
                case "--cookie-file": options.cookieFile = args[index]; browserOptions = true
                default: options.apiKeyFile = args[index]
                }
            case "--api-key-stdin": options.apiKeyStdin = true
            case "--json": options.json = true
            case "--verbose", "-v": options.verbose = true
            case "--allow-keychain-prompt": options.allowKeychainPrompt = true
            case "--help", "-h": options.command = "help"
            default: throw ArgumentError(message: "Unknown option. Run MistralGauge help.")
            }
            index += 1
        }
        guard CredentialExtractor.validProfile(options.profile) else {
            throw ArgumentError(message: "Profile must be a directory name, e.g. Default or ‘Profile 1’.")
        }
        options.auth = explicitAuth ?? (browserOptions ? .browser : .keychain)
        let keyInput = options.apiKeyFile != nil || options.apiKeyStdin
        guard !(options.auth == .keychain && browserOptions),
              !(options.auth == .browser && keyInput),
              !(options.apiKeyFile != nil && options.apiKeyStdin) else {
            throw ArgumentError(message: "Choose one connection method; do not mix API-key and browser options.")
        }
        if options.command == "connect", options.auth != .keychain || !keyInput {
            throw ArgumentError(message: "connect requires --api-key-stdin or --api-key-file; it saves only the provided API key.")
        }
        return options
    }

    static func run(args: [String]) async -> Int32 {
        let options: CLIOptions
        do { options = try parse(args: args) }
        catch { fputs("error: \(error.localizedDescription)\n\n\(helpText)\n", stderr); return 2 }
        if options.command == "help" { print(helpText); return 0 }
        let credentials: MistralCredentials
        do {
            credentials = try resolveCredentials(options)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 3
        }
        do {
            if options.verbose {
                let endpoint = options.auth == .keychain ? MistralAPIClient.budgetURL : MistralAPIClient.browserBudgetURL
                fputs("GET \(endpoint.absoluteString) [\(credentials.source)]\n", stderr)
            }
            let result = try await fetchUsage(credentials: credentials, saveKey: options.command == "connect")
            if options.json {
                let output = MistralUsageOutput(httpStatus: result.status, source: credentials.source,
                    observedAt: ISO8601DateFormatter().string(from: Date()),
                    api: result.usage.api, vibe: result.usage.vibe)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                print(String(decoding: try encoder.encode(output), as: UTF8.self))
            } else {
                print("[\(credentials.source)] HTTP \(result.status)")
                print(usageHuman(result.usage))
            }
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 4
        }
    }

    static func fetchUsage(credentials: MistralCredentials, saveKey: Bool,
                           client: MistralAPIClient = MistralAPIClient(),
                           keyWriter: (String) throws -> Void = VibeCredentialStore.save) async throws
        -> (usage: MistralUsageResponse, status: Int) {
        switch credentials.value {
        case .apiKey(let key):
            let result = try await client.fetchUsage(apiKey: key)
            if saveKey { try keyWriter(key) }
            return result
        case .cookie(let cookie):
            return try await client.fetchUsage(cookieHeader: cookie)
        }
    }

    static func resolveCredentials(_ options: CLIOptions) throws -> MistralCredentials {
        if options.auth == .keychain {
            if options.apiKeyStdin {
                var data = Data()
                while data.count <= 4_096 {
                    let chunk = try FileHandle.standardInput.read(upToCount: 4_097 - data.count) ?? Data()
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }
                guard data.count <= 4_096, let key = String(data: data, encoding: .utf8) else {
                    throw MistralError.credentials("Invalid API key on stdin.")
                }
                return MistralCredentials(value: .apiKey(try VibeCredentialStore.validatedKey(key)), source: "stdin")
            }
            if let path = options.apiKeyFile {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard let key = try? String(contentsOf: url, encoding: .utf8) else {
                    throw MistralError.credentials("Cannot read API key file.")
                }
                return MistralCredentials(value: .apiKey(try VibeCredentialStore.validatedKey(key)), source: "api-key-file")
            }
            return try VibeCredentialStore.resolve(environment: ProcessInfo.processInfo.environment) { service, account in
                try VibeCredentialStore.read(service: service, account: account, allowPrompt: options.allowKeychainPrompt)
            }
        }
        if let path = options.cookieFile {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                throw MistralError.credentials("Cannot read cookie file.")
            }
            return MistralCredentials(value: .cookie(try CredentialExtractor.validatedHeader(raw.trimmingCharacters(in: .newlines))), source: "cookie-file")
        }
        if let raw = ProcessInfo.processInfo.environment["MISTRAL_COOKIE"] {
            return MistralCredentials(value: .cookie(try CredentialExtractor.validatedHeader(raw)), source: "env:MISTRAL_COOKIE")
        }
        return MistralCredentials(value: .cookie(try CredentialExtractor.extract(source: options.source, profile: options.profile,
                                                allowKeychainPrompt: options.allowKeychainPrompt)),
                source: "\(options.source.rawValue):\(options.profile)")
    }

    static func usageHuman(_ usage: MistralUsageResponse) -> String {
        let allowances = usage.vibe != nil ? [("Vibe & Studio", usage.vibe)] : [("API/Studio", usage.api)]
        let lines = allowances.compactMap { label, allowance -> String? in
            guard let allowance else { return nil }
            return String(format: "%@: %.1f%% · %.2f / %.2f %@ used · %.2f remaining · resets in %@",
                          label, allowance.usedPercent, allowance.used, allowance.total,
                          allowance.currency, allowance.remaining, allowance.resetLabel)
        }
        return lines.isEmpty ? "Mistral: allowance unavailable" : lines.joined(separator: "\n")
    }
}
