import Foundation

/// Reads Claude Code's JSONL session logs under ~/.claude/projects.
enum ClaudeTranscript: TranscriptReader {
    private static let tailChunk: UInt64 = 262_144

    static var projectsDirectory: URL {
        // Claude Code honours CLAUDE_CONFIG_DIR; follow it so a relocated
        // config directory does not silently disable every Claude feature.
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// Claude Code encodes a project cwd as a directory name by replacing
    /// every non-alphanumeric character with "-".
    static func encodeProjectPath(_ path: String) -> String {
        String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    static func logFile(projectPath: String?, sessionID: String?) -> URL? {
        guard let projectPath else { return nil }
        let dir = projectsDirectory.appendingPathComponent(encodeProjectPath(projectPath))
        if let sessionID {
            let candidate = dir.appendingPathComponent("\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return Transcripts.newestJSONL(in: dir)
    }

    /// Classifies the last user/assistant entry, skipping snapshots, summaries
    /// and other bookkeeping lines. The candidate line is JSON-parsed rather
    /// than string-matched, so text that merely mentions these keys cannot be
    /// mistaken for structure.
    static func tailState(_ url: URL) -> LogTailState {
        var result = LogTailState.unknown
        Transcripts.forEachLineFromEnd(of: url, limit: tailChunk) { line in
            // Loose prefilter (whitespace-agnostic); the JSON parse decides.
            guard line.contains("assistant") || line.contains("user"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                      as? [String: Any],
                  let type = object["type"] as? String
            else { return false }

            if type == "user" {
                result = .awaitingAssistant
                return true
            }
            guard type == "assistant" else { return false }

            let message = object["message"] as? [String: Any]
            let blocks = message?["content"] as? [[String: Any]] ?? []
            if blocks.contains(where: { $0["type"] as? String == "tool_use" }) {
                result = .pendingToolUse
                return true
            }
            // Text and thinking blocks are written mid-turn too, so their mere
            // presence means nothing. stop_reason is what says whether the
            // model is done: "tool_use" means another block is still coming.
            result = endOfTurnReasons.contains(message?["stop_reason"] as? String ?? "")
                ? .turnEnded : .awaitingAssistant
            return true
        }
        return result
    }

    private static let endOfTurnReasons: Set<String> = [
        "end_turn", "stop_sequence", "max_tokens", "refusal",
    ]

    /// The most recent real user prompt — i.e. what the session was asked to
    /// do. Skips tool results, slash commands, and meta entries.
    static func lastUserPrompt(in url: URL) -> String? {
        var found: String?
        Transcripts.forEachLineFromEnd(of: url, limit: Transcripts.deepChunk) { line in
            guard line.contains("\"type\":\"user\""),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                      as? [String: Any],
                  object["type"] as? String == "user",
                  let prompt = promptText(in: object)
            else { return false }
            found = prompt
            return true
        }
        return found
    }

    static func detail(in url: URL) -> SessionDetail? {
        var detail = SessionDetail()
        var isLatestEntry = true
        Transcripts.forEachLineFromEnd(of: url, limit: Transcripts.deepChunk) { line in
            guard line.contains("assistant") || line.contains("user"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                      as? [String: Any],
                  let type = object["type"] as? String,
                  type == "assistant" || type == "user"
            else { return false }

            if type == "user" {
                // A user/tool_result entry answers everything before it.
                isLatestEntry = false
                if detail.lastPrompt == nil, let prompt = promptText(in: object) {
                    detail.lastPrompt = prompt
                }
                return detail.lastResponse != nil && detail.lastPrompt != nil
            }

            let message = object["message"] as? [String: Any]
            let blocks = message?["content"] as? [[String: Any]] ?? []

            // A tool_use in the newest entry has no result yet — that is what
            // the session is stopped on when it waits for permission/an answer.
            if isLatestEntry {
                for block in blocks where block["type"] as? String == "tool_use" {
                    let name = block["name"] as? String ?? "?"
                    let input = block["input"] as? [String: Any] ?? [:]
                    if name == "AskUserQuestion",
                       let questions = input["questions"] as? [[String: Any]],
                       let question = questions.first?["question"] as? String {
                        detail.pendingQuestion = Transcripts.clip(question, 160)
                    } else {
                        detail.pendingTool = Transcripts.toolSummary(name: name, input: input)
                    }
                }
            }
            isLatestEntry = false

            if detail.lastResponse == nil {
                let texts = blocks.compactMap { block -> String? in
                    block["type"] as? String == "text" ? block["text"] as? String : nil
                }
                let joined = texts.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { detail.lastResponse = Transcripts.clip(joined, 200) }
            }
            return detail.lastResponse != nil && detail.lastPrompt != nil
        }
        return detail
    }

    /// The user-authored text of a "user" entry, or nil when the entry is a
    /// tool result, a slash command, or other bookkeeping.
    private static func promptText(in object: [String: Any]) -> String? {
        guard object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any] else { return nil }

        var prompt: String?
        if let content = message["content"] as? String {
            prompt = content
        } else if let items = message["content"] as? [[String: Any]] {
            let texts = items.compactMap { item -> String? in
                item["type"] as? String == "text" ? item["text"] as? String : nil
            }
            if !texts.isEmpty { prompt = texts.joined(separator: " ") }
        }

        guard let result = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty,
              !result.hasPrefix("<"),          // command/system-reminder wrappers
              !result.hasPrefix("[Request"),   // interruption markers
              !result.hasPrefix("Caveat:")
        else { return nil }
        return Transcripts.clip(result, 120)
    }
}
