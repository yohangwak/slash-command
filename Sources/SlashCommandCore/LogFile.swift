import Foundation

/// The one place that appends a line to a log file. The app, the Windows tray app and the CLI all write through it, so they follow the same rules:
/// past `limit` bytes the current file is moved to `<name>.1` (the previous `.1` is discarded), and outside Windows the folder is 0700 and the file is 0600.
/// A failure is ignored on purpose: a log problem must never stop the app.
public enum LogFile {
    public static func append(_ line: String, to url: URL, limit: Int = 2_000_000) {
        let manager = FileManager.default
        #if !os(Windows)
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        #else
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #endif
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > limit {
            let old = url.appendingPathExtension("1")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            #if !os(Windows)
            _ = manager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
            #else
            try? data.write(to: url)
            #endif
        }
        #if !os(Windows)
        if let mode = (try? manager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber, mode.intValue != 0o600 {
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        #endif
    }
}
