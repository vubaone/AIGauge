import AppKit
import Combine
import SwiftUI

/// Owns the NSStatusItem in the menu bar and the settings NSWindow.
@MainActor
final class MenuBarController: NSObject {
    /// Keeps a verbose backend error from widening the entire dropdown beyond
    /// the comfortable size of the normal usage rows.
    nonisolated static let maximumMenuErrorWidth: CGFloat = 280
    /// Keep a long reset-grant label from determining the width of the menu.
    /// The resulting dropdown is about 60% as wide as the unbounded label.
    nonisolated static let maximumMenuResetWidth: CGFloat = 350
    /// A JSON error body needs more than one line to be readable, but the menu
    /// is not a log window — wrap it, then ellipsize.
    nonisolated static let maximumMenuErrorLines = 3

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
        .merge(with: store.$mistral.map { _ in () },
               store.$isLoadingMistral.map { _ in () },
               settings.$mistralColorHex.map { _ in () },
               settings.$mistralEnabled.map { _ in () })
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
            case .mistral:
                guard backend.includesMistral, s.mistralEnabled else { continue }
                appendPart(label: "Mistral", pct: item.percent, colorHex: item.colorHex, err: item.hasError)
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
        if s.mistralEnabled {
            let snapshot = UsageStore.shared.mistral
            if let error = snapshot.error { tipParts.append("Mistral: \(error)") }
            else if let percent = snapshot.primaryPercent {
                tipParts.append(String(format: "Mistral: %.1f%%", percent))
            }
        }
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
            let codex = UsageStore.shared.codex
            addProviderSection(to: menu,
                               title: "Codex",
                               snapshot: codex,
                               refreshSelector: codex.supportsWindowRefresh
                                   ? #selector(triggerCodex) : nil,
                               refreshTitle: "Refresh 5-hour window (~24 tokens)",
                               isLoading: UsageStore.shared.isLoadingCodex,
                               // Resolved only on error — it touches the disk.
                               reloadSource: codex.error.flatMap {
                                   TokenSource.canReload(after: $0) ? .forCodex() : nil
                               },
                               reloadSelector: #selector(reloadCodexToken))
        }
        if m.includesMistral, AppSettings.shared.mistralEnabled {
            if m.includesClaude || m.includesCodex { menu.addItem(.separator()) }
            addProviderSection(to: menu, title: "Mistral",
                               snapshot: UsageStore.shared.mistral,
                               refreshSelector: nil, refreshTitle: "",
                               isLoading: UsageStore.shared.isLoadingMistral)
        }
        if !menu.items.isEmpty {
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
                if TokenSource.canReload(after: err) {
                    addReloadItem(.forClaude(source: account.source),
                                  action: #selector(reloadClaudeToken(_:)),
                                  representedObject: account.id,
                                  to: menu)
                }
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

            if let count = account.availableResetCount, count > 0 {
                addResetCreditsSummary(count: count, credits: account.resetCredits, to: menu)
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
        isLoading: Bool,
        reloadSource: TokenSource? = nil,
        reloadSelector: Selector? = nil
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
            if let reloadSource = reloadSource, let reloadSelector = reloadSelector {
                addReloadItem(reloadSource, action: reloadSelector,
                              representedObject: nil, to: menu)
            }
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
                if let detail = w.detailText {
                    let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                    detailItem.title = Self.wrappedMenuTitle(detail, firstPrefix: "    ",
                        continuationPrefix: "    ", maximumWidth: Self.maximumMenuResetWidth, maximumLines: 2)
                    detailItem.toolTip = detail
                    detailItem.isEnabled = false
                    menu.addItem(detailItem)
                }
            }
        }

        if let count = snapshot.availableResetCount {
            addResetCreditsSummary(count: count, credits: snapshot.resetCredits, to: menu)
        }

