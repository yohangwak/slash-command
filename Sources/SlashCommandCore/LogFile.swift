import Foundation

/// The one place that appends a line to a log file. The app, the Windows tray app and the CLI all write through it, so they follow the same rules:
/// past `limit` bytes the current file is moved to `<name>.1` (the previous `.1` is discarded), and outside Windows the folder is 0700 and the file is 0600.
/// A failure is ignored on purpose: a log problem must never stop the app.
public enum LogFile {
    public static func append(_ line: String, to url: URL, limit: Int = 2_000_000) {
        let manager = FileManager.default
        #if !os(Windows)
        let folder = url.deletingLastPathComponent()
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A folder made by an earlier version keeps its old mode unless it is set here.
        if let mode = (try? manager.attributesOfItem(atPath: folder.path))?[.posixPermissions] as? NSNumber, mode.intValue != 0o700 {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
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
        // The current file and the rotated one, which an earlier version may have left readable by others.
        for file in [url, url.appendingPathExtension("1")] {
            if let mode = (try? manager.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber, mode.intValue != 0o600 {
                try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        #endif
    }

    /// Versions before 0.2.3 could write screen text into the log. The first time this version starts, any such log is moved to the Trash (deleted where there is no Trash), and a
    /// marker file next to the log records that this was done, so the new log is never touched again. The marker is made only when every file was removed, so a failure is retried
    /// at the next start. Returns how many files were removed.
    @discardableResult
    public static func retireOldLogs(at url: URL, discard: (URL) throws -> Void = LogFile.discard) -> Int {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        let marker = folder.appendingPathComponent(".log-format-2")
        if manager.fileExists(atPath: marker.path) { return 0 }
        var removed = 0
        for file in [url, url.appendingPathExtension("1")] where manager.fileExists(atPath: file.path) {
            do { try discard(file); removed += 1 } catch { return removed }
        }
        #if !os(Windows)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = manager.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        #else
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data().write(to: marker)
        #endif
        return removed
    }

    /// Moves a file to the Trash on macOS (deleting it if that fails); deletes it elsewhere.
    public static func discard(_ url: URL) throws {
        #if os(macOS)
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { try FileManager.default.removeItem(at: url) }
        #else
        try FileManager.default.removeItem(at: url)
        #endif
    }
}
