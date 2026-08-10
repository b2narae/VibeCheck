import Foundation
import Darwin

enum ActivityState: String {
    case absent   // no session process at all
    case idle     // session open, waiting for input
    case working  // actively doing work (CPU above threshold recently)
}

struct Assistant {
    let id: String
    let displayName: String
    let runnerEmoji: String
    /// Executable basenames that identify this assistant's CLI process.
    let binaryNames: Set<String>
}

/// One terminal session of an assistant (one interactive CLI process).
struct SessionStatus {
    let assistant: Assistant
    let pid: Int32
    let state: ActivityState  // idle or working
    let cpu: Double
    /// Full working directory of the session, e.g. "/Users/me/Desktop/code/foo".
    let projectPath: String?
    /// True when the session is stopped waiting for the user: a permission
    /// prompt, a question, an env var/key request, etc.
    let needsAttention: Bool

    var projectName: String? {
        projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}

struct AssistantStatus {
    let assistant: Assistant
    let sessions: [SessionStatus]

    var state: ActivityState {
        if sessions.isEmpty { return .absent }
        return sessions.contains { $0.state == .working } ? .working : .idle
    }
}

final class ProcessMonitor {
    static let assistants: [Assistant] = [
        Assistant(id: "claude", displayName: "Claude Code", runnerEmoji: "🐎",
                  binaryNames: ["claude", "claude.exe"]),
        Assistant(id: "gemini", displayName: "Gemini CLI", runnerEmoji: "🦄",
                  binaryNames: ["gemini", "gemini.js"]),
        Assistant(id: "codex", displayName: "Codex CLI", runnerEmoji: "🐫",
                  binaryNames: ["codex", "codex.exe"]),
    ]

    /// Helper/daemon processes that stay resident even without an interactive session.
    private static let excludeSubstrings = [
        " daemon run", "bg-pty-host", "bg-spare", ".app/",
    ]

    /// A session counts as "working" if its CPU (own + child processes)
    /// crossed this within the recent window.
    private let workingCPUThreshold = 8.0
    private let historySize = 4          // samples kept per session (~6s window)
    private let pollInterval: TimeInterval = 1.5

    var onUpdate: (([AssistantStatus]) -> Void)?
    /// Fired when a session stops working (went idle, or exited mid-run).
    var onFinished: ((SessionStatus) -> Void)?
    /// Fired when a session starts waiting for user input (permission/question).
    var onNeedsAttention: ((SessionStatus) -> Void)?

    private let queue = DispatchQueue(label: "gallop.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cpuHistory: [Int32: [Double]] = [:]
    private var lastStates: [Int32: ActivityState] = [:]
    private var lastAttention: [Int32: Bool] = [:]
    private var lastSessions: [Int32: SessionStatus] = [:]
    private var cwdCache: [Int32: String?] = [:]
    private var attentionCache: [String: (mtime: Date, pending: Bool)] = [:]

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        guard let processes = Self.listProcesses() else { return }

        var cpuByPid: [Int32: Double] = [:]
        var children: [Int32: [Int32]] = [:]
        var matched: [(assistant: Assistant, pid: Int32, args: String)] = []
        for proc in processes {
            cpuByPid[proc.pid] = proc.cpu
            children[proc.ppid, default: []].append(proc.pid)
            if let assistant = Self.match(args: proc.args) {
                matched.append((assistant, proc.pid, proc.args))
            }
        }
        let sessionPids = Set(matched.map(\.pid))

        var sessionsByAssistant: [String: [SessionStatus]] = [:]
        var finished: [SessionStatus] = []
        var attentionStarted: [SessionStatus] = []
        var currentSessions: [Int32: SessionStatus] = [:]

        for (assistant, pid, args) in matched {
            // Own CPU plus child processes (tools the session is running),
            // stopping at nested sessions so they aren't double-counted.
            let cpu = Self.subtreeCPU(
                root: pid, children: children, cpu: cpuByPid,
                stops: sessionPids.subtracting([pid]))

            var history = cpuHistory[pid] ?? []
            history.append(cpu)
            if history.count > historySize {
                history.removeFirst(history.count - historySize)
            }
            cpuHistory[pid] = history

            let state: ActivityState =
                (history.max() ?? 0) >= workingCPUThreshold ? .working : .idle
            let projectPath = workingDirectory(for: pid)
            let needsAttention = state == .idle && assistant.id == "claude"
                && pendingToolUse(projectPath: projectPath,
                                  sessionID: Self.sessionID(fromArgs: args))

            let session = SessionStatus(
                assistant: assistant, pid: pid, state: state, cpu: cpu,
                projectPath: projectPath, needsAttention: needsAttention)

            if lastStates[pid] == .working && state == .idle {
                finished.append(session)
            }
            if needsAttention && lastAttention[pid] != true {
                attentionStarted.append(session)
            }
            lastStates[pid] = state
            lastAttention[pid] = needsAttention
            currentSessions[pid] = session
            sessionsByAssistant[assistant.id, default: []].append(session)
        }

        // A session that exited while still working also counts as finished.
        for (pid, previous) in lastSessions
        where !sessionPids.contains(pid) && previous.state == .working {
            finished.append(previous)
        }

        cpuHistory = cpuHistory.filter { sessionPids.contains($0.key) }
        lastStates = lastStates.filter { sessionPids.contains($0.key) }
        lastAttention = lastAttention.filter { sessionPids.contains($0.key) }
        cwdCache = cwdCache.filter { sessionPids.contains($0.key) }
        lastSessions = currentSessions

        let statuses = Self.assistants.map { assistant in
            AssistantStatus(
                assistant: assistant,
                sessions: (sessionsByAssistant[assistant.id] ?? []).sorted { $0.pid < $1.pid })
        }

        DispatchQueue.main.async {
            SessionAnimals.prune(livePids: sessionPids)
            self.onUpdate?(statuses)
            for session in finished {
                self.onFinished?(session)
            }
            for session in attentionStarted {
                self.onNeedsAttention?(session)
            }
        }
    }

