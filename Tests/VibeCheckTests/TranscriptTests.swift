import Foundation
import Testing
@testable import VibeCheck

/// Writes JSONL fixtures into a throwaway directory.
private struct Fixture {
    let directory: URL

    init() {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibecheck-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    func write(_ lines: [String], named name: String = "session.jsonl") -> URL {
        let url = directory.appendingPathComponent(name)
        try? (lines.joined(separator: "\n") + "\n").write(
            to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - Claude

@Suite("Claude transcript")
struct ClaudeTranscriptTests {
    private let userEntry = #"{"type":"user","message":{"role":"user","content":"do the thing"}}"#

    private func assistant(stopReason: String, text: String = "working on it") -> String {
        """
        {"type":"assistant","message":{"role":"assistant","stop_reason":"\(stopReason)",\
        "content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    @Test("A finished turn is only end_turn and friends")
    func turnEnded() {
        let file = Fixture().write([userEntry, assistant(stopReason: "end_turn")])
        #expect(ClaudeTranscript.tailState(file) == .turnEnded)
    }

    @Test("Assistant text mid-turn does not mean the turn is over")
    func midTurnTextIsNotDone() {
        // The bug this locks down: text and thinking blocks are written many
        // times per turn, so judging by content marked busy sessions finished
        // dozens of times and the runners kept dashing off screen.
        let file = Fixture().write([userEntry, assistant(stopReason: "tool_use")])
        #expect(ClaudeTranscript.tailState(file) == .awaitingAssistant)
    }

    @Test("A tool_use block with no result yet is pending")
    func pendingToolUse() {
        let line = """
            {"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use",\
            "content":[{"type":"tool_use","name":"Bash","input":{"command":"git push"}}]}}
            """
        let file = Fixture().write([userEntry, line])
        #expect(ClaudeTranscript.tailState(file) == .pendingToolUse)
    }

    @Test("A user entry means the model is computing")
    func userEntryIsAwaiting() {
        let file = Fixture().write([assistant(stopReason: "end_turn"), userEntry])
        #expect(ClaudeTranscript.tailState(file) == .awaitingAssistant)
    }

    @Test("Text that merely quotes the structure cannot fake a finished turn")
    func quotedStructureIsNotStructure() {
        let line = """
            {"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use",\
            "content":[{"type":"text","text":"we check for \\"stop_reason\\":\\"end_turn\\" here"}]}}
            """
        let file = Fixture().write([userEntry, line])
        #expect(ClaudeTranscript.tailState(file) == .awaitingAssistant)
    }

    @Test("Bookkeeping lines are skipped")
    func skipsBookkeeping() {
        let file = Fixture().write([
            userEntry,
            assistant(stopReason: "end_turn"),
            #"{"type":"summary","summary":"a previous conversation"}"#,
            #"{"type":"file-history-snapshot","messageId":"abc"}"#,
        ])
        #expect(ClaudeTranscript.tailState(file) == .turnEnded)
    }

    @Test("The last real user prompt wins over meta and wrapper entries")
    func lastPrompt() {
        let file = Fixture().write([
            #"{"type":"user","message":{"role":"user","content":"first ask"}}"#,
            #"{"type":"user","message":{"role":"user","content":"second ask"}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"meta noise"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
        ])
        #expect(ClaudeTranscript.lastUserPrompt(in: file) == "second ask")
    }

    @Test("The pending question and the latest answer are read back")
    func detail() {
        let file = Fixture().write([
            #"{"type":"user","message":{"role":"user","content":"ship it"}}"#,
            """
            {"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn",\
            "content":[{"type":"text","text":"Here is what I found."}]}}
            """,
            """
            {"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use",\
            "content":[{"type":"tool_use","name":"AskUserQuestion","input":\
            {"questions":[{"question":"Which database?"}]}}]}}
            """,
        ])
        let detail = ClaudeTranscript.detail(in: file)
        #expect(detail?.pendingQuestion == "Which database?")
        #expect(detail?.lastResponse == "Here is what I found.")
    }

    @Test("A tool awaiting permission is summarised with its argument")
    func pendingToolSummary() {
        let file = Fixture().write([
            #"{"type":"user","message":{"role":"user","content":"push"}}"#,
            """
            {"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use",\
            "content":[{"type":"tool_use","name":"Bash","input":{"command":"git push origin main"}}]}}
            """,
        ])
        #expect(ClaudeTranscript.detail(in: file)?.pendingTool == "Bash — git push origin main")
    }

    @Test("A project path encodes to Claude's own folder name")
    func projectEncoding() {
        #expect(ClaudeTranscript.encodeProjectPath("/Users/me/Desktop/code/VibeCheck")
            == "-Users-me-Desktop-code-VibeCheck")
        #expect(ClaudeTranscript.encodeProjectPath("/tmp/a_b.c") == "-tmp-a-b-c")
    }
}

// MARK: - Codex

@Suite("Codex transcript")
struct CodexTranscriptTests {
    private func event(_ type: String, _ extra: String = "") -> String {
        """
        {"timestamp":"2026-09-08T10:00:00.000Z","type":"event_msg",\
        "payload":{"type":"\(type)"\(extra.isEmpty ? "" : ",\(extra)")}}
        """
    }
    private func item(_ type: String, _ extra: String = "") -> String {
        """
        {"timestamp":"2026-09-08T10:00:00.000Z","type":"response_item",\
        "payload":{"type":"\(type)"\(extra.isEmpty ? "" : ",\(extra)")}}
        """
    }
    private let tokenNoise = """
        {"timestamp":"2026-09-08T10:00:01.000Z","type":"event_msg",\
        "payload":{"type":"token_count","info":{"total":1234}}}
        """

    @Test("A started turn with no completion is still running")
    func started() {
        let file = Fixture().write([event("user_message", #""message":"go""#), event("task_started")])
        #expect(CodexTranscript.tailState(file) == .awaitingAssistant)
    }

    @Test("token_count noise never ends the scan")
    func tokenNoiseIgnored() {
        // These fire many times a turn; treating one as decisive would make
        // every Codex session look finished mid-turn.
        let file = Fixture().write([
            event("task_started"), tokenNoise, tokenNoise, tokenNoise,
        ])
        #expect(CodexTranscript.tailState(file) == .awaitingAssistant)
    }

    @Test("task_complete ends the turn")
    func complete() {
        let file = Fixture().write([event("task_started"), event("task_complete")])
        #expect(CodexTranscript.tailState(file) == .turnEnded)
    }

    @Test("An interrupted turn ends too")
    func aborted() {
        let file = Fixture().write([
            event("task_started"), event("turn_aborted", #""reason":"interrupted""#),
        ])
        #expect(CodexTranscript.tailState(file) == .turnEnded)
    }

    @Test("An approval request blocks on the user")
    func approvalBlocks() {
        let file = Fixture().write([
            event("task_started"),
            event("exec_approval_request", #""command":"rm -rf build""#),
        ])
        #expect(CodexTranscript.tailState(file) == .awaitingUser)
    }

    @Test("An answered approval no longer blocks")
    func approvalSuperseded() {
        // Approving fires no second event, so the tool output that follows is
        // what has to release the wall.
        let file = Fixture().write([
            event("task_started"),
            event("apply_patch_approval_request", #""patch":"diff""#),
            item("custom_tool_call_output", #""output":"done""#),
        ])
        #expect(CodexTranscript.tailState(file) == .awaitingAssistant)
    }

    @Test("A tool call with no output yet is pending")
    func pendingCall() {
        let file = Fixture().write([
            event("task_started"),
            item("function_call", #""name":"shell","arguments":"{\"command\":\"ls\"}""#),
        ])
        #expect(CodexTranscript.tailState(file) == .pendingToolUse)
    }

    @Test("A completed tool call is not pending")
    func completedCall() {
        let file = Fixture().write([
            event("task_started"),
            item("custom_tool_call", #""name":"exec","status":"completed","input":"ls""#),
        ])
        #expect(CodexTranscript.tailState(file) == .awaitingAssistant)
    }

    @Test("The last user message and agent message are read back")
    func promptAndDetail() {
        let file = Fixture().write([
            event("user_message", #""message":"first""#),
            event("agent_message", #""message":"an earlier answer""#),
            event("user_message", #""message":"deploy the site""#),
            event("agent_message", #""message":"Deploying now."#+#"""#),
            event("task_started"),
        ])
        #expect(CodexTranscript.lastUserPrompt(in: file) == "deploy the site")
        #expect(CodexTranscript.detail(in: file)?.lastResponse == "Deploying now.")
    }

    @Test("A pending approval is summarised with the command")
    func approvalSummary() {
        let file = Fixture().write([
            event("task_started"),
            event("exec_approval_request", #""command":"git push --force""#),
        ])
        let tool = CodexTranscript.detail(in: file)?.pendingTool
        #expect(tool?.contains("git push --force") == true)
    }

    @Test("An empty or unreadable log says nothing rather than guessing")
    func emptyLog() {
        let file = Fixture().write([])
        #expect(CodexTranscript.tailState(file) == .unknown)
        let missing = URL(fileURLWithPath: "/nope/does-not-exist.jsonl")
        #expect(CodexTranscript.tailState(missing) == .unknown)
    }
}

