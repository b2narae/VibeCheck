import Foundation
import Darwin

enum ActivityState: String, Sendable {
    case absent   // no session process at all
    case idle     // session open, waiting for input
    case working  // actively doing work
}

struct Assistant: Sendable {
    let id: String
    let displayName: String
    let runnerEmoji: String
    /// Executable basenames that identify this assistant's CLI process.
    let binaryNames: Set<String>
}

/// One terminal session of an assistant (one interactive CLI process).
struct SessionStatus: Sendable {
    let assistant: Assistant
    let pid: Int32
    let state: ActivityState  // idle or working
    let cpu: Double
    /// Full working directory of the session, e.g. "/Users/me/Desktop/code/foo".
    let projectPath: String?
    /// Session UUID when present in the process arguments or a hook report.
    let sessionID: String?
    /// True when the session is stopped waiting for the user: a permission
    /// prompt, a question, an env var/key request, etc.
    let needsAttention: Bool
    /// Why the session is waiting, when the hook reported it
    /// (e.g. "Claude needs your permission to use Bash").
    let attentionMessage: String?
    /// The transcript backing this session, resolved once per poll so the
    /// menu and the click panel never have to search the disk themselves.
    let logFile: URL?

    var projectName: String? {
        projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// The reader that understands this session's transcript, if any.
    var transcript: (any TranscriptReader.Type)? {
        logFile == nil ? nil : Transcripts.reader(for: assistant.id)
    }
}

struct AssistantStatus: Sendable {
    let assistant: Assistant
    let sessions: [SessionStatus]

