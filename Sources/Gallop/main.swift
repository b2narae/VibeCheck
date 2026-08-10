import AppKit

if let flagIndex = CommandLine.arguments.firstIndex(of: "--check-pending"),
   flagIndex + 1 < CommandLine.arguments.count {
    // Dev utility: does this session log end with a pending tool_use?
    let url = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    print(ProcessMonitor.lastEntryIsPendingToolUse(url))
    exit(0)
}

if CommandLine.arguments.contains("--debug") {
    // Headless mode: print detection results once per poll, for development.
    setvbuf(stdout, nil, _IOLBF, 0)
    let monitor = ProcessMonitor()
    monitor.onUpdate = { statuses in
        let line = statuses
            .map { status in
                let sessions = status.sessions
                    .map {
                        "\($0.pid)(\($0.projectName ?? "?"))="
                        + "\($0.state.rawValue)\($0.needsAttention ? "!" : "") \(Int($0.cpu))%"
                    }
                    .joined(separator: " ")
                return "\(status.assistant.id)[\(sessions)]"
            }
            .joined(separator: "   ")
        print(line)
    }
    monitor.onFinished = { session in
        print(">>> \(session.assistant.displayName) @ \(session.projectName ?? "?") finished")
    }
    let tracker = UsageWindowTracker()
    tracker.onUpdate = { window in
        if let window {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            print("usage-window: \(f.string(from: window.start))–\(f.string(from: window.end)) "
                + "fraction=\(String(format: "%.2f", window.fraction()))")
        } else {
            print("usage-window: none active")
        }
    }
    monitor.start()
    tracker.start()
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar only — no Dock icon, no main window.
    app.setActivationPolicy(.accessory)
    app.run()
}
