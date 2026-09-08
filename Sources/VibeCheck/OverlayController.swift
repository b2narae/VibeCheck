import AppKit

/// Content view that reports clicks to the controller.
private final class OverlayContentView: NSView {
    var onClick: ((NSPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil))
    }
}

/// A transparent, click-through overlay where one pixel-art runner per visible
/// session trots from right to left with an animated 4-frame gait. A session
/// waiting for user input halts in front of a brick wall and nudges against it.
/// Hovering over a runner (or its wall) makes just that spot clickable;
/// clicking shows what the session was asked, its latest response, and — when
/// blocked — the question or permission it is waiting on.
@MainActor
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
        var isTombstone = false   // Claude reported the usage limit reached
    }

    private static let overlayDefaultsKey = "overlayEnabled"
    private let laneHeight: CGFloat = 55
    private let wallFontSize: CGFloat = 44
    /// Floor for a running Claude runner's opacity — it fades toward this as
    /// the block's time runs out, but never gets hard to see.
    private let minRunnerAlpha: CGFloat = 0.28
    private let tickInterval: TimeInterval = 1.0 / 30.0
    private let ticksPerGaitFrame = 8

    private var window: NSWindow?
    private var runners: [Int32: Runner] = [:]   // keyed by session pid
    private var timer: Timer?
    private var sessions: [Int32: SessionStatus] = [:]
    private var order: [Int32] = []              // stable display order
    private var infoPanel: NSView?
    private var infoPanelTimer: Timer?

    /// Claude's current 5-hour block. Claude runners run high on the screen
    /// when the block is fresh and sink as it approaches its reset. This is
    /// time remaining, not quota remaining — see `UsageWindow`.
    var usageWindow: UsageWindow?

    /// Honour the system "reduce motion" setting: an always-present animation
    /// crossing the screen is exactly what that preference is asking about.
    /// The runners stay, and still say everything they say — which session,
    /// blocked or not, how much of the block is left — they just hold still.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// How many rows of runners fit on the current screen arrangement.
    private var laneCount: Int {
        guard let height = window?.contentView?.bounds.height else { return 4 }
        return max(4, min(8, Int(height / laneHeight) - 1))
    }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.overlayDefaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.overlayDefaultsKey)
            refresh()
        }
    }

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Sessions to display: working ones plus those needing attention.
    func update(visible: [SessionStatus]) {
        sessions = Dictionary(uniqueKeysWithValues: visible.map { ($0.pid, $0) })
        order = visible.map(\.pid)
        refresh()
    }

    private func refresh() {
        guard enabled else {
            teardown()
            return
        }

        if !sessions.isEmpty { ensureWindow() }
        syncRunners()
        refreshSprites()

        // Keep ticking while finished runners are still dashing off-screen.
        guard !runners.isEmpty else {
            timer?.invalidate()
            timer = nil
            window?.orderOut(nil)
            return
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer!, forMode: .common)
        }
        window?.orderFrontRegardless()
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        for runner in runners.values {
            runner.view.removeFromSuperview()
            runner.wall?.removeFromSuperview()
        }
        runners.removeAll()
        infoPanel?.removeFromSuperview()
        infoPanel = nil
        window?.orderOut(nil)
    }

    /// The rectangle covering every attached display. Runners used to live on
    /// `NSScreen.main` only, decided once and never revisited, so a laptop
    /// docked to an external display lost them.
    private static func overlayFrame() -> NSRect {
        NSScreen.screens.reduce(NSRect.zero) { union, screen in
            union.isEmpty ? screen.visibleFrame : union.union(screen.visibleFrame)
        }
    }

    private func ensureWindow() {
        if window != nil { return }
        let frame = Self.overlayFrame()
        guard !frame.isEmpty else { return }

        let window = NSWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = OverlayContentView(frame: NSRect(origin: .zero, size: frame.size))
        content.onClick = { [weak self] point in
            MainActor.assumeIsolated { self?.handleClick(at: point) }
        }
        window.contentView = content
        self.window = window
    }

    /// A display was attached, removed or rearranged: resize to the new union
    /// and pull any runner that is now outside it back into view.
    private func screensChanged() {
        guard let window else { return }
        let frame = Self.overlayFrame()
        guard !frame.isEmpty else { return }
        window.setFrame(frame, display: true)
        window.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        let width = frame.width
        for (pid, var runner) in runners where runner.x > width {
            runner.x = width
            runners[pid] = runner
        }
        refresh()
    }

    private func syncRunners() {
        guard let content = window?.contentView else { return }

        // Runners whose session vanished are not removed here — tick() lets
        // them dash off the left edge first. Their wall goes away immediately.
        for (pid, var runner) in runners where sessions[pid] == nil && runner.wall != nil {
            runner.wall?.removeFromSuperview()
            runner.wall = nil
            runners[pid] = runner
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
            let lanes = laneCount
            let lane = (0..<lanes).first { !usedLanes.contains($0) } ?? runners.count % lanes
            let runner = Runner(
                view: view,
                assistantID: session.assistant.id,
                emoji: emoji,
                x: content.bounds.width,
                lane: lane,
                speed: CGFloat.random(in: 0.7...1.3))  // leisurely: ~1 min per crossing
            runners[pid] = runner
            refreshAppearance(pid)
            position(runners[pid]!, session: session)
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
        let still = reduceMotion
        for (pid, var runner) in runners {
            guard let session = sessions[pid] else {
                // Finished: dash off the left edge, then leave. With motion
                // reduced there is nothing to watch, so it just goes.
                if still {
                    runner.view.removeFromSuperview()
                    runners.removeValue(forKey: pid)
                    continue
                }
                runner.x -= 5
                runner.tickCount += 1
                if runner.tickCount % 3 == 0 {
                    runner.frameIndex = (runner.frameIndex + 1) % 4
                    runner.view.image = Sprites.frames(for: runner.emoji)[runner.frameIndex]
                }
                if runner.x < -Sprites.size.width {
                    runner.view.removeFromSuperview()
                    runners.removeValue(forKey: pid)
                } else {
                    runner.view.setFrameOrigin(NSPoint(x: runner.x, y: baseY(for: runner)))
                    runners[pid] = runner
                }
                continue
            }
            runners[pid] = runner
            refreshAppearance(pid)
            runner = runners[pid]!

            if runner.isTombstone {
                // Claude said the limit is reached: stay put as a grave marker.
            } else if session.needsAttention {
                // Halted at the wall in a standing pose; only the nudge rhythm runs.
                if !still { runner.phase += 0.12 }
                if runner.frameIndex != Sprites.standingFrame {
                    runner.frameIndex = Sprites.standingFrame
                    runner.view.image = Sprites.frames(for: runner.emoji)[Sprites.standingFrame]
                }
            } else if !still {
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
        if runners.isEmpty {
            timer?.invalidate()
            timer = nil
            window?.orderOut(nil)
        }
        updateHoverState()
    }

    /// True when the point is on the runner or the wall blocking it.
    private func hits(_ runner: Runner, at point: NSPoint) -> Bool {
        if runner.view.frame.insetBy(dx: -6, dy: -6).contains(point) { return true }
        if let wall = runner.wall,
           wall.frame.insetBy(dx: -6, dy: -6).contains(point) { return true }
        return false
    }

    /// The overlay is click-through except directly over a runner or its
    /// wall: hovering one makes the window interactive so it can be clicked.
    private func updateHoverState() {
        guard let window else { return }
        let point = NSPoint(
            x: NSEvent.mouseLocation.x - window.frame.origin.x,
            y: NSEvent.mouseLocation.y - window.frame.origin.y)
        let overRunner = runners.contains {
            sessions[$0.key] != nil && hits($0.value, at: point)
        }
        if window.ignoresMouseEvents == overRunner {
            window.ignoresMouseEvents = !overRunner
        }
    }

    private func handleClick(at point: NSPoint) {
        guard let (pid, runner) = runners.first(where: { hits($0.value, at: point) }),
              let session = sessions[pid] else { return }
        showInfoPanel(for: session, runner: runner)
    }

    private func showInfoPanel(for session: SessionStatus, runner: Runner) {
        guard let content = window?.contentView else { return }
        infoPanel?.removeFromSuperview()
        infoPanelTimer?.invalidate()

        let label = NSTextField(wrappingLabelWithString: SessionSummary.panelText(
            for: session, animal: runner.emoji))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .white
        label.preferredMaxLayoutWidth = 300
        let labelSize = label.sizeThatFits(NSSize(width: 300, height: 400))
        label.frame = NSRect(x: 12, y: 10, width: labelSize.width, height: labelSize.height)

        let panel = NSView(frame: NSRect(
            x: 0, y: 0, width: labelSize.width + 24, height: labelSize.height + 20))
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.88).cgColor
        panel.layer?.cornerRadius = 10
        panel.addSubview(label)

        // Above the runner, clamped to the overlay.
        let x = min(max(runner.x - 20, 8), content.bounds.width - panel.frame.width - 8)
        let y = min(baseY(for: runner) + Sprites.size.height + 10,
                    content.bounds.height - panel.frame.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        content.addSubview(panel)
        infoPanel = panel

        let timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.infoPanel?.removeFromSuperview()
                self?.infoPanel = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        infoPanelTimer = timer
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
        // Claude: altitude = how much of the 5-hour block is left to run.
        // Fresh block → top of the screen; close to reset → bottom.
        // With no block detected yet we know nothing, so the runner starts
        // high rather than being drawn as though the time were nearly up.
        if runner.assistantID == "claude", let content = window?.contentView {
            let top = content.bounds.height - Sprites.size.height - 24
            let bottom: CGFloat = 6
            let elapsed = usageWindow?.elapsedFraction() ?? 0
            let altitude = bottom + (top - bottom) * CGFloat(1 - elapsed)
            // Stagger concurrent Claude runners so they don't fully overlap.
            return altitude + CGFloat(runner.lane) * 14
        }
        return 6 + CGFloat(runner.lane) * laneHeight
    }

    /// Fades a running Claude runner toward `minRunnerAlpha` as its block's
    /// time runs out, or swaps it for the frozen tombstone once Claude has
    /// reported that the usage limit is actually reached.
    ///
    /// The tombstone used to appear whenever no block was detected, which is
    /// what happens in the first seconds of a *new* block — the moment you
    /// have the most left. It now waits for Claude to say so itself.
    private func refreshAppearance(_ pid: Int32) {
        guard var runner = runners[pid] else { return }
        let exhausted = runner.assistantID == "claude"
            && (usageWindow?.isExhausted() ?? false)
        if exhausted {
            if !runner.isTombstone {
                runner.isTombstone = true
                runner.view.image = Sprites.tombstone
                runner.view.alphaValue = 1
            }
        } else {
            if runner.isTombstone {
                runner.isTombstone = false
                runner.view.image = Sprites.frames(for: runner.emoji)[runner.frameIndex]
            }
            if runner.assistantID == "claude", let usage = usageWindow {
                let remaining = CGFloat(1 - usage.elapsedFraction())
                runner.view.alphaValue = minRunnerAlpha + (1 - minRunnerAlpha) * remaining
            } else {
                runner.view.alphaValue = 1
            }
        }
        runners[pid] = runner
    }
}