    var state: ActivityState {
        if sessions.isEmpty { return .absent }
        return sessions.contains { $0.state == .working } ? .working : .idle
    }
}

/// Watches the process list and each session's transcript, and reports what
/// every assistant session is doing.
///
/// All mutable state is confined to `queue`; the callbacks are snapshotted in
/// `start()` and only ever invoked on the main actor, which is what makes the
/// unchecked conformance safe.
final class ProcessMonitor: @unchecked Sendable {
    static let assistants: [Assistant] = [
        Assistant(id: "claude", displayName: "Claude Code", runnerEmoji: "🐎",
                  binaryNames: ["claude", "claude.exe"]),
        Assistant(id: "gemini", displayName: "Gemini CLI", runnerEmoji: "🦄",
                  binaryNames: ["gemini", "gemini.js"]),
        Assistant(id: "codex", displayName: "Codex CLI", runnerEmoji: "🐫",
                  binaryNames: ["codex", "codex.exe", "codex.js"]),
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
    /// A pending tool call younger than this is assumed to be a tool still
    /// running, not a permission prompt waiting for the user.
    private let pendingAttentionGrace: TimeInterval = 10

    /// Assigned before `start()`; `start()` copies them onto the poll queue.
    var onUpdate: (@MainActor @Sendable ([AssistantStatus]) -> Void)?
    /// Fired when a session stops working (went idle, or exited mid-run).
    var onFinished: (@MainActor @Sendable (SessionStatus) -> Void)?
    /// Fired when a session starts waiting for user input (permission/question).
    var onNeedsAttention: (@MainActor @Sendable (SessionStatus) -> Void)?
    /// Fired when a session begins a turn — used to refresh the usage window
    /// immediately instead of waiting for its own timer.
    var onSessionActive: (@MainActor @Sendable () -> Void)?

    private struct Handlers: Sendable {
        let update: (@MainActor @Sendable ([AssistantStatus]) -> Void)?
        let finished: (@MainActor @Sendable (SessionStatus) -> Void)?
        let attention: (@MainActor @Sendable (SessionStatus) -> Void)?
        let active: (@MainActor @Sendable () -> Void)?
    }

    private let queue = DispatchQueue(label: "vibecheck.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var handlers = Handlers(update: nil, finished: nil, attention: nil, active: nil)

    // Queue-confined caches.
    private var cpuHistory: [Int32: [Double]] = [:]
    private var cpuSamples: [Int32: (nanoseconds: UInt64, at: Date)] = [:]
    private var lastStates: [Int32: ActivityState] = [:]
    private var lastAttention: [Int32: Bool] = [:]
    private var lastSessions: [Int32: SessionStatus] = [:]
    private var cwdCache: [Int32: String] = [:]
    private var logFileCache: [Int32: URL] = [:]
    /// When a session's transcript could not be found, when to look again.
    private var logFileRetry: [Int32: Date] = [:]
    private var logTailCache: [String: (mtime: Date, state: LogTailState)] = [:]

    func start() {
        handlers = Handlers(
            update: onUpdate, finished: onFinished,
            attention: onNeedsAttention, active: onSessionActive)
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

        /// Matches on the strongest identifier available. A working directory
        /// is only conclusive when a single session of the *same assistant*
        /// reports from it — otherwise a Claude session would hand its phase
        /// to a Codex session sharing the directory.
        func lookup(assistantID: String, pid: Int32, sessionID: String?, cwd: String?)
            -> HookState? {
            if let state = byPID[pid], state.assistantID == assistantID { return state }
            if let sessionID, let state = bySessionID[sessionID],
               state.assistantID == assistantID { return state }
            if let cwd {
                let matching = (byCWD[cwd] ?? []).filter { $0.assistantID == assistantID }
                if matching.count == 1 { return matching[0] }
            }
            return nil
        }
    }

    private func poll() {
        let candidateNames = Set(Self.assistants.flatMap(\.binaryNames))
        guard let processes = ProcessList.snapshot(argvFor: candidateNames)
                ?? ProcessList.snapshotViaPS()
        else { return }
        let hooks = HookIndex(HookBridge.readAll())
        let now = Date()

        var children: [Int32: [Int32]] = [:]
        var parentOf: [Int32: Int32] = [:]
        var matched: [(assistant: Assistant, pid: Int32, args: String)] = []
        for entry in processes {
            children[entry.ppid, default: []].append(entry.pid)
            parentOf[entry.pid] = entry.ppid
            if let assistant = Self.match(args: entry.args) {
                matched.append((assistant, entry.pid, entry.args))
            }
        }
        matched = Self.rootSessions(matched, parentOf: parentOf)
        let sessionPids = Set(matched.map(\.pid))

        var sessionsByAssistant: [String: [SessionStatus]] = [:]
        var finished: [SessionStatus] = []
        var attentionStarted: [SessionStatus] = []
        var currentSessions: [Int32: SessionStatus] = [:]
        var sampledPids = Set<Int32>()
        var anyTurnStarted = false

        for (assistant, pid, args) in matched {
            // Own CPU plus child processes (tools the session is running),
            // stopping at nested sessions so they aren't double-counted.
            let subtree = Self.subtree(
                root: pid, children: children, stops: sessionPids.subtracting([pid]))
            sampledPids.formUnion(subtree)
            let cpu = cpuPercent(for: subtree, now: now)

            var history = cpuHistory[pid] ?? []
            history.append(cpu)
            if history.count > historySize {
                history.removeFirst(history.count - historySize)
            }
            cpuHistory[pid] = history

            let cpuActive = (history.max() ?? 0) >= workingCPUThreshold
            var state: ActivityState = cpuActive ? .working : .idle
            var needsAttention = false
            var attentionMessage: String?
            let projectPath = workingDirectory(for: pid)
            let argsSessionID = Self.sessionID(fromArgs: args)
            let hook = hooks.lookup(
                assistantID: assistant.id, pid: pid,
                sessionID: argsSessionID, cwd: projectPath)
            // Hooks carry the true session id even when the args have none;
            // with it, log lookups hit this session's own file instead of the
            // project's most recently written one.
            let sessionID = argsSessionID ?? hook?.sessionID
            let logFile = logFile(
                for: pid, assistantID: assistant.id,
                projectPath: projectPath, sessionID: sessionID, now: now)
            let tail = logFile.flatMap { self.logTail(assistantID: assistant.id, file: $0) }

            if history.count < 2 {
                // First sighting: hold the pid as idle for one poll, so
                // one-shot CLI calls that slipped past the filters die
                // before they can flash a runner on screen.
                state = .idle
            } else if let hook, Self.trusts(hook, tail: tail, horizon: turnActivityHorizon) {
                // Hooks report the session's own state, so they win over
                // anything inferred from CPU or the transcript.
                switch hook.phase {
                case .working:
                    state = .working
                case .attention:
                    state = .idle
                    needsAttention = true
                    attentionMessage = hook.message
                case .idle:
                    state = .idle
                }
            } else if let tail {
                // No hooks: the transcript still says where the turn stands
                // even when the process idles on an API wait.
                switch tail.state {
                case .awaitingUser:
                    // Codex says outright that it is blocked on an approval.
                    state = .idle
                    needsAttention = true
                case .awaitingAssistant where tail.age < turnActivityHorizon:
                    state = .working
                case .pendingToolUse:
                    if !cpuActive && tail.age >= pendingAttentionGrace {
                        state = .idle
                        needsAttention = true
                    } else {
                        state = .working
                    }
                case .turnEnded:
                    state = .idle
                default:
                    break
                }
            }

            let session = SessionStatus(
                assistant: assistant, pid: pid, state: state, cpu: cpu,
                projectPath: projectPath, sessionID: sessionID,
                needsAttention: needsAttention, attentionMessage: attentionMessage,
                logFile: logFile)

            if lastStates[pid] == .working && state == .idle && !needsAttention {
                finished.append(session)
            }
            if state == .working && lastStates[pid] != .working {
                anyTurnStarted = true
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
        cpuSamples = cpuSamples.filter { sampledPids.contains($0.key) }
        lastStates = lastStates.filter { sessionPids.contains($0.key) }
        lastAttention = lastAttention.filter { sessionPids.contains($0.key) }
        cwdCache = cwdCache.filter { sessionPids.contains($0.key) }
        logFileCache = logFileCache.filter { sessionPids.contains($0.key) }
        logFileRetry = logFileRetry.filter { sessionPids.contains($0.key) }
        lastSessions = currentSessions

        let statuses = Self.assistants.map { assistant in
            AssistantStatus(
                assistant: assistant,
                sessions: (sessionsByAssistant[assistant.id] ?? []).sorted { $0.pid < $1.pid })
        }

        let handlers = self.handlers
        let turnStarted = anyTurnStarted
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                SessionAnimals.prune(livePids: sessionPids)
                handlers.update?(statuses)
                for session in finished {
                    handlers.finished?(session)
                }
                for session in attentionStarted {
                    handlers.attention?(session)
                }
                if turnStarted { handlers.active?() }
            }
        }
    }

    /// Some phase changes fire no hook event, so a report is only good while
    /// the transcript agrees with it. Interrupting a turn with Esc fires no
    /// Stop hook: a "working" report whose transcript has gone quiet must not
    /// pin the runner forever. Answering a permission prompt fires nothing
    /// either: an "attention" report is stale once the transcript has moved
    /// past it (a tool result or new assistant entry landed afterwards).
    static func trusts(
        _ hook: HookState, tail: (state: LogTailState, age: TimeInterval)?,
        horizon: TimeInterval
    ) -> Bool {
        guard let tail else { return true }
        switch hook.phase {
        case .working:
            return tail.age < horizon
        case .attention:
            // (now - updated) - (now - mtime) = how far the log ran past the
            // report; the slack absorbs write-vs-hook ordering jitter.
            return Date().timeIntervalSince(hook.updated) - tail.age <= 2
        case .idle:
            return true
        }
    }

    // MARK: - CPU

    /// Every pid in a session's process tree, stopping at nested sessions.
    static func subtree(
        root: Int32, children: [Int32: [Int32]], stops: Set<Int32>
    ) -> [Int32] {
        var result: [Int32] = [root]
        var index = 0
        while index < result.count {
            let pid = result[index]
            index += 1
            for child in children[pid] ?? [] where !stops.contains(child) {
                result.append(child)
            }
        }
        return result
    }

    /// Utilisation across a process tree since the previous poll. `ps` only
    /// ever reported a decaying lifetime average; sampling consumed CPU time
    /// twice gives what the runner actually needs — is it busy *now*.
    private func cpuPercent(for pids: [Int32], now: Date) -> Double {
        var total = 0.0
        for pid in pids {
            guard let nanoseconds = ProcessList.cpuTime(of: pid) else { continue }
            if let previous = cpuSamples[pid] {
                let seconds = now.timeIntervalSince(previous.at)
                if seconds > 0.05, nanoseconds >= previous.nanoseconds {
                    total += Double(nanoseconds - previous.nanoseconds) / seconds / 1e7
                }
            }
            cpuSamples[pid] = (nanoseconds, now)
        }
        return total
    }

    // MARK: - Process matching

    /// A first argument that marks a one-shot invocation (a subcommand like
    /// `claude auth status` or print mode), not an interactive session.
    private static let nonSessionArguments: Set<String> = [
        "auth", "config", "mcp", "doctor", "update", "install", "plugin",
        "extensions", "setup-token", "migrate-installer", "exec", "login",
        "logout", "apply", "-p", "--print", "--version", "-v", "--help", "-h",
    ]

    /// Matches a process against known assistants by the basename of its first
    /// two argv tokens (covers both `claude ...` and `node /path/claude ...`),
    /// skipping one-shot invocations that are not interactive sessions.
    static func match(args: String) -> Assistant? {
        let lower = args.lowercased()
        for pattern in excludeSubstrings where lower.contains(pattern) {
            return nil
        }
        let tokens = args.split(separator: " ", omittingEmptySubsequences: true)
        for index in tokens.indices.prefix(2) {
            let name = URL(fileURLWithPath: String(tokens[index]))
                .lastPathComponent.lowercased()
            guard let assistant = assistants.first(where: { $0.binaryNames.contains(name) })
            else { continue }
            let next = tokens.index(after: index)
            if next < tokens.endIndex,
               nonSessionArguments.contains(tokens[next].lowercased()) {
                return nil
            }
            return assistant
        }
        return nil
    }

    /// Filters out matched processes that descend from another matched one —
    /// those are a session's own tool calls (an MCP server or a dev script
    /// shelling out to a CLI), or the npm shim that spawned the real binary,
    /// not separate terminal sessions.
    static func rootSessions(
        _ matched: [(assistant: Assistant, pid: Int32, args: String)],
        parentOf: [Int32: Int32]
    ) -> [(assistant: Assistant, pid: Int32, args: String)] {
        let pids = Set(matched.map(\.pid))
        return matched.filter { entry in
            var ancestor = parentOf[entry.pid]
            var hops = 0
            while let pid = ancestor, pid > 1, hops < 32 {
                if pids.contains(pid) { return false }
                ancestor = parentOf[pid]
                hops += 1
            }
            return true
        }
    }

    static func sessionID(fromArgs args: String) -> String? {
        let tokens = args.split(separator: " ")
        guard let index = tokens.firstIndex(of: "--session-id"),
              tokens.index(after: index) < tokens.endIndex else { return nil }
        return String(tokens[tokens.index(after: index)])
    }

    // MARK: - Transcript

    /// How long to wait before searching again for a transcript that could
    /// not be found. A miss is not cached permanently — a session's log may
    /// not exist yet on the first poll, and Codex writes its rollout a moment
    /// after start — but retrying every 1.5s is not free either: locating a
    /// Codex rollout means reading the head of each candidate file, so a
    /// session whose log never turns up would otherwise re-read them for as
    /// long as it lives.
    private let logFileRetryInterval: TimeInterval = 15

    /// Resolves (and remembers) the transcript file backing a session.
    private func logFile(
        for pid: Int32, assistantID: String, projectPath: String?, sessionID: String?,
        now: Date
    ) -> URL? {
        if let cached = logFileCache[pid],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        if let retryAt = logFileRetry[pid], now < retryAt { return nil }
        guard let reader = Transcripts.reader(for: assistantID),
              let file = reader.logFile(projectPath: projectPath, sessionID: sessionID)
        else {
            logFileRetry[pid] = now.addingTimeInterval(logFileRetryInterval)
            return nil
        }
        logFileCache[pid] = file
        logFileRetry.removeValue(forKey: pid)
        return file
    }

    /// Classifies a session's transcript tail, plus how long ago it was
    /// written. Only re-reads when the mtime changes.
    private func logTail(
        assistantID: String, file: URL
    ) -> (state: LogTailState, age: TimeInterval)? {
        guard let reader = Transcripts.reader(for: assistantID) else { return nil }
        let mtime = Transcripts.modified(file)
        guard mtime != .distantPast else { return nil }

        let age = Date().timeIntervalSince(mtime)
        if let cached = logTailCache[file.path], cached.mtime == mtime {
            return (cached.state, age)
        }
        let state = reader.tailState(file)
        logTailCache[file.path] = (mtime, state)
        return (state, age)
    }

    // MARK: - Working directory

    private func workingDirectory(for pid: Int32) -> String? {
        if let cached = cwdCache[pid] { return cached }
        // A failed read is not cached: libproc can transiently fail while a
        // process is still starting up, and caching that nil would strip the
        // session of its project name and transcript for its whole life.
        guard let path = Self.workingDirectory(of: pid) else { return nil }
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
}
