import Foundation
import Darwin

/// Ground truth reported by Claude Code hooks for one session.
struct HookState {
    enum Phase: String {
        case working    // a turn is in progress
        case attention  // Claude is waiting on the user (permission, question)
        case idle       // turn finished
    }

    let sessionID: String
    let pid: Int32?
    let cwd: String?
    let phase: Phase
    let message: String?
    let updated: Date
    /// Which assistant reported this. Without it a report would be matched to
    /// any session sharing the working directory — a Claude hook would hand
    /// its phase to a Codex session running in the same folder.
    let assistantID: String
}

/// Bridges Claude Code hooks into VibeCheck.
///
/// A hook invocation runs `VibeCheck --hook`, which reads the event JSON on stdin
/// and records the session's phase as a small file under ~/.vibecheck/sessions.
/// The app reads those files each poll and prefers them over the CPU and
/// transcript heuristics, which can only ever approximate what the hooks state
/// outright.
///
/// Only turn-boundary events are registered. Hooks block Claude Code while they
/// run, so per-tool events (which fire dozens of times per turn) are
/// deliberately avoided — the turn boundary is all VibeCheck needs.
enum HookBridge {
    static let events = [
        "SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd",
    ]

    /// Notification types that genuinely mean "Claude is blocked on you".
    /// Others (idle reminders, auth notices, completion notices) are ignored.
    private static let attentionNotifications: Set<String> = [
        "permission_prompt", "agent_needs_input", "elicitation_dialog",
    ]

