import AppKit

/// A transparent, click-through overlay where one pixel-art runner per visible
/// session trots from right to left with an animated 4-frame gait. A session
/// waiting for user input halts in front of a brick wall and nudges against it.
final class OverlayController {
    private struct Runner {
        let view: NSImageView
        let assistantID: String
        var emoji: String
        var x: CGFloat
        let lane: Int
        let speed: CGFloat   // points per tick
        var tickCount = 0
        var frameIndex = 0
        var phase: CGFloat = 0   // wall-nudge rhythm
        var wall: NSTextField?
    }

    private static let overlayDefaultsKey = "overlayEnabled"
    private let maxLanes = 4
    private let laneHeight: CGFloat = 55
    private let wallFontSize: CGFloat = 44
    private let tickInterval: TimeInterval = 1.0 / 30.0
    private let ticksPerGaitFrame = 8

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
            runners.values.forEach {
                $0.view.removeFromSuperview()
                $0.wall?.removeFromSuperview()
            }
            runners.removeAll()
            window?.orderOut(nil)
            return
        }

        ensureWindow()
        syncRunners()
        refreshSprites()
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
            runner.view.removeFromSuperview()
            runner.wall?.removeFromSuperview()
            runners.removeValue(forKey: pid)
        }

        for pid in order {
            guard runners[pid] == nil, let session = sessions[pid] else { continue }
            let emoji = SessionAnimals.emoji(for: session)
            let view = NSImageView()
            view.imageScaling = .scaleNone
            view.frame = NSRect(origin: .zero, size: Sprites.size)
            view.image = Sprites.frames(for: emoji)[0]
            content.addSubview(view)

            let usedLanes = runners.values.map(\.lane)
            let lane = (0..<maxLanes).first { !usedLanes.contains($0) }
                ?? runners.count % maxLanes
            let runner = Runner(
                view: view,
                assistantID: session.assistant.id,
                emoji: emoji,
                x: content.bounds.width,
                lane: lane,
                speed: CGFloat.random(in: 0.7...1.3))  // leisurely: ~1 min per crossing
            runners[pid] = runner
            position(runner, session: session)
        }
    }

    /// Re-applies each session's assigned animal and adds/removes the wall
    /// that blocks a runner while it waits for user input.
    func refreshSprites() {
        guard let content = window?.contentView else { return }
        for (pid, session) in sessions {
            guard var runner = runners[pid] else { continue }
            let emoji = SessionAnimals.emoji(for: session)
            if runner.emoji != emoji {
                runner.emoji = emoji
                runner.view.image = Sprites.frames(for: emoji)[runner.frameIndex]
                runners[pid] = runner
            }

            if session.needsAttention && runner.wall == nil {
                let wall = NSTextField(labelWithString: "🧱")
                wall.font = .systemFont(ofSize: wallFontSize)
                wall.backgroundColor = .clear
                wall.isBezeled = false
                wall.sizeToFit()
                content.addSubview(wall)
                // Keep the wall on screen even if the runner was near the edge.
                runner.x = max(runner.x, wall.frame.width + 16)
                runner.wall = wall
                runners[pid] = runner
            } else if !session.needsAttention, let wall = runner.wall {
                wall.removeFromSuperview()
                runner.wall = nil
                runners[pid] = runner
            }
        }
    }

    private func tick() {
        guard let content = window?.contentView else { return }
        for (pid, var runner) in runners {
            guard let session = sessions[pid] else { continue }
            if session.needsAttention {
                // Halted at the wall in a standing pose; only the nudge rhythm runs.
                runner.phase += 0.12
                if runner.frameIndex != Sprites.standingFrame {
                    runner.frameIndex = Sprites.standingFrame
                    runner.view.image = Sprites.frames(for: runner.emoji)[Sprites.standingFrame]
                }
            } else {
                runner.x -= runner.speed
                runner.tickCount += 1
                if runner.tickCount % ticksPerGaitFrame == 0 {
                    runner.frameIndex = (runner.frameIndex + 1) % 4
                    runner.view.image = Sprites.frames(for: runner.emoji)[runner.frameIndex]
                }
                if runner.x < -Sprites.size.width {
                    runner.x = content.bounds.width
                }
            }
            runners[pid] = runner
            position(runner, session: session)
        }
    }

    private func position(_ runner: Runner, session: SessionStatus) {
        let base = baseY(for: runner)
        if session.needsAttention {
            // Stopped, periodically pushing against the wall in front.
            let nudge = max(0, sin(runner.phase)) * 5
            runner.view.setFrameOrigin(NSPoint(x: runner.x - nudge, y: base))
            if let wall = runner.wall {
                wall.setFrameOrigin(NSPoint(x: runner.x - wall.frame.width - 2, y: base))
            }
        } else {
            // Level, forward-only motion — the gait frames carry the animation.
            runner.view.setFrameOrigin(NSPoint(x: runner.x, y: base))
        }
    }

    private func baseY(for runner: Runner) -> CGFloat {
        // Claude: altitude = how much of the 5-hour window remains.
        // Fresh window → top of the screen; nearly reset → bottom.
        if runner.assistantID == "claude", let usage = usageWindow,
           let content = window?.contentView {
            let top = content.bounds.height - Sprites.size.height - 24
            let bottom: CGFloat = 6
            let altitude = bottom + (top - bottom) * CGFloat(1 - usage.fraction())
            // Stagger concurrent Claude runners so they don't fully overlap.
            return altitude + CGFloat(runner.lane) * 14
        }
        return 6 + CGFloat(runner.lane) * laneHeight
    }
}
