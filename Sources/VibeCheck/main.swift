import AppKit

let arguments = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag),
          index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// Which transcript reader understands a log path handed to a dev flag.
func reader(forLogPath path: String) -> any TranscriptReader.Type {
    path.contains("/.codex/") ? CodexTranscript.self : ClaudeTranscript.self
}

if arguments.contains("--hook") {
    // Invoked by a Claude Code hook: record the event and get out of the way.
    HookBridge.handleHookInvocation()
    exit(0)
}

if arguments.contains("--install-hooks") || arguments.contains("--uninstall-hooks") {
    let installing = arguments.contains("--install-hooks")
    if let error = installing ? HookBridge.install() : HookBridge.uninstall() {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
    print(installing ? "hooks installed" : "hooks uninstalled")
    exit(0)
}

if arguments.contains("--hooks-status") {
    print(HookBridge.isInstalled ? "installed" : "not installed")
    exit(0)
}

if let path = value(after: "--check-log") {
    // Dev utility: classify the tail of a session log (Claude or Codex).
    let url = URL(fileURLWithPath: path)
    print(reader(forLogPath: path).tailState(url).rawValue)
    exit(0)
}

if let path = value(after: "--check-prompt") {
    // Dev utility: extract the last user prompt from a session log.
    let url = URL(fileURLWithPath: path)
    print(reader(forLogPath: path).lastUserPrompt(in: url) ?? "(none)")
    exit(0)
}

if let path = value(after: "--check-detail") {
    // Dev utility: what the session is doing right now, per its transcript.
    let url = URL(fileURLWithPath: path)
    guard let detail = reader(forLogPath: path).detail(in: url) else {
        print("(none)")
        exit(0)
    }
    print("lastResponse: \(detail.lastResponse ?? "-")")
    print("pendingQuestion: \(detail.pendingQuestion ?? "-")")
    print("pendingTool: \(detail.pendingTool ?? "-")")
    exit(0)
}

if let path = value(after: "--dump-sprites") {
    // Dev utility: render every animal's 4 gait frames into one contact sheet.
    // Top-level code is main-actor in Swift 6 but not under the plain
    // swiftc build, so the isolation is stated explicitly here.
    if MainActor.assumeIsolated({ Sprites.writeContactSheet(to: URL(fileURLWithPath: path)) }) {
        print("wrote sprite sheet")
    } else {
        FileHandle.standardError.write(Data("could not write sprite sheet\n".utf8))
        exit(1)
    }
    exit(0)
}

if let path = value(after: "--dump-iconset") {
    // Build step: render the .iconset the app bundle's icon is made from,
    // so no binary image asset has to live in the repository.
    if MainActor.assumeIsolated({ Sprites.writeIconSet(to: URL(fileURLWithPath: path)) }) {
        print("wrote iconset")
    } else {
        FileHandle.standardError.write(Data("could not write iconset\n".utf8))
        exit(1)
    }
    exit(0)
}

if let cwd = value(after: "--check-session") {
    // Dev utility: what VibeCheck would read for a session in this directory.
    for assistant in ProcessMonitor.assistants {
        guard let reader = Transcripts.reader(for: assistant.id) else {
            print("\(assistant.displayName): no transcript reader")
            continue
        }
        guard let file = reader.logFile(projectPath: cwd, sessionID: nil) else {
            print("\(assistant.displayName): no log found for \(cwd)")
            continue
        }
        print("\(assistant.displayName): \(file.path)")
        print("  tail:   \(reader.tailState(file).rawValue)")
        print("  prompt: \(reader.lastUserPrompt(in: file) ?? "-")")
        if let detail = reader.detail(in: file) {
            print("  answer: \(detail.lastResponse ?? "-")")
            print("  waiting on: \(detail.pendingQuestion ?? detail.pendingTool ?? "-")")
        }
    }
    exit(0)
}

if arguments.contains("--check-usage") {
    // Dev utility: what the 5-hour block looks like right now, synchronously.
    let tracker = UsageWindowTracker()
    guard let window = tracker.currentWindow() else {
        print("no active block")
        exit(0)
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    print("start:    \(formatter.string(from: window.start))")
    print("end:      \(formatter.string(from: window.end))")
    print("elapsed:  \(String(format: "%.3f", window.elapsedFraction()))")
    print("tokens:   \(window.tokens)")
    print("exhausted:\(window.isExhausted())")
    exit(0)
}

if arguments.contains("--debug") {
    // Headless mode: print detection results once per poll, for development.
    setvbuf(stdout, nil, _IOLBF, 0)
    let monitor = ProcessMonitor()
    monitor.onUpdate = { statuses in
        let line = statuses
            .filter { !$0.sessions.isEmpty }
            .map { status in
                let sessions = status.sessions
                    .map { session in
                        let log = session.logFile?.lastPathComponent ?? "no-log"
                        return "\(session.pid)(\(session.projectName ?? "?"))="
                            + "\(session.state.rawValue)\(session.needsAttention ? "!" : "") "
                            + "\(Int(session.cpu))% [\(log)]"
                    }
                    .joined(separator: " ")
                return "\(status.assistant.id)[\(sessions)]"
            }
            .joined(separator: "   ")
        print(line.isEmpty ? "(no sessions)" : line)
    }
    monitor.onFinished = { session in
        print(">>> \(session.assistant.displayName) @ \(session.projectName ?? "?") finished")
    }
    monitor.onNeedsAttention = { session in
        print(">>> \(session.assistant.displayName) @ \(session.projectName ?? "?") needs you")
    }
    let tracker = UsageWindowTracker()
    monitor.onSessionActive = { tracker.refreshNow() }
    tracker.onUpdate = { window in
        guard let window else {
            print("usage-block: none active")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let elapsed = String(format: "%.2f", window.elapsedFraction())
        print("usage-block: \(formatter.string(from: window.start))"
            + "–\(formatter.string(from: window.end)) elapsed=\(elapsed) "
            + "tokens=\(window.tokens)"
            + (window.isExhausted() ? " LIMIT-REACHED" : ""))
    }
    monitor.start()
    tracker.start()
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    // Menu bar only — no Dock icon, no main window.
    app.setActivationPolicy(.accessory)
    app.run()
}