// MARK: - Shared helpers

@Suite("Transcript helpers")
struct TranscriptHelperTests {
    @Test("JSON string values are read back through their escapes")
    func jsonEscapes() {
        let line = #"{"cwd":"/Users/me/Desktop/code \"x\"/app","other":1}"#
        #expect(Transcripts.jsonString("cwd", in: line) == #"/Users/me/Desktop/code "x"/app"#)
        #expect(Transcripts.jsonString("missing", in: line) == nil)
    }

    @Test("Long text is clipped and flattened")
    func clip() {
        #expect(Transcripts.clip("a\nb", 10) == "a b")
        #expect(Transcripts.clip(String(repeating: "x", count: 20), 5) == "xxxxx…")
    }
}

// MARK: - Locating a session's log

/// Serialized because it sets CODEX_HOME, which is process-wide.
@Suite("Codex log lookup", .serialized)
struct CodexLookupTests {
    /// Builds a $CODEX_HOME/sessions/YYYY/MM/DD tree and points Codex at it.
    private func makeHome(_ rollouts: [(day: String, name: String, cwd: String)]) -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-home-\(UUID().uuidString)")
        for rollout in rollouts {
            let parts = rollout.day.split(separator: "-")
            let dir = home.appendingPathComponent("sessions")
                .appendingPathComponent(String(parts[0]))
                .appendingPathComponent(String(parts[1]))
                .appendingPathComponent(String(parts[2]))
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            let meta = """
                {"timestamp":"2026-09-08T10:00:00.000Z","type":"session_meta",\
                "payload":{"session_id":"\(rollout.name)","cwd":"\(rollout.cwd)",\
                "originator":"codex-tui","base_instructions":{"text":"\
                \(String(repeating: "system prompt filler ", count: 400))"}}}
                {"timestamp":"2026-09-08T10:00:01.000Z","type":"event_msg",\
                "payload":{"type":"task_started"}}
                """
            try? (meta + "\n").write(
                to: dir.appendingPathComponent("rollout-\(rollout.name).jsonl"),
                atomically: true, encoding: .utf8)
        }
        setenv("CODEX_HOME", home.path, 1)
        return home
    }

    @Test("A session is found by the working directory its rollout records")
    func findsByCWD() {
        defer { unsetenv("CODEX_HOME") }
        _ = makeHome([
            (day: "2026-09-08", name: "aaa", cwd: "/Users/me/project-a"),
            (day: "2026-09-08", name: "bbb", cwd: "/Users/me/project-b"),
        ])
        let file = CodexTranscript.logFile(projectPath: "/Users/me/project-b", sessionID: nil)
        #expect(file?.lastPathComponent == "rollout-bbb.jsonl")
        #expect(CodexTranscript.tailState(file!) == .awaitingAssistant)
    }

    @Test("The cwd is read past a very large system-prompt line")
    func readsPastBigMetaLine() {
        // session_meta carries the whole base prompt, so the cwd has to be
        // found without parsing the line in full.
        defer { unsetenv("CODEX_HOME") }
        _ = makeHome([(day: "2026-09-08", name: "big", cwd: "/Users/me/wide")])
        #expect(CodexTranscript.logFile(projectPath: "/Users/me/wide", sessionID: nil) != nil)
    }

    @Test("An unknown directory resolves to nothing rather than the wrong log")
    func unknownDirectory() {
        defer { unsetenv("CODEX_HOME") }
        _ = makeHome([(day: "2026-09-08", name: "aaa", cwd: "/Users/me/project-a")])
        #expect(CodexTranscript.logFile(projectPath: "/Users/me/elsewhere", sessionID: nil) == nil)
        #expect(CodexTranscript.logFile(projectPath: nil, sessionID: nil) == nil)
    }
}
