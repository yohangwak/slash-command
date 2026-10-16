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
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("slashcommand.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
            let old = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        let data = Data(WindowsAppModel.logLine(message).utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
        } else { try? data.write(to: url) }
    }
}
#endif