    static var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibecheck/sessions", isDirectory: true)
    }

    private static var settingsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    // MARK: - Hook side (runs as `VibeCheck --hook`)

    /// Reads one hook event from stdin and records it. Never fails loudly:
    /// a monitoring hook must not disturb the session that invoked it.
    static func handleHookInvocation() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = event["session_id"] as? String, !sessionID.isEmpty
        else { return }

        let name = event["hook_event_name"] as? String ?? ""
        let file = stateDirectory.appendingPathComponent("\(sessionID).json")

        if name == "SessionEnd" {
            try? FileManager.default.removeItem(at: file)
            return
        }

        let previous = read(file: file)
        // Events that omit a field must not erase what earlier ones established.
        let cwd = event["cwd"] as? String ?? previous?.cwd
        var phase: HookState.Phase
        var message: String?

        switch name {
        case "UserPromptSubmit":
            phase = .working
        case "Stop", "SessionStart":
            phase = .idle
        case "Notification":
            let type = event["notification_type"] as? String
            message = event["message"] as? String
            if let type {
                // Only genuine "blocked on you" notifications raise the wall;
                // anything else leaves the phase untouched.
                guard Self.attentionNotifications.contains(type) else {
                    phase = previous?.phase ?? .working
                    message = previous?.message
                    break
                }
                phase = .attention
            } else {
                // Older builds may omit the type: a notification arriving
                // mid-turn is the blocking kind, one after Stop is not.
                phase = previous?.phase == .working ? .attention : (previous?.phase ?? .idle)
            }
        default:
            phase = previous?.phase ?? .working
        }

        var record: [String: Any] = [
            "session_id": sessionID,
            "phase": phase.rawValue,
            "updated": Date().timeIntervalSince1970,
        ]
        if let cwd { record["cwd"] = cwd }
        if let message { record["message"] = message }
        let resolved = resolveAssistant()
        if let pid = resolved?.pid { record["pid"] = Int(pid) }
        // Only Claude Code invokes these hooks today, but recording the
        // assistant keeps the match honest if that ever changes.
        record["assistant"] = resolved?.assistantID ?? "claude" 

        try? FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true)
        if let out = try? JSONSerialization.data(withJSONObject: record) {
            try? out.write(to: file, options: .atomic)
        }
    }

    /// Walks up from this hook process to the assistant process that spawned
    /// it, so the app can match hook state to a runner by pid.
    ///
    /// Hooks block the session that invokes them, so this takes the libproc
    /// path (a few syscalls) and only falls back to listing every process when
    /// the executable name alone cannot identify the assistant.
    private static func resolveAssistant() -> (pid: Int32, assistantID: String)? {
        var pid = getppid()
        for _ in 0..<8 {
            guard pid > 1 else { break }
            if let name = executableName(of: pid),
               let assistant = ProcessMonitor.assistants
                   .first(where: { $0.binaryNames.contains(name) }) {
                return (pid, assistant.id)
            }
            guard let parent = parentPID(of: pid) else { break }
            pid = parent
        }
        return resolveAssistantByScanning()
    }

    private static func executableName(of pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro isn't exposed to Swift.
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
            .lastPathComponent.lowercased()
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }

    private static func resolveAssistantByScanning() -> (pid: Int32, assistantID: String)? {
        var pid = getppid()
        for _ in 0..<8 {
            guard pid > 1, let line = ProcessList.arguments(of: pid) else { return nil }
            if let assistant = ProcessMonitor.match(args: line) {
                return (pid, assistant.id)
            }
            guard let next = parentPID(of: pid), next > 1 else { return nil }
            pid = next
        }
        return nil
    }

    // MARK: - App side

    static func readAll() -> [HookState] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDirectory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { read(file: $0) }
    }

    private static func read(file: URL) -> HookState? {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = object["session_id"] as? String,
              let phase = (object["phase"] as? String).flatMap(HookState.Phase.init(rawValue:)),
              let updated = object["updated"] as? Double
        else { return nil }
        return HookState(
            sessionID: sessionID,
            pid: (object["pid"] as? Int).map(Int32.init),
            cwd: object["cwd"] as? String,
            phase: phase,
            message: object["message"] as? String,
            updated: Date(timeIntervalSince1970: updated),
            assistantID: object["assistant"] as? String ?? "claude")
    }

    /// Removes state files left behind by sessions that ended without a
    /// SessionEnd hook (crash, kill).
    static func pruneStaleFiles(olderThan age: TimeInterval = 7 * 24 * 3600) {
        let cutoff = Date().addingTimeInterval(-age)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for file in files {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let mtime, mtime < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Install / uninstall in ~/.claude/settings.json

    static var isInstalled: Bool {
        guard let settings = loadSettings(),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.contains { event in
            entries(in: hooks, event: event).contains(where: isVibeCheckEntry)
        }
    }

    /// Adds VibeCheck's hooks to ~/.claude/settings.json, leaving every other
    /// setting and any existing hooks untouched. Returns an error message on
    /// failure, nil on success.
    static func install() -> String? {
        guard let command = hookCommand() else { return "실행 파일 경로를 찾지 못했습니다." }
        var settings = loadSettings() ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in events {
            var list = entries(in: hooks, event: event).filter { !isVibeCheckEntry($0) }
            list.append([
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": 10,
                ]]
            ])
            hooks[event] = list
        }
        settings["hooks"] = hooks
        return write(settings: settings)
    }

    /// Removes only VibeCheck's own hook entries.
    static func uninstall() -> String? {
        guard var settings = loadSettings(),
              var hooks = settings["hooks"] as? [String: Any] else { return nil }
        for event in events {
            let list = entries(in: hooks, event: event).filter { !isVibeCheckEntry($0) }
            if list.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = list
            }
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        return write(settings: settings)
    }

    static func hookCommand() -> String? {
        guard let path = Bundle.main.executablePath else { return nil }
        // Single-quote the path so spaces in it survive the shell.
        return "'\(path.replacingOccurrences(of: "'", with: "'\\''"))' --hook"
    }

    private static func entries(in hooks: [String: Any], event: String) -> [[String: Any]] {
        hooks[event] as? [[String: Any]] ?? []
    }

    /// "Gallop" was this app's name before 0.2; entries pointing at it are
    /// still ours, so installing or uninstalling cleans them up rather than
    /// leaving a hook that runs a binary the user no longer has.
    private static let ownNames = ["VibeCheck", "Gallop"]

    private static func isVibeCheckEntry(_ entry: [String: Any]) -> Bool {
        guard let commands = entry["hooks"] as? [[String: Any]] else { return false }
        return commands.contains { command in
            let text = command["command"] as? String ?? ""
            return text.contains("--hook") && ownNames.contains { text.contains($0) }
        }
    }

    private static func loadSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func write(settings: [String: Any]) -> String? {
        let file = settingsFile
        // Keep a one-time backup before VibeCheck ever edits the user's settings.
        let backup = file.appendingPathExtension("vibecheck-backup")
        if FileManager.default.fileExists(atPath: file.path),
           !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: file, to: backup)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "설정을 직렬화하지 못했습니다." }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
