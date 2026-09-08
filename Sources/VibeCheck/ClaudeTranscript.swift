import Foundation

/// Reads Claude Code's JSONL session logs under ~/.claude/projects.
enum ClaudeTranscript: TranscriptReader {
    private static let tailChunk: UInt64 = 262_144
    private static let promptChunk: UInt64 = 1_048_576

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
        guard let text = Transcripts.tail(of: url, limit: tailChunk) else { return .unknown }

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
            return endOfTurnReasons.contains(message?["stop_reason"] as? String ?? "")
                ? .turnEnded : .awaitingAssistant
        }
        return .unknown
    }

    private static let endOfTurnReasons: Set<String> = [
        "end_turn", "stop_sequence", "max_tokens", "refusal",
    ]

    /// The most recent real user prompt — i.e. what the session was asked to
    /// do. Skips tool results, slash commands, and meta entries.
    static func lastUserPrompt(in url: URL) -> String? {
        guard let text = Transcripts.tail(of: url, limit: promptChunk) else { return nil }

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

            guard let result = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !result.isEmpty,
                  !result.hasPrefix("<"),          // command/system-reminder wrappers
                  !result.hasPrefix("[Request"),   // interruption markers
                  !result.hasPrefix("Caveat:")
            else { continue }
            return Transcripts.clip(result, 120)
        }
        return nil
    }

    static func detail(in url: URL) -> SessionDetail? {
        guard let text = Transcripts.tail(of: url, limit: promptChunk) else { return nil }

        var detail = SessionDetail()
        var isLatestEntry = true
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("assistant") || line.contains("user"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                      as? [String: Any],
                  let type = object["type"] as? String,
                  type == "assistant" || type == "user"
            else { continue }

            if type == "user" {
                // A user/tool_result entry answers everything before it.
                isLatestEntry = false
                continue
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
            if detail.lastResponse != nil { break }
        }
        return detail
    }
}
