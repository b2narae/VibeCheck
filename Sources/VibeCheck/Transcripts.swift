import Foundation

/// Shape of the last entry in a session transcript — tells us where the turn
/// stands even when the process is quietly waiting on the API.
enum LogTailState: String, Sendable {
    case pendingToolUse     // a tool call was issued, no result yet
    case awaitingAssistant  // the model is computing (or a tool is producing)
    case awaitingUser       // the assistant said outright that it needs the user
    case turnEnded          // the turn is over
    case unknown
}

/// What a session's transcript says it is doing: the latest response text the
/// assistant produced and — when the turn is stopped — what it is asking for.
struct SessionDetail: Sendable {
    /// Most recent assistant text (the answer in progress, or the last one).
    var lastResponse: String?
    /// The instruction the session was last given. Collected in the same
    /// backward pass as the rest: reading the tail is the expensive part, and
    /// asking for this separately meant reading it twice.
    var lastPrompt: String?
    /// The question text when the assistant asked one outright.
    var pendingQuestion: String?
    /// "ToolName — argument" summary of a pending tool call.
    var pendingTool: String?
}

/// Reads one assistant's on-disk session transcript.
///
/// Every method is pure: locating the log is the only part that touches the
/// directory tree, and `ProcessMonitor` calls it once per poll and carries the
/// resolved URL on `SessionStatus`, so the menu and the click panel never
/// re-scan from the main thread.
protocol TranscriptReader {
    /// The log file backing a session, or nil when it cannot be identified.
    static func logFile(projectPath: String?, sessionID: String?) -> URL?
    static func tailState(_ url: URL) -> LogTailState
    static func lastUserPrompt(in url: URL) -> String?
    static func detail(in url: URL) -> SessionDetail?
}

enum Transcripts {
    /// The reader for an assistant, or nil when we cannot read its logs.
    static func reader(for assistantID: String) -> (any TranscriptReader.Type)? {
        switch assistantID {
        case "claude": return ClaudeTranscript.self
        case "codex": return CodexTranscript.self
        default: return nil  // Gemini CLI keeps no transcript we can read yet.
        }
    }

    // MARK: - Shared helpers

    /// How much of a transcript's tail to keep in reach when looking for the
    /// instruction and the last answer. They are usually within a few hundred
    /// kilobytes of the end, but a long tool-heavy turn buries them — in a
    /// real 34 MB Codex rollout the last instruction sat 2.75 MB back.
    static let deepChunk: UInt64 = 4 << 20

    /// Calls `body` with each line of the file's tail, newest first, and stops
    /// as soon as it returns true.
    ///
    /// Only the lines actually examined are decoded. That is the whole point:
    /// these transcripts answer every question from their newest few entries,
    /// so splitting a multi-megabyte tail into strings up front does work that
    /// is thrown away — and doing it repeatedly with a growing window, which
    /// is the obvious way to reach a buried instruction, measured worse than
    /// the fixed window it replaced.
    static func forEachLineFromEnd(of url: URL, limit: UInt64, _ body: (String) -> Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > limit ? size - limit : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        let bytes = [UInt8](data)
        let newline = UInt8(ascii: "\n")
        var end = bytes.count
        if end > 0, bytes[end - 1] == newline { end -= 1 }  // a trailing NL is not a line
        while end > 0 {
            var start = end
            while start > 0, bytes[start - 1] != newline { start -= 1 }
            if start < end,
               body(String(decoding: bytes[start..<end], as: UTF8.self)) { return }
            // The first line of the window is usually a fragment; it simply
            // fails to parse and the walk ends here either way.
            if start == 0 { return }
            end = start - 1
        }
    }

    /// Reads the last `limit` bytes of a file as text. Transcripts are
    /// append-only JSONL, so the tail is all any of these questions need.
    static func tail(of url: URL, limit: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > limit ? size - limit : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads the first `limit` bytes of a file as text.
    static func head(of url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Pulls one JSON string value out of raw text by key, honouring escapes.
    /// Used where the line is too large to be worth parsing in full.
    static func jsonString(_ key: String, in text: some StringProtocol) -> String? {
        guard let range = text.range(of: "\"\(key)\":\"") else { return nil }
        var result = ""
        var index = range.upperBound
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { return nil }
                switch text[next] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "u": return result  // give up on \uXXXX; paths never need it
                case let other: result.append(other)
                }
                index = text.index(after: next)
                continue
            }
            if character == "\"" { return result }
            result.append(character)
            index = text.index(after: index)
        }
        return nil
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// Newest `.jsonl` in a directory, by modification time.
    static func newestJSONL(in dir: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        return files
            .filter { $0.pathExtension == "jsonl" }
            .max { modified($0) < modified($1) }
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    /// Compact "ToolName — key argument" line for a pending tool call.
    static func toolSummary(name: String, input: [String: Any]) -> String {
        let hintKeys = [
            "command", "file_path", "path", "description",
            "pattern", "query", "url", "prompt",
        ]
        for key in hintKeys {
            if let value = input[key] as? String, !value.isEmpty {
                return "\(name) — \(clip(value, 100))"
            }
            if let list = input[key] as? [String], !list.isEmpty {
                return "\(name) — \(clip(list.joined(separator: " "), 100))"
            }
        }
        return name
    }
}
