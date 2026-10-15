import Foundation

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

    /// Past this size the current file is moved to `slashcommand.log.1` and a new one is started (the previous `.1` is discarded), so the log does not grow without bound.
    private static let limit = 2_000_000

    static func write(_ message: String) {
        queue.async {
            let line = "\(formatter.string(from: Date())) \(message)\n"
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit {
                let old = url.appendingPathExtension("1")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
