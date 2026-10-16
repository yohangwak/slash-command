#if os(Windows)
import Foundation
import WinSDK

extension Detector {
    /// Reuses the process-image reader used by the native detector, without exposing process data.
    public static func isWindowsOrca(pid: UInt32) -> Bool {
        WindowsAppModel.supports(image: ProcessTable.executablePath(of: Int32(bitPattern: pid)))
    }

    /// Pins asynchronous resolution to the process where the shortcut was pressed.
    public static func target(app: String, frontPID: UInt32) throws -> Target {
        func requireFront() throws {
            var current: DWORD = 0
            guard let window = GetForegroundWindow() else { throw SlashCommandError(loc("Cannot tell which app is in front.")) }
            GetWindowThreadProcessId(window, &current)
            guard current == frontPID, isWindowsOrca(pid: current) else {
                throw SlashCommandError(loc("The foreground app changed. Press the shortcut again."))
            }
        }
        try requireFront()
        let found = try target(app: app)
        try requireFront()
        return found
    }
}
#endif
