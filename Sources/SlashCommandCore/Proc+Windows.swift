#if os(Windows)
import Foundation
import WinSDK

extension Proc {
    /// Ends `root` and every process it started, deepest first.
    static func terminateTree(_ root: Int32) {
        var parents: [Int32: Int32] = [:]
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
        // A child whose start time cannot be read, or that started before its claimed parent, is left alone.
        let reused: (Int32, Int32) -> Bool = { child, parent in
            guard let childStart = startTime(child), let parentStart = startTime(parent) else { return true }
            return childStart < parentStart
        }
        for pid in descendants(of: root, parents: parents, startedBefore: reused) + [root] {
            guard let handle = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(bitPattern: pid)) else { continue }
            _ = TerminateProcess(handle, 1)
            CloseHandle(handle)
        }
    }

    /// Creation time as a FILETIME count, or nil when the process cannot be opened.
    static func startTime(_ pid: Int32) -> UInt64? {
        guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(bitPattern: pid)) else { return nil }
        defer { CloseHandle(handle) }
        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(handle, &created, &exited, &kernel, &user) else { return nil }
        return UInt64(created.dwHighDateTime) << 32 | UInt64(created.dwLowDateTime)
    }
}
#endif
