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
    /// Once, at start: deletes a log written by a version before 0.2.3 (which could hold screen text).
    static func retireOldLogs() {
        queue.async {
            guard let folder else { return }
            let url = folder.appendingPathComponent("slashcommand.log")
            if LogFile.retireOldLogs(at: url) > 0 {
                LogFile.append(WindowsAppModel.logLine("earlier log deleted: versions before 0.2.3 could write screen text into it"), to: url)
            }
        }
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
