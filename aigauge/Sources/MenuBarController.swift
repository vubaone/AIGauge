import AppKit
import Combine
import SwiftUI

/// Owns the NSStatusItem in the menu bar and the settings NSWindow.
@MainActor
final class MenuBarController: NSObject {
    /// Keeps a verbose backend error from widening the entire dropdown beyond
    /// the comfortable size of the normal usage rows.
    static let maximumMenuErrorWidth: CGFloat = 280

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Persist the user's chosen slot across launches (⌘-drag to move it,
        // e.g. to the right of the notch so it isn't hidden).
        statusItem.autosaveName = "AIGaugeStatusItem"

        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent",
                                accessibilityDescription: "AIGauge")
            btn.imagePosition = .imageLeft
            btn.title = ""
        }

        rebuild()

        // Coalesce all redraw-triggering signals onto the main runloop tick.
        // `.receive(on: .main)` defers each closure so we always see the
        // post-write value, not the pre-write one (avoids @Published willSet
        // ordering bugs).
        let store = UsageStore.shared
        let settings = AppSettings.shared

        Publishers.Merge4(
            store.$claudeAccounts.map { _ in () },
            store.$codex.map  { _ in () },
            settings.$trayBackend.map  { _ in () },
            settings.$menuBackends.map { _ in () }
        )
        .merge(with: Publishers.Merge4(
            settings.$trayShowLabel.map       { _ in () },
            settings.$trayShowPercentSign.map { _ in () },
            settings.$claudeColorHex.map      { _ in () },
            settings.$codexColorHex.map       { _ in () }
        ))
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.rebuild() }
        .store(in: &cancellables)
    }

    // MARK: - Rebuild

    private func rebuild() {
        updateTitle()
        buildMenu()
    }

    // MARK: - Tray title

    private func updateTitle() {
        guard let btn = statusItem.button else { return }
        let s = AppSettings.shared

        let codexPct  = UsageStore.shared.codex.primaryPercent
        let codexErr  = UsageStore.shared.codex.error

        let title = NSMutableAttributedString()

        /// Append one chunk: optional name (label color) + a percent (or "!"/"…")
        /// in the chunk's own color.
        func appendPart(label: String, pct: Double?, colorHex: String, err: Bool) {
            if title.length > 0 {
                title.append(NSAttributedString(string: "  "))
            }
            if s.trayShowLabel, !label.isEmpty {
                title.append(NSAttributedString(string: "\(label) ",
                    attributes: [.foregroundColor: NSColor.labelColor]))
            }
            let valueStr: String
            if err {
                valueStr = "!"
            } else if let p = pct {
                valueStr = s.trayShowPercentSign
                    ? String(format: "%.0f%%", p)
                    : String(format: "%.0f", p)
            } else {
                valueStr = "…"
            }
            title.append(NSAttributedString(string: valueStr,
                attributes: [.foregroundColor: NSColor(hex: colorHex)]))
        }

        // Walk the unified ordered tray sequence (Claude accounts + Codex),
        // emitting only the kinds the trayBackend filter allows. Claude chunks
        // are named "(Alias):"; Codex is named "Codex".
        let backend = s.trayBackend
        var emittedClaude = false
        var anyClaudeEmitted = false  // for the "Claude" prefix on the first one
        let items = UsageStore.shared.orderedTrayItems

        // Zero-accounts fallback: a single aggregated "Claude" chunk.
        let claudeAccountsEmpty = UsageStore.shared.claudeAccounts.isEmpty

        for item in items {
            switch item.kind {
            case .claude:
                guard backend.includesClaude else { continue }
                if claudeAccountsEmpty { continue }   // handled below
                let name: String
                if s.trayShowLabel {
                    name = anyClaudeEmitted ? "(\(item.label)):" : "Claude (\(item.label)):"
                } else {
                    name = ""
                }
                appendPart(label: name, pct: item.percent, colorHex: item.colorHex, err: item.hasError)
                anyClaudeEmitted = true
                emittedClaude = true
            case .codex:
                guard backend.includesCodex else { continue }
                appendPart(label: "Codex", pct: codexPct, colorHex: s.codexColorHex, err: codexErr != nil)
            }
        }

        // No Claude accounts but Claude is enabled → one aggregated chunk.
        if backend.includesClaude && claudeAccountsEmpty && !emittedClaude {
            // Prepend so it still leads the line.
            let agg = NSMutableAttributedString()
            if s.trayShowLabel {
                agg.append(NSAttributedString(string: "Claude ",
                    attributes: [.foregroundColor: NSColor.labelColor]))
            }
            let err = UsageStore.shared.claudeFirstError != nil
            let valueStr: String
            if err {
                valueStr = "!"
            } else if let p = UsageStore.shared.claudePrimaryPercent {
                valueStr = s.trayShowPercentSign ? String(format: "%.0f%%", p) : String(format: "%.0f", p)
            } else {
                valueStr = "…"
            }
            agg.append(NSAttributedString(string: valueStr,
                attributes: [.foregroundColor: NSColor(hex: s.claudeColorHex)]))
            if title.length > 0 { agg.append(NSAttributedString(string: "  ")) }
            agg.append(title)
            title.setAttributedString(agg)
        }

        if title.length == 0 {
            btn.attributedTitle = NSAttributedString(string: "")
            btn.title = ""
        } else {
            // Leading space gives a small gap after the icon.
            let prefix = NSMutableAttributedString(string: " ")
            prefix.append(title)
            btn.attributedTitle = prefix
        }

        // Tooltip always carries the full picture, one line per Claude account.
        var tipParts: [String] = []
        let accounts = UsageStore.shared.claudeAccounts
        if accounts.isEmpty {
            if let e = UsageStore.shared.claudeFirstError { tipParts.append("Claude: \(e)") }
            else if let p = UsageStore.shared.claudePrimaryPercent {
                tipParts.append(String(format: "Claude: %.1f%%", p))
            }
        } else {
            for acct in accounts {
                if let e = acct.error {
                    tipParts.append("Claude (\(acct.shownLabel)): \(e)")
                } else if let p = acct.primaryPercent {
                    tipParts.append(String(format: "Claude (%@): %.1f%%", acct.shownLabel, p))
                }
            }
        }
        if let e = codexErr  { tipParts.append("Codex: \(e)") }
        else if let p = codexPct  { tipParts.append(String(format: "Codex: %.1f%%", p)) }
        btn.toolTip = tipParts.isEmpty ? "AIGauge" : tipParts.joined(separator: " · ")
    }

    // MARK: - Dropdown menu

    private func buildMenu() {
        let menu = NSMenu()
        let m = AppSettings.shared.menuBackends

        if m.includesClaude {
            addClaudeAccountSections(to: menu)
        }
        if m.includesCodex {
            if m.includesClaude { menu.addItem(.separator()) }
            addProviderSection(to: menu,
                               title: "Codex",
                               snapshot: UsageStore.shared.codex,
                               refreshSelector: UsageStore.shared.codex.supportsWindowRefresh
                                   ? #selector(triggerCodex) : nil,
                               refreshTitle: "Refresh 5-hour window (~24 tokens)",
                               isLoading: UsageStore.shared.isLoadingCodex)
        }
        if m != .none {
            menu.addItem(.separator())
        }

        let open = NSMenuItem(title: "Open Settings…",
                              action: #selector(openSettings),
                              keyEquivalent: ",")
        open.target = self
        menu.addItem(open)

        let reAll = NSMenuItem(title: "Refresh Usage Now",
                               action: #selector(refreshNow),
                               keyEquivalent: "r")
        reAll.target = self
        menu.addItem(reAll)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit AIGauge",
                              action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// One menu section per Claude account, each with its own refresh item.
    private func addClaudeAccountSections(to menu: NSMenu) {
        let store = UsageStore.shared
        let loading = store.isLoadingClaude

        if let err = store.claudeGlobalError, store.claudeAccounts.isEmpty {
            let header = NSMenuItem()
            header.attributedTitle = NSAttributedString(
                string: "Claude" + (loading ? "  …" : ""),
                attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
                             .foregroundColor: NSColor.secondaryLabelColor])
            header.isEnabled = false
            menu.addItem(header)
            addErrorItem(err, to: menu)
            return
        }

        for (idx, account) in store.claudeAccounts.enumerated() {
            if idx > 0 { menu.addItem(.separator()) }

            let header = NSMenuItem()
            header.attributedTitle = NSAttributedString(
                string: "\(account.shownLabel) · \(account.sourceDisplayName)" + (loading ? "  …" : ""),
                attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
                             .foregroundColor: NSColor(hex: account.colorHex)])
            header.isEnabled = false
            menu.addItem(header)

            if let err = account.error {
                addErrorItem(err, to: menu)
            } else if account.windows.isEmpty {
                let item = NSMenuItem(title: "  (no data yet)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                for w in account.windows.prefix(2) {
                    let line = String(format: "  %@ · %.1f%%  (resets in %@)",
                                      w.label, w.percent, w.resetText)
                    let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
            }

            let refresh = NSMenuItem(title: "  ↻ Refresh window (~2 tokens)",
                                     action: #selector(triggerClaudeAccount(_:)),
                                     keyEquivalent: "")
            refresh.target = self
            refresh.representedObject = account.id   // carry which account to refresh
            menu.addItem(refresh)
        }
    }

    private func addProviderSection(
        to menu: NSMenu,
        title: String,
        snapshot: UsageSnapshot,
        refreshSelector: Selector?,
        refreshTitle: String,
        isLoading: Bool
    ) {
        // Section header (bold, disabled).
        let header = NSMenuItem()
        header.attributedTitle = NSAttributedString(
            string: title + (isLoading ? "  …" : ""),
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        header.isEnabled = false
        menu.addItem(header)

        if let err = snapshot.error {
            addErrorItem(err, to: menu)
        } else if snapshot.windows.isEmpty {
            let item = NSMenuItem(title: "  (no data yet)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for w in snapshot.windows.prefix(2) {
                let line = String(format: "  %@ · %.1f%%  (resets in %@)",
                                  w.label, w.percent, w.resetText)
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        if let count = snapshot.availableResetCount {
            let noun = count == 1 ? "reset" : "resets"
            let summary = NSMenuItem(title: "  \(count) \(noun) available",
                                     action: nil, keyEquivalent: "")
            summary.isEnabled = false
            menu.addItem(summary)

            for reset in snapshot.resetCredits.prefix(3) {
                let line = "    \(reset.title) · expires \(reset.expirationText)"
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        if let refreshSelector {
            let refresh = NSMenuItem(title: "  ↻ " + refreshTitle,
                                     action: refreshSelector,
                                     keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)
        }
    }

    /// Collapse multiline process errors and truncate by rendered width rather
    /// than character count, so wide glyphs cannot unexpectedly grow the menu.
    /// The caller keeps the complete normalized message in the tooltip.
    static func menuErrorTitle(_ error: String, maximumWidth: CGFloat) -> String {
        let prefix = "  ⚠ "
        let normalized = error.split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        let font = NSFont.menuFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]

        func renderedWidth(_ value: String) -> CGFloat {
            (value as NSString).size(withAttributes: attributes).width
        }

        let full = prefix + normalized
        guard renderedWidth(full) > maximumWidth else { return full }

        let characters = Array(normalized)
        var lower = 0
        var upper = characters.count
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            let candidate = prefix + String(characters.prefix(middle)) + "…"
            if renderedWidth(candidate) <= maximumWidth {
                lower = middle
            } else {
                upper = middle - 1
            }
        }
        return prefix + String(characters.prefix(lower)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func addErrorItem(_ error: String, to menu: NSMenu) {
        let normalized = error.split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        let title = Self.menuErrorTitle(
            normalized, maximumWidth: Self.maximumMenuErrorWidth)
        let item = NSMenuItem(title: title,
                              action: nil, keyEquivalent: "")
        item.toolTip = normalized
        item.isEnabled = false
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: host)
            w.title = "AIGauge"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 540, height: 540))
            w.center()
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func refreshNow() {
        Task { await UsageStore.shared.refreshAll() }
    }

    @objc private func triggerClaudeAccount(_ sender: NSMenuItem) {
        let accountId = sender.representedObject as? String
        let label = UsageStore.shared.claudeAccounts.first { $0.id == accountId }?.shownLabel ?? "Claude"
        confirm("Send a tiny prompt from \(label)? Costs ~2 tokens and starts/extends its 5-hour quota window.") {
            Task { await UsageStore.shared.triggerClaudeRefresh(accountId: accountId) }
        }
    }

    @objc private func triggerCodex() {
        confirm("Send a tiny prompt to Codex? Costs ~24 tokens and starts or extends the detected 5-hour quota window.") {
            Task { await UsageStore.shared.triggerCodexRefresh() }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func confirm(_ message: String, _ action: @escaping () -> Void) {
        // Confirmation turned off (via "Don't ask again" or the General tab):
        // send straight away.
        guard AppSettings.shared.confirmQuotaRefresh else {
            action()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Trigger quota refresh"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            // Only remember the suppression once the user has actually confirmed
            // a send — future refreshes then skip the dialog.
            if alert.suppressionButton?.state == .on {
                AppSettings.shared.confirmQuotaRefresh = false
            }
            action()
        }
    }
}
