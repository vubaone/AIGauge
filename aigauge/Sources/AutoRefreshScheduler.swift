import Foundation
import Combine
import AppKit

/// Fires the token-spending "Refresh window" for each service at one or more
/// user-chosen times of day (a comma-separated "HH:mm" list per service).
///
/// Behaviour (per the product spec):
///   • At each scheduled time each day, send one refresh for that service.
///   • If the Mac is asleep at that time, send it as soon as it wakes.
///   • If several scheduled times were missed while asleep (e.g. the Mac was off
///     from before 06:00 until 11:00, or across multiple days), only ONE refresh
///     is sent on wake — missed occurrences coalesce into a single catch-up.
///
/// The coalescing is achieved by tracking, per service, the most recent
/// occurrence we already acted on (`AutoRefreshConfig.lastFired`). On every
/// evaluation we look at the single most-recent scheduled occurrence at or
/// before "now"; if we haven't fired that one yet, we fire once and record it.
@MainActor
final class AutoRefreshScheduler {
    static let shared = AutoRefreshScheduler()

    /// How often we re-check schedules while awake. A scheduled time can fire up
    /// to this late; a minute of slack is fine for a daily quota-window refresh.
    private let tickInterval: TimeInterval = 30

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    /// Begin evaluating schedules: on a periodic tick, on system wake, and
    /// whenever the Claude account list changes (so a catch-up can fire right
    /// after accounts finish loading at launch).
    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }

        UsageStore.shared.$claudeAccounts
            .sink { [weak self] _ in Task { @MainActor in self?.evaluate() } }
            .store(in: &cancellables)

        evaluate()
    }

    @objc private func handleWake() {
        Task { @MainActor in evaluate() }
    }

    /// Seed a freshly enabled (or re-timed) schedule so it does NOT retro-fire
    /// for an occurrence that already passed earlier today. The next fire will be
    /// the next future occurrence. Call this right after the user turns the
    /// checkbox on or edits the time.
    func seedBaseline(for key: String) {
        let s = AppSettings.shared
        let cfg = s.autoRefreshConfig(for: key)
        guard cfg.enabled,
              let occ = Self.mostRecentOccurrence(of: cfg.time, atOrBefore: Date()) else { return }
        s.updateAutoRefreshConfig(for: key) { $0.lastFired = occ.timeIntervalSince1970 }
    }

    /// Check every service and fire any whose scheduled time has arrived (or was
    /// missed) and hasn't been handled yet.
    func evaluate() {
        let now = Date()
        let s = AppSettings.shared
        let store = UsageStore.shared

        for (key, cfg) in s.autoRefreshConfigs {
            guard cfg.enabled,
                  let occ = Self.mostRecentOccurrence(of: cfg.time, atOrBefore: now) else { continue }

            let occTS = occ.timeIntervalSince1970
            // Already acted on this occurrence (1s tolerance for float rounding).
            guard cfg.lastFired + 1 < occTS else { continue }

            // For Claude accounts, wait until the account list has loaded and
            // only fire for accounts that still exist (avoid spending tokens on
            // a stale id). Codex ("codex" key) always proceeds.
            if key != AppSettings.codexOrderKey {
                if store.claudeAccounts.isEmpty { continue }
                if !store.claudeAccounts.contains(where: { $0.id == key }) { continue }
            }

            // Record before firing so a slow refresh can't double-fire on the
            // next tick.
            s.updateAutoRefreshConfig(for: key) { $0.lastFired = occTS }
            fire(key: key)
        }
    }

    private func fire(key: String) {
        let store = UsageStore.shared
        if key == AppSettings.codexOrderKey {
            Task { await store.triggerCodexRefresh() }
        } else {
            Task { await store.triggerClaudeRefresh(accountId: key) }
        }
    }

    // MARK: - Time helpers

    /// Parse a single "HH:mm" (24-hour). Accepts a leading-zero-optional hour ("6:00").
    static func parseHHmm(_ raw: String) -> (hour: Int, minute: Int)? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// Parse a comma-separated list of "HH:mm" times (e.g. "06:00, 10:00, 14:00").
    /// Returns nil if the string is empty or ANY entry is malformed.
    static func parseTimes(_ raw: String) -> [(hour: Int, minute: Int)]? {
        let tokens = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        var out: [(hour: Int, minute: Int)] = []
        for t in tokens {
            guard let hm = parseHHmm(t) else { return nil }
            out.append(hm)
        }
        return out
    }

    /// The most recent scheduled occurrence at or before `date`, considering ALL
    /// times in the (comma-separated) list. This is what coalesces missed times:
    /// if 06:00 and 10:00 both passed while the Mac was asleep, we only ever
    /// compare against the single latest one (10:00), so waking at 11:00 fires
    /// exactly one catch-up rather than one per missed time.
    static func mostRecentOccurrence(of times: String, atOrBefore date: Date) -> Date? {
        guard let list = parseTimes(times) else { return nil }
        let cal = Calendar.current
        var best: Date?
        for (h, m) in list {
            guard let today = cal.date(bySettingHour: h, minute: m, second: 0, of: date) else { continue }
            let occ = today <= date ? today : cal.date(byAdding: .day, value: -1, to: today)
            if let occ = occ, best == nil || occ > best! { best = occ }
        }
        return best
    }
}
