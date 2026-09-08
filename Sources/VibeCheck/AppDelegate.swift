import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: ProcessMonitor!
    private var overlay: OverlayController!
    private var statusBar: StatusBarController!
    private var usageTracker: UsageWindowTracker!

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = ProcessMonitor()
        overlay = OverlayController()
        statusBar = StatusBarController(monitor: monitor, overlay: overlay)
        usageTracker = UsageWindowTracker()
        usageTracker.onUpdate = { [weak self] window in
            self?.overlay.usageWindow = window
            self?.statusBar.usageWindow = window
        }
        // A block can begin the moment a session starts a turn. Without this
        // the runner spent up to a minute drawn against a stale window — long
        // enough to be visibly wrong right after a break.
        monitor.onSessionActive = { [weak self] in
            self?.usageTracker.refreshNow()
        }
        HookBridge.pruneStaleFiles()
        monitor.start()
        usageTracker.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        usageTracker.stop()
    }
}
