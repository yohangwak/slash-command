#if os(Windows)
import Foundation
import WinSDK

extension Detector {
    /// Reuses the process-image reader used by the native detector, without exposing process data.
    public static func isWindowsOrca(pid: UInt32) -> Bool {
        WindowsAppModel.app(image: ProcessTable.executablePath(of: Int32(bitPattern: pid))) == "orca"
    }

    /// Pins asynchronous resolution to the process where the shortcut was pressed.
    public static func target(app: String, frontPID: UInt32) throws -> Target {
        func requireFront() throws {
            var current: DWORD = 0
            guard let window = GetForegroundWindow() else { throw SlashCommandError(loc("Cannot tell which app is in front.")) }
            GetWindowThreadProcessId(window, &current)
            guard current == frontPID, WindowsAppModel.supports(image: ProcessTable.executablePath(of: Int32(bitPattern: current))) else {
                throw SlashCommandError(loc("The foreground app changed. Press the shortcut again."))
            }
        }
        try requireFront()
        let image = ProcessTable.executablePath(of: Int32(bitPattern: frontPID))
        let found = try WindowsAppModel.app(image: image) == "wezterm"
            ? windowsWezTerm(frontPID: Int32(bitPattern: frontPID)) : target(app: app)
        try requireFront()
        return found
    }
}
#endif
