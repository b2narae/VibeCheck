import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {
    /// macOS system sounds offered in the picker.
    private static let systemSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]
    private static let soundOff = "off"

    /// (defaults key, menu title, default sound) per event.
    private static let soundEvents: [(key: String, title: String, fallback: String)] = [
        ("sound.finish", "작업 완료", "Hero"),
        ("sound.attention", "입력 요청", "Ping"),
    ]

    private let statusItem: NSStatusItem
    private let monitor: ProcessMonitor
    private let overlay: OverlayController
    private var statuses: [AssistantStatus] = []
    private var animationFrame = 0
    private var animationTimer: Timer?

    /// Claude's current 5-hour usage window (estimated from local logs).
    var usageWindow: UsageWindow?

    private func soundName(forEvent key: String) -> String {
        let fallback = Self.soundEvents.first { $0.key == key }?.fallback ?? "Hero"
        return UserDefaults.standard.string(forKey: key) ?? fallback
    }

    private func play(event key: String) {
        let name = soundName(forEvent: key)
        guard name != Self.soundOff else { return }
        NSSound(named: name)?.play()
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
        play(event: "sound.finish")
    }

    private func sessionNeedsAttention(_ session: SessionStatus) {
        play(event: "sound.attention")
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

        let hookItem = NSMenuItem(
            title: "Claude Code 훅 연동 (정확한 감지)",
            action: #selector(toggleHooks), keyEquivalent: "")
        hookItem.target = self
        hookItem.state = HookBridge.isInstalled ? .on : .off
        menu.addItem(hookItem)

        menu.addItem(soundPickerItem())

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

    private func soundPickerItem() -> NSMenuItem {
        let root = NSMenuItem(title: "알림 사운드", action: nil, keyEquivalent: "")
        let rootMenu = NSMenu()
        for event in Self.soundEvents {
            let current = soundName(forEvent: event.key)
            let title = current == Self.soundOff
                ? "\(event.title) — 끔"
                : "\(event.title) — \(current)"
            let eventItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for sound in Self.systemSounds {
                submenu.addItem(soundChoiceItem(
                    title: sound, eventKey: event.key, value: sound,
                    isSelected: current == sound))
            }
            submenu.addItem(.separator())
            submenu.addItem(soundChoiceItem(
                title: "끔", eventKey: event.key, value: Self.soundOff,
                isSelected: current == Self.soundOff))
            eventItem.submenu = submenu
            rootMenu.addItem(eventItem)
        }
        root.submenu = rootMenu
        return root
    }

    private func soundChoiceItem(
        title: String, eventKey: String, value: String, isSelected: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectSound(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = [eventKey, value]
        item.state = isSelected ? .on : .off
        return item
    }

    @objc private func selectSound(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        UserDefaults.standard.set(pair[1], forKey: pair[0])
        if pair[1] != Self.soundOff {
            NSSound(named: pair[1])?.play()  // preview
        }
    }

    @objc private func toggleOverlay() {
        overlay.enabled.toggle()
    }

    @objc private func toggleHooks() {
        let installing = !HookBridge.isInstalled
        let error = installing ? HookBridge.install() : HookBridge.uninstall()

        let alert = NSAlert()
        if let error {
            alert.alertStyle = .warning
            alert.messageText = "훅 설정을 바꾸지 못했습니다"
            alert.informativeText = error
        } else if installing {
            alert.messageText = "훅 연동을 켰습니다"
            alert.informativeText = """
                ~/.claude/settings.json에 Gallop 훅을 추가했습니다. \
                이미 실행 중인 Claude 세션에는 다음 세션부터 적용됩니다.

                이제 CPU 추정 대신 Claude가 직접 알려주는 신호로 \
                작업 시작·종료와 입력 요청을 감지합니다.
                """
        } else {
            alert.messageText = "훅 연동을 껐습니다"
            alert.informativeText =
                "Gallop이 추가한 훅만 제거했습니다. 다른 훅 설정은 그대로입니다."
        }
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
