import Foundation

/// Claude's current 5-hour rate-limit block, estimated from local session logs.
///
/// **This measures time, not consumption.** A block resets Claude's limits
/// every five hours, and what the logs can prove is *where in that block you
/// are* — not how much of the quota you have burned. Two people with the same
/// reading may have spent 2% and 98% of their allowance. The app used to call
/// this "usage remaining"; it is "time until reset", and the wording follows
/// the code now rather than the other way round. `tokens` is the one genuinely
/// measured quantity, so it is reported as a plain count and never as a
/// fraction of a limit nobody publishes.
struct UsageWindow: Sendable {
    let start: Date
    let end: Date
    /// Tokens recorded across local sessions during this block.
    let tokens: Int
    /// Set only when Claude Code itself wrote a "usage limit reached" error,
    /// carrying the reset time it named. This is the one true exhaustion
    /// signal available locally.
    let limitResetsAt: Date?

    /// 0.0 = the block just started, 1.0 = it is about to reset.
    /// Elapsed time — deliberately not named "usage".
    func elapsedFraction(at now: Date = Date()) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }

    func remaining(at now: Date = Date()) -> TimeInterval {
        max(0, end.timeIntervalSince(now))
    }

    /// True only when Claude reported the limit reached and the reset it named
    /// has not arrived yet.
    func isExhausted(at now: Date = Date()) -> Bool {
        guard let limitResetsAt else { return false }
        return limitResetsAt > now
    }
}

/// Estimates the current Claude 5-hour block by scanning message timestamps in
/// ~/.claude/projects/**/*.jsonl (same approach as ccusage): a block starts at
/// the first activity after the previous block ended, floored to the hour, and
/// lasts exactly 5 hours.
///
/// Logs are append-only, so each file is read once and then only from wherever
/// the previous scan stopped. The first implementation re-read every recently
/// touched transcript in full, every minute, which for an app that sells
/// itself on being light was the heaviest thing it did.
final class UsageWindowTracker: @unchecked Sendable {
    private let blockLength: TimeInterval = 5 * 3600
    private let recomputeInterval: TimeInterval = 60
    private let lookback: TimeInterval = 24 * 3600

    /// Assigned before `start()`.
    var onUpdate: (@MainActor @Sendable (UsageWindow?) -> Void)?

    /// Where the transcripts live. Injectable so the block arithmetic can be
    /// tested against fixtures instead of the developer's own history.
    private let projectsDirectory: URL

    init(projectsDirectory: URL? = nil) {
        self.projectsDirectory = projectsDirectory ?? ClaudeTranscript.projectsDirectory
    }

    private let queue = DispatchQueue(label: "vibecheck.usage", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var handler: (@MainActor @Sendable (UsageWindow?) -> Void)?

    /// What a previous pass already read out of one transcript.
    private struct FileScan {
        var offset: UInt64
        var mtime: Date
        /// Minute-since-epoch → tokens recorded in that minute.
        var minutes: [Int: Int]
        /// The newest usage-limit report in the file, if any.
        var limit: (seenAt: Date, resetsAt: Date)?
    }
    private var scans: [String: FileScan] = [:]

    func start() {
        handler = onUpdate
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: recomputeInterval)
        timer.setEventHandler { [weak self] in self?.recompute() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Recomputes right away instead of waiting for the next tick. A block can
    /// begin the instant a session starts a turn, and a runner must not be
    /// drawn against a window that is up to a minute out of date.
    func refreshNow() {
        queue.async { [weak self] in self?.recompute() }
    }

    private func recompute() {
        let window = currentWindow()
        let handler = self.handler
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler?(window) }
        }
    }

    // MARK: - Block detection

    func currentWindow(now: Date = Date()) -> UsageWindow? {
        let cutoff = now.addingTimeInterval(-lookback)
        refreshScans(since: cutoff)

        var minutes: [Int: Int] = [:]
        var limit: (seenAt: Date, resetsAt: Date)?
        let cutoffMinute = Int(cutoff.timeIntervalSince1970 / 60)
        for scan in scans.values {
            for (minute, tokens) in scan.minutes where minute >= cutoffMinute {
                minutes[minute, default: 0] += tokens
            }
            if let candidate = scan.limit,
               candidate.seenAt > (limit?.seenAt ?? .distantPast) {
                limit = candidate
            }
        }
        guard !minutes.isEmpty else { return nil }

        let times = minutes.keys.sorted().map {
            Date(timeIntervalSince1970: Double($0) * 60)
        }
        var blockStart = Self.floorToHour(times[0])
        for time in times where time.timeIntervalSince(blockStart) >= blockLength {
            blockStart = Self.floorToHour(time)
        }
        let end = blockStart.addingTimeInterval(blockLength)
        guard now < end else { return nil }  // block elapsed, none active

        let startMinute = Int(blockStart.timeIntervalSince1970 / 60)
        let tokens = minutes
            .filter { $0.key >= startMinute }
            .values.reduce(0, +)

        // A limit report only speaks for the block it was made in.
        let resetsAt = limit.flatMap { $0.seenAt >= blockStart ? $0.resetsAt : nil }
        return UsageWindow(start: blockStart, end: end, tokens: tokens, limitResetsAt: resetsAt)
    }

