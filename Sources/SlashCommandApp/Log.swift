import Foundation

/// `~/Library/Logs/SlashCommand/slashcommand.log` 에 한 줄씩 남긴다. 무엇을 눌렀고 어떻게 끝났는지 나중에 확인하기 위한 것.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SlashCommand/slashcommand.log")
    private static let queue = DispatchQueue(label: "slashcommand.log")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    /// 이 크기를 넘으면 지금 파일을 `slashcommand.log.1` 로 넘기고 새로 쓴다(앞의 `.1` 은 버린다) — 기록이 끝없이 자라지 않게.
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
