import Foundation
import Darwin

enum ActivityState: String {
    case absent   // no session process at all
    case idle     // session open, waiting for input
    case working  // actively doing work (CPU above threshold recently)
}

/// Shape of the last entry in a session log — tells us where the turn stands
/// even when the process is quietly waiting on the API.
enum LogTailState: String {
    case pendingToolUse     // assistant issued a tool_use, no result yet
    case awaitingAssistant  // last entry is user/tool_result — model is computing
    case turnEnded          // assistant finished with a text message
    case unknown
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
    /// Session UUID when present in the process arguments.
    let sessionID: String?
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
    /// A mid-turn-shaped log keeps the session "working" while its last write
    /// is at most this old — covers long API waits without CPU activity, but
    /// lets interrupted sessions decay back to idle.
    private let turnActivityHorizon: TimeInterval = 180
    /// A pending tool_use younger than this is assumed to be a tool still
    /// running, not a permission prompt waiting for the user.
    private let pendingAttentionGrace: TimeInterval = 10

    var onUpdate: (([AssistantStatus]) -> Void)?
    /// Fired when a session stops working (went idle, or exited mid-run).
    var onFinished: ((SessionStatus) -> Void)?
    /// Fired when a session starts waiting for user input (permission/question).
    var onNeedsAttention: ((SessionStatus) -> Void)?

