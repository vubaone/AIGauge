import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar.install()
        _ = UsageStore.shared  // boot the singleton so the usage-poll timer starts
        AutoRefreshScheduler.shared.start()  // scheduled per-service "Refresh window"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
