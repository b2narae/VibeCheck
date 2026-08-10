import Foundation

/// Claude usage-limit window info, estimated from local session logs.
struct UsageWindow {
    let start: Date
    let end: Date

    /// 0.0 = window just started (plenty left), 1.0 = about to reset.
    func fraction(at now: Date = Date()) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }

    func remaining(at now: Date = Date()) -> TimeInterval {
        max(0, end.timeIntervalSince(now))
    }
}

/// Estimates the current Claude 5-hour usage block by scanning message
/// timestamps in ~/.claude/projects/**/*.jsonl (same approach as ccusage):
/// a block starts at the first activity after the previous block ended,
/// floored to the hour, and lasts exactly 5 hours.
final class UsageWindowTracker {
    private let blockLength: TimeInterval = 5 * 3600
    private let recomputeInterval: TimeInterval = 60
    private let lookback: TimeInterval = 24 * 3600

    var onUpdate: ((UsageWindow?) -> Void)?

    private let queue = DispatchQueue(label: "vibecheck.usage", qos: .utility)
    private var timer: DispatchSourceTimer?

    func start() {
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

    private func recompute() {
        let window = Self.currentWindow(
            projectsDir: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects"),
            blockLength: blockLength,
            lookback: lookback)
        DispatchQueue.main.async { self.onUpdate?(window) }
    }

    static func currentWindow(
        projectsDir: URL, blockLength: TimeInterval, lookback: TimeInterval
    ) -> UsageWindow? {
        let now = Date()
        let cutoff = now.addingTimeInterval(-lookback)
        let times = activityTimes(projectsDir: projectsDir, since: cutoff)
        guard !times.isEmpty else { return nil }

        var blockStart = floorToHour(times[0])
        for time in times where time.timeIntervalSince(blockStart) >= blockLength {
            blockStart = floorToHour(time)
        }
        let end = blockStart.addingTimeInterval(blockLength)
        guard now < end else { return nil }  // window expired, none active
        return UsageWindow(start: blockStart, end: end)
    }

    /// Sorted, minute-deduplicated message timestamps from recently-touched logs.
    private static func activityTimes(projectsDir: URL, since cutoff: Date) -> [Date] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        else { return [] }

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainParser = ISO8601DateFormatter()

        var minutes = Set<Int>()
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate,
                  mtime > cutoff,
                  let content = try? String(contentsOf: url, encoding: .utf8)
            else { continue }

            for line in content.split(separator: "\n") {
                guard let stamp = extractTimestamp(line) else { continue }
                guard let date = parser.date(from: stamp) ?? plainParser.date(from: stamp)
                else { continue }
                if date > cutoff {
                    minutes.insert(Int(date.timeIntervalSince1970 / 60))
                }
            }
        }
        return minutes.sorted().map { Date(timeIntervalSince1970: Double($0) * 60) }
    }

    private static func extractTimestamp(_ line: Substring) -> String? {
        guard let keyRange = line.range(of: "\"timestamp\":\"") else { return nil }
        let rest = line[keyRange.upperBound...]
        guard let quote = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<quote])
    }

    private static func floorToHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}
