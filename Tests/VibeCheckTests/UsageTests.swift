import Foundation
import Testing
@testable import VibeCheck

@Suite("Timestamp parsing")
struct TimestampTests {
    @Test("The transcript timestamp shape parses to the right instant")
    func fractionalUTC() {
        let date = UsageWindowTracker.parseISO8601("2026-08-06T12:03:18.257Z")
        #expect(date?.timeIntervalSince1970 == 1786017798.257)
    }

    @Test("A whole-second timestamp parses too")
    func plainUTC() {
        let date = UsageWindowTracker.parseISO8601("2026-08-06T12:03:18Z")
        #expect(date?.timeIntervalSince1970 == 1786017798)
    }

    @Test("A zone offset is applied")
    func offset() {
        let utc = UsageWindowTracker.parseISO8601("2026-08-06T12:00:00Z")!
        let kst = UsageWindowTracker.parseISO8601("2026-08-06T21:00:00+09:00")!
        #expect(utc == kst)
    }

    @Test("Junk is rejected rather than guessed at", arguments: [
        "", "not a date", "2026-08-06", "20260806T120000Z",
    ])
    func rejectsJunk(_ text: String) {
        #expect(UsageWindowTracker.parseISO8601(text) == nil)
    }

    @Test("The civil-date arithmetic matches Foundation across leap years",
          arguments: ["2024-02-29T00:00:00Z", "2000-01-01T00:00:00Z",
                      "1970-01-01T00:00:00Z", "2100-03-01T12:34:56Z"])
    func matchesFoundation(_ text: String) {
        let reference = ISO8601DateFormatter()
        #expect(UsageWindowTracker.parseISO8601(text) == reference.date(from: text))
    }
}

@Suite("Usage line parsing")
struct UsageLineTests {
    private let usageLine = """
        {"type":"assistant","message":{"usage":{"input_tokens":2,\
        "cache_creation_input_tokens":11432,"cache_read_input_tokens":22745,\
        "output_tokens":546}}}
        """

    @Test("Fresh tokens are counted")
    func tokens() {
        #expect(UsageWindowTracker.tokenCount(in: usageLine) == 2 + 11432 + 546)
    }

    @Test("Cache reads are excluded from the count")
    func cacheReadsExcluded() {
        // Re-reading the same cached prefix on every request dwarfs everything
        // else — 5.7 billion against 19 million in a day of real work — so
        // including it would measure conversation length, not spend.
        #expect(UsageWindowTracker.tokenCount(in: usageLine) < 22745)
    }

    @Test("A line with no usage costs nothing")
    func noTokens() {
        #expect(UsageWindowTracker.tokenCount(in: #"{"type":"user"}"#) == 0)
    }

