import Foundation
import Testing
@testable import VibeCheck

// MARK: - Process matching

@Suite("Process matching")
struct MatchTests {
    @Test("A bare interactive CLI is matched")
    func bareCommand() {
        #expect(ProcessMonitor.match(args: "claude")?.id == "claude")
        #expect(ProcessMonitor.match(args: "/opt/homebrew/bin/claude --resume")?.id == "claude")
    }

    @Test("A CLI launched through node is matched on the second token")
    func viaNode() {
        let args = "/Users/me/.nvm/versions/node/v24.11.0/bin/node "
            + "/Users/me/.npm/lib/node_modules/@google/gemini-cli/dist/gemini.js"
        #expect(ProcessMonitor.match(args: args)?.id == "gemini")
    }

    @Test("Codex is matched as the native binary and as the npm shim")
    func codexBothShapes() {
        let native = "/Users/me/.npm/.../codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
        #expect(ProcessMonitor.match(args: native)?.id == "codex")
        let shim = "node /Users/me/.npm/lib/node_modules/@openai/codex/bin/codex.js"
        #expect(ProcessMonitor.match(args: shim)?.id == "codex")
    }

    @Test("One-shot invocations are not sessions", arguments: [
        "claude auth status", "claude -p 'hello'", "claude --version",
        "codex exec 'do a thing'", "gemini config list", "claude mcp list",
    ])
    func oneShot(_ args: String) {
        #expect(ProcessMonitor.match(args: args) == nil)
    }

    @Test("Resident helpers are excluded", arguments: [
        "claude daemon run", "/Applications/VibeCheck.app/Contents/MacOS/VibeCheck --hook",
        "codex bg-pty-host",
    ])
    func helpers(_ args: String) {
        #expect(ProcessMonitor.match(args: args) == nil)
    }

    @Test("An unrelated process is never an assistant")
    func unrelated() {
        #expect(ProcessMonitor.match(args: "node /Users/me/app/server.js") == nil)
        #expect(ProcessMonitor.match(args: "/bin/zsh -l") == nil)
    }

    @Test("--session-id is picked out of the arguments")
    func sessionID() {
        let id = "b09e5583-9c70-4488-8b30-4f1c2f2b8ce3"
        #expect(ProcessMonitor.sessionID(fromArgs: "claude --session-id \(id)") == id)
        #expect(ProcessMonitor.sessionID(fromArgs: "claude") == nil)
        #expect(ProcessMonitor.sessionID(fromArgs: "claude --session-id") == nil)
    }
}

@Suite("Session tree")
struct SessionTreeTests {
    private func assistant(_ id: String) -> Assistant {
        ProcessMonitor.assistants.first { $0.id == id }!
    }

    @Test("A CLI spawned by another session is not a second session")
    func nestedSessionIsDropped() {
        let matched = [
            (assistant: assistant("claude"), pid: Int32(100), args: "claude"),
            (assistant: assistant("gemini"), pid: Int32(140), args: "gemini"),
        ]
        // 140's parent chain reaches 100: it is a tool call, not a terminal.
        let parents: [Int32: Int32] = [140: 120, 120: 100, 100: 1]
        let roots = ProcessMonitor.rootSessions(matched, parentOf: parents)
        #expect(roots.map(\.pid) == [100])
    }

    @Test("The codex npm shim and its native child collapse to one session")
    func shimAndChild() {
        let matched = [
            (assistant: assistant("codex"), pid: Int32(200), args: "node .../bin/codex.js"),
            (assistant: assistant("codex"), pid: Int32(201), args: ".../vendor/.../bin/codex"),
        ]
        let roots = ProcessMonitor.rootSessions(matched, parentOf: [201: 200, 200: 1])
        #expect(roots.map(\.pid) == [200])
    }

    @Test("Independent sessions both survive")
    func siblings() {
        let matched = [
            (assistant: assistant("claude"), pid: Int32(300), args: "claude"),
            (assistant: assistant("claude"), pid: Int32(400), args: "claude"),
        ]
        let roots = ProcessMonitor.rootSessions(matched, parentOf: [300: 1, 400: 1])
        #expect(Set(roots.map(\.pid)) == [300, 400])
    }

    @Test("A subtree stops at a nested session")
    func subtreeStops() {
        let children: [Int32: [Int32]] = [10: [11, 12], 11: [13], 12: [14]]
        let all = ProcessMonitor.subtree(root: 10, children: children, stops: [])
        #expect(Set(all) == [10, 11, 12, 13, 14])
        let stopped = ProcessMonitor.subtree(root: 10, children: children, stops: [12])
        #expect(Set(stopped) == [10, 11, 13])
    }
}

// MARK: - Hook trust

@Suite("Hook reports are only trusted while the transcript agrees")
struct HookTrustTests {
    private func hook(_ phase: HookState.Phase, updated: Date = Date()) -> HookState {
        HookState(sessionID: "s", pid: 1, cwd: "/tmp", phase: phase,
                  message: nil, updated: updated, assistantID: "claude")
    }

    @Test("With no transcript there is nothing to contradict the hook")
    func noTranscript() {
        #expect(ProcessMonitor.trusts(hook(.working), tail: nil, horizon: 180))
    }

    @Test("A 'working' report survives while the log is still moving")
    func workingFresh() {
        let tail = (state: LogTailState.awaitingAssistant, age: TimeInterval(5))
        #expect(ProcessMonitor.trusts(hook(.working), tail: tail, horizon: 180))
    }

    @Test("A 'working' report is dropped once the log has gone quiet")
    func workingStale() {
        // Esc fires no Stop hook, so a silent transcript is the only sign.
        let tail = (state: LogTailState.awaitingAssistant, age: TimeInterval(600))
        #expect(!ProcessMonitor.trusts(hook(.working), tail: tail, horizon: 180))
    }

    @Test("An 'attention' report is dropped once the log runs past it")
    func attentionSuperseded() {
        // Report is 60s old; the log was written 5s ago, i.e. 55s after it.
        let hook = hook(.attention, updated: Date().addingTimeInterval(-60))
        let tail = (state: LogTailState.awaitingAssistant, age: TimeInterval(5))
        #expect(!ProcessMonitor.trusts(hook, tail: tail, horizon: 180))
    }

    @Test("An 'attention' report stands while nothing has happened since")
    func attentionStands() {
        let hook = hook(.attention, updated: Date().addingTimeInterval(-60))
        let tail = (state: LogTailState.pendingToolUse, age: TimeInterval(65))
        #expect(ProcessMonitor.trusts(hook, tail: tail, horizon: 180))
    }
}
