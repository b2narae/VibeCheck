import Foundation

/// Reads Codex CLI's rollout logs under ~/.codex/sessions.
///
/// Codex records explicit turn boundaries — `task_started`, `task_complete`,
/// `turn_aborted` — which is a stronger signal than anything Claude's log
/// offers, so a Codex session no longer has to be judged by CPU alone. Until
/// this existed, a Codex session waiting on the API looked finished: the
/// runner ran off screen and the completion sound fired mid-turn.
enum CodexTranscript: TranscriptReader {
    private static let tailChunk: UInt64 = 262_144
    private static let headChunk = 32_768
    /// Rollout files live in sessions/YYYY/MM/DD; only the newest few day
    /// folders can hold a live session, so history size never costs anything.
    private static let dayFoldersScanned = 3
    private static let maxCandidates = 40

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

    /// Rollout files from the newest day folders, newest write first.
    private static func recentRollouts() -> [URL] {
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

        var files: [URL] = []
        for day in days.suffix(dayFoldersScanned) {
            guard let contents = try? fm.contentsOfDirectory(
                at: day, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            files += contents.filter { $0.pathExtension == "jsonl" }
        }
        return files
            .sorted { Transcripts.modified($0) > Transcripts.modified($1) }
            .prefix(maxCandidates)
            .map { $0 }
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
        guard let text = Transcripts.tail(of: url, limit: tailChunk) else { return .unknown }
        for line in text.split(separator: "\n").reversed() {
            guard let entry = parse(line) else { continue }
            if let state = decision(type: entry.type, payload: entry.payloadType) {
                // A tool call that already carries a terminal status is not
                // pending — Codex rewrites the record once the call returns.
                if state == .pendingToolUse,
                   let status = entry.payload["status"] as? String,
                   status == "completed" || status == "failed" {
                    return .awaitingAssistant
                }
                return state
            }
        }
        return .unknown
    }

    static func lastUserPrompt(in url: URL) -> String? {
        guard let text = Transcripts.tail(of: url, limit: tailChunk) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let entry = parse(line),
                  entry.type == "event_msg", entry.payloadType == "user_message",
                  let message = entry.payload["message"] as? String
            else { continue }
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { continue }
            return Transcripts.clip(trimmed, 120)
        }
        return nil
    }

    static func detail(in url: URL) -> SessionDetail? {
        guard let text = Transcripts.tail(of: url, limit: tailChunk) else { return nil }

        var detail = SessionDetail()
        var sawProgress = false
        for line in text.split(separator: "\n").reversed() {
            guard let entry = parse(line) else { continue }

            if entry.type == "event_msg", entry.payloadType.hasSuffix("_approval_request") {
                if detail.pendingTool == nil {
                    detail.pendingTool = approvalSummary(entry.payload)
                }
                continue
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
            if detail.lastResponse != nil && detail.pendingTool != nil { break }
        }
        return detail
    }

    // MARK: - Parsing

    private struct Entry {
        let type: String
        let payloadType: String
        let payload: [String: Any]
    }

    private static func parse(_ line: Substring) -> Entry? {
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
