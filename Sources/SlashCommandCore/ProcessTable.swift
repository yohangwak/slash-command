#if os(macOS)
import Darwin
import Foundation

/// Reads the command line and environment variables of running processes from inside the process (the same information as `ps -axEww`).
///
/// Starting `ps` costs about 0.2 s (measured 2026-10-06). Reading only the processes attached to a terminal directly takes a few ms.
/// Environment variables may contain secrets, so what is read here is not kept anywhere.
enum ProcessTable {
    struct Entry {
        let pid: Int32
        let parent: Int32
        let hasTerminal: Bool
        /// Device number of the attached terminal (the same value as `stat("/dev/ttys004").st_rdev`).
        let terminalDevice: UInt32
        /// This process's process group, and the process group that is "currently in front" on that terminal. If they are equal, it is that terminal's foreground job
        /// (one stopped with Ctrl-Z or `tmux suspend-client` is different).
        var processGroup: Int32 = 0
        var foregroundGroup: Int32 = 0
        var isForeground: Bool { processGroup != 0 && processGroup == foregroundGroup }
        let arguments: [String]
        let environment: [String]
        /// Path of the file actually running (symlinks resolved). The first word of the command line can be just a name like `claude`.
        let executable: String
    }

    /// Processes that are attached to a terminal and readable, plus the parent relations of all processes.
    static func snapshot() -> (entries: [Entry], parents: [Int32: Int32]) {
        var entries: [Entry] = []
        var parents: [Int32: Int32] = [:]
        for pid in allPIDs() {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            parents[pid] = Int32(info.pbi_ppid)
            // If e_tdev is NODEV (-1), the process has no terminal; it is not an agent session, so its command line is not read.
            guard info.e_tdev != UInt32.max, let (arguments, environment) = commandLine(of: pid) else { continue }
            entries.append(Entry(pid: pid, parent: Int32(info.pbi_ppid), hasTerminal: true, terminalDevice: info.e_tdev,
                                 processGroup: Int32(info.pbi_pgid), foregroundGroup: Int32(info.e_tpgid),
                                 arguments: arguments, environment: environment,
                                 executable: executablePath(of: pid)))
        }
        return (entries, parents)
    }

    /// When that process started (seconds and microseconds as one number). It stays the same even if it becomes another program through `exec`; used to tell whether a pid was reused.
    static func startTime(of pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    static func executablePath(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }

    static func allPIDs() -> [Int32] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(needed) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    static func commandLine(of pid: Int32) -> (arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parse(procargs: Array(buffer.prefix(size)))
    }

    /// Layout of `KERN_PROCARGS2`: argument count (Int32) · executable path · zero padding · arguments · environment variables (each ends with 0).
    static func parse(procargs buffer: [UInt8]) -> (arguments: [String], environment: [String])? {
        let header = MemoryLayout<Int32>.size
        guard buffer.count > header else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        var index = header
        while index < buffer.count, buffer[index] != 0 { index += 1 }   // executable path
        while index < buffer.count, buffer[index] == 0 { index += 1 }   // padding
        var strings: [String] = []
        while index < buffer.count {
            var end = index
            while end < buffer.count, buffer[end] != 0 { end += 1 }
            if end == index, strings.count >= Int(argc) { break }       // empty string after the environment variables = end
            strings.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        guard strings.count >= Int(argc) else { return nil }
        return (Array(strings.prefix(Int(argc))), Array(strings.dropFirst(Int(argc))))
    }
}
#endif
