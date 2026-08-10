import AppKit

/// A transparent, click-through overlay where one runner per visible session
/// gallops from right to left. Working sessions run; sessions waiting for
/// user input bounce in place (or dig down when they're at the top).
final class OverlayController {
    private struct Runner {
        let label: NSTextField
        let assistantID: String
        var x: CGFloat
        let lane: Int
        let speed: CGFloat   // points per tick
        var phase: CGFloat   // for vertical bobbing/jumping
    }

    private static let overlayDefaultsKey = "overlayEnabled"
    private let maxLanes = 4
    private let laneHeight: CGFloat = 55
    private let fontSize: CGFloat = 44
    private let tickInterval: TimeInterval = 1.0 / 30.0
    private let jumpAmplitude: CGFloat = 45

    private var window: NSWindow?
    private var runners: [Int32: Runner] = [:]   // keyed by session pid
    private var timer: Timer?
    private var sessions: [Int32: SessionStatus] = [:]
    private var order: [Int32] = []              // stable display order

    /// Claude's current 5-hour usage window. Claude runners run high on the
    /// screen when the window is fresh and sink to the bottom as it nears reset.
    var usageWindow: UsageWindow?

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.overlayDefaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.overlayDefaultsKey)
            refresh()
        }
    }

    /// Sessions to display: working ones plus those needing attention.
    func update(visible: [SessionStatus]) {
        sessions = Dictionary(uniqueKeysWithValues: visible.map { ($0.pid, $0) })
        order = visible.map(\.pid)
        refresh()
    }

    private func refresh() {
        guard enabled, !sessions.isEmpty else {
            timer?.invalidate()
            timer = nil
            runners.values.forEach { $0.label.removeFromSuperview() }
            runners.removeAll()
            window?.orderOut(nil)
            return
        }

        ensureWindow()
        syncRunners()
        refreshEmojis()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(timer!, forMode: .common)
        }
        window?.orderFrontRegardless()
    }

    private func ensureWindow() {
        if window != nil { return }
        guard let screen = NSScreen.main else { return }

        // Full visible height: Claude runners' altitude encodes the usage window.
        let frame = screen.visibleFrame

        let window = NSWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.window = window
    }

    private func syncRunners() {
        guard let content = window?.contentView else { return }

        for (pid, runner) in runners where sessions[pid] == nil {
            runner.label.removeFromSuperview()
            runners.removeValue(forKey: pid)
        }

        for pid in order {
            guard runners[pid] == nil, let session = sessions[pid] else { continue }
            let label = NSTextField(labelWithString: SessionAnimals.emoji(for: session))
            label.font = .systemFont(ofSize: fontSize)
            label.backgroundColor = .clear
            label.isBezeled = false
            label.sizeToFit()
            content.addSubview(label)

            let usedLanes = runners.values.map(\.lane)
            let lane = (0..<maxLanes).first { !usedLanes.contains($0) }
                ?? runners.count % maxLanes
            let runner = Runner(
                label: label,
                assistantID: session.assistant.id,
                x: content.bounds.width,
                lane: lane,
                speed: CGFloat.random(in: 0.7...1.3),  // leisurely: ~1 min per crossing
                phase: CGFloat.random(in: 0...(2 * .pi)))
            runners[pid] = runner
            position(runner, session: session)
        }
    }

    /// Re-applies each session's assigned emoji and attention marker.
    func refreshEmojis() {
        for (pid, session) in sessions {
            guard let runner = runners[pid] else { continue }
            let text = SessionAnimals.emoji(for: session) + (session.needsAttention ? "❗" : "")
            if runner.label.stringValue != text {
                runner.label.stringValue = text
                runner.label.sizeToFit()
            }
        }
    }

    private func tick() {
        guard let content = window?.contentView else { return }
        for (pid, var runner) in runners {
            guard let session = sessions[pid] else { continue }
            if session.needsAttention {
                // Nearly stationary, bouncing hard to call the user over.
                runner.x -= runner.speed * 0.2
                runner.phase += 0.55
            } else {
                runner.x -= runner.speed
                runner.phase += 0.18  // calm gait to match the slow run
            }
            if runner.x < -runner.label.frame.width {
                runner.x = content.bounds.width
            }
            runners[pid] = runner
            position(runner, session: session)
        }
    }

    private func position(_ runner: Runner, session: SessionStatus) {
        let base = baseY(for: runner)
        let amplitude: CGFloat = session.needsAttention ? jumpAmplitude : 7
        var offset = abs(sin(runner.phase)) * amplitude

        // At the top of the screen there is no room to jump up — dig down instead.
        if let content = window?.contentView,
           base + amplitude + fontSize > content.bounds.height - 10 {
            offset = -offset
        }
        runner.label.setFrameOrigin(NSPoint(x: runner.x, y: base + offset))
    }

    private func baseY(for runner: Runner) -> CGFloat {
        // Claude: altitude = how much of the 5-hour window remains.
        // Fresh window → top of the screen; nearly reset → bottom.
        if runner.assistantID == "claude", let usage = usageWindow,
           let content = window?.contentView {
            let top = content.bounds.height - fontSize - 24
            let bottom: CGFloat = 6
            let altitude = bottom + (top - bottom) * CGFloat(1 - usage.fraction())
            // Stagger concurrent Claude runners so they don't fully overlap.
            return altitude + CGFloat(runner.lane) * 14
        }
        return 6 + CGFloat(runner.lane) * laneHeight
    }
}