    private let queue = DispatchQueue(label: "vibecheck.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cpuHistory: [Int32: [Double]] = [:]
    private var lastStates: [Int32: ActivityState] = [:]
    private var lastAttention: [Int32: Bool] = [:]
    private var lastSessions: [Int32: SessionStatus] = [:]
    private var cwdCache: [Int32: String?] = [:]
    private var logTailCache: [String: (mtime: Date, state: LogTailState)] = [:]

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

    /// Indexes the current hook reports so each tracked session can find its own.
    private struct HookIndex {
        private var byPID: [Int32: HookState] = [:]
        private var bySessionID: [String: HookState] = [:]
        private var byCWD: [String: [HookState]] = [:]

        init(_ states: [HookState]) {
            for state in states {
                if let pid = state.pid { byPID[pid] = state }
                bySessionID[state.sessionID] = state
                if let cwd = state.cwd { byCWD[cwd, default: []].append(state) }
            }
        }

        var isEmpty: Bool { bySessionID.isEmpty }

        /// Matches on the strongest identifier available. A working directory
        /// is only conclusive when a single session reports from it.
        func lookup(pid: Int32, sessionID: String?, cwd: String?) -> HookState? {
            if let state = byPID[pid] { return state }
            if let sessionID, let state = bySessionID[sessionID] { return state }
            if let cwd, let states = byCWD[cwd], states.count == 1 { return states[0] }
            return nil
        }
    }

    private func poll() {
        guard let processes = Self.listProcesses() else { return }
        let hooks = HookIndex(HookBridge.readAll())

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

            let cpuActive = (history.max() ?? 0) >= workingCPUThreshold
            var state: ActivityState = cpuActive ? .working : .idle
            var needsAttention = false
            let projectPath = workingDirectory(for: pid)
            let sessionID = Self.sessionID(fromArgs: args)
            let tail = assistant.id == "claude"
                ? logTail(projectPath: projectPath, sessionID: sessionID) : nil

            if let hook = hooks.lookup(pid: pid, sessionID: sessionID, cwd: projectPath),
               Self.trusts(hook, tail: tail, horizon: turnActivityHorizon) {
                // Hooks report the session's own state, so they win over
                // anything inferred from CPU or the transcript.
                switch hook.phase {
                case .working:
                    state = .working
                case .attention:
                    state = .idle
                    needsAttention = true
                case .idle:
                    state = .idle
                }
            } else if let tail {
                // No hooks: the transcript still says where the turn stands
                // even when the process idles on an API wait.
                switch tail.state {
                case .awaitingAssistant where tail.age < turnActivityHorizon:
                    state = .working
                case .pendingToolUse:
                    if !cpuActive && tail.age >= pendingAttentionGrace {
                        state = .idle
                        needsAttention = true
                    } else {
                        state = .working
                    }
                default:
                    break
                }
            }

            let session = SessionStatus(
                assistant: assistant, pid: pid, state: state, cpu: cpu,
                projectPath: projectPath, sessionID: sessionID,
                needsAttention: needsAttention)

            if lastStates[pid] == .working && state == .idle && !needsAttention {
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

    /// Interrupting a turn with Esc fires no Stop hook, so a "working" report
    /// whose transcript has gone quiet must not pin the runner forever.
    private static func trusts(
        _ hook: HookState, tail: (state: LogTailState, age: TimeInterval)?,
        horizon: TimeInterval
    ) -> Bool {
        guard hook.phase == .working, let tail else { return true }
        return tail.age < horizon
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

    // MARK: - Session log tail

    /// Locates the session's log and classifies its last entry, plus how long
    /// ago the log was last written. Only re-reads when the mtime changes.
    /// Locates the log file backing a session (by session id when known,
    /// otherwise the project's most recently written log).
    static func sessionLogFile(projectPath: String?, sessionID: String?) -> URL? {
        guard let projectPath else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(encodeProjectPath(projectPath))
        if let sessionID {
            let candidate = dir.appendingPathComponent("\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return newestJSONL(in: dir)
    }

    private func logTail(
        projectPath: String?, sessionID: String?
    ) -> (state: LogTailState, age: TimeInterval)? {
        guard let file = Self.sessionLogFile(projectPath: projectPath, sessionID: sessionID),
              let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate
        else { return nil }

        let age = Date().timeIntervalSince(mtime)
        if let cached = logTailCache[file.path], cached.mtime == mtime {
            return (cached.state, age)
        }
        let state = Self.logTailState(file)
        logTailCache[file.path] = (mtime, state)
        return (state, age)
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

    /// Reads the tail of a session log and classifies the last user/assistant
    /// entry (skipping snapshots, summaries and other bookkeeping lines).
    /// The candidate line is JSON-parsed rather than string-matched, so text
    /// that merely mentions these keys cannot be mistaken for structure.
    static func logTailState(_ url: URL) -> LogTailState {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 262_144
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? handle.readToEnd() else { return .unknown }
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\n").reversed() {
            // Loose prefilter (whitespace-agnostic); the JSON parse decides.
            guard line.contains("assistant") || line.contains("user"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                      as? [String: Any],
                  let type = object["type"] as? String
            else { continue }

            if type == "user" { return .awaitingAssistant }
            guard type == "assistant" else { continue }

            let message = object["message"] as? [String: Any]
            let blocks = message?["content"] as? [[String: Any]] ?? []
            if blocks.contains(where: { $0["type"] as? String == "tool_use" }) {
                return .pendingToolUse
            }
            // Text and thinking blocks are written mid-turn too, so their mere
            // presence means nothing. stop_reason is what says whether the
            // model is done: "tool_use" means another block is still coming.
            return Self.endOfTurnReasons.contains(message?["stop_reason"] as? String ?? "")
                ? .turnEnded : .awaitingAssistant
        }
        return .unknown
    }

    private static let endOfTurnReasons: Set<String> = [
        "end_turn", "stop_sequence", "max_tokens", "refusal",
    ]

    /// The most recent real user prompt in a session log — i.e. what the
    /// session was asked to do. Skips tool results, commands, and meta entries.
    static func lastUserPrompt(projectPath: String?, sessionID: String?) -> String? {
        guard let file = sessionLogFile(projectPath: projectPath, sessionID: sessionID)
        else { return nil }
        return lastUserPrompt(in: file)
    }

    static func lastUserPrompt(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 1_048_576
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"type\":\"user\""),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                      as? [String: Any],
                  object["type"] as? String == "user",
                  object["isMeta"] as? Bool != true,
                  let message = object["message"] as? [String: Any]
            else { continue }

            var prompt: String?
            if let content = message["content"] as? String {
                prompt = content
            } else if let items = message["content"] as? [[String: Any]] {
                let texts = items.compactMap { item -> String? in
                    item["type"] as? String == "text" ? item["text"] as? String : nil
                }
                if !texts.isEmpty { prompt = texts.joined(separator: " ") }
            }

            guard var result = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !result.isEmpty,
                  !result.hasPrefix("<"),          // command/system-reminder wrappers
                  !result.hasPrefix("[Request"),   // interruption markers
                  !result.hasPrefix("Caveat:")
            else { continue }

            result = result.replacingOccurrences(of: "\n", with: " ")
            if result.count > 120 {
                result = String(result.prefix(120)) + "…"
            }
            return result
        }
        return nil
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
    static func listProcesses() -> [(pid: Int32, ppid: Int32, cpu: Double, args: String)]? {
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
