import AppKit

/// Where a provider's token comes from, and how to reopen that place so the
/// user can sign in again once it expires.
///
/// AIGauge never owns a login: a Claude account re-reads its cookie from the
/// browser or app that holds it on every check, and Codex re-reads
/// ~/.codex/auth.json (or the Keychain entry the desktop app writes). So the
/// whole fix for an expired token is getting the user back into that source —
/// the next read then picks the fresh credentials up on its own.
enum TokenSource {
    /// Launch an installed app, optionally opening a page inside it.
    case application(name: String, bundleIds: [String], page: URL?)
    /// Run a login command in a new Terminal window.
    case terminal(name: String, command: String)
    /// Nothing local to open — a page in the default browser.
    case webPage(name: String, url: URL)

    static let claudeLoginPage = URL(string: "https://claude.ai/login")!

    /// Bundle ids of the ChatGPT/Codex desktop app, newest branding first.
    static let codexAppBundleIds = ["com.openai.codex", "com.openai.chat"]

    /// A sign-in link is useful for credential failures, not for an outage or
    /// a malformed backend response.
    static func canReload(after error: String) -> Bool {
        let message = error.lowercased()
        return ["401", "authentication_error", "unauthorized", "unauthenticated",
                "session expired", "invalid token", "missing credentials",
                "cookie", "credential extraction"].contains { message.contains($0) }
    }

    /// The cookie source ids ClaudeGauge persists per account.
    static func forClaude(source raw: String) -> TokenSource {
        let name = humanSourceName(raw)
        switch raw {
        case "claude-desktop":
            // The desktop app owns its own cookie jar; a URL would be handed to
            // the browser instead, so just bring the app forward.
            return .application(name: name,
                                bundleIds: ["com.anthropic.claudefordesktop",
                                            "com.anthropic.claude"],
                                page: nil)
        case "edge":
            return .application(name: name, bundleIds: ["com.microsoft.edgemac"],
                                page: claudeLoginPage)
        case "chrome":
            return .application(name: name, bundleIds: ["com.google.Chrome"],
                                page: claudeLoginPage)
        case "brave":
            return .application(name: name, bundleIds: ["com.brave.Browser"],
                                page: claudeLoginPage)
        case "safari":
            return .application(name: name, bundleIds: ["com.apple.Safari"],
                                page: claudeLoginPage)
        default:
            // "manual" (pasted org id + session key) or an unknown source: the
            // login page is the best we can do, then re-add the account.
            return .webPage(name: "claude.ai", url: claudeLoginPage)
        }
    }

    /// Mirrors CodexGauge's credential resolution order, so the source we offer
    /// to renew is the one it will actually read next time.
    static func forCodex() -> TokenSource {
        let authFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        if FileManager.default.fileExists(atPath: authFile.path) {
            return .terminal(name: "Codex CLI", command: "codex login")
        }
        if installedApplication(bundleIds: codexAppBundleIds) != nil {
            return .application(name: "ChatGPT", bundleIds: codexAppBundleIds, page: nil)
        }
        return .terminal(name: "Codex CLI", command: "codex login")
    }

    var displayName: String {
        switch self {
        case .application(let name, _, _),
             .terminal(let name, _),
             .webPage(let name, _):
            return name
        }
    }

    /// Wording for the menu row / button that performs the reload.
    var actionTitle: String {
        switch self {
        case .application(let name, _, _), .webPage(let name, _):
            return "Reload token — open \(name)"
        case .terminal(_, let command):
            return "Reload token — run `\(command)`"
        }
    }

    var helpText: String {
        switch self {
        case .application(let name, _, _), .webPage(let name, _):
            return "Sign in again in \(name). AIGauge re-reads the token from there — no tokens are spent."
        case .terminal(_, let command):
            return "Opens a Terminal window running `\(command)` so AIGauge can read the renewed token."
        }
    }

    /// Opens the source. Returns false when there was nothing to open.
    @discardableResult
    func open() -> Bool {
        let workspace = NSWorkspace.shared
        switch self {
        case .application(_, let bundleIds, let page):
            if let app = Self.installedApplication(bundleIds: bundleIds) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                if let page = page {
                    workspace.open([page], withApplicationAt: app,
                                   configuration: config, completionHandler: nil)
                } else {
                    workspace.openApplication(at: app, configuration: config,
                                              completionHandler: nil)
                }
                return true
            }
            // Uninstalled since the account was added — the login page in the
            // default browser still beats doing nothing.
            if let page = page { return workspace.open(page) }
            return false

        case .terminal(_, let command):
            return Self.runInTerminal(command)

        case .webPage(_, let url):
            return workspace.open(url)
        }
    }

    static func installedApplication(bundleIds: [String]) -> URL? {
        bundleIds.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    /// Hands the command to Terminal through a throwaway `.command` script —
    /// a login shell so the user's PATH (and therefore `codex`) resolves.
    private static func runInTerminal(_ command: String) -> Bool {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("aigauge-reload-token-\(UUID().uuidString).command")
        let body = """
        #!/bin/zsh -l
        trap 'rm -- "$0"' EXIT
        echo "AIGauge — renewing your login. Follow the prompts below."
        \(command)
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: script.path)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(script)
    }
}