    private static func subtreeCPU(
        root: Int32, children: [Int32: [Int32]], cpu: [Int32: Double], stops: Set<Int32>
    ) -> Double {
        var total = cpu[root] ?? 0
        for child in children[root] ?? [] where !stops.contains(child) {
            total += subtreeCPU(root: child, children: children, cpu: cpu, stops: stops)
        }
        return total
    }

    /// Matches a process against known assistants by the basename of its first
    /// two argv tokens (covers both `claude ...` and `node /path/claude ...`).
    static func match(args: String) -> Assistant? {
        let lower = args.lowercased()
        for pattern in excludeSubstrings where lower.contains(pattern) {
            return nil
        }
        let tokens = args.split(separator: " ", omittingEmptySubsequences: true).prefix(2)
        for token in tokens {
            let name = URL(fileURLWithPath: String(token)).lastPathComponent.lowercased()
            for assistant in assistants where assistant.binaryNames.contains(name) {
                return assistant
            }
        }
        return nil
    }

    static func sessionID(fromArgs args: String) -> String? {
        let tokens = args.split(separator: " ")
        guard let index = tokens.firstIndex(of: "--session-id"),
              tokens.index(after: index) < tokens.endIndex else { return nil }
        return String(tokens[tokens.index(after: index)])
    }

    // MARK: - Attention (waiting for user input)

    /// True when the session's log ends with an assistant tool_use that has no
    /// result yet — i.e. Claude asked something (permission, a question) and is
    /// waiting. Only re-reads the log when its mtime changes.
    private func pendingToolUse(projectPath: String?, sessionID: String?) -> Bool {
        guard let projectPath else { return false }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(Self.encodeProjectPath(projectPath))

        var file: URL?
        if let sessionID {
            let candidate = dir.appendingPathComponent("\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                file = candidate
            }
        }
        if file == nil {
            file = Self.newestJSONL(in: dir)
        }
        guard let file,
              let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate
        else { return false }

        if let cached = attentionCache[file.path], cached.mtime == mtime {
            return cached.pending
        }
        let pending = Self.lastEntryIsPendingToolUse(file)
        attentionCache[file.path] = (mtime, pending)
        return pending
    }

    /// Claude Code encodes a project cwd as a directory name by replacing
    /// every non-alphanumeric character with "-".
    static func encodeProjectPath(_ path: String) -> String {
        String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    private static func newestJSONL(in dir: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        return files
            .filter { $0.pathExtension == "jsonl" }
            .max { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l < r
            }
    }

    /// Reads the tail of a session log and checks whether the last entry is an
    /// assistant message containing a tool_use (= no result written yet).
    static func lastEntryIsPendingToolUse(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 262_144
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? handle.readToEnd() else { return false }
        let text = String(decoding: data, as: UTF8.self)
        guard let lastLine = text.split(separator: "\n").last(where: { $0.contains("\"type\"") })
        else { return false }
        return lastLine.contains("\"type\":\"assistant\"")
            && lastLine.contains("\"type\":\"tool_use\"")
    }

    // MARK: - Working directory

    private func workingDirectory(for pid: Int32) -> String? {
        if let cached = cwdCache[pid] { return cached }
        let path = Self.workingDirectory(of: pid)
        cwdCache[pid] = path
        return path
    }

    /// Reads a process's current working directory via libproc (no subprocess).
    static func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) > 0 else {
            return nil
        }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return nil }
            return String(cString: base)
        }
    }

    // MARK: - Process listing

    /// Returns (pid, ppid, cpuPercent, args) for every visible process.
    private static func listProcesses() -> [(pid: Int32, ppid: Int32, cpu: Double, args: String)]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Axo", "pid=,ppid=,pcpu=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        var result: [(Int32, Int32, Double, String)] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]),
                  let cpu = Double(parts[2]) else { continue }
            result.append((pid, ppid, cpu, String(parts[3])))
        }
        return result
    }
}
