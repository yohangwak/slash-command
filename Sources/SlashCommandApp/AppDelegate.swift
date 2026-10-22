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
    /// The notice about Accessibility being off in Orca is given only once per run.
    private var nudgedOrcaAccessibility = false
    /// The last preset-file error reported — the same error is not reported again each time you switch terminals.
    private var announcedConfigError: String?
    /// The last hotkey state logged — logged only when it changes.
    private var loggedHotKeys = ""
    /// The "last known" state of the Automation permission (bundle id -> state). A check can take arbitrarily long if the target app does not respond,
    /// so it is done off the main thread and the menu looks only at this value. An app not yet known is not in the table.
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
        // The first time only: if Accessibility is off, first show the window that has the permission row (after that it is opened from the menu).
        if !Permissions.accessibility, !UserDefaults.standard.bool(forKey: "permissionsIntroShown") {
            UserDefaults.standard.set(true, forKey: "permissionsIntroShown")
            openSettings()
        } else if CommandLine.arguments.contains("--settings") {
            // `open -a "Slash Command" --args --settings` — starts with the settings window showing.
            openSettings()
        }
    }

    /// The app has no menu bar, so this menu is not visible. It must still exist for ⌘C, ⌘V, ⌘A, ⌘Z and ⌘W to work in the settings window's text fields
    /// (text fields receive these shortcuts from the main menu). ⌘Q is deliberately left out — quitting the app while trying to close the settings window would silently kill the hotkeys.
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

    // MARK: - Hotkeys

    /// Grabs the hotkeys only while a supported terminal is frontmost — so the same combination in other apps is not intercepted.
    /// `front` is the app that just came to the front (as the notification reported it). Reading `frontmostApplication` inside the notification may still give the previous app.
    private func refreshHotKeys(front given: String? = nil) {
        let front = given ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        var config: SlashCommandConfig?
        if Detector.supportedBundleIDs.contains(front) {
            do {
                config = try store.load()
                announcedConfigError = nil
            } catch {
                // If the file cannot be read, the hotkeys silently die — show it on screen once.
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
        // If some key could not be grabbed because another app holds it, try again each time a terminal comes to the front.
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
        // Re-learn each time a terminal comes to the front — so the value is ready before the menu is opened.
        refreshAutomation()
    }

    /// Reads the Automation permission again off the main thread and puts it in `automation`. If the previous check has not finished, does not put in a new one.
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

    // MARK: - Switching

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

    /// Checks whether Ghostty and iTerm2 may be driven. If the user has not been asked yet, asks here and waits for the answer (called from the worker thread).
    /// While the permission dialog is showing, that dialog is frontmost — if after permission is granted the terminal does not come back to the front (the user went to another app meanwhile), nothing is sent.
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
        // Carry the pid that is frontmost now, so that with two instances of the same terminal app the keys go to "the process where the key was pressed".
        let frontPID = front.processIdentifier
        // Ghostty's screen is read through accessibility. Without the permission, open "the settings screen that turns it on" right away and stop here
        // — do not make the user find their way in System Settings. (Orca works without it, but with it Orca knows the currently visible tab without delay.)
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
                // If claude asks again whether to change the model, tell the user, wait until they choose, then finish up.
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
            // Show the notification first — the re-check of the defaults (0.25 s) comes after.
            DispatchQueue.main.async {
                switch outcome {
                case .success(let result):
                    Log.write("applied \(action.label): \(result.summary)\(result.confirmed ? "" : " (no confirmation text)") → \(result.target.agent.rawValue)@\(result.target.host.appName)\(result.warning.map { " ⚠️ " + $0 } ?? "")")
                    var lines = ["\(result.target.agent.displayName) · \(result.target.host.appName) · \(result.target.label)"]
                    if !result.slotName.isEmpty { lines.append(result.slotName) }
                    // The warning goes first — the notification shows only a few lines, so anything after it is cut off.
                    if let warning = result.warning { lines.append("⚠️ \(warning)") }
                    // Orca works without the permission, but without it, for 1-2.5 s right after moving tabs it may go to the terminal from before the move — tell the user once.
                    if bundleID == Detector.orcaBundleID, !Permissions.accessibility, !self.nudgedOrcaAccessibility {
                        self.nudgedOrcaAccessibility = true
                        lines.append(loc("Turn on %@ from the menu bar icon to stay accurate right after switching tabs.", SettingsNames.accessibility))
                    }
                    self.hud.show(result.summary, detail: lines.joined(separator: "\n"), seconds: lines.count > 2 ? 4 : 1.6)
                case .failure(let error as SlashCommandError) where error.awaitingUser:
                    Log.write("awaiting confirmation \(action.label): \(error)")
                    self.hud.show(loc("Press Enter to confirm"), detail: "\(error)", seconds: 6)
                case .failure(let error as SlashCommandError) where error.nothingToDo:
                    // There was nothing to change (already at the highest level, etc.) — this is a notice, not a failure.
                    Log.write("unchanged \(action.label): \(error)")
                    self.hud.show("\(error)", seconds: 2.5)
                case .failure(let error as SlashCommandError) where error.needsAccessibility:
                    // Before writing, iTerm2 checks through accessibility whether input broadcast is off — without the permission, open that settings screen right away (nothing was sent).
                    Log.write("failed \(action.label): no Accessibility permission — opened System Settings")
                    Permissions.openAccessibility()
                    self.hud.show(loc("%@ permission needed", SettingsNames.accessibility), detail: "\(error)", seconds: 6)
                case .failure(let error as SlashCommandError) where error.needsAutomation:
                    // Automation is off — the system does not ask again, so open that settings screen right away (nothing was sent).
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

    // MARK: - Menu

    /// Increases by one each time the menu opens. Keeps a late "front session" answer from altering a menu that was opened again in the meantime.
    private var menuOpening = 0
    private var headerItem: NSMenuItem?
    private var presetItems: [(item: NSMenuItem, slot: Slot, number: Int)] = []

    /// The "front session" the menu knows.
    private enum Front {
        /// A supported terminal is not frontmost.
        case unsupported
        /// Not known yet — it is being worked out (the menu is fixed when the answer arrives), or it cannot be known without asking.
        case checking(appName: String)
        case agent(Target)
        /// No agent was found in that terminal.
        case none(appName: String)
    }

    /// The main thread briefly waits for and receives an answer worked out by another thread.
    private final class Answer {
        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var value: Target??
        /// The main thread gave up waiting — if the answer arrives, the menu must be fixed. Read and written only on the main thread.
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
        // The menu is drawn from the "already known" permission state. Read it again in the background for the next time it is opened.
        refreshAutomation()
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier ?? ""
        fill(menu, bundleID: bundleID, appName: app?.localizedName ?? bundleID, frontPID: app?.processIdentifier)
    }

    private func fill(_ menu: NSMenu, bundleID: String, appName: String, frontPID: Int32? = nil) {
        menuOpening += 1
        build(menu, front: frontSession(bundleID: bundleID, appName: appName, frontPID: frontPID, menu: menu))
    }

    /// The front session's agent — lets the menu show "what pressing it now will do". Sends nothing.
    private func frontSession(bundleID: String, appName: String, frontPID: Int32? = nil, menu: NSMenu) -> Front {
        guard Detector.supportedBundleIDs.contains(bundleID) else { return .unsupported }
        // During a switch, do not touch that terminal.
        guard !busy else { return .checking(appName: appName) }
        if Permissions.automatedTerminals.contains(where: { $0.bundleID == bundleID }) {
            // Ghostty and iTerm2 are read with AppleScript, and AppleScript runs on the main thread — read right here (usually tens of ms; the script has a time limit).
            // Read only when we "know" that Automation is allowed: merely opening the menu must not bring up a permission dialog,
            // and the permission check itself is not done here (the main thread) either — look at the value learned beforehand.
            // If it is not allowed or not yet known, that is "unknown", not "not found" — only the app name is written in the header.
            guard automation[bundleID] == .allowed else { return .checking(appName: appName) }
            return (try? Detector.target(bundleID: bundleID, appName: appName, frontPID: frontPID)).map(Front.agent) ?? .none(appName: appName)
        }
        // Orca is read off the main thread (about 0.1 s). If it arrives within 0.25 s it is drawn as is; if late, the menu is fixed after it arrives.
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
        var modifierWarning: String?
        do {
            let config = try store.load()
            modifierWarning = config.modifierWarning
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

        // Shown only when there is something to fix. If everything is fine, the menu says nothing about permissions (the state is in the settings window).
        var problems: [NSMenuItem] = []
        if let modifierWarning {
            problems.append(warning(modifierWarning, #selector(openSettings)))
        }
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

    /// Writes the header and the preset-line text to match the front session. Also called while the menu is showing (a late answer).
    private func show(_ front: Front) {
        var agent: Agent?
        var usable = true
        switch front {
        case .unsupported:
            headerItem?.title = loc("Works in Ghostty, Orca, iTerm2, WezTerm and kitty")
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
                // This number has no setting for that agent — pressing it now does nothing.
                let name = entry.slot.name.isEmpty ? loc("Preset %@", entry.number) : entry.slot.name
                entry.item.title = loc("%@ — not set for %@", name, agent.displayName)
                entry.item.action = nil
            }
        }
    }

    /// For development: builds the menu and returns it as text, one line per item. Waits briefly so that Orca's late answer is also received.
    /// If `bundleID` is given, that app is treated as frontmost (to check without changing the frontmost app).
    func menuText(asIfFront bundleID: String? = nil) -> String {
        // Called without launching the app, so the Automation permission is not yet known. Have it worked out off the main thread and wait only briefly here
        // (if it does not finish, draw with it unknown — the same rule as the menu).
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