    // MARK: - Incremental scanning

    /// How much of a transcript is read at a time. Recent logs can add up to
    /// hundreds of megabytes, so they are streamed rather than held whole.
    private static let chunkSize = 4 << 20

    private func refreshScans(since cutoff: Date) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        else { return }

        var live = Set<String>()
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate,
                  mtime > cutoff
            else { continue }
            live.insert(url.path)
            if scans[url.path]?.mtime == mtime { continue }
            scan(url, mtime: mtime)
        }
        // Files that fell out of the lookback window stop costing memory.
        scans = scans.filter { live.contains($0.key) }
    }

    /// Reads whatever is new in one transcript. Logs are append-only, so each
    /// file is parsed once and afterwards only from where the last pass ended.
    private func scan(_ url: URL, mtime: Date) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0

        var state = scans[url.path] ?? FileScan(
            offset: 0, mtime: .distantPast, minutes: [:], limit: nil)
        // A shrunken file was rotated or rewritten; start over.
        if size < state.offset {
            state = FileScan(offset: 0, mtime: .distantPast, minutes: [:], limit: nil)
        }
        guard size > state.offset else {
            state.mtime = mtime
            scans[url.path] = state
            return
        }
        try? handle.seek(toOffset: state.offset)

        var consumed = 0
        var carry: [UInt8] = []
        while let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            var buffer = carry
            buffer.append(contentsOf: chunk)
            carry = []
            // Only whole lines are consumed; a half-written tail waits for the
            // next pass rather than being parsed as truncated JSON.
            let used = buffer.withUnsafeBufferPointer { bytes in
                Self.scanLines(bytes, into: &state)
            }
            consumed += used
            if used < buffer.count { carry = Array(buffer[used...]) }
        }
        state.offset += UInt64(consumed)
        state.mtime = mtime
        scans[url.path] = state
    }

    /// Walks complete lines, returning how many bytes were consumed.
    ///
    /// This runs over every byte of every recent transcript, so it works on
    /// raw UTF-8 rather than building Swift strings: decoding these logs into
    /// `String` and splitting them cost about eighteen seconds on a working
    /// day's history, which an app that sells itself on being light cannot
    /// spend at launch.
    private static func scanLines(
        _ bytes: UnsafeBufferPointer<UInt8>, into scan: inout FileScan
    ) -> Int {
        var lineStart = 0
        var consumed = 0
        for index in 0..<bytes.count where bytes[index] == UInt8(ascii: "\n") {
            parseLine(bytes, from: lineStart, to: index, into: &scan)
            lineStart = index + 1
            consumed = index + 1
        }
        return consumed
    }

    private static func parseLine(
        _ bytes: UnsafeBufferPointer<UInt8>, from: Int, to: Int, into scan: inout FileScan
    ) {
        guard let stamp = timestamp(bytes, from, to) else { return }
        let minute = Int(stamp.timeIntervalSince1970 / 60)
        // Entries with no usage still mark activity, which is what decides
        // where the block starts.
        scan.minutes[minute, default: 0] += tokenCount(bytes, from, to)
        if let reset = usageLimitReset(bytes, from, to) {
            scan.limit = (seenAt: stamp, resetsAt: reset)
        }
    }

    // MARK: - Line parsing

    private static let timestampKey = Array(#""timestamp":""#.utf8)
    private static let usageKey = Array(#""usage""#.utf8)
    private static let apiErrorKey = Array(#""isApiErrorMessage":true"#.utf8)
    private static let limitKey = Array("usage limit reached|".utf8)
    /// Tokens billed by one entry.
    ///
    /// Cache *reads* are deliberately left out. They are the same cached
    /// prefix re-read on every request — 5.7 billion of them against 19
    /// million real input and output tokens in one day here — so including
    /// them turns the number into a measure of how long the conversation is,
    /// not of what the block spent.
    private static let tokenKeys = [
        Array(#""input_tokens":"#.utf8),
        Array(#""output_tokens":"#.utf8),
        Array(#""cache_creation_input_tokens":"#.utf8),
    ]

    /// Index of `needle` in `bytes[start..<end]`.
    static func index(
        of needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Int? {
        guard !needle.isEmpty, end - start >= needle.count else { return nil }
        let first = needle[0]
        let limit = end - needle.count
        var index = start
        while index <= limit {
            if bytes[index] == first {
                var offset = 1
                while offset < needle.count, bytes[index + offset] == needle[offset] {
                    offset += 1
                }
                if offset == needle.count { return index }
            }
            index += 1
        }
        return nil
    }

    private static func digits(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Int {
        var value = 0
        var index = start
        while index < end, bytes[index] >= 48, bytes[index] <= 57 {
            value = value * 10 + Int(bytes[index] - 48)
            index += 1
        }
        return value
    }

    static func timestamp(
        _ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int
    ) -> Date? {
        guard let key = index(of: timestampKey, in: bytes, from: start, to: end)
        else { return nil }
        return parseISO8601(bytes, key + timestampKey.count, end)
    }

    static func tokenCount(
        _ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int
    ) -> Int {
        guard index(of: usageKey, in: bytes, from: start, to: end) != nil else { return 0 }
        var total = 0
        for key in tokenKeys {
            guard let at = index(of: key, in: bytes, from: start, to: end) else { continue }
            total += digits(bytes, from: at + key.count, to: end)
        }
        return total
    }

    /// Claude Code records hitting the limit as an API error entry whose text
    /// is "Claude AI usage limit reached|<epoch>". That epoch is the server's
    /// own reset time — better than our estimate whenever it shows up.
    static func usageLimitReset(
        _ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int
    ) -> Date? {
        guard index(of: apiErrorKey, in: bytes, from: start, to: end) != nil,
              let at = index(of: limitKey, in: bytes, from: start, to: end)
        else { return nil }
        let epoch = digits(bytes, from: at + limitKey.count, to: end)
        guard epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(epoch))
    }

    /// Parses the "2026-08-06T12:03:18.257Z" shape these logs use.
    ///
    /// ISO8601DateFormatter is a class with mutable options — it is not
    /// Sendable, so a shared one would have to be locked and a per-line one
    /// re-allocated. This does the arithmetic directly instead.
    static func parseISO8601(
        _ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int
    ) -> Date? {
        guard end - start >= 19 else { return nil }

        func number(_ offset: Int, _ count: Int) -> Int? {
            var value = 0
            for index in (start + offset)..<(start + offset + count) {
                guard index < end, bytes[index] >= 48, bytes[index] <= 57 else { return nil }
                value = value * 10 + Int(bytes[index] - 48)
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              bytes[start + 4] == UInt8(ascii: "-"), bytes[start + 10] == UInt8(ascii: "T"),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        var index = start + 19
        var fraction = 0.0
        if index < end, bytes[index] == UInt8(ascii: ".") {
            index += 1
            var scale = 0.1
            while index < end, bytes[index] >= 48, bytes[index] <= 57 {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }

        // Trailing "Z", or a ±HH:MM offset to subtract.
        var offset = 0
        if index < end,
           bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
            let sign = bytes[index] == UInt8(ascii: "-") ? -1 : 1
            guard let hours = number(index - start + 1, 2),
                  let minutes = number(index - start + 4, 2) else { return nil }
            offset = sign * (hours * 3600 + minutes * 60)
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset)
        return Date(timeIntervalSince1970: seconds + fraction)
    }

    /// Days between 1970-01-01 and the given date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var year = year
        year -= month <= 2 ? 1 : 0
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func floorToHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}

// MARK: - String-facing wrappers (used by the tests and dev flags)

extension UsageWindowTracker {
    private static func onBytes<T>(
        _ text: some StringProtocol, _ body: (UnsafeBufferPointer<UInt8>, Int, Int) -> T
    ) -> T {
        Array(text.utf8).withUnsafeBufferPointer { body($0, 0, $0.count) }
    }

    static func parseTimestamp(_ line: some StringProtocol) -> Date? {
        onBytes(line) { timestamp($0, $1, $2) }
    }

    static func parseISO8601(_ text: some StringProtocol) -> Date? {
        onBytes(text) { parseISO8601($0, $1, $2) }
    }

    static func tokenCount(in line: some StringProtocol) -> Int {
        onBytes(line) { tokenCount($0, $1, $2) }
    }

    static func usageLimitReset(in line: some StringProtocol) -> Date? {
        onBytes(line) { usageLimitReset($0, $1, $2) }
    }
}
