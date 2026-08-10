import AppKit

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
        HookBridge.pruneStaleFiles()
        monitor.start()
        usageTracker.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        usageTracker.stop()
    }
}
