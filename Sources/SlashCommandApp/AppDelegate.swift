import AppKit
import SlashCommandCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ConfigStore()
    private let hotKeys = HotKeyCenter()
    private let hud = HUD()
    private let worker = DispatchQueue(label: "slashcommand.apply")
    private let detector = DispatchQueue(label: "slashcommand.detect")
    private var statusItem: NSStatusItem!
    private var settings: SettingsWindowController?
    private var busy = false
    /// Orca 에서 손쉬운 사용이 꺼져 있을 때의 안내는 실행마다 한 번만 한다.
    private var nudgedOrcaAccessibility = false
    /// 마지막으로 알린 프리셋 파일 오류 — 터미널을 오갈 때마다 같은 오류를 다시 알리지 않는다.
    private var announcedConfigError: String?
    /// 마지막으로 기록한 단축키 상태 — 달라졌을 때만 기록한다.
    private var loggedHotKeys = ""
    /// 자동화 권한의 «마지막으로 아는» 상태(번들 id → 상태). 확인은 대상 앱이 응답하지 않으면 얼마든지 오래 걸릴 수 있어
    /// 주 스레드 밖에서 해 두고, 메뉴는 이 값만 본다. 아직 모르는 앱은 표에 없다.
    private var automation: [String: Permissions.Automation] = [:]
    private let permissionQueue = DispatchQueue(label: "slashcommand.automation-check")
    private var checkingAutomation = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.image()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        installMainMenu()

        hotKeys.onPress = { [weak self] id in
            switch id {
            case HotKeyCenter.effortUp:
                Log.write("hotkey effort up")
                self?.perform(.effort(up: true))
            case HotKeyCenter.effortDown:
                Log.write("hotkey effort down")
                self?.perform(.effort(up: false))
            default:
                Log.write("hotkey \(id)")
                self?.perform(.preset(id))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        refreshHotKeys()
        refreshAutomation()
        // 처음 한 번: 손쉬운 사용이 꺼져 있으면 권한 칸이 있는 창을 먼저 보여 준다(그 뒤로는 메뉴에서 연다).
        if !Permissions.accessibility, !UserDefaults.standard.bool(forKey: "permissionsIntroShown") {
            UserDefaults.standard.set(true, forKey: "permissionsIntroShown")
            openSettings()
        } else if CommandLine.arguments.contains("--settings") {
            // `open -a "Slash Command" --args --settings` — 설정 창을 띄운 채로 시작한다.
            openSettings()
        }
    }

    /// 메뉴 막대가 없는 앱이라 이 메뉴는 보이지 않는다. 그래도 있어야 설정 창의 글 상자에서 ⌘C·⌘V·⌘A·⌘Z 와 ⌘W 가 듣는다
    /// (글 상자는 이 단축키들을 주 메뉴에서 받는다). ⌘Q 는 일부러 넣지 않는다 — 설정 창을 닫으려다 앱을 끄면 단축키가 조용히 죽는다.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: - 단축키

    /// 지원하는 터미널이 맨 앞일 때만 단축키를 잡는다 — 다른 앱의 같은 조합을 가로채지 않는다.
    /// `front` 는 방금 앞으로 온 앱(알림이 알려 준 것). 알림 안에서 `frontmostApplication` 을 읽으면 아직 앞의 앱일 수 있다.
    private func refreshHotKeys(front given: String? = nil) {
        let front = given ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        var config: SlashCommandConfig?
        if Detector.supportedBundleIDs.contains(front) {
            do {
                config = try store.load()
                announcedConfigError = nil
            } catch {
                // 파일을 못 읽으면 단축키가 조용히 죽는다 — 한 번은 화면에 알린다.
                let text = "\(error)"
                if announcedConfigError != text {
                    announcedConfigError = text
                    Log.write("presets unreadable: \(text)")
                    hud.show(loc("Shortcuts are off"), detail: loc("The presets file could not be read. Open Settings from the menu bar icon to see why."), seconds: 6)
                }
            }
        }
        let wanted = config?.slots.count ?? 0
        let modifiers = config?.modifiers ?? []
        let effortKeys = config?.effortKeys ?? false
        let active = wanted > 0 || effortKeys
        let same = wanted == hotKeys.registeredCount && effortKeys == hotKeys.registeredEffortKeys
            && (!active || modifiers == hotKeys.registeredModifiers)
        // 다른 앱이 쥐고 있어 못 잡은 키가 있으면, 터미널이 앞으로 올 때마다 다시 잡아 본다.
        guard !same || (active && !hotKeys.failed.isEmpty) else { return }
        var state: String
        if let config, active {
            hotKeys.register(count: wanted, modifiers: modifiers, effortKeys: effortKeys, retry: true)
            state = "hotkeys on \(config.modifierSymbols)1…\(wanted)\(effortKeys ? " · = · -" : "")\(hotKeys.failed.isEmpty ? "" : " — taken by another app: \(hotKeys.failed)")"
        } else {
            hotKeys.unregister()
            state = "hotkeys off"
        }
        if state != loggedHotKeys {
            loggedHotKeys = state
            Log.write("\(state) (\(front))")
        }
    }

    @objc private func frontAppChanged(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        refreshHotKeys(front: app?.bundleIdentifier)
        // 터미널이 앞으로 올 때마다 다시 알아 둔다 — 메뉴를 열기 전에 값이 준비돼 있게.
        refreshAutomation()
    }

    /// 자동화 권한을 주 스레드 밖에서 다시 읽어 `automation` 에 넣는다. 앞의 확인이 끝나지 않았으면 새로 넣지 않는다.
    private func refreshAutomation() {
        guard !checkingAutomation else { return }
        let terminals = Permissions.installedAutomatedTerminals.map(\.bundleID)
        guard !terminals.isEmpty else { return }
        checkingAutomation = true
        permissionQueue.async { [weak self] in
            var found: [String: Permissions.Automation] = [:]
            for bundleID in terminals { found[bundleID] = Permissions.automation(bundleID: bundleID) }
            DispatchQueue.main.async {
                self?.automation = found
                self?.checkingAutomation = false
            }
        }
    }

    // MARK: - 전환

    private enum Action {
        case preset(Int)
        case effort(up: Bool)

        var label: String {
            switch self {
            case .preset(let slot): return "preset \(slot)"
            case .effort(let up): return up ? "effort up" : "effort down"
            }
        }
    }

    /// Ghostty · iTerm2 를 다뤄도 되는지 확인한다. 아직 묻지 않았으면 여기서 묻고 답을 기다린다(작업 스레드에서 부른다).
    /// 허용 창이 떠 있는 동안에는 그 창이 맨 앞이다 — 허락받은 뒤 터미널이 다시 맨 앞에 오지 않으면(그사이 다른 앱으로 갔다) 보내지 않는다.
    private func confirmAutomation(bundleID: String, appName: String, action: Action) throws {
        let asked = try AutomationConsent.ensure(bundleID: bundleID, appName: appName, willAsk: {
            DispatchQueue.main.async {
                self.hud.show(loc("Allow Slash Command to control %@", appName),
                              detail: loc("macOS is asking for permission. Click Allow and the switch continues."), seconds: nil)
            }
        }, note: { Log.write("\(action.label): \($0)") })
        guard asked else { return }
        Log.write("\(action.label): automation \(appName): allowed")
        try AutomationConsent.requireFront(bundleID: bundleID, appName: appName)
    }

    private func perform(_ action: Action) {
        guard !busy else {
            hud.show(loc("Still switching"), detail: loc("Press again when it is done."))
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication, let bundleID = front.bundleIdentifier else { return }
        let appName = front.localizedName ?? bundleID
        // 같은 터미널 앱을 둘 띄웠을 때 «누른 그 프로세스» 로 가게, 지금 맨 앞인 pid 를 들고 간다.
        let frontPID = front.processIdentifier
        // Ghostty 화면은 접근성으로 읽는다. 권한이 없으면 «그 권한을 켜는 설정 화면» 을 바로 열어 주고 여기서 멈춘다
        // — 사용자가 시스템 설정에서 길을 찾게 하지 않는다. (Orca 는 없어도 되지만 있으면 지금 보이는 탭을 지연 없이 안다.)
        if bundleID == Detector.ghosttyBundleID, !Permissions.accessibility {
            Log.write("failed \(action.label): no Accessibility permission — opened System Settings")
            Permissions.openAccessibility()
            hud.show(loc("%@ permission needed", SettingsNames.accessibility),
                     detail: loc("Slash Command reads the Ghostty screen to check the input box. Turn on Slash Command in the list that just opened, then press again."),
                     seconds: 6)
            return
        }
        busy = true

        worker.async { [store] in
            let trace = Trace()
            var switcher: Switcher?
            let outcome = Result { () throws -> SwitchResult in
                var made = Switcher(config: try store.load())
                made.trace = trace
                // claude 가 모델을 바꿀지 되물으면 알리고, 고를 때까지 기다렸다가 마무리한다.
                made.onAwaitingUser = { model in
                    Log.write("awaiting confirmation \(action.label): \(model)")
                    DispatchQueue.main.async {
                        self.hud.show(loc("Press Enter to confirm"),
                                      detail: loc("Claude Code is asking whether to switch to %@ (it re-reads the conversation).", model), seconds: nil)
                    }
                }
                switcher = made
                try self.confirmAutomation(bundleID: bundleID, appName: appName, action: action)
                trace.mark("automation")
                let target = try Detector.target(bundleID: bundleID, appName: appName, frontPID: frontPID)
                trace.mark("find target")
                switch action {
                case .preset(let slot): return try made.apply(slot: slot, to: target, deferFinalCheck: true)
                case .effort(let up): return try made.stepEffort(up: up, on: target)
                }
            }
            // 알림을 먼저 띄운다 — 기본값 재확인(0.25초)은 그 뒤에 한다.
            DispatchQueue.main.async {
                switch outcome {
                case .success(let result):
                    Log.write("applied \(action.label): \(result.summary)\(result.confirmed ? "" : " (no confirmation text)") → \(result.target.agent.rawValue)@\(result.target.host.appName)\(result.warning.map { " ⚠️ " + $0 } ?? "")")
                    var lines = ["\(result.target.agent.displayName) · \(result.target.host.appName) · \(result.target.label)"]
                    if !result.slotName.isEmpty { lines.append(result.slotName) }
                    // 경고가 맨 먼저다 — 알림은 몇 줄만 보여 주므로 뒤에 두면 잘린다.
                    if let warning = result.warning { lines.append("⚠️ \(warning)") }
                    // Orca 는 권한 없이도 되지만, 없으면 탭을 옮긴 직후 1~2.5초 동안 옮기기 전 터미널로 갈 수 있다 — 한 번 알려 준다.
                    if bundleID == Detector.orcaBundleID, !Permissions.accessibility, !self.nudgedOrcaAccessibility {
                        self.nudgedOrcaAccessibility = true
                        lines.append(loc("Turn on %@ from the menu bar icon to stay accurate right after switching tabs.", SettingsNames.accessibility))
                    }
                    self.hud.show(result.summary, detail: lines.joined(separator: "\n"), seconds: lines.count > 2 ? 4 : 1.6)
                case .failure(let error as SlashCommandError) where error.awaitingUser:
                    Log.write("awaiting confirmation \(action.label): \(error)")
                    self.hud.show(loc("Press Enter to confirm"), detail: "\(error)", seconds: 6)
                case .failure(let error as SlashCommandError) where error.nothingToDo:
                    // 바꿀 것이 없었다(이미 가장 높은 단계 등) — 실패가 아니라 안내다.
                    Log.write("unchanged \(action.label): \(error)")
                    self.hud.show("\(error)", seconds: 2.5)
                case .failure(let error as SlashCommandError) where error.needsAccessibility:
                    // iTerm2 는 쓰기 직전에 입력 방송이 꺼져 있는지 접근성으로 본다 — 권한이 없으면 그 설정 화면을 바로 열어 준다(아무것도 보내지 않았다).
                    Log.write("failed \(action.label): no Accessibility permission — opened System Settings")
                    Permissions.openAccessibility()
                    self.hud.show(loc("%@ permission needed", SettingsNames.accessibility), detail: "\(error)", seconds: 6)
                case .failure(let error as SlashCommandError) where error.needsAutomation:
                    // 자동화가 꺼져 있다 — 시스템은 다시 묻지 않으므로 그 설정 화면을 바로 열어 준다(아무것도 보내지 않았다).
                    Log.write("failed \(action.label): Automation is off for \(appName) — opened System Settings")
                    Permissions.openAutomation()
                    self.hud.show(loc("Automation permission needed"), detail: "\(error)", seconds: 6)
                case .failure(let error):
                    Log.write("failed \(action.label): \(error)")
                    self.hud.show(loc("Not switched"), detail: "\(error)", seconds: 5)
                }
            }
            if case .success(let result) = outcome, let before = result.pendingRestore, let switcher,
               let late = switcher.verifyRestore(before) {
                Log.write("⚠️ \(late)")
                DispatchQueue.main.async { self.hud.show(result.summary, detail: "⚠️ \(late)", seconds: 4) }
            }
            Log.write("timing \(action.label): \(trace.report)")
            DispatchQueue.main.async { self.busy = false }
        }
    }

    // MARK: - 메뉴

    /// 메뉴를 열 때마다 하나씩 는다. 늦게 온 «맨 앞 세션» 답이 그사이 다시 연 메뉴를 고치지 않게 한다.
    private var menuOpening = 0
    private var headerItem: NSMenuItem?
    private var presetItems: [(item: NSMenuItem, slot: Slot, number: Int)] = []

    /// 메뉴가 알고 있는 «맨 앞 세션».
    private enum Front {
        /// 지원하는 터미널이 맨 앞이 아니다.
        case unsupported
        /// 아직 모른다 — 알아보는 중이거나(답이 오면 메뉴를 고친다), 묻지 않고는 알 수 없다.
        case checking(appName: String)
        case agent(Target)
        /// 그 터미널에서 에이전트를 찾지 못했다.
        case none(appName: String)
    }

    /// 다른 스레드가 알아낸 답을 주 스레드가 잠깐 기다렸다 받는다.
    private final class Answer {
        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var value: Target??
        /// 주 스레드가 기다리다 그만뒀다 — 답이 오면 메뉴를 고쳐야 한다. 주 스레드에서만 읽고 쓴다.
        var late = false

        func give(_ target: Target?) {
            lock.lock()
            value = .some(target)
            lock.unlock()
            ready.signal()
        }

        func wait(seconds: Double) -> Target?? {
            _ = ready.wait(timeout: .now() + seconds)
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // 메뉴는 «알아 둔» 권한 상태로 그린다. 다음에 열 때를 위해 뒤에서 다시 읽어 둔다.
        refreshAutomation()
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier ?? ""
        fill(menu, bundleID: bundleID, appName: app?.localizedName ?? bundleID, frontPID: app?.processIdentifier)
    }

    private func fill(_ menu: NSMenu, bundleID: String, appName: String, frontPID: Int32? = nil) {
        menuOpening += 1
        build(menu, front: frontSession(bundleID: bundleID, appName: appName, frontPID: frontPID, menu: menu))
    }

    /// 맨 앞 세션의 에이전트 — 메뉴가 «지금 누르면 무엇이 되는가» 를 보여 주게 한다. 아무것도 보내지 않는다.
    private func frontSession(bundleID: String, appName: String, frontPID: Int32? = nil, menu: NSMenu) -> Front {
        guard Detector.supportedBundleIDs.contains(bundleID) else { return .unsupported }
        // 전환 중에는 그 터미널을 건드리지 않는다.
        guard !busy else { return .checking(appName: appName) }
        if Permissions.automatedTerminals.contains(where: { $0.bundleID == bundleID }) {
            // Ghostty · iTerm2 는 AppleScript 로 읽고, AppleScript 는 주 스레드에서 돈다 — 여기서 바로 읽는다(보통 수십 ms, 스크립트에 시간 제한이 있다).
            // 자동화가 허용된 것을 «알고 있을» 때만 읽는다: 메뉴를 여는 것만으로 권한 창이 뜨면 안 되고,
            // 권한 확인 자체도 여기(주 스레드)서 하지 않는다 — 미리 알아 둔 값을 본다.
            // 허용이 아니거나 아직 모르면 «못 찾았다» 가 아니라 «모른다» 다 — 머리말에 앱 이름만 적는다.
            guard automation[bundleID] == .allowed else { return .checking(appName: appName) }
            return (try? Detector.target(bundleID: bundleID, appName: appName, frontPID: frontPID)).map(Front.agent) ?? .none(appName: appName)
        }
        // Orca 는 주 스레드 밖에서 읽는다(0.1초 안팎). 0.25초 안에 오면 그대로 그리고, 늦으면 온 뒤에 메뉴를 고친다.
        let answer = Answer()
        let opening = menuOpening
        detector.async { [weak self] in
            let target = try? Detector.target(bundleID: bundleID, appName: appName, frontPID: frontPID)
            answer.give(target)
            DispatchQueue.main.async {
                guard let self, answer.late, opening == self.menuOpening else { return }
                self.show(target.map(Front.agent) ?? .none(appName: appName))
            }
        }
        if let arrived = answer.wait(seconds: 0.25) {
            return arrived.map(Front.agent) ?? .none(appName: appName)
        }
        answer.late = true
        return .checking(appName: appName)
    }

    private func modifierMask(_ config: SlashCommandConfig) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(config.modifiers.compactMap {
            ["shift": .shift, "option": .option, "control": .control, "command": .command][$0]
        })
    }

    private func build(_ menu: NSMenu, front: Front) {
        menu.removeAllItems()
        presetItems = []
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.isEnabled = false
        headerItem = header
        menu.addItem(header)

        var supported = true
        if case .unsupported = front { supported = false }
        do {
            let config = try store.load()
            let mask = modifierMask(config)
            for (index, slot) in config.slots.enumerated() {
                let item = NSMenuItem(title: "", action: #selector(menuApply(_:)), keyEquivalent: "\(index + 1)")
                item.keyEquivalentModifierMask = mask
                item.tag = index + 1
                item.target = self
                menu.addItem(item)
                presetItems.append((item, slot, index + 1))
            }
            if config.slots.isEmpty {
                menu.addItem(NSMenuItem(title: loc("No presets yet — add one in Settings"), action: nil, keyEquivalent: ""))
            }
            if config.effortKeys {
                menu.addItem(.separator())
                for (title, action, key) in [(loc("Raise Effort"), #selector(menuEffortUp), "="),
                                             (loc("Lower Effort"), #selector(menuEffortDown), "-")] {
                    let entry = item(title, supported ? action : nil, key: key)
                    entry.keyEquivalentModifierMask = mask
                    menu.addItem(entry)
                }
            }
        } catch {
            menu.addItem(warning(loc("The presets file could not be read — open Settings…"), #selector(openSettings)))
        }
        show(front)

        // 손댈 것이 있을 때만 보인다. 다 괜찮으면 메뉴에 권한 이야기가 없다(상태는 설정 창에 있다).
        var problems: [NSMenuItem] = []
        if !hotKeys.failed.isEmpty {
            let keys = hotKeys.failed.map { id -> String in
                switch id {
                case HotKeyCenter.effortUp: return "="
                case HotKeyCenter.effortDown: return "-"
                default: return String(id)
                }
            }.joined(separator: ", ")
            problems.append(warning(loc("Another app is using these shortcut keys: %@", keys), nil))
        }
        if !Permissions.accessibility {
            problems.append(warning(loc("Turn On %@…", SettingsNames.accessibility), #selector(openAccessibilitySettings)))
        }
        let denied = Permissions.automatedTerminals.filter { automation[$0.bundleID] == .denied }.map(\.name)
        if !denied.isEmpty {
            problems.append(warning(loc("Allow Automation for %@…", denied.joined(separator: " · ")), #selector(openAutomationSettings)))
        }
        if !problems.isEmpty {
            menu.addItem(.separator())
            problems.forEach(menu.addItem)
        }

        menu.addItem(.separator())
        menu.addItem(item(loc("Settings…"), #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item(loc("Quit Slash Command"), #selector(quit), key: "q"))
    }

    /// 맨 앞 세션에 맞춰 머리말과 프리셋 줄의 글을 쓴다. 메뉴가 떠 있는 동안에도 불린다(늦게 온 답).
    private func show(_ front: Front) {
        var agent: Agent?
        var usable = true
        switch front {
        case .unsupported:
            headerItem?.title = loc("Works in Ghostty and Orca")
            usable = false
        case .checking(let appName):
            headerItem?.title = appName
        case .agent(let target):
            agent = target.agent
            headerItem?.title = "\(target.agent.displayName) · \(target.host.appName)"
        case .none(let appName):
            headerItem?.title = loc("%@ — no agent found in the front session", appName)
        }
        for entry in presetItems {
            if let title = entry.slot.menuTitle(for: agent) {
                entry.item.title = title
                entry.item.action = usable ? #selector(menuApply(_:)) : nil
            } else if let agent {
                // 이 번호에는 그 에이전트의 설정이 없다 — 지금 눌러도 아무것도 하지 않는다.
                let name = entry.slot.name.isEmpty ? loc("Preset %@", entry.number) : entry.slot.name
                entry.item.title = loc("%@ — not set for %@", name, agent.displayName)
                entry.item.action = nil
            }
        }
    }

    /// 개발용: 메뉴를 만들어 줄마다 글로 돌려준다. Orca 의 늦은 답도 받도록 잠깐 기다린다.
    /// `bundleID` 를 주면 그 앱이 맨 앞인 것으로 친다(맨 앞 앱을 바꾸지 않고 확인하려는 것).
    func menuText(asIfFront bundleID: String? = nil) -> String {
        // 앱을 띄우지 않고 불리므로 자동화 권한을 아직 모른다. 주 스레드 밖에서 알아보게 하고 여기서는 잠깐만 기다린다
        // (끝나지 않으면 모르는 채로 그린다 — 메뉴와 같은 규칙).
        refreshAutomation()
        let deadline = Date().addingTimeInterval(2)
        while checkingAutomation, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let menu = NSMenu()
        if let bundleID {
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
            fill(menu, bundleID: bundleID, appName: name)
        } else {
            menuNeedsUpdate(menu)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        return menu.items.map { item in
            if item.isSeparatorItem { return "  ────" }
            let state = item.action == nil || !item.isEnabled ? "·" : "▸"
            let mask = item.keyEquivalentModifierMask
            let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { mask.contains($0.0) }.map(\.1).joined()
            let key = item.keyEquivalent.isEmpty ? "" : "   [\(symbols)\(item.keyEquivalent)]"
            return "\(state) \(item.title)\(key)"
        }.joined(separator: "\n")
    }

    private func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func warning(_ title: String, _ action: Selector?) -> NSMenuItem {
        let entry = item(title, action)
        entry.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        return entry
    }

    @objc private func menuApply(_ sender: NSMenuItem) {
        perform(.preset(sender.tag))
    }

    @objc private func menuEffortUp() { perform(.effort(up: true)) }
    @objc private func menuEffortDown() { perform(.effort(up: false)) }

    @objc private func openSettings() {
        if settings == nil {
            settings = SettingsWindowController(store: store) { [weak self] in self?.refreshHotKeys() }
        }
        settings?.present()
    }

    @objc private func openAccessibilitySettings() { Permissions.openAccessibility() }
    @objc private func openAutomationSettings() { Permissions.openAutomation() }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
