#if os(Windows)
import Foundation
import WinSDK

/// Native x64 process reads. Only the exact Orca marker survives the temporary environment buffer.
/// WOW64 processes and inaccessible processes are skipped rather than guessed at.
enum ProcessTable {
    struct Entry {
        let pid: Int32
        let parent: Int32
        let arguments: [String]
        let environment: [String]
        let executable: String
    }

    typealias Query = @convention(c) (HANDLE?, UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<UInt32>?) -> Int32
    static let query: Query? = {
        guard let dll = "ntdll.dll".withCString(encodedAs: UTF16.self, GetModuleHandleW),
              let address = GetProcAddress(dll, "NtQueryInformationProcess") else { return nil }
        return unsafeBitCast(address, to: Query.self)
    }()

    static func executablePath(of pid: Int32) -> String {
        guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(bitPattern: pid)) else { return "" }
        defer { CloseHandle(process) }
        return image(process)
    }

    static func image(_ process: HANDLE) -> String {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        var size = DWORD(buffer.count)
        guard QueryFullProcessImageNameW(process, 0, &buffer, &size) else { return "" }
        return String(decoding: buffer.prefix(Int(size)), as: UTF16.self)
    }

    static func snapshot() -> (entries: [Entry], parents: [Int32: Int32]) {
        var entries: [Entry] = [], parents: [Int32: Int32] = [:]
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard snapshot != INVALID_HANDLE_VALUE, let snapshot else { return (entries, parents) }
        defer { CloseHandle(snapshot) }
        var item = PROCESSENTRY32W()
        item.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var more = Process32FirstW(snapshot, &item)
        while more {
            let pid = Int32(bitPattern: item.th32ProcessID), parent = Int32(bitPattern: item.th32ParentProcessID)
            parents[pid] = parent
            if let process = OpenProcess(DWORD(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ), false, item.th32ProcessID) {
                var wow64: WindowsBool = false
                if IsWow64Process(process, &wow64), !wow64.boolValue,
                   let marker = orcaMarker(process) {
                    let command = commandLine(process) ?? ""
                    entries.append(Entry(pid: pid, parent: parent, arguments: [command], environment: [marker], executable: image(process)))
                }
                CloseHandle(process)
            }
            more = Process32NextW(snapshot, &item)
        }
        return (entries, parents)
    }

    /// Every native process started under `root` (not `root` itself), with its command line and image.
    /// Unlike `snapshot()` it does not require the Orca marker, and it reads no environment.
    /// A descendant that cannot be opened is still listed, with an empty command line and image, so a caller can refuse instead of missing it.
    static func descendants(of root: Int32) -> [Entry] {
        var parents: [Int32: Int32] = [:]
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard snapshot != INVALID_HANDLE_VALUE, let snapshot else { return [] }
        defer { CloseHandle(snapshot) }
        var item = PROCESSENTRY32W()
        item.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var more = Process32FirstW(snapshot, &item)
        while more {
            parents[Int32(bitPattern: item.th32ProcessID)] = Int32(bitPattern: item.th32ParentProcessID)
            more = Process32NextW(snapshot, &item)
        }
        var children: [Int32: [Int32]] = [:]
        for (pid, parent) in parents where pid != parent { children[parent, default: []].append(pid) }
        // A pid can be reused: a "child" that started before its parent belongs to someone else, and so does everything under it.
        func started(_ pid: Int32) -> (UInt64?, String, String) {
            guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(bitPattern: pid)) else { return (nil, "", "") }
            defer { CloseHandle(process) }
            return (Proc.startTime(process), commandLine(process) ?? "", image(process))
        }
        guard let rootStart = started(root).0 else { return [] }
        var queue = (children[root] ?? []).map { ($0, rootStart) }, seen: Set<Int32> = [root], entries: [Entry] = []
        while let (pid, parentStart) = queue.popLast() {
            guard seen.insert(pid).inserted else { continue }
            let (start, command, executable) = started(pid)
            if let start, start < parentStart { continue }
            entries.append(Entry(pid: pid, parent: parents[pid] ?? 0, arguments: [command], environment: [], executable: executable))
            if let start { queue += (children[pid] ?? []).map { ($0, start) } }
        }
        return entries
    }

    static func commandLine(_ process: HANDLE) -> String? {
        guard let query else { return nil }
        var size: UInt32 = 0
        _ = query(process, 60, nil, 0, &size) // ProcessCommandLineInformation
        guard size >= 16, size <= 1_048_576 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(size))
        return buffer.withUnsafeMutableBytes { bytes in
            guard query(process, 60, bytes.baseAddress, size, &size) >= 0 else { return nil }
            let length = Int(bytes.loadUnaligned(as: UInt16.self))
            let address = bytes.loadUnaligned(fromByteOffset: 8, as: UInt.self)
            let start = UInt(bitPattern: bytes.baseAddress!)
            guard length % 2 == 0, address >= start + 16, address <= start + UInt(bytes.count),
                  UInt(length) <= start + UInt(bytes.count) - address else { return nil }
            let string = UnsafeRawBufferPointer(start: UnsafeRawPointer(bitPattern: address), count: length)
            return String(decoding: string.bindMemory(to: UInt16.self), as: UTF16.self)
        }
    }

    /// Snapshot only parent IDs, without reading any environment or command line.
    private static func parentIDs() throws -> [Int32: Int32] {
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard snapshot != INVALID_HANDLE_VALUE, let snapshot else { throw WindowsTerminal.unmatched }
        defer { CloseHandle(snapshot) }
        var entry = PROCESSENTRY32W(), parents: [Int32: Int32] = [:]
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var more = Process32FirstW(snapshot, &entry)
        guard more else { throw WindowsTerminal.unmatched }
        while more {
            parents[Int32(bitPattern: entry.th32ProcessID)] = Int32(bitPattern: entry.th32ParentProcessID)
            more = Process32NextW(snapshot, &entry)
        }
        guard GetLastError() == ERROR_NO_MORE_FILES else { throw WindowsTerminal.unmatched }
        return parents
    }

    /// Only direct children created after WT itself. No command-line reads during candidate discovery.
    static func consoleCandidates(of root: Int32) throws -> [Entry] {
        guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(bitPattern: root)) else { throw WindowsTerminal.unmatched }
        defer { CloseHandle(process) }
        guard let rootStart = Proc.startTime(process) else { throw WindowsTerminal.unmatched }
        return try parentIDs().compactMap { pid, parent in
            guard parent == root, pid != root else { return nil }
            guard let child = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(bitPattern: pid)) else { throw WindowsTerminal.unmatched }
            defer { CloseHandle(child) }
            guard let start = Proc.startTime(child) else { throw WindowsTerminal.unmatched }
            guard start >= rootStart else { return nil }
            let executable = image(child)
            guard !executable.isEmpty else { throw WindowsTerminal.unmatched }
            return Entry(pid: pid, parent: parent, arguments: [], environment: [], executable: executable)
        }
    }

    /// Read exactly the console members. An unreadable member remains visible to fail-closed identity checks.
    static func consoleMember(_ member: WindowsConsoleMember) -> Entry? {
        guard let parents = try? parentIDs(),
              let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, member.pid) else { return nil }
        defer { CloseHandle(process) }
        guard member.start > 0, Proc.startTime(process) == member.start,
              let command = commandLine(process), !command.isEmpty else { return nil }
        let executable = image(process)
        guard !executable.isEmpty else { return nil }
        let pid = Int32(bitPattern: member.pid)
        return Entry(pid: pid, parent: parents[pid] ?? 0, arguments: [command], environment: [], executable: executable)
    }

    static func read(_ process: HANDLE, address: UInt, count: Int) -> [UInt8]? {
        guard address > 0, count > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: count)
        var read: SIZE_T = 0
        guard ReadProcessMemory(process, UnsafeRawPointer(bitPattern: address), &buffer, SIZE_T(count), &read), read == SIZE_T(count) else { return nil }
        return buffer
    }

    static func pointer(_ process: HANDLE, at address: UInt) -> UInt? {
        read(process, address: address, count: 8)?.withUnsafeBytes { $0.loadUnaligned(as: UInt.self) }
    }

    static func adding(_ address: UInt, _ offset: UInt) -> UInt? {
        let (result, overflow) = address.addingReportingOverflow(offset)
        return overflow ? nil : result
    }

    static func orcaMarker(_ process: HANDLE) -> String? {
        guard MemoryLayout<UInt>.size == 8, let query else { return nil }
        var basic = [UInt8](repeating: 0, count: 48)
        guard query(process, 0, &basic, 48, nil) >= 0 else { return nil }
        let peb = basic.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt.self) }
        guard let parametersAddress = adding(peb, 0x20),
              let parameters = pointer(process, at: parametersAddress),
              let environmentAddress = adding(parameters, 0x80),
              let environment = pointer(process, at: environmentAddress), environment > 0 else { return nil }
        // Bound the private-layout read; no environment string other than the marker escapes this scope.
        var units: [UInt16] = []
        var offset: UInt = 0
        while offset < 1_048_576 {
            var info = MEMORY_BASIC_INFORMATION()
            guard let address = adding(environment, offset),
                  VirtualQueryEx(process, UnsafeRawPointer(bitPattern: address), &info, SIZE_T(MemoryLayout<MEMORY_BASIC_INFORMATION>.size)) > 0,
                  let end = adding(UInt(bitPattern: info.BaseAddress), UInt(info.RegionSize)), end > address else { return nil }
            let count = Int(min(4096, end - address, 1_048_576 - offset)) & ~1
            guard count > 0, let bytes = read(process, address: address, count: count) else { return nil }
            let chunk = bytes.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
            for unit in chunk {
                if unit == 0 {
                    if units.isEmpty { return nil }
                    let prefix = Array("ORCA_TERMINAL_HANDLE=".utf16)
                    if units.starts(with: prefix), units.count > prefix.count { return String(decoding: units, as: UTF16.self) }
                    units.removeAll(keepingCapacity: true)
                } else { units.append(unit) }
            }
            offset += UInt(count)
        }
        return nil
    }
}
#endif
