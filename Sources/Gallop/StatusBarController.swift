import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {
    private static let soundDefaultsKey = "finishSoundEnabled"

    private let statusItem: NSStatusItem
    private let monitor: ProcessMonitor
    private let overlay: OverlayController
    private var statuses: [AssistantStatus] = []
    private var animationFrame = 0
    private var animationTimer: Timer?

    /// Claude's current 5-hour usage window (estimated from local logs).
    var usageWindow: UsageWindow?

    private var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.soundDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.soundDefaultsKey) }
    }

    private var workingSessions: [SessionStatus] {
        statuses.flatMap(\.sessions).filter { $0.state == .working }
    }

    init(monitor: ProcessMonitor, overlay: OverlayController) {
        self.monitor = monitor
        self.overlay = overlay
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.title = "🐴"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        monitor.onUpdate = { [weak self] statuses in self?.apply(statuses) }
        monitor.onFinished = { [weak self] session in self?.sessionFinished(session) }
        monitor.onNeedsAttention = { [weak self] session in self?.sessionNeedsAttention(session) }

        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.animationFrame += 1
            self?.render()
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }

    private var attentionSessions: [SessionStatus] {
        statuses.flatMap(\.sessions).filter(\.needsAttention)
    }

    private func apply(_ statuses: [AssistantStatus]) {
        self.statuses = statuses
        overlay.update(visible: statuses.flatMap(\.sessions)
            .filter { $0.state == .working || $0.needsAttention })
        render()
    }

    private func render() {
        let working = workingSessions
        let attention = attentionSessions
        var title: String
        if let urgent = attention.first {
            title = "🧱" + SessionAnimals.emoji(for: urgent)
        } else if let first = working.first {
            let dust = animationFrame % 2 == 0 ? "💨" : "\u{2004}\u{2004}"  // keep width stable
            let count = working.count > 1 ? " ×\(working.count)" : ""
            title = SessionAnimals.emoji(for: first) + dust + count
        } else if statuses.contains(where: { $0.state == .idle }) {
            title = "🐴"
        } else {
            title = "💤"
        }
        if !attention.isEmpty && !working.isEmpty {
            title += " 🏃×\(working.count)"
        }
        if statusItem.button?.title != title {
            statusItem.button?.title = title
        }
    }

    private func sessionFinished(_ session: SessionStatus) {
        guard soundEnabled else { return }
        NSSound(named: "Hero")?.play()
    }

    private func sessionNeedsAttention(_ session: SessionStatus) {
        guard soundEnabled else { return }
        NSSound(named: "Ping")?.play()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let usage = usageWindow {
            menu.addItem(disabledItem(usageLine(usage)))
            menu.addItem(.separator())
        }

        if statuses.isEmpty {
            menu.addItem(disabledItem("어시스턴트를 찾는 중…"))
        }
        for status in statuses {
            if status.sessions.isEmpty {
                menu.addItem(disabledItem("💤 \(status.assistant.displayName) — 꺼져 있음"))
                continue
            }
            menu.addItem(disabledItem(
                "\(status.assistant.displayName) — 세션 \(status.sessions.count)개"))
            for session in status.sessions {
                let item = disabledItem(sessionLine(session))
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(animalPickerItem())
        menu.addItem(.separator())

        let overlayItem = NSMenuItem(
            title: "화면에서 러너 달리기", action: #selector(toggleOverlay), keyEquivalent: "")
        overlayItem.target = self
        overlayItem.state = overlay.enabled ? .on : .off
        menu.addItem(overlayItem)

        let soundItem = NSMenuItem(
            title: "알림 사운드 (완료·입력 요청)", action: #selector(toggleSound), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = soundEnabled ? .on : .off
        menu.addItem(soundItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Gallop 종료", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func usageLine(_ usage: UsageWindow) -> String {
        let remaining = Int(usage.remaining() / 60)  // minutes
        let hours = remaining / 60
        let minutes = remaining % 60
        let remainingText = hours > 0 ? "\(hours)시간 \(minutes)분" : "\(minutes)분"
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let gauge = usage.fraction() < 0.8 ? "⏳" : "🔻"
        return "\(gauge) Claude 5시간 윈도우 — \(remainingText) 남음 (\(formatter.string(from: usage.end)) 리셋)"
    }

    private func sessionLine(_ session: SessionStatus) -> String {
        let name = session.projectName ?? "PID \(session.pid)"
        let emoji = SessionAnimals.emoji(for: session)
        if session.needsAttention {
            return "🧱\(emoji) \(name) — 입력을 기다리는 중"
        }
        switch session.state {
        case .working:
            return "\(emoji) \(name) — 달리는 중 (CPU \(Int(session.cpu))%)"
        default:
            return "\(emoji) \(name) — 대기 중"
        }
    }

    private func animalPickerItem() -> NSMenuItem {
        let root = NSMenuItem(title: "러너 동물", action: nil, keyEquivalent: "")
        let rootMenu = NSMenu()
        for assistant in ProcessMonitor.assistants {
            let stored = RunnerSettings.storedValue(for: assistant)
            let title = stored == RunnerSettings.randomValue
                ? "🎲 \(assistant.displayName)"
                : "\(stored) \(assistant.displayName)"
            let assistantItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for animal in RunnerSettings.animals {
                submenu.addItem(pickItem(
                    title: "\(animal.emoji) \(animal.name)",
                    assistant: assistant, value: animal.emoji,
                    isSelected: stored == animal.emoji))
            }
            submenu.addItem(.separator())
            submenu.addItem(pickItem(
                title: "🎲 랜덤",
                assistant: assistant, value: RunnerSettings.randomValue,
                isSelected: stored == RunnerSettings.randomValue))
            assistantItem.submenu = submenu
            rootMenu.addItem(assistantItem)
        }
        root.submenu = rootMenu
        return root
    }

    private func pickItem(
        title: String, assistant: Assistant, value: String, isSelected: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectAnimal(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = [assistant.id, value]
        item.state = isSelected ? .on : .off
        return item
    }

    @objc private func selectAnimal(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let assistant = ProcessMonitor.assistants.first(where: { $0.id == pair[0] })
        else { return }
        RunnerSettings.set(pair[1], for: assistant)
        SessionAnimals.reset(assistantID: assistant.id)
        overlay.refreshSprites()
        render()
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleOverlay() {
        overlay.enabled.toggle()
    }

    @objc private func toggleSound() {
        soundEnabled.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
