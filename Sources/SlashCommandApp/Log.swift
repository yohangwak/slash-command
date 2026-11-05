import Foundation
import SlashCommandCore

/// Appends one line at a time to `~/Library/Logs/SlashCommand/slashcommand.log`, so you can check later what was pressed and how it ended.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SlashCommand/slashcommand.log")
    private static let queue = DispatchQueue(label: "slashcommand.log")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    /// Once, at launch: moves a log written by a version before 0.2.3 (which could hold screen text) to the Trash.
    static func retireOldLogs() {
        queue.async {
            if LogFile.retireOldLogs(at: url) > 0 {
                LogFile.append("\(formatter.string(from: Date())) earlier log moved to the Trash: versions before 0.2.3 could write screen text into it\n", to: url)
            }
        }
    }

    static func write(_ message: String) {
        queue.async {
            let line = "\(formatter.string(from: Date())) \(message)\n"
            LogFile.append(line, to: url)
        }
    }
}
