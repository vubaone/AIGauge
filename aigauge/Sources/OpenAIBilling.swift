import AppKit
import WebKit

/// Reads the organization balance from its own signed-in Platform page.
/// WebKit retains the session in AIGauge's website data store.
@MainActor
final class OpenAIBilling: NSObject, WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate {
    private static let overviewURL = URL(string: "https://platform.openai.com/settings/organization/billing/overview")!
    private static let connectedKey = "openAIBillingConnected"
    private static let messageName = "openAIBillingBalance"

    var onMenuTitleChange: ((String) -> Void)?
    private(set) var menuTitle = "OpenAI API balance · Connect…" {
        didSet { onMenuTitleChange?(menuTitle) }
    }

    private var webView: WKWebView?
    private var window: NSWindow?
    private var timeout: Task<Void, Never>?
    private var lastReadStartedAt: ContinuousClock.Instant?
    private var balance: String?

    override init() {
        super.init()
        if isConnected {
            menuTitle = "OpenAI API balance · Check billing…"
        }
    }

    private var isConnected: Bool {
        get { UserDefaults.standard.bool(forKey: Self.connectedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.connectedKey) }
    }

    nonisolated static func canRefresh(since lastRead: ContinuousClock.Instant?, at now: ContinuousClock.Instant) -> Bool {
        lastRead.map { $0.duration(to: now) >= .seconds(10) } ?? true
    }

    func refreshOnMenuOpen() {
        let now = ContinuousClock.now
        guard isConnected, webView == nil, Self.canRefresh(since: lastReadStartedAt, at: now) else { return }
        if balance == nil { menuTitle = "OpenAI API balance · Checking…" }
        let view = makeWebView()
        loadOverview(in: view)
        timeout = Task { [weak self, weak view] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, let view, self.webView === view else { return }
            self.backgroundReadFailed()
        }
    }

    func openBilling() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        stopReading()
        let view = makeWebView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "OpenAI Platform Billing"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = view

        let billingButton = NSButton(title: "Open Billing Overview", target: self, action: #selector(reopenOverview))
        billingButton.sizeToFit()
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = billingButton
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)

        self.window = window
        loadOverview(in: view)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func reopenOverview() {
        if let webView { loadOverview(in: webView) }
    }

    private func loadOverview(in view: WKWebView) {
        lastReadStartedAt = .now
        view.load(URLRequest(url: Self.overviewURL, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: Self.balanceScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        config.userContentController.add(self, contentWorld: .defaultClient, name: Self.messageName)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 940, height: 680), configuration: config)
        view.navigationDelegate = self
        webView = view
        return view
    }

    private func stopReading() {
        timeout?.cancel()
        timeout = nil
        guard let view = webView else { return }
        webView = nil
        view.navigationDelegate = nil
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName, contentWorld: .defaultClient)
    }

    private func backgroundReadFailed() {
        stopReading()
        menuTitle = balance.map { "OpenAI API balance · \($0) (last seen)" } ?? "OpenAI API balance · Unavailable"
    }

    private func needsSignIn() {
        isConnected = false
        balance = nil
        menuTitle = "OpenAI API balance · Connect…"
    }

    private static func isOverview(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host == overviewURL.host &&
            (url?.port == nil || url?.port == 443) && url?.path == overviewURL.path
    }

    private static func isSignIn(_ url: URL?) -> Bool {
        guard url?.scheme == "https" else { return false }
        if url?.host == "auth.openai.com" || url?.host == "auth0.openai.com" { return true }
        guard url?.host == overviewURL.host, let path = url?.path else { return false }
        return path == "/login" || path.hasPrefix("/login/") || path.hasPrefix("/auth/login")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = webView, message.webView === view, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == Self.overviewURL.host,
              Self.isOverview(view.url), let amount = message.body as? String, amount.count <= 32 else { return }
        balance = amount
        if !isConnected { isConnected = true }
        menuTitle = "OpenAI API balance · \(amount)"
        if window == nil { stopReading() }
    }

    func webView(_ view: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        guard webView === view else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true, window == nil, !Self.isOverview(url) {
            if Self.isSignIn(url) {
                stopReading()
                needsSignIn()
            } else {
                backgroundReadFailed()
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.targetFrame?.isMainFrame == true && url?.scheme != "https" ? .cancel : .allow)
    }

    func webView(_ view: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === view, let window else { return }
        window.subtitle = view.url?.host ?? ""
        if Self.isSignIn(view.url) { needsSignIn() }
    }

    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if window == nil, webView === view { backgroundReadFailed() }
    }

    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if window == nil, webView === view { backgroundReadFailed() }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        stopReading()
        if balance == nil, isConnected { menuTitle = "OpenAI API balance · Check billing…" }
    }

    // Run in an isolated world and return only the visible USD amount adjacent
    // to the balance label. The dashboard renders asynchronously after loading.
    nonisolated static let balanceScript = #"""
    (() => {
        if (location.origin !== 'https://platform.openai.com') return;
        const overviewPath = '/settings/organization/billing/overview';
        const labels = new Set(['api credit balance', 'credit balance', 'số dư tín dụng api']);
        const number = '[0-9]+(?:[., ][0-9]+)*';
        const currency = '(?:US\\$|USD|\\$)';
        const usd = new RegExp(`^(?:[-−]?${currency} *[-−]?${number}|[-−]?${number} *${currency})$`, 'i');
        const normalize = text => text.replace(/\s+/g, ' ').trim();

        let lastAmount;
        const readBalance = () => {
            if (location.pathname.replace(/\/$/, '') !== overviewPath) return;
            const root = document.querySelector('main') ?? document.body;
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) {
                const label = walker.currentNode;
                if (!labels.has(normalize(label.textContent).toLowerCase())) continue;
                if (!label.parentElement?.getClientRects().length) continue;
                let group = label.parentElement;
                for (let depth = 0; group && group !== root && depth < 5; depth++, group = group.parentElement) {
                    const amounts = (group.innerText ?? '').split('\n').map(normalize).filter(text => usd.test(text));
                    if (amounts.length > 1) break;
                    if (amounts.length === 1) {
                        const amount = amounts[0];
                        if (amount !== lastAmount) {
                            lastAmount = amount;
                            webkit.messageHandlers.openAIBillingBalance.postMessage(amount);
                        }
                        return;
                    }
                }
            }
            lastAmount = undefined;
        };
        const observer = new MutationObserver(readBalance);
        observer.observe(document.body, { childList: true, characterData: true, subtree: true });
        readBalance();
    })();
    """#
}
