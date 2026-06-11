import Foundation

// MARK: - Claude (mirrors ClaudeGauge --json shape)

struct ClaudeUsageJSON: Codable {
    let fiveHour: Period?
    let sevenDay: Period?
    let sevenDayOpus: Period?
    let sevenDayOauthApps: Period?

    struct Period: Codable {
        let utilization: Double
        let resetsAt: String?
        let timeUntilReset: String?
    }
}

/// One element of `ClaudeGauge usage --all --json` (the multi-account array form).
struct ClaudeAccountUsageJSON: Codable {
    let accountId: String
    let label: String
    let source: String
    let organizationId: String?
    let usage: ClaudeUsageJSON?
    let error: String?
}

/// One element of `ClaudeGauge accounts list --json`.
struct ClaudeAccountJSON: Codable, Identifiable {
    let id: String
    let label: String
    let source: String          // "claude-desktop" | "edge" | "chrome" | "brave" | "manual"
    let organizationId: String?
}

/// One element of `ClaudeGauge sources --json`.
struct ClaudeSourceJSON: Codable, Identifiable {
    let id: String              // "claude-desktop" | "edge" | ...
    let name: String            // "Claude Desktop" | "Microsoft Edge" | ...
    let available: Bool
    var idValue: String { id }
}

// MARK: - Codex (mirrors CodexGauge --json shape)

struct CodexUsageJSON: Codable {
    let httpStatus: Int?
    let planType: String?
    let email: String?
    let rateLimit: RateLimit?

    struct RateLimit: Codable {
        let allowed: Bool?
        let limitReached: Bool?
        let primaryWindow: Window?
        let secondaryWindow: Window?
    }

    struct Window: Codable {
        let usedPercent: Double?
        let limitWindowSeconds: Int?
        let resetAfterSeconds: Int?
        let resetAt: Int?
        let resetLabel: String?
        let window: String?
    }
}

// MARK: - Normalised snapshot used by the UI / tray

struct UsageWindow: Identifiable {
    let id = UUID()
    let label: String        // "5-hour", "7-day", "Opus 7d"
    let percent: Double      // 0-100
    let resetText: String    // "4 hr 12 min" / "n/a"
}

struct UsageSnapshot {
    let serviceName: String                 // "Claude" / "Codex"
    let windows: [UsageWindow]
    let primaryPercent: Double?             // for tray display
    let lastUpdated: Date
    let error: String?

    static func empty(_ service: String) -> UsageSnapshot {
        UsageSnapshot(serviceName: service, windows: [], primaryPercent: nil,
                      lastUpdated: .distantPast, error: nil)
    }

    static func failure(_ service: String, _ err: String) -> UsageSnapshot {
        UsageSnapshot(serviceName: service, windows: [], primaryPercent: nil,
                      lastUpdated: Date(), error: err)
    }
}

/// Usage for one Claude account — what the stacked-section UI renders per row.
struct ClaudeAccountSnapshot: Identifiable {
    let id: String              // account UUID string (or "single" for legacy)
    let label: String           // CLI label (also the --account selector)
    let source: String          // raw source id; "manual" if none
    let windows: [UsageWindow]
    let primaryPercent: Double?
    let error: String?

    /// User-facing name (alias override if set, else the CLI label). Filled in
    /// by UsageStore from AppSettings; defaults to `label` until then.
    var displayLabel: String = ""
    /// Resolved per-account color hex used in the tray / UI accents.
    var colorHex: String = "#22D3EE"

    var sourceDisplayName: String { humanSourceName(source) }

    /// The name actually shown to the user (alias or CLI label).
    var shownLabel: String { displayLabel.isEmpty ? label : displayLabel }
}

/// One reorderable unit shown in the tray and the General-tab reorder strip.
/// A Claude account (identified by its account id) or the single Codex chunk.
struct TrayItem: Identifiable {
    enum Kind { case claude, codex }

    let id: String          // account UUID, or AppSettings.codexOrderKey for Codex
    let kind: Kind
    let label: String       // shown name ("Team" / "Codex")
    let colorHex: String
    let percent: Double?    // primary (5-hour) utilization
    let hasError: Bool

    var isCodex: Bool { kind == .codex }
}

/// Map a raw source id to a human label (kept in sync with CredentialExtractor.Source).
func humanSourceName(_ raw: String) -> String {
    switch raw {
    case "claude-desktop": return "Claude Desktop"
    case "edge":           return "Microsoft Edge"
    case "chrome":         return "Google Chrome"
    case "brave":          return "Brave Browser"
    case "safari":         return "Safari"
    case "manual":         return "Manual"
    default:               return raw.capitalized
    }
}

