import AppKit
import ModelSwitchCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ConfigStore()
    private let hotKeys = HotKeyCenter()
    private let hud = HUD()
    private let worker = DispatchQueue(label: "modelswitch.apply")
    private var statusItem: NSStatusItem!
    private var settings: SettingsWindowController?
    private var busy = false
    /// Orca 에서 손쉬운 사용이 꺼져 있을 때의 안내는 실행마다 한 번만 한다.
    private var nudgedOrcaAccessibility = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "switch.2", accessibilityDescription: "ModelSwitch")
            ?? NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: "ModelSwitch")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hotKeys.onPress = { [weak self] id in
            switch id {
            case HotKeyCenter.effortUp:
                Log.write("단축키 effort 올림")
                self?.perform(.effort(up: true))
            case HotKeyCenter.effortDown:
                Log.write("단축키 effort 내림")
                self?.perform(.effort(up: false))
            default:
                Log.write("단축키 \(id)번")
                self?.perform(.preset(id))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        refreshHotKeys()
        // 처음 한 번: 손쉬운 사용이 꺼져 있으면 권한 상자가 있는 창을 먼저 보여 준다(그 뒤로는 메뉴에서 연다).
        if !Permissions.accessibility, !UserDefaults.standard.bool(forKey: "permissionsIntroShown") {
            UserDefaults.standard.set(true, forKey: "permissionsIntroShown")
            openSettings()
        } else if CommandLine.arguments.contains("--settings") {
            // `open -a ModelSwitch --args --settings` — 프리셋·권한 창을 띄운 채로 시작한다.
            openSettings()
        }
    }

    // MARK: - 단축키

    /// 지원하는 터미널이 맨 앞일 때만 단축키를 잡는다 — 다른 앱의 ⌃⌘숫자를 가로채지 않는다.
    private func refreshHotKeys() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let config = Detector.supportedBundleIDs.contains(front) ? try? store.load() : nil
        let wanted = config?.slots.count ?? 0
        let modifiers = config?.modifiers ?? []
        let effortKeys = config?.effortKeys ?? false
        guard wanted != hotKeys.registeredCount || effortKeys != hotKeys.registeredEffortKeys
                || ((wanted > 0 || effortKeys) && modifiers != hotKeys.registeredModifiers) else { return }
        if let config, wanted > 0 || effortKeys {
            hotKeys.register(count: wanted, modifiers: modifiers, effortKeys: effortKeys)
            Log.write("단축키 등록 \(config.modifierSymbols)1…\(wanted)\(effortKeys ? " · = · -" : "") (\(front))\(hotKeys.failed.isEmpty ? "" : " — 못 잡은 키 \(hotKeys.failed)")")
        } else {
            hotKeys.unregister()
            Log.write("단축키 해제 (\(front))")
        }
    }

    @objc private func frontAppChanged() {
        refreshHotKeys()
    }

    // MARK: - 전환

    private enum Action {
        case preset(Int)
        case effort(up: Bool)

        var label: String {
            switch self {
            case .preset(let slot): return "\(slot)번"
            case .effort(let up): return up ? "effort 올림" : "effort 내림"
            }
        }
    }

    private func perform(_ action: Action) {
        guard !busy else {
            hud.show("전환 중입니다", detail: "끝난 뒤 다시 눌러 주세요.")
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication, let bundleID = front.bundleIdentifier else { return }
        let appName = front.localizedName ?? bundleID
        // Ghostty 화면은 접근성으로 읽는다. 권한이 없으면 «그 권한을 켜는 설정 화면» 을 바로 열어 주고 여기서 멈춘다
        // — 사용자가 시스템 설정에서 길을 찾게 하지 않는다. (Orca 는 없어도 되지만 있으면 지금 보이는 탭을 지연 없이 안다.)
        if bundleID == Detector.ghosttyBundleID, !Permissions.accessibility {
            Log.write("실패 \(action.label): 손쉬운 사용 권한 없음 — 설정 화면을 엶")
            Permissions.openAccessibility()
            hud.show("손쉬운 사용 권한이 필요합니다",
                     detail: "Ghostty 화면을 읽어 입력창 상태를 확인합니다. 방금 연 설정 화면의 목록에서 ModelSwitch 를 켠 뒤 다시 눌러 주세요.",
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
                    Log.write("확인 대기 \(action.label): \(model)")
                    DispatchQueue.main.async {
                        self.hud.show("Enter 로 확정해 주세요",
                                      detail: "claude 가 \(model) 로 바꿀지 묻고 있습니다(대화 기록을 다시 읽습니다).", seconds: nil)
                    }
                }
                switcher = made
                let target = try Detector.target(bundleID: bundleID, appName: appName)
                trace.mark("대상찾기")
                switch action {
                case .preset(let slot): return try made.apply(slot: slot, to: target, deferFinalCheck: true)
                case .effort(let up): return try made.stepEffort(up: up, on: target)
                }
            }
            // 알림을 먼저 띄운다 — 기본값 재확인(0.25초)은 그 뒤에 한다.
            DispatchQueue.main.async {
                switch outcome {
                case .success(let result):
                    Log.write("적용 \(action.label): \(result.summary)\(result.confirmed ? "" : " (확인 문구 없음)") → \(result.target.agent.rawValue)@\(result.target.host.appName)\(result.warning.map { " ⚠️ " + $0 } ?? "")")
                    var detail = "\(result.target.agent.rawValue) · \(result.target.host.appName) · \(result.target.label)"
                    if !result.slotName.isEmpty { detail += "\n\(result.slotName)" }
                    // Orca 는 권한 없이도 되지만, 없으면 탭을 옮긴 직후 1~2.5초 동안 옮기기 전 터미널로 갈 수 있다 — 한 번 알려 준다.
                    if bundleID == Detector.orcaBundleID, !Permissions.accessibility, !self.nudgedOrcaAccessibility {
                        self.nudgedOrcaAccessibility = true
                        detail += "\n메뉴 → 「손쉬운 사용 켜기」를 해 두면 탭을 옮긴 직후에도 정확합니다."
                    }
                    if let warning = result.warning {
                        self.hud.show(result.summary, detail: "\(detail)\n⚠️ \(warning)", seconds: 4)
                    } else {
                        self.hud.show(result.summary, detail: detail)
                    }
                case .failure(let error as ModelSwitchError) where error.awaitingUser:
                    Log.write("확인 대기 \(action.label): \(error)")
                    self.hud.show("Enter 로 확정해 주세요", detail: "\(error)", seconds: 6)
                case .failure(let error as ModelSwitchError) where error.nothingToDo:
                    // 바꿀 것이 없었다(이미 가장 높은 단계 등) — 실패가 아니라 안내다.
                    Log.write("그대로 \(action.label): \(error)")
                    self.hud.show("\(error)", seconds: 2.5)
                case .failure(let error):
                    Log.write("실패 \(action.label): \(error)")
                    self.hud.show("전환하지 않았습니다", detail: "\(error)", seconds: 4)
                }
            }
            if case .success(let result) = outcome, let before = result.pendingRestore, let switcher,
               let late = switcher.verifyRestore(before) {
                Log.write("⚠️ \(late)")
                DispatchQueue.main.async { self.hud.show(result.summary, detail: "⚠️ \(late)", seconds: 4) }
            }
            Log.write("시간 \(action.label): \(trace.report)")
            DispatchQueue.main.async { self.busy = false }
        }
    }

    // MARK: - 메뉴

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        do {
            let config = try store.load()
            for (index, slot) in config.slots.enumerated() {
                let item = NSMenuItem(title: slot.listing, action: #selector(menuApply(_:)), keyEquivalent: "\(index + 1)")
                item.keyEquivalentModifierMask = NSEvent.ModifierFlags(config.modifiers.compactMap {
                    ["shift": .shift, "option": .option, "control": .control, "command": .command][$0]
                })
                item.tag = index + 1
                item.target = self
                menu.addItem(item)
            }
            if config.effortKeys {
                let mask = NSEvent.ModifierFlags(config.modifiers.compactMap {
                    ["shift": .shift, "option": .option, "control": .control, "command": .command][$0]
                })
                menu.addItem(.separator())
                for (title, action, key) in [("effort 한 단계 올리기", #selector(menuEffortUp), "="),
                                             ("effort 한 단계 내리기", #selector(menuEffortDown), "-")] {
                    let entry = item(title, action, key: key)
                    entry.keyEquivalentModifierMask = mask
                    menu.addItem(entry)
                }
            }
        } catch {
            let item = NSMenuItem(title: "프리셋 파일 오류 — \(error)", action: nil, keyEquivalent: "")
            menu.addItem(item)
        }
        if !hotKeys.failed.isEmpty {
            let numbers = hotKeys.failed.map { id -> String in
                switch id {
                case HotKeyCenter.effortUp: return "="
                case HotKeyCenter.effortDown: return "-"
                default: return String(id)
                }
            }.joined(separator: ", ")
            menu.addItem(NSMenuItem(title: "⚠️ 단축키 \(numbers) 은(는) 다른 앱이 쓰고 있어 잡지 못했습니다", action: nil, keyEquivalent: ""))
        }
        // 권한: 꺼져 있으면 눈에 띄게, 켜져 있어도 설정 화면으로 가는 길은 늘 둔다.
        menu.addItem(.separator())
        if Permissions.accessibility {
            let entry = item("손쉬운 사용(Accessibility) 켜짐 — 설정 보기…", #selector(openAccessibilitySettings))
            entry.state = .on
            menu.addItem(entry)
        } else {
            menu.addItem(item("⚠️ 손쉬운 사용(Accessibility) 켜기 — 설정 열기…", #selector(openAccessibilitySettings)))
        }
        menu.addItem(item("자동화(Automation) 설정 열기…", #selector(openAutomationSettings)))
        menu.addItem(.separator())
        menu.addItem(item("프리셋·권한…", #selector(openSettings), key: ","))
        menu.addItem(item("프리셋 파일 열기", #selector(openConfigFile)))
        let login = item("로그인할 때 실행", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("ModelSwitch 종료", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
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

    @objc private func openConfigFile() {
        _ = try? store.load()
        NSWorkspace.shared.open(store.url)
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            hud.show("로그인 항목을 바꾸지 못했습니다", detail: error.localizedDescription, seconds: 4)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
