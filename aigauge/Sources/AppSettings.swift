import Foundation
import Combine
import SwiftUI

/// Which providers a multi-choice setting covers.
/// Used for both the tray status item and the dropdown menu sections.
enum BackendSelection: String, CaseIterable, Identifiable {
    case claude, codex, both, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .both:   return "Both"
        case .none:   return "None"
        }
    }
    var includesClaude: Bool { self == .claude || self == .both }
    var includesCodex:  Bool { self == .codex  || self == .both }
}

/// Back-compat alias — older code referred to this as TrayBackend.
typealias TrayBackend = BackendSelection

/// Per-service scheduled "auto-refresh at HH:mm" configuration, keyed by a
/// Claude account id or the Codex order key. Codex schedules are enabled only
/// when its current usage response exposes a 5-hour window. `lastFired` tracks
/// the last handled occurrence so wake catch-ups coalesce and fire exactly once.
struct AutoRefreshConfig: Codable, Equatable {
    var enabled: Bool = false
    var time: String = ""          // one or more "HH:mm" (24h), comma-separated; empty = unset
    var lastFired: Double = 0      // timeIntervalSince1970 of last handled occurrence
}

/// Observable wrapper over UserDefaults. Bindings on this auto-persist.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // --- Tray status item ---
    @Published var trayBackend: BackendSelection {
        didSet { defaults.set(trayBackend.rawValue, forKey: "trayBackend") }
    }
    @Published var trayShowLabel: Bool {
        didSet { defaults.set(trayShowLabel, forKey: "trayShowLabel") }
    }
    /// Whether the tray percentage carries a trailing "%" (off → just the number).
    @Published var trayShowPercentSign: Bool {
        didSet { defaults.set(trayShowPercentSign, forKey: "trayShowPercentSign") }
    }
    @Published var claudeColorHex: String {
        didSet { defaults.set(claudeColorHex, forKey: "claudeColorHex") }
    }
    @Published var codexColorHex: String {
        didSet { defaults.set(codexColorHex, forKey: "codexColorHex") }
    }

    // --- Tray dropdown menu sections ---
    @Published var menuBackends: BackendSelection {
        didSet { defaults.set(menuBackends.rawValue, forKey: "menuBackends") }
    }

    // --- General behaviour ---
    @Published var autoRefreshSeconds: Int {
        didSet { defaults.set(autoRefreshSeconds, forKey: "autoRefreshSeconds") }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin") }
    }
    @Published var closeToTray: Bool {
        didSet { defaults.set(closeToTray, forKey: "closeToTray") }
    }
    /// Whether to show the "Trigger quota refresh" confirmation before spending
    /// tokens from the tray menu. The dialog's "Don't ask again" checkbox sets
    /// this false; the General tab can turn it back on.
    @Published var confirmQuotaRefresh: Bool {
        didSet { defaults.set(confirmQuotaRefresh, forKey: "confirmQuotaRefresh") }
    }

    // --- CLI overrides ---
    @Published var claudeGaugePath: String {
        didSet { defaults.set(claudeGaugePath, forKey: "claudeGaugePath") }
    }
    @Published var codexGaugePath: String {
        didSet { defaults.set(codexGaugePath, forKey: "codexGaugePath") }
    }

    // --- Per-Claude-account overrides (GUI-only, keyed by account id) ---
    // The CLI's account `label` stays the selector; these only affect display.
    @Published var accountAliases: [String: String] {
        didSet { persistDict(accountAliases, forKey: "accountAliases") }
    }
    @Published var accountColors: [String: String] {
        didSet { persistDict(accountColors, forKey: "accountColors") }
    }
    /// User-defined display order of account ids. Ids missing here sort to the
    /// end (in their original CLI order); unknown ids are ignored.
    @Published var accountOrder: [String] {
        didSet { defaults.set(accountOrder, forKey: "accountOrder") }
    }

    /// Scheduled refresh configs keyed by Claude account id or the Codex order
    /// key. Persisted as JSON.
    @Published var autoRefreshConfigs: [String: AutoRefreshConfig] {
        didSet { persistAutoRefreshConfigs() }
    }

    /// Distinct fallback colors handed out to accounts that have no explicit
    /// color yet, cycled by their position in the account list.
    static let accountColorPalette: [String] = [
        "#22D3EE", // cyan
        "#A78BFA", // violet
        "#F472B6", // pink
        "#34D399", // emerald
        "#FBBF24", // amber
        "#60A5FA", // blue
    ]

    private init() {
        let trayRaw = defaults.string(forKey: "trayBackend") ?? BackendSelection.claude.rawValue
        self.trayBackend       = BackendSelection(rawValue: trayRaw) ?? .claude

        let menuRaw = defaults.string(forKey: "menuBackends") ?? BackendSelection.both.rawValue
        self.menuBackends      = BackendSelection(rawValue: menuRaw) ?? .both

        self.trayShowLabel     = (defaults.object(forKey: "trayShowLabel") as? Bool) ?? true
        self.trayShowPercentSign = (defaults.object(forKey: "trayShowPercentSign") as? Bool) ?? true
        self.claudeColorHex    = defaults.string(forKey: "claudeColorHex") ?? "#D97706" // amber
        self.codexColorHex     = defaults.string(forKey: "codexColorHex")  ?? "#10A37F" // OpenAI green

        self.autoRefreshSeconds = defaults.object(forKey: "autoRefreshSeconds") as? Int ?? 60
        self.launchAtLogin     = defaults.bool(forKey: "launchAtLogin")
        self.closeToTray       = (defaults.object(forKey: "closeToTray") as? Bool) ?? true
        self.confirmQuotaRefresh = (defaults.object(forKey: "confirmQuotaRefresh") as? Bool) ?? true
        self.claudeGaugePath   = defaults.string(forKey: "claudeGaugePath") ?? ""
        self.codexGaugePath    = defaults.string(forKey: "codexGaugePath") ?? ""

        self.accountAliases    = Self.loadDict(forKey: "accountAliases", from: defaults)
        self.accountColors     = Self.loadDict(forKey: "accountColors",  from: defaults)
        self.accountOrder      = (defaults.array(forKey: "accountOrder") as? [String]) ?? []

        if let data = defaults.data(forKey: "autoRefreshConfigs"),
           let decoded = try? JSONDecoder().decode([String: AutoRefreshConfig].self, from: data) {
            self.autoRefreshConfigs = decoded
        } else {
            self.autoRefreshConfigs = [:]
        }
    }

    // MARK: - Auto-refresh schedule accessors

    /// Config for a service key, or a disabled default when none is saved yet.
    func autoRefreshConfig(for key: String) -> AutoRefreshConfig {
        autoRefreshConfigs[key] ?? AutoRefreshConfig()
    }

    /// Mutate (creating if absent) the config for a service key. Reassigning the
    /// dictionary triggers persistence and republishes to any observing views.
    func updateAutoRefreshConfig(for key: String, _ mutate: (inout AutoRefreshConfig) -> Void) {
        var c = autoRefreshConfigs[key] ?? AutoRefreshConfig()
        mutate(&c)
        autoRefreshConfigs[key] = c
    }

    private func persistAutoRefreshConfigs() {
        if let data = try? JSONEncoder().encode(autoRefreshConfigs) {
            defaults.set(data, forKey: "autoRefreshConfigs")
        }
    }

    // MARK: - Tray item ordering

    /// `accountOrder` is the unified left-to-right tray sequence. Entries are
    /// Claude account UUIDs or this sentinel for the Codex chunk.
    static let codexOrderKey = "codex"

    /// Sort ids by the saved tray order; ids not present keep their incoming
    /// order and trail the explicitly-ranked ones. Works for a mix of account
    /// ids and the Codex sentinel (unrelated ids are simply ignored).
    func orderedAccountIds(_ ids: [String]) -> [String] {
        let rank = Dictionary(uniqueKeysWithValues: accountOrder.enumerated().map { ($1, $0) })
        return ids.enumerated().sorted { lhs, rhs in
            let lr = rank[lhs.element] ?? Int.max
            let rr = rank[rhs.element] ?? Int.max
            if lr != rr { return lr < rr }
            return lhs.offset < rhs.offset   // stable: preserve original order
        }.map(\.element)
    }

    /// Persist a new explicit tray order (called after a drag-reorder).
    func setAccountOrder(_ ids: [String]) {
        accountOrder = ids
    }

    // MARK: - Per-account override accessors

    /// Display name for an account: the user's alias if set, else the CLI label.
    func displayLabel(forAccountId id: String, fallback: String) -> String {
        let alias = accountAliases[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let alias = alias, !alias.isEmpty { return alias }
        return fallback
    }

    /// Set (or clear, when blank/equal to the CLI label) an account's alias.
    func setAlias(_ alias: String, forAccountId id: String, cliLabel: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == cliLabel {
            accountAliases.removeValue(forKey: id)
        } else {
            accountAliases[id] = trimmed
        }
    }

    /// Resolved color hex for an account: explicit color, else a palette color
    /// chosen by `index` so accounts stay visually distinct out of the box.
    func colorHex(forAccountId id: String, index: Int) -> String {
        if let hex = accountColors[id], !hex.isEmpty { return hex }
        let palette = Self.accountColorPalette
        return palette[index % palette.count]
    }

    func setColorHex(_ hex: String, forAccountId id: String) {
        accountColors[id] = hex
    }

    // MARK: - Dictionary persistence helpers

    private func persistDict(_ dict: [String: String], forKey key: String) {
        defaults.set(dict, forKey: key)
    }

    private static func loadDict(forKey key: String, from defaults: UserDefaults) -> [String: String] {
        (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
    }
}

// MARK: - Color <-> hex helpers (used by ColorPicker bindings and the tray)

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: s).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    var hexString: String {
        let ns = (NSColor(self).usingColorSpace(.sRGB)) ?? .black
        let r = Int(round(ns.redComponent   * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent  * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: s).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255
        let g = CGFloat((int >> 8)  & 0xFF) / 255
        let b = CGFloat( int        & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