        if let refreshSelector {
            let refresh = NSMenuItem(title: "  ↻ " + refreshTitle,
                                     action: refreshSelector,
                                     keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)
        }
    }

    private func addResetCreditsSummary(count: Int, credits: [UsageResetCredit], to menu: NSMenu) {
        let noun = count == 1 ? "reset" : "resets"
        let summary = NSMenuItem(title: "  \(count) \(noun) available",
                                 action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        for reset in credits.prefix(3) {
            let quantity = reset.remainingCount > 1 ? "\(reset.remainingCount) × " : ""
            let fullTitle = "    \(quantity)\(reset.title) · expires \(reset.expirationText)"
            let title = Self.menuResetTitle(reset, maximumWidth: Self.maximumMenuResetWidth)
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.menuFont(ofSize: 0),
                             .foregroundColor: NSColor.secondaryLabelColor])
            item.toolTip = fullTitle
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    static func menuResetTitle(_ reset: UsageResetCredit, maximumWidth: CGFloat) -> String {
        let prefix = "    "
        let quantity = reset.remainingCount > 1 ? "\(reset.remainingCount) × " : ""
        let detail = quantity + reset.title
        let expiry = "expires \(reset.expirationText)"
        let font = NSFont.menuFont(ofSize: 0)
        let combined = prefix + detail + " · " + expiry
        if (combined as NSString).size(withAttributes: [.font: font]).width <= maximumWidth {
            return combined
        }
        let titleLines = wrappedMenuTitle(detail, firstPrefix: prefix,
                                         continuationPrefix: prefix,
                                         maximumWidth: maximumWidth, maximumLines: 2)
        let expiryLine = wrappedMenuTitle(expiry, firstPrefix: prefix,
                                          continuationPrefix: prefix,
                                          maximumWidth: maximumWidth, maximumLines: 1)
        return titleLines + "\n" + expiryLine
    }

    /// Collapse multiline process errors, then wrap them over at most
    /// `maximumLines` lines each fitted to `maximumWidth`. Measuring rendered
    /// width (rather than counting characters) keeps wide glyphs from growing
    /// the menu, and wrapping keeps a JSON error body legible instead of
    /// cutting it off after a few words. Anything past the last line is
    /// ellipsized; the caller keeps the complete message in the tooltip.
    static func menuErrorTitle(_ error: String,
                               maximumWidth: CGFloat,
                               maximumLines: Int = maximumMenuErrorLines) -> String {
        wrappedMenuTitle(error, firstPrefix: "  ⚠ ", continuationPrefix: "     ",
                         maximumWidth: maximumWidth, maximumLines: maximumLines)
    }

    private static func wrappedMenuTitle(_ message: String,
                                         firstPrefix: String,
                                         continuationPrefix: String,
                                         maximumWidth: CGFloat,
                                         maximumLines: Int) -> String {
        let normalized = message.split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]

        func renderedWidth(_ value: String) -> CGFloat {
            (value as NSString).size(withAttributes: attributes).width
        }

        var lines: [String] = []
        var remaining = Substring(normalized)

        while !remaining.isEmpty, lines.count < max(maximumLines, 1) {
            let linePrefix = lines.isEmpty ? firstPrefix : continuationPrefix
            let isLastLine = lines.count == max(maximumLines, 1) - 1
            let budget = maximumWidth - renderedWidth(linePrefix)

            if renderedWidth(String(remaining)) <= budget {
                lines.append(linePrefix + remaining)
                remaining = ""
                break
            }

            // The last line has to absorb the rest, so reserve room for "…".
            let ellipsis = isLastLine ? "…" : ""
            let fitting = fittingPrefixLength(remaining,
                                              budget: budget - renderedWidth(ellipsis),
                                              attributes: attributes)
            guard fitting > 0 else { break }   // nothing fits — don't spin

            // Prefer a word boundary, but only when it isn't so far back that
            // the line ends up mostly empty (JSON has few spaces to break on).
            var breakAt = fitting
            if !isLastLine, let space = remaining.prefix(fitting).lastIndex(of: " ") {
                let upToSpace = remaining.distance(from: remaining.startIndex, to: space)
                if upToSpace >= fitting / 2 { breakAt = upToSpace }
            }

            let end = remaining.index(remaining.startIndex, offsetBy: breakAt)
            lines.append(linePrefix
                         + remaining[..<end].trimmingCharacters(in: .whitespaces)
                         + ellipsis)
            remaining = remaining[end...].drop { $0 == " " }
        }

        guard !lines.isEmpty else { return firstPrefix + normalized }
        return lines.joined(separator: "\n")
    }

    /// Longest prefix of `text` that renders within `budget`, by binary search.
    private static func fittingPrefixLength(_ text: Substring,
                                            budget: CGFloat,
                                            attributes: [NSAttributedString.Key: Any]) -> Int {
        var lower = 0
        var upper = text.count
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            let candidate = String(text.prefix(middle)) as NSString
            if candidate.size(withAttributes: attributes).width <= budget {
                lower = middle
            } else {
                upper = middle - 1
            }
        }
        return lower
    }

    private func addErrorItem(_ error: String, to menu: NSMenu) {
        let normalized = error.split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        let title = Self.menuErrorTitle(
            normalized, maximumWidth: Self.maximumMenuErrorWidth)
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        // A plain `title` collapses the newlines onto one very wide row; only an
        // attributed title makes NSMenu lay the wrapped lines out vertically.
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.menuFont(ofSize: 0),
                         .foregroundColor: NSColor.systemRed])
        item.toolTip = normalized
        item.isEnabled = false
        menu.addItem(item)
    }

    /// The tappable row that sits under an error: reopens the app the token
    /// came from so the user can sign in again and reclaim it.
    private func addReloadItem(_ source: TokenSource,
                               action: Selector,
                               representedObject: Any?,
                               to menu: NSMenu) {
        let item = NSMenuItem(title: "  ↻ " + source.actionTitle,
                              action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        item.toolTip = source.helpText
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

    @objc private func reloadClaudeToken(_ sender: NSMenuItem) {
        guard let accountId = sender.representedObject as? String else { return }
        UsageStore.shared.reloadClaudeToken(accountId: accountId)
    }

    @objc private func reloadCodexToken() {
        UsageStore.shared.reloadCodexToken()
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
