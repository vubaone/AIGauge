import Foundation
import Combine

/// Holds the latest snapshots from each backend and exposes refresh/trigger actions.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    /// Per-account Claude usage (stacked-section UI). One entry per saved account.
    @Published var claudeAccounts: [ClaudeAccountSnapshot] = []
    @Published var claudeLastUpdated: Date = .distantPast
    /// Set when fetching usage failed before any per-account data could be read
    /// (e.g. CLI not found, no accounts configured).
    @Published var claudeGlobalError: String?

    @Published var codex:  UsageSnapshot = .empty("Codex")
    @Published var isLoadingClaude = false
    @Published var isLoadingCodex  = false
    @Published var lastActionMessage: String?

    /// Highest 5-hour utilization across accounts — what the tray shows.
    var claudePrimaryPercent: Double? {
        claudeAccounts.compactMap { $0.primaryPercent }.max()
    }
    /// First per-account error, for the tray tooltip / "!" indicator.
    var claudeFirstError: String? {
        claudeGlobalError ?? claudeAccounts.compactMap { $0.error }.first
    }

    /// The unified, reorderable tray sequence: every Claude account plus Codex,
    /// sorted by the saved cross-provider order. Drives the General-tab strip
    /// and the tray title. Does NOT apply the trayBackend provider filter —
    /// callers (the tray) decide which kinds to actually render.
    var orderedTrayItems: [TrayItem] {
        var items: [TrayItem] = claudeAccounts.map { acct in
            TrayItem(id: acct.id, kind: .claude, label: acct.shownLabel,
                     colorHex: acct.colorHex, percent: acct.primaryPercent,
                     hasError: acct.error != nil)
        }
        items.append(TrayItem(
            id: AppSettings.codexOrderKey, kind: .codex, label: "Codex",
            colorHex: AppSettings.shared.codexColorHex,
            percent: codex.primaryPercent, hasError: codex.error != nil))

        let order = AppSettings.shared.orderedAccountIds(items.map(\.id))
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return order.compactMap { byId[$0] }
    }

    private var timerCancellable: AnyCancellable?
    private var settingsObserver: AnyCancellable?

    private init() {
        configureTimer(interval: AppSettings.shared.autoRefreshSeconds)
        settingsObserver = AppSettings.shared.$autoRefreshSeconds.sink { [weak self] s in
            self?.configureTimer(interval: s)
        }
        // Fire one refresh on startup
        Task { await self.refreshAll() }
    }

    private func configureTimer(interval: Int) {
        timerCancellable?.cancel()
        guard interval > 0 else { return }
        timerCancellable = Timer.publish(every: TimeInterval(interval), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.refreshAll() }
            }
    }

    // MARK: - Refresh (read-only — fetches latest usage)

    func refreshAll() async {
        async let a: () = refreshClaude()
        async let b: () = refreshCodex()
        _ = await (a, b)
    }

    func refreshClaude() async {
        isLoadingClaude = true
        defer { isLoadingClaude = false }

        // 1. Discover configured accounts.
        let accounts: [ClaudeAccountJSON]
        do {
            accounts = try await BackendRunner.runJSON(
                .claude, args: ["accounts", "list"], as: [ClaudeAccountJSON].self)
        } catch {
            // Old CLI without `accounts`, or it failed — fall back to single fetch.
            await refreshClaudeSingleFallback()
            return
        }

        guard !accounts.isEmpty else {
            self.claudeAccounts = []
            self.claudeGlobalError = "No Claude accounts configured. Add one in Settings → Claude."
            self.claudeLastUpdated = Date()
            return
        }

        // 2. Fetch usage for all accounts in one call.
        do {
            let arr = try await BackendRunner.runJSON(
                .claude, args: ["usage", "--all"], as: [ClaudeAccountUsageJSON].self)
            // Preserve the account list order from `accounts list`.
            let byId = Dictionary(uniqueKeysWithValues: arr.map { ($0.accountId, $0) })
            let snapshots = accounts.map { acct -> ClaudeAccountSnapshot in
                if let e = byId[acct.id] {
                    return ClaudeAccountSnapshot.from(e)
                }
                return ClaudeAccountSnapshot.failure(
                    id: acct.id, label: acct.label, source: acct.source, "no data returned")
            }
            self.claudeAccounts = Self.applyOverrides(to: snapshots)
            self.claudeGlobalError = nil
            self.claudeLastUpdated = Date()
        } catch {
            // Don't leave stale percentages looking valid: replace each known
            // account with an errored snapshot so the tray shows "!" not an old %.
            let msg = error.localizedDescription
            let errored = accounts.map {
                ClaudeAccountSnapshot.failure(id: $0.id, label: $0.label, source: $0.source, msg)
            }
            self.claudeAccounts = Self.applyOverrides(to: errored)
            self.claudeGlobalError = msg
            self.claudeLastUpdated = Date()
        }
    }

    /// Fallback for an older ClaudeGauge binary that only understands `usage`.
    private func refreshClaudeSingleFallback() async {
        do {
            let j = try await BackendRunner.runJSON(.claude, args: ["usage"], as: ClaudeUsageJSON.self)
            let single = ClaudeAccountSnapshot.fromSingle(
                j, account: ClaudeAccountJSON(id: "single", label: "Claude",
                                              source: "manual", organizationId: nil))
            self.claudeAccounts = Self.applyOverrides(to: [single])
            self.claudeGlobalError = nil
        } catch {
            self.claudeAccounts = []
            self.claudeGlobalError = error.localizedDescription
        }
        self.claudeLastUpdated = Date()
    }

    /// Sort by the saved display order, then stamp each snapshot with its alias
    /// and resolved color. Color falls back to a palette entry keyed by the
    /// final (sorted) position so a stable account keeps a stable default color.
    static func applyOverrides(to snapshots: [ClaudeAccountSnapshot]) -> [ClaudeAccountSnapshot] {
        let s = AppSettings.shared
        let order = s.orderedAccountIds(snapshots.map(\.id))
        let byId = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        let sorted = order.compactMap { byId[$0] }
        return sorted.enumerated().map { idx, snap in
            var snap = snap
            snap.displayLabel = s.displayLabel(forAccountId: snap.id, fallback: snap.label)
            snap.colorHex = s.colorHex(forAccountId: snap.id, index: idx)
            return snap
        }
    }

    /// Apply a new unified tray order (Claude accounts + Codex) from a drag and
    /// re-decorate the accounts live. Reassigning `claudeAccounts` also nudges
    /// the tray to rebuild from the new `orderedTrayItems`.
    func reorderTrayItems(_ orderedIds: [String]) {
        AppSettings.shared.setAccountOrder(orderedIds)
        claudeAccounts = Self.applyOverrides(to: claudeAccounts)
    }

    /// Set an account's display alias (GUI-only) and re-decorate live.
    func setClaudeAlias(_ alias: String, forAccountId id: String) {
        guard let acct = claudeAccounts.first(where: { $0.id == id }) else { return }
        AppSettings.shared.setAlias(alias, forAccountId: id, cliLabel: acct.label)
        claudeAccounts = Self.applyOverrides(to: claudeAccounts)
    }

    /// Set an account's color (GUI-only) and re-decorate live.
    func setClaudeColor(_ hex: String, forAccountId id: String) {
        AppSettings.shared.setColorHex(hex, forAccountId: id)
        claudeAccounts = Self.applyOverrides(to: claudeAccounts)
    }

    func refreshCodex() async {
        isLoadingCodex = true
        defer { isLoadingCodex = false }
        do {
            let j = try await BackendRunner.runJSON(.codex, args: ["usage"], as: CodexUsageJSON.self)
            self.codex = .fromCodex(j)
        } catch {
            self.codex = .failure("Codex", error.localizedDescription)
        }
    }

    // MARK: - Trigger (consumes tokens — sends a tiny prompt)

    /// Trigger the 5-hour window for one specific account (by id) or, when nil,
    /// the sole account if there is exactly one.
    func triggerClaudeRefresh(accountId: String? = nil) async {
        isLoadingClaude = true
        defer { isLoadingClaude = false }
        var args = ["refresh", "--json"]
        if let id = accountId, id != "single" {
            args += ["--account", id]
        }
        do {
            _ = try await BackendRunner.run(kind: .claude, args: args)
            lastActionMessage = "Claude refresh fired (~2 tokens). Re-checking usage…"
            // Give the server a moment to register the started/extended window,
            // then re-read so the on-screen usage windows show the new state.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshClaude()
        } catch {
            lastActionMessage = "Claude refresh failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Claude account management (shell out to ClaudeGauge accounts …)

    /// List configured accounts (does not fetch usage).
    func listClaudeAccounts() async -> [ClaudeAccountJSON] {
        (try? await BackendRunner.runJSON(.claude, args: ["accounts", "list"],
                                          as: [ClaudeAccountJSON].self)) ?? []
    }

    /// List cookie sources detected on this machine.
    func listClaudeSources() async -> [ClaudeSourceJSON] {
        (try? await BackendRunner.runJSON(.claude, args: ["sources"],
                                          as: [ClaudeSourceJSON].self)) ?? []
    }

    /// Add an account from a cookie source. Returns an error message, or nil on success.
    func addClaudeAccount(label: String, sourceId: String) async -> String? {
        do {
            _ = try await BackendRunner.run(
                kind: .claude,
                args: ["accounts", "add", "--label", label, "--source", sourceId, "--json"])
            await refreshClaude()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Remove an account by id (or label). Returns an error message, or nil on success.
    func removeClaudeAccount(idOrLabel: String) async -> String? {
        do {
            _ = try await BackendRunner.run(
                kind: .claude, args: ["accounts", "remove", "--account", idOrLabel, "--json"])
            await refreshClaude()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func triggerCodexRefresh() async {
        isLoadingCodex = true
        defer { isLoadingCodex = false }
        do {
            _ = try await BackendRunner.run(kind: .codex, args: ["refresh", "--json"])
            lastActionMessage = "Codex refresh fired (~24 tokens). Re-checking usage…"
            // Give the server a moment to register the started/extended window,
            // then re-read so the on-screen usage windows show the new state.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshCodex()
        } catch {
            lastActionMessage = "Codex refresh failed: \(error.localizedDescription)"
        }
    }

}
