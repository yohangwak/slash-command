#if os(Windows)
import Foundation
import WinSDK

extension Detector {
    /// Reuses the process-image reader used by the native detector, without exposing process data.
    public static func isWindowsOrca(pid: UInt32) -> Bool {
        WindowsAppModel.app(image: ProcessTable.executablePath(of: Int32(bitPattern: pid))) == "orca"
    }

    /// Menu reads retain the terminal snapshot while Explorer/the tray owns focus.
    /// This only resolves the pinned pane; writes still require WindowsWezTermIO's foreground guard.
    /// For Windows Terminal, `pane` is the runtime ID of the pane last seen with focus: once the tray is in front, no pane has focus.
    public static func windowsMenuTarget(app: String, frontPID: UInt32, frontWindow: UInt? = nil, pane: String? = nil) throws -> Target {
        guard WindowsAppModel.app(image: ProcessTable.executablePath(of: Int32(bitPattern: frontPID))) == app else {
            throw SlashCommandError(loc("The foreground app changed. Press the shortcut again."))
        }
        if app == "windowsterminal" {
            guard let pane else { throw WindowsTerminal.changed }
            return try windowsTerminal(window: frontWindow ?? WindowsTerminal.window(pid: frontPID), pane: pane)
        }
        return try app == "wezterm" ? windowsWezTerm(frontPID: Int32(bitPattern: frontPID)) : target(app: app)
    }

    /// Pins asynchronous resolution to the process where the shortcut was pressed.
    public static func target(app: String, frontPID: UInt32, frontWindow: UInt? = nil) throws -> Target {
        guard WindowsAppModel.app(image: app) != nil || ["orca", "wezterm", "windowsterminal"].contains(app.lowercased()) else {
            throw SlashCommandError(loc("This is not supported on this operating system yet."))
        }
        let pinnedWindow = ["windowsterminal", "windowsterminal.exe"].contains(app.lowercased()) ? frontWindow : nil
        func requireFront() throws {
            var current: DWORD = 0
            guard let window = GetForegroundWindow() else { throw SlashCommandError(loc("Cannot tell which app is in front.")) }
            GetWindowThreadProcessId(window, &current)
            guard current == frontPID, pinnedWindow == nil || UInt(bitPattern: window) == pinnedWindow,
                  WindowsAppModel.supports(image: ProcessTable.executablePath(of: Int32(bitPattern: current))) else {
                throw SlashCommandError(loc("The foreground app changed. Press the shortcut again."))
            }
        }
        try requireFront()
        let image = ProcessTable.executablePath(of: Int32(bitPattern: frontPID))
        if WindowsAppModel.app(image: image) == "windowsterminal" {
            let pinnedWindow = frontWindow ?? GetForegroundWindow().map { UInt(bitPattern: $0) }
            let found = try windowsTerminal(window: pinnedWindow, requireForeground: true)
            try requireFront(); return found
        }
        let found = try WindowsAppModel.app(image: image) == "wezterm"
            ? windowsWezTerm(frontPID: Int32(bitPattern: frontPID)) : target(app: app)
        try requireFront()
        return found
    }
}
#endif
