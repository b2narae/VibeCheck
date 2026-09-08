import AppKit
import ServiceManagement

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    /// macOS system sounds offered in the picker.
    private static let systemSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]
    private static let soundOff = "off"

    /// (defaults key, menu title, default sound) per event.
    private static var soundEvents: [(key: String, title: String, fallback: String)] {
        [
            ("sound.finish", L10n.t("Work finished", "작업 완료"), "Hero"),
            ("sound.attention", L10n.t("Needs you", "입력 요청"), "Ping"),
        ]
    }

    private let statusItem: NSStatusItem
    private let monitor: ProcessMonitor
    private let overlay: OverlayController
    private var statuses: [AssistantStatus] = []

    /// Claude's current 5-hour block (estimated from local logs).
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

    private var attentionSessions: [SessionStatus] {
        statuses.flatMap(\.sessions).filter(\.needsAttention)
    }

    init(monitor: ProcessMonitor, overlay: OverlayController) {
        self.monitor = monitor
        self.overlay = overlay
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.title = "🐾"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        monitor.onUpdate = { [weak self] statuses in self?.apply(statuses) }
        monitor.onFinished = { [weak self] _ in self?.play(event: "sound.finish") }
        monitor.onNeedsAttention = { [weak self] _ in self?.play(event: "sound.attention") }
    }

    private func apply(_ statuses: [AssistantStatus]) {
        self.statuses = statuses
        overlay.update(visible: statuses.flatMap(\.sessions)
            .filter { $0.state == .working || $0.needsAttention })
        render()
    }

    /// One emoji per active session: blocked ones lead with their wall,
    /// running ones are just the animal itself.
    private func render() {
        let working = workingSessions
        let attention = attentionSessions
        let title: String
        if working.isEmpty && attention.isEmpty {
            title = statuses.contains(where: { $0.state == .idle }) ? "🐾" : "💤"
        } else {
            let blocked = attention.map { "🧱" + SessionAnimals.emoji(for: $0) }.joined()
            let running = working.map { SessionAnimals.emoji(for: $0) }.joined()
            title = blocked + running
        }
        if statusItem.button?.title != title {
            statusItem.button?.title = title
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let usage = usageWindow {
            menu.addItem(disabledItem(usageLine(usage)))
            menu.addItem(.separator())
        }

        if statuses.allSatisfy({ $0.sessions.isEmpty }) {
            menu.addItem(disabledItem(L10n.t("No sessions running", "실행 중인 세션 없음")))
        }
        for status in statuses {
            if status.sessions.isEmpty {
                menu.addItem(disabledItem(
                    "💤 \(status.assistant.displayName) — " + L10n.t("off", "꺼져 있음")))
                continue
            }
            menu.addItem(disabledItem(L10n.t(
                "\(status.assistant.displayName) — \(status.sessions.count) session(s)",
                "\(status.assistant.displayName) — 세션 \(status.sessions.count)개")))
            for session in status.sessions {
                let animal = SessionAnimals.emoji(for: session)
                let item = disabledItem(SessionSummary.menuLine(session, animal: animal))
                item.indentationLevel = 1
                item.submenu = sessionDetailMenu(session)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(animalPickerItem())
        menu.addItem(.separator())

        menu.addItem(toggleItem(
            title: L10n.t("Run the animals on screen", "화면에서 러너 달리기"),
            isOn: overlay.enabled, action: #selector(toggleOverlay)))
        menu.addItem(toggleItem(
            title: L10n.t("Claude Code hooks (exact detection)",
                          "Claude Code 훅 연동 (정확한 감지)"),
            isOn: HookBridge.isInstalled, action: #selector(toggleHooks)))
        menu.addItem(toggleItem(
            title: L10n.t("Open at login", "로그인 시 실행"),
            isOn: LaunchAtLogin.isEnabled, action: #selector(toggleLaunchAtLogin)))
        menu.addItem(soundPickerItem())

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: L10n.t("Quit VibeCheck", "VibeCheck 종료"),
            action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// What the 5-hour block line says. Deliberately phrased as time, because
    /// time is what the logs can prove; the token count is the one measured
    /// quantity and is shown as a plain number, never as "x% of your limit".
    private func usageLine(_ usage: UsageWindow) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        if usage.isExhausted(), let reset = usage.limitResetsAt {
            return L10n.t(
                "🪦 Claude usage limit reached — resets \(formatter.string(from: reset))",
                "🪦 Claude 사용량 한도 도달 — \(formatter.string(from: reset)) 리셋")
        }

        let minutes = Int(usage.remaining() / 60)
        let time = minutes >= 60
            ? L10n.t("\(minutes / 60)h \(minutes % 60)m", "\(minutes / 60)시간 \(minutes % 60)분")
            : L10n.t("\(minutes)m", "\(minutes)분")
        let gauge = usage.elapsedFraction() < 0.8 ? "⏳" : "🔻"
        return L10n.t(
            "\(gauge) Claude 5-hour block — \(time) until reset "
                + "(\(formatter.string(from: usage.end))) · \(tokens(usage.tokens)) tokens",
            "\(gauge) Claude 5시간 블록 — 리셋까지 \(time) "
                + "(\(formatter.string(from: usage.end))) · 토큰 \(tokens(usage.tokens))")
    }

    private func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: return String(format: "%.0fK", Double(count) / 1_000)
        default: return "\(count)"
        }
    }

    /// Submenu with what the session is doing right now. Available for any
    /// assistant whose transcript VibeCheck can read.
    private func sessionDetailMenu(_ session: SessionStatus) -> NSMenu? {
        let lines = SessionSummary.detailLines(session)
        guard !lines.isEmpty else { return nil }
        let menu = NSMenu()
        for line in lines {
            menu.addItem(disabledItem(Transcripts.clip(line, 90)))
        }
        return menu
    }

    private func animalPickerItem() -> NSMenuItem {
        let root = NSMenuItem(
            title: L10n.t("Runner animal", "러너 동물"), action: nil, keyEquivalent: "")
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
                    title: "\(animal) \(L10n.animalName(animal))",
                    assistant: assistant, value: animal,
                    isSelected: stored == animal))
            }
            submenu.addItem(.separator())
            submenu.addItem(pickItem(
                title: L10n.t("🎲 Random", "🎲 랜덤"),
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

    private func toggleItem(title: String, isOn: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        return item
    }

    private func soundPickerItem() -> NSMenuItem {
        let root = NSMenuItem(
            title: L10n.t("Notification sounds", "알림 사운드"), action: nil, keyEquivalent: "")
        let rootMenu = NSMenu()
        for event in Self.soundEvents {
            let current = soundName(forEvent: event.key)
            let title = current == Self.soundOff
                ? "\(event.title) — \(L10n.t("off", "끔"))"
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
                title: L10n.t("Off", "끔"), eventKey: event.key, value: Self.soundOff,
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

    @objc private func toggleLaunchAtLogin() {
        if let error = LaunchAtLogin.toggle() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.t("Could not change the login item",
                                       "로그인 항목을 바꾸지 못했습니다")
            alert.informativeText = error
            alert.runModal()
        }
    }

    @objc private func toggleHooks() {
        let installing = !HookBridge.isInstalled
        let error = installing ? HookBridge.install() : HookBridge.uninstall()

        let alert = NSAlert()
        if let error {
            alert.alertStyle = .warning
            alert.messageText = L10n.t("Could not change the hook settings",
                                       "훅 설정을 바꾸지 못했습니다")
            alert.informativeText = error
        } else if installing {
            alert.messageText = L10n.t("Hooks are on", "훅 연동을 켰습니다")
            alert.informativeText = L10n.t(
                """
                VibeCheck's hooks were added to ~/.claude/settings.json. \
                Sessions already running pick them up on their next start.

                Turn start, turn end and permission prompts now come from \
                Claude Code itself instead of being inferred from CPU.
                """,
                """
                ~/.claude/settings.json에 VibeCheck 훅을 추가했습니다. \
                이미 실행 중인 Claude 세션에는 다음 세션부터 적용됩니다.

                이제 CPU 추정 대신 Claude가 직접 알려주는 신호로 \
                작업 시작·종료와 입력 요청을 감지합니다.
                """)
        } else {
            alert.messageText = L10n.t("Hooks are off", "훅 연동을 껐습니다")
            alert.informativeText = L10n.t(
                "Only the entries VibeCheck added were removed. "
                    + "Every other hook is untouched.",
                "VibeCheck이 추가한 훅만 제거했습니다. 다른 훅 설정은 그대로입니다.")
        }
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// The "open at login" toggle, backed by SMAppService (macOS 13+).
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Flips the setting; returns an error message when macOS refuses.
    static func toggle() -> String? {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            return nil
        } catch {
            // Registering only works for a real .app bundle, so a bare
            // `build/VibeCheck` binary lands here — say so rather than
            // failing silently.
            return L10n.t(
                "\(error.localizedDescription)\n\n"
                    + "Open at login needs VibeCheck.app itself — "
                    + "copy it to /Applications and launch it from there.",
                "\(error.localizedDescription)\n\n"
                    + "로그인 시 실행은 VibeCheck.app 번들에서만 됩니다 — "
                    + "/Applications 로 복사한 뒤 거기서 실행하세요.")
        }
    }
}
