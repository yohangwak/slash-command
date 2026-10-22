#if os(Windows)
import WinSDK
import SlashCommandCore

final class HotKeys {
    private(set) var registered: [Int] = []
    private var loggedState: [Int] = []
    private var signature = ""
    private(set) var failed: [Int] = []
    private(set) var warning: String?

    func update(window: HWND, foreground: Foreground, config: SlashCommandConfig?, retry: Bool = false) {
        // The warning is part of the signature: a presets-file edit that changes only the warning must still refresh it.
        let next = foreground.supported ? "\(config?.slots.count ?? 0):\(config?.modifiers ?? []):\(config?.effortKeys ?? false):\(config.flatMap(WindowsAppModel.modifierWarning(for:)) ?? ""):\(UInt(bitPattern: GetKeyboardLayout(GetWindowThreadProcessId(foreground.window, nil))))" : "off"
        guard retry || next != signature else { return }
        clear(window: window)
        signature = next
        guard foreground.supported, let config else { logState(); return }
        let modifiers = WindowsAppModel.modifiers(config.modifiers)
        warning = WindowsAppModel.modifierWarning(for: config)
        if let warning { Log.write("hotkeys: \(warning)") }
        var ids = Array(1...9).prefix(config.slots.count).map { $0 }
        if config.effortKeys { ids += [WindowsAppModel.effortUp, WindowsAppModel.effortDown] }
        let layout = GetKeyboardLayout(GetWindowThreadProcessId(foreground.window, nil))
        for id in ids {
            let vk = MapVirtualKeyExW(WindowsAppModel.scanCode(for: id)!, UINT(MAPVK_VSC_TO_VK_EX), layout)
            if vk != 0, RegisterHotKey(window, Int32(id), modifiers.flags, vk) {
                registered.append(id)
            } else {
                failed.append(id)
                Log.write("hotkey registration failed \(WindowsAppModel.keyName(id)): \(GetLastError())")
            }
        }
        logState()
    }

    private func clear(window: HWND) {
        for id in registered { UnregisterHotKey(window, Int32(id)) }
        registered = []; failed = []; warning = nil; signature = ""
    }
    func unregister(window: HWND) { clear(window: window); logState() }
    private func logState() {
        guard let line = WindowsAppModel.hotkeysLine(previous: loggedState, registered: registered) else { return }
        loggedState = registered
        Log.write(line)
    }
}
#endif
