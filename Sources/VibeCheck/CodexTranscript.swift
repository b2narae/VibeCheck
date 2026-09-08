import Foundation

/// Reads Codex CLI's rollout logs under ~/.codex/sessions.
///
/// Codex records explicit turn boundaries — `task_started`, `task_complete`,
/// `turn_aborted` — which is a stronger signal than anything Claude's log
/// offers, so a Codex session no longer has to be judged by CPU alone. Until
/// this existed, a Codex session waiting on the API looked finished: the
/// runner ran off screen and the completion sound fired mid-turn.
enum CodexTranscript: TranscriptReader {
    /// Enough of the tail to settle the turn state, which the newest few
    /// entries always decide.
    private static let tailChunk: UInt64 = 262_144
    /// The instruction and the last answer can sit much further back in a
    /// tool-heavy turn — a 32 MB rollout can carry a megabyte of tool traffic
    /// since the user last typed — so the detail pass reads a wider window,
    /// matching what the Claude reader does.
    private static let detailChunk: UInt64 = 1_048_576
    private static let headChunk = 65_536
    /// Rollout files live in sessions/YYYY/MM/DD under the date the session
    /// *started*, and a session that outlives that day keeps writing to the
    /// same file. Sampling this machine's history, 1 session in 10 was still
    /// being written a day or more after its folder's date, one of them four
    /// days later — so a window of three folders silently lost exactly the
    /// long-running sessions this reader exists to track.
    private static let dayFoldersScanned = 14
    /// A live session is by definition being appended to right now, so mtime
    /// is the real filter. It also keeps dead sessions from costing a head
    /// read on every miss.
    private static let liveWindow: TimeInterval = 3 * 86_400
    private static let maxCandidates = 12