extension ClaudeAccountSnapshot {
    /// Build the per-window rows for a single account's usage payload.
    static func windows(from j: ClaudeUsageJSON) -> [UsageWindow] {
        var w: [UsageWindow] = []
        if let p = j.fiveHour {
            w.append(UsageWindow(label: "5 hours", percent: p.utilization,
                                 resetText: p.timeUntilReset ?? "n/a"))
        }
        if let p = j.sevenDay {
            w.append(UsageWindow(label: "1 week", percent: p.utilization,
                                 resetText: p.timeUntilReset ?? "n/a"))
        }
        if let p = j.sevenDayOpus {
            w.append(UsageWindow(label: "1 week (Opus)", percent: p.utilization,
                                 resetText: p.timeUntilReset ?? "n/a"))
        }
        return w
    }

    /// From the `usage --all --json` array element.
    static func from(_ e: ClaudeAccountUsageJSON) -> ClaudeAccountSnapshot {
        let windows = e.usage.map { Self.windows(from: $0) } ?? []
        return ClaudeAccountSnapshot(
            id: e.accountId,
            label: e.label,
            source: e.source,
            windows: windows,
            primaryPercent: e.usage?.fiveHour?.utilization,
            error: e.error
        )
    }

    /// From the legacy single-object `usage --json` form, tagged with an account.
    static func fromSingle(_ j: ClaudeUsageJSON, account: ClaudeAccountJSON) -> ClaudeAccountSnapshot {
        ClaudeAccountSnapshot(
            id: account.id,
            label: account.label,
            source: account.source,
            windows: Self.windows(from: j),
            primaryPercent: j.fiveHour?.utilization,
            error: nil
        )
    }

    static func failure(id: String, label: String, source: String, _ err: String) -> ClaudeAccountSnapshot {
        ClaudeAccountSnapshot(id: id, label: label, source: source,
                              windows: [], primaryPercent: nil, error: err)
    }
}

extension UsageSnapshot {
    static func fromClaude(_ j: ClaudeUsageJSON) -> UsageSnapshot {
        var w: [UsageWindow] = []
        if let p = j.fiveHour {
            w.append(UsageWindow(label: "5 hours", percent: p.utilization,
                                 resetText: p.timeUntilReset ?? "n/a"))
        }
        if let p = j.sevenDay {
            w.append(UsageWindow(label: "1 week",  percent: p.utilization,
                                 resetText: p.timeUntilReset ?? "n/a"))
        }
        if let p = j.sevenDayOpus {
            w.append(UsageWindow(label: "1 week (Opus)", percent: p.utilization,
                                 resetText: p.timeUntilReset ?? "n/a"))
        }
        return UsageSnapshot(serviceName: "Claude", windows: w,
                             primaryPercent: j.fiveHour?.utilization,
                             lastUpdated: Date(), error: nil)
    }

    static func fromCodex(_ j: CodexUsageJSON) -> UsageSnapshot {
        var w: [UsageWindow] = []
        if let p = j.rateLimit?.primaryWindow {
            w.append(UsageWindow(label: humanWindowLabel(seconds: p.limitWindowSeconds),
                                 percent: p.usedPercent ?? 0,
                                 resetText: p.resetLabel ?? "n/a"))
        }
        if let p = j.rateLimit?.secondaryWindow {
            w.append(UsageWindow(label: humanWindowLabel(seconds: p.limitWindowSeconds),
                                 percent: p.usedPercent ?? 0,
                                 resetText: p.resetLabel ?? "n/a"))
        }
        return UsageSnapshot(serviceName: "Codex", windows: w,
                             primaryPercent: j.rateLimit?.primaryWindow?.usedPercent,
                             lastUpdated: Date(), error: nil)
    }
}

/// "18000" → "5 hours", "604800" → "1 week", etc. Pluralises correctly.
func humanWindowLabel(seconds: Int?) -> String {
    guard let s = seconds, s > 0 else { return "—" }
    func plural(_ n: Int, _ unit: String) -> String {
        "\(n) \(unit)\(n == 1 ? "" : "s")"
    }
    if s < 3600   { return plural(s / 60, "minute") }
    if s < 86400  { return plural(s / 3600, "hour") }
    if s < 604800 { return plural(s / 86400, "day") }
    return plural(s / 604800, "week")
}
