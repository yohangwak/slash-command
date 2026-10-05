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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: "ModelSwitch")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hotKeys.onPress = { [weak self] slot in
            Log.write("단축키 \(slot)번")
            self?.apply(slot: slot)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        refreshHotKeys()
    }

    // MARK: - 단축키

    /// 지원하는 터미널이 맨 앞일 때만 단축키를 잡는다 — 다른 앱의 ⌃⌘숫자를 가로채지 않는다.
    private func refreshHotKeys() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let config = Detector.supportedBundleIDs.contains(front) ? try? store.load() : nil
        let wanted = config?.slots.count ?? 0
        let modifiers = config?.modifiers ?? []
        guard wanted != hotKeys.registeredCount || (wanted > 0 && modifiers != hotKeys.registeredModifiers) else { return }
        if let config, wanted > 0 {
            hotKeys.register(count: wanted, modifiers: modifiers)
            Log.write("단축키 등록 \(config.modifierSymbols)1…\(wanted) (\(front))\(hotKeys.failed.isEmpty ? "" : " — 못 잡은 번호 \(hotKeys.failed)")")
        } else {
            hotKeys.unregister()
            Log.write("단축키 해제 (\(front))")
        }
    }

    @objc private func frontAppChanged() {
        refreshHotKeys()
    }

    // MARK: - 전환

    private func apply(slot: Int) {
        guard !busy else {
            hud.show("전환 중입니다", detail: "끝난 뒤 다시 눌러 주세요.")
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication, let bundleID = front.bundleIdentifier else { return }
        let appName = front.localizedName ?? bundleID
        // Ghostty 화면은 접근성으로 읽는다. 권한이 없으면 시스템 안내 창을 띄우고 여기서 멈춘다.
        if bundleID == Detector.ghosttyBundleID, !GhosttyScreen.trusted(prompt: true) {
            Log.write("실패 \(slot): 손쉬운 사용 권한 없음")
            hud.show("손쉬운 사용 권한이 필요합니다",
                     detail: "Ghostty 화면을 읽어 입력창 상태를 확인합니다. 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 ModelSwitch 를 켠 뒤 다시 눌러 주세요.",
                     seconds: 6)
            return
        }
        busy = true
        hud.show("\(slot)번 프리셋 적용 중…", seconds: nil)

        worker.async { [store] in
            let trace = Trace()
            var switcher: Switcher?
            let outcome = Result { () throws -> SwitchResult in
                var made = Switcher(config: try store.load())
                made.trace = trace
                switcher = made
                let target = try Detector.target(bundleID: bundleID, appName: appName)
                trace.mark("대상찾기")
                return try made.apply(slot: slot, to: target, deferFinalCheck: true)
            }
            // 알림을 먼저 띄운다 — 기본값 재확인(0.25초)은 그 뒤에 한다.
            DispatchQueue.main.async {
                switch outcome {
                case .success(let result):
                    Log.write("적용 \(slot): \(result.summary)\(result.confirmed ? "" : " (확인 문구 없음)") → \(result.target.agent.rawValue)@\(result.target.host.appName)\(result.warning.map { " ⚠️ " + $0 } ?? "")")
                    var detail = "\(result.target.agent.rawValue) · \(result.target.host.appName) · \(result.target.label)"
                    if !result.slotName.isEmpty { detail += "\n\(result.slotName)" }
                    if let warning = result.warning {
                        self.hud.show(result.summary, detail: "\(detail)\n⚠️ \(warning)", seconds: 4)
                    } else {
                        self.hud.show(result.summary, detail: detail)
                    }
                case .failure(let error as ModelSwitchError) where error.awaitingUser:
                    Log.write("확인 대기 \(slot): \(error)")
                    self.hud.show("Enter 로 확정해 주세요", detail: "\(error)", seconds: 6)
                case .failure(let error):
                    Log.write("실패 \(slot): \(error)")
                    self.hud.show("전환하지 않았습니다", detail: "\(error)", seconds: 4)
                }
            }
            if case .success(let result) = outcome, let before = result.pendingRestore, let switcher,
               let late = switcher.verifyRestore(before) {
                Log.write("⚠️ \(late)")
                DispatchQueue.main.async { self.hud.show(result.summary, detail: "⚠️ \(late)", seconds: 4) }
            }
            Log.write("시간 \(slot): \(trace.report)")
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
        } catch {
            let item = NSMenuItem(title: "프리셋 파일 오류 — \(error)", action: nil, keyEquivalent: "")
            menu.addItem(item)
        }
        if !hotKeys.failed.isEmpty {
            let numbers = hotKeys.failed.map(String.init).joined(separator: ", ")
            menu.addItem(NSMenuItem(title: "⚠️ \(numbers)번 단축키는 다른 앱이 쓰고 있어 잡지 못했습니다", action: nil, keyEquivalent: ""))
        }
        if !GhosttyScreen.trusted() {
            menu.addItem(item("⚠️ Ghostty 용 손쉬운 사용 권한 켜기…", #selector(openAccessibilitySettings)))
        }
        menu.addItem(.separator())
        menu.addItem(item("프리셋 편집…", #selector(openSettings), key: ","))
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
        apply(slot: sender.tag)
    }

    @objc private func openSettings() {
        if settings == nil {
            settings = SettingsWindowController(store: store) { [weak self] in self?.refreshHotKeys() }
        }
        settings?.present()
    }

    @objc private func openAccessibilitySettings() {
        _ = GhosttyScreen.trusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

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
