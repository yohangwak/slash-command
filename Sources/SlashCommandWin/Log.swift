#if os(Windows)
import Foundation
import WinSDK
import SlashCommandCore

// Only explicit action/result/timing strings enter this logger. Screen snapshots never do.
enum Log {
    private static let queue = DispatchQueue(label: "slashcommand.windows.log")
    static func flush() { queue.sync {} }
    static var folder: URL? {
        guard let path = ProcessInfo.processInfo.environment.first(where: { $0.key.lowercased() == "localappdata" })?.value,
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).appendingPathComponent("SlashCommand/Logs")
    }
    static func write(_ message: String) {
        queue.async { append(message) }
    }
    private static func append(_ message: String) {
        guard let folder else { return }
        LogFile.append(WindowsAppModel.logLine(message), to: folder.appendingPathComponent("slashcommand.log"))
    }
}
#endif
