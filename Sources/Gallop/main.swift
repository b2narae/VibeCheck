import AppKit

if let flagIndex = CommandLine.arguments.firstIndex(of: "--check-log"),
   flagIndex + 1 < CommandLine.arguments.count {
    // Dev utility: classify the tail of a session log.
    let url = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    print(ProcessMonitor.logTailState(url).rawValue)
    exit(0)
}

if let flagIndex = CommandLine.arguments.firstIndex(of: "--check-prompt"),
   flagIndex + 1 < CommandLine.arguments.count {
    // Dev utility: extract the last user prompt from a session log.
    let url = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    print(ProcessMonitor.lastUserPrompt(in: url) ?? "(none)")
    exit(0)
}

if let flagIndex = CommandLine.arguments.firstIndex(of: "--dump-sprites"),
   flagIndex + 1 < CommandLine.arguments.count {
    // Dev utility: render every animal's 4 gait frames into one contact sheet.
    let scale: CGFloat = 2
    let cell = Sprites.size
    let cols = 4
    let rows = RunnerSettings.animals.count
    let pad: CGFloat = 8
    let sheet = NSImage(size: NSSize(
        width: (cell.width * scale + pad) * CGFloat(cols) + pad,
        height: (cell.height * scale + pad) * CGFloat(rows) + pad))
    sheet.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: sheet.size).fill()
    NSGraphicsContext.current?.imageInterpolation = .none
    for (row, animal) in RunnerSettings.animals.enumerated() {
        for (col, frame) in Sprites.frames(for: animal.emoji).enumerated() {
            let origin = NSPoint(
                x: pad + CGFloat(col) * (cell.width * scale + pad),
                y: sheet.size.height - (pad + cell.height * scale
                    + CGFloat(row) * (cell.height * scale + pad)))
            frame.draw(
                in: NSRect(origin: origin, size: NSSize(
                    width: cell.width * scale, height: cell.height * scale)))
        }
    }
    sheet.unlockFocus()
    if let tiff = sheet.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1]))
        print("wrote sprite sheet")
    }
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