    static var sessionsDirectory: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
        return home.appendingPathComponent("sessions")
    }

    /// The newest rollout whose `session_meta` records this working directory.
    /// Codex puts no session id on its command line, so the cwd is the only
    /// link between a running process and its log.
    static func logFile(projectPath: String?, sessionID: String?) -> URL? {
        guard let projectPath else { return nil }
        for url in recentRollouts() {
            guard let head = Transcripts.head(of: url, limit: headChunk),
                  let cwd = Transcripts.jsonString("cwd", in: head)
            else { continue }
            if cwd == projectPath { return url }
        }
        return nil
    }

    /// Rollout files that could belong to a live session, newest write first.
    private static func recentRollouts(now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        let root = sessionsDirectory
        guard let years = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return [] }

        // sessions/<year>/<month>/<day> — the names sort lexically in date
        // order, so the tail of a sorted walk is the most recent few days.
        var days: [URL] = []
        for year in years.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).suffix(2) {
            guard let months = try? fm.contentsOfDirectory(
                at: year, includingPropertiesForKeys: nil) else { continue }
            for month in months.sorted(by: {
                $0.lastPathComponent < $1.lastPathComponent
            }).suffix(2) {
                guard let dayFolders = try? fm.contentsOfDirectory(
                    at: month, includingPropertiesForKeys: nil) else { continue }
                days += dayFolders.sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
        }

        let cutoff = now.addingTimeInterval(-liveWindow)
        var files: [(url: URL, mtime: Date)] = []
        for day in days.suffix(dayFoldersScanned) {
            guard let contents = try? fm.contentsOfDirectory(
                at: day, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for url in contents where url.pathExtension == "jsonl" {
                let mtime = Transcripts.modified(url)
                if mtime > cutoff { files.append((url, mtime)) }
            }
        }
        return files
            .sorted { $0.mtime > $1.mtime }
            .prefix(maxCandidates)
            .map(\.url)
    }

    // MARK: - Turn state

    /// Events that settle where the turn stands. The scan runs backwards and
    /// stops at the first one it recognises, so a later event always wins:
    /// an approval request that has since been answered is buried under the
    /// tool output that followed it.
    private static func decision(type: String, payload: String) -> LogTailState? {
        switch (type, payload) {
        case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
            return .turnEnded
        case ("event_msg", "task_started"), ("event_msg", "user_message"):
            return .awaitingAssistant
        // Anything the assistant produced means it is still going.
        case ("event_msg", "agent_message"), ("event_msg", "patch_apply_end"),
             ("event_msg", "web_search_end"), ("event_msg", "mcp_tool_call_end"),
             ("event_msg", "item_completed"), ("event_msg", "sub_agent_activity"),
             ("response_item", "function_call_output"),
             ("response_item", "custom_tool_call_output"),
             ("response_item", "reasoning"), ("response_item", "message"),
             ("response_item", "agent_message"), ("response_item", "web_search_call"):
            return .awaitingAssistant
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
            return .pendingToolUse
        default:
            // Approval requests are the one thing that blocks Codex on the
            // user; their exact names differ across versions, so match the
            // shape (`*_approval_request`) rather than a fixed list.
            if type == "event_msg", payload.hasSuffix("_approval_request") {
                return .awaitingUser
            }
            // token_count and settings events fire constantly mid-turn and
            // must never end the scan.
            return nil
        }
    }

    static func tailState(_ url: URL) -> LogTailState {
        var result = LogTailState.unknown
        Transcripts.forEachLineFromEnd(of: url, limit: tailChunk) { line in
            guard let entry = parse(line),
                  let state = decision(type: entry.type, payload: entry.payloadType)
            else { return false }
            // A tool call that already carries a terminal status is not
            // pending — Codex rewrites the record once the call returns.
            if state == .pendingToolUse,
               let status = entry.payload["status"] as? String,
               status == "completed" || status == "failed" {
                result = .awaitingAssistant
            } else {
                result = state
            }
            return true
        }
        return result
    }

    static func lastUserPrompt(in url: URL) -> String? {
        var found: String?
        Transcripts.forEachLineFromEnd(of: url, limit: Transcripts.deepChunk) { line in
            guard let entry = parse(line),
                  entry.type == "event_msg", entry.payloadType == "user_message",
                  let prompt = userMessageText(entry.payload)
            else { return false }
            found = prompt
            return true
        }
        return found
    }

    /// The user's own text in a `user_message` event, or nil for wrappers.
    private static func userMessageText(_ payload: [String: Any]) -> String? {
        guard let message = payload["message"] as? String else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return Transcripts.clip(trimmed, 120)
    }

    static func detail(in url: URL) -> SessionDetail? {
        var detail = SessionDetail()
        var sawProgress = false
        Transcripts.forEachLineFromEnd(of: url, limit: Transcripts.deepChunk) { line in
            guard let entry = parse(line) else { return false }

            if entry.type == "event_msg", entry.payloadType.hasSuffix("_approval_request") {
                if detail.pendingTool == nil {
                    detail.pendingTool = approvalSummary(entry.payload)
                }
                return false
            }
            // Only a tool call that is still the newest thing in the log is
            // the one the session is stopped on.
            if !sawProgress, entry.type == "response_item",
               entry.payloadType == "function_call" || entry.payloadType == "custom_tool_call",
               (entry.payload["status"] as? String).map({
                   $0 != "completed" && $0 != "failed"
               }) ?? true {
                detail.pendingTool = detail.pendingTool ?? toolCallSummary(entry.payload)
            }
            if entry.payloadType.hasSuffix("_output") || entry.payloadType == "task_complete" {
                sawProgress = true
            }

            if detail.lastResponse == nil, entry.type == "event_msg",
               entry.payloadType == "agent_message",
               let message = entry.payload["message"] as? String, !message.isEmpty {
                detail.lastResponse = Transcripts.clip(message, 200)
            }
            if detail.lastPrompt == nil, entry.type == "event_msg",
               entry.payloadType == "user_message",
               let prompt = userMessageText(entry.payload) {
                detail.lastPrompt = prompt
            }
            return detail.lastResponse != nil && detail.lastPrompt != nil
        }
        return detail
    }

    // MARK: - Parsing

    private struct Entry {
        let type: String
        let payloadType: String
        let payload: [String: Any]
    }

    private static func parse(_ line: some StringProtocol) -> Entry? {
        guard line.contains("\"payload\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                  as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String
        else { return nil }
        return Entry(type: type, payloadType: payloadType, payload: payload)
    }

    private static func toolCallSummary(_ payload: [String: Any]) -> String {
        let name = payload["name"] as? String ?? "tool"
        // `function_call` carries JSON in `arguments`; `custom_tool_call`
        // carries the raw script in `input`.
        if let arguments = payload["arguments"] as? String,
           let data = arguments.data(using: .utf8),
           let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return Transcripts.toolSummary(name: name, input: input)
        }
        if let input = payload["input"] as? String, !input.isEmpty {
            return "\(name) — \(Transcripts.clip(input, 100))"
        }
        return name
    }

    private static func approvalSummary(_ payload: [String: Any]) -> String {
        for key in ["command", "reason", "call_id", "patch"] {
            if let value = payload[key] as? String, !value.isEmpty {
                return "\(L10n.t("approval", "승인")) — \(Transcripts.clip(value, 100))"
            }
            if let list = payload[key] as? [String], !list.isEmpty {
                return "\(L10n.t("approval", "승인")) — "
                    + Transcripts.clip(list.joined(separator: " "), 100)
            }
        }
        return L10n.t("waiting for your approval", "승인을 기다리는 중")
    }
}