    @Test("Claude's own limit report carries the reset time")
    func limitReport() {
        let line = """
            {"type":"assistant","isApiErrorMessage":true,"message":{"content":\
            [{"type":"text","text":"Claude AI usage limit reached|1786050000"}]}}
            """
        #expect(UsageWindowTracker.usageLimitReset(in: line)
            == Date(timeIntervalSince1970: 1786050000))
    }

    @Test("A transcript discussing the limit marker does not trigger it")
    func discussingTheMarkerIsNotAReport() {
        // Taken from a real session: asking Claude to grep for this very
        // marker writes the marker text into the transcript, as an assistant
        // tool_use entry. Fifteen such lines existed in one day's logs and
        // none may raise the tombstone — isApiErrorMessage is what separates
        // a report from a mention.
        let line = #"""
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
            "name":"Bash","input":{"command":"grep -rh 'usage limit reached|' ~/.claude"}}],\
            "stop_reason":"tool_use"}}
            """#
        #expect(UsageWindowTracker.usageLimitReset(in: line) == nil)
    }

    @Test("Text that merely mentions the limit is not a limit report")
    func mentionIsNotReport() {
        // A conversation *about* rate limits must not tombstone the runner.
        let line = """
            {"type":"assistant","message":{"content":[{"type":"text",\
            "text":"grep for 'usage limit reached|' in the logs"}]}}
            """
        #expect(UsageWindowTracker.usageLimitReset(in: line) == nil)
    }
}

@Suite("Five-hour block detection")
struct UsageWindowTests {
    /// Builds a transcript directory whose entries sit at the given offsets
    /// (in minutes) before `now`.
    private func tracker(
        minutesAgo: [Int], tokensEach: Int = 100, now: Date, extraLines: [String] = []
    ) -> UsageWindowTracker {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibecheck-usage-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-Users-me-app")
        try? FileManager.default.createDirectory(
            at: project, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        var lines = minutesAgo.map { minutes -> String in
            let stamp = formatter.string(from: now.addingTimeInterval(-Double(minutes) * 60))
            return """
                {"timestamp":"\(stamp)","type":"assistant",\
                "message":{"usage":{"output_tokens":\(tokensEach)}}}
                """
        }
        lines += extraLines
        try? (lines.joined(separator: "\n") + "\n").write(
            to: project.appendingPathComponent("s.jsonl"),
            atomically: true, encoding: .utf8)
        return UsageWindowTracker(projectsDirectory: root)
    }

    @Test("A block starts at the hour the first activity fell in")
    func blockStartsOnTheHour() {
        let now = Date(timeIntervalSince1970: 1786032198)  // 2026-08-06 12:03 UTC
        let window = tracker(minutesAgo: [30, 10, 1], now: now).currentWindow(now: now)
        let expectedStart = UsageWindowTracker.floorToHour(now.addingTimeInterval(-30 * 60))
        #expect(window?.start == expectedStart)
        #expect(window?.end == expectedStart.addingTimeInterval(5 * 3600))
    }

    @Test("Tokens inside the block are summed")
    func tokensSummed() {
        let now = Date(timeIntervalSince1970: 1786032198)
        let window = tracker(minutesAgo: [30, 20, 10], tokensEach: 250, now: now)
            .currentWindow(now: now)
        #expect(window?.tokens == 750)
    }

    @Test("Nothing recent means no block at all — not an empty one")
    func noActivity() {
        let now = Date(timeIntervalSince1970: 1786032198)
        #expect(tracker(minutesAgo: [], now: now).currentWindow(now: now) == nil)
    }

    @Test("An elapsed block is over, and that is not the same as exhausted")
    func elapsedBlockIsNotExhaustion() {
        // The old code treated "no active block" as "usage fully spent" and
        // drew a tombstone. This is the state that happens after a break —
        // when the most is left, not the least.
        let now = Date(timeIntervalSince1970: 1786032198)
        let window = tracker(minutesAgo: [7 * 60], now: now).currentWindow(now: now)
        #expect(window == nil)
    }

    @Test("A limit report inside the block is carried, and marks exhaustion")
    func limitReportCarried() {
        let now = Date(timeIntervalSince1970: 1786032198)
        let reset = now.addingTimeInterval(3600)
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-300))
        let report = """
            {"timestamp":"\(stamp)","type":"assistant","isApiErrorMessage":true,\
            "message":{"content":[{"type":"text","text":\
            "Claude AI usage limit reached|\(Int(reset.timeIntervalSince1970))"}]}}
            """
        let window = tracker(minutesAgo: [30], now: now, extraLines: [report])
            .currentWindow(now: now)
        #expect(window?.isExhausted(at: now) == true)
        #expect(window?.limitResetsAt == Date(timeIntervalSince1970: reset.timeIntervalSince1970))
    }

    @Test("A block with no limit report is never exhausted")
    func noReportNoExhaustion() {
        let now = Date(timeIntervalSince1970: 1786032198)
        let window = tracker(minutesAgo: [30], now: now).currentWindow(now: now)
        #expect(window?.isExhausted(at: now) == false)
    }

    @Test("Elapsed fraction runs from the start of the block to its reset")
    func elapsedFraction() {
        let start = Date(timeIntervalSince1970: 1786032000)
        let window = UsageWindow(
            start: start, end: start.addingTimeInterval(5 * 3600),
            tokens: 0, limitResetsAt: nil)
        #expect(window.elapsedFraction(at: start) == 0)
        #expect(window.elapsedFraction(at: start.addingTimeInterval(2.5 * 3600)) == 0.5)
        #expect(window.elapsedFraction(at: start.addingTimeInterval(9 * 3600)) == 1)
        #expect(window.remaining(at: start.addingTimeInterval(4 * 3600)) == 3600)
    }

    @Test("Appending to a transcript is picked up without re-reading it whole")
    func incrementalScan() {
        let now = Date(timeIntervalSince1970: 1786032198)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibecheck-incremental-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-Users-me-app")
        try? FileManager.default.createDirectory(
            at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s.jsonl")
        let formatter = ISO8601DateFormatter()

        func line(minutesAgo: Int, tokens: Int) -> String {
            let stamp = formatter.string(from: now.addingTimeInterval(-Double(minutesAgo) * 60))
            return """
                {"timestamp":"\(stamp)","type":"assistant",\
                "message":{"usage":{"output_tokens":\(tokens)}}}\n
                """
        }

        try? line(minutesAgo: 30, tokens: 100).write(
            to: file, atomically: true, encoding: .utf8)
        let tracker = UsageWindowTracker(projectsDirectory: root)
        #expect(tracker.currentWindow(now: now)?.tokens == 100)

        let handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
        try? handle?.write(contentsOf: Data(line(minutesAgo: 5, tokens: 40).utf8))
        try? handle?.close()
        // Fixtures can land inside the same second, so nudge the mtime past
        // the recorded one the way a live session's writes would.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: file.path)

        #expect(tracker.currentWindow(now: now)?.tokens == 140)
    }
}
