#if os(Windows)
import Foundation
import WinSDK

extension Proc {
    /// Ends `root` and every process it started, deepest first.
    /// Each process is opened once, and its start time is read and it is terminated through that same handle,
    /// so a pid reused between the snapshot and the termination can never point at another process.
    static func terminateTree(_ root: Int32) {
        var parents: [Int32: Int32] = [:]
        // Every process in the snapshot existed before this moment; one that started later only inherited a pid.
        var now = FILETIME()
        GetSystemTimeAsFileTime(&now)
        let snapshotTime = UInt64(now.dwHighDateTime) << 32 | UInt64(now.dwLowDateTime)
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        if snapshot != INVALID_HANDLE_VALUE {
            defer { CloseHandle(snapshot) }
            var entry = PROCESSENTRY32W()
            entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
            var more = Process32FirstW(snapshot, &entry)
            while more {
                parents[Int32(bitPattern: entry.th32ProcessID)] = Int32(bitPattern: entry.th32ParentProcessID)
                more = Process32NextW(snapshot, &entry)
            }
        }
        var handles: [Int32: HANDLE] = [:]
        defer { for handle in handles.values { CloseHandle(handle) } }
        func handle(_ pid: Int32) -> HANDLE? {
            if let open = handles[pid] { return open }
            guard let opened = OpenProcess(DWORD(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(bitPattern: pid)) else { return nil }
            handles[pid] = opened
            return opened
        }
        // Left alone: a "child" that cannot be opened, that started before its claimed parent (the parent pid was reused),
        // or that started after the snapshot (its own pid was reused between the snapshot and OpenProcess).
        let reused: (Int32, Int32) -> Bool = { child, parent in
            guard let childHandle = handle(child), let parentHandle = handle(parent),
                  let childStart = startTime(childHandle), let parentStart = startTime(parentHandle) else { return true }
            return childStart < parentStart || childStart > snapshotTime
        }
        for pid in descendants(of: root, parents: parents, startedBefore: reused) + [root] {
            guard let target = handle(pid) else { continue }
            _ = TerminateProcess(target, 1)
        }
    }

    /// Creation time as a FILETIME count.
    static func startTime(_ process: HANDLE) -> UInt64? {
        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(process, &created, &exited, &kernel, &user) else { return nil }
        return UInt64(created.dwHighDateTime) << 32 | UInt64(created.dwLowDateTime)
    }
}
#endif
