#if os(Windows)
import Foundation
import WinSDK

extension Proc {
    /// No console allocation, and only the three standard handles are inherited.
    static func runWindows(_ exe: String, _ args: [String], env: [String: String]?, cwd: String?, timeout: TimeInterval) -> ProcResult {
        var executable = exe, arguments = args
        if let batch = batchArguments(exe, args) {
            executable = ProcessInfo.processInfo.environment.first { $0.key.uppercased() == "COMSPEC" }?.value
                ?? #"C:\Windows\System32\cmd.exe"#
            arguments = batch
        } else if isBatchFile(exe) {
            return ProcResult(status: -1, out: "", err: "\(exe): " + loc("Refused to run a batch file with arguments that cmd.exe could misread."), timedOut: false)
        }
        func failed() -> ProcResult {
            ProcResult(status: -1, out: "", err: "\(exe): Win32 \(GetLastError())", timedOut: false)
        }
        var security = SECURITY_ATTRIBUTES()
        security.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
        security.bInheritHandle = WindowsBool(true)
        var outRead: HANDLE?, outWrite: HANDLE?, errRead: HANDLE?, errWrite: HANDLE?
        var input: HANDLE?
        defer {
            for handle in [outRead, outWrite, errRead, errWrite, input].compactMap({ $0 }) { CloseHandle(handle) }
        }
        guard CreatePipe(&outRead, &outWrite, &security, 0),
              CreatePipe(&errRead, &errWrite, &security, 0),
              SetHandleInformation(outRead, DWORD(HANDLE_FLAG_INHERIT), 0),
              SetHandleInformation(errRead, DWORD(HANDLE_FLAG_INHERIT), 0) else { return failed() }
        input = "NUL".withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), &security, DWORD(OPEN_EXISTING), 0, nil)
        }
        guard let inputHandle = input, inputHandle != INVALID_HANDLE_VALUE else { input = nil; return failed() }
        var attributeSize: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &attributeSize)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(attributeSize), alignment: MemoryLayout<UInt>.alignment)
        defer { storage.deallocate() }
        let attributes = OpaquePointer(storage)
        guard InitializeProcThreadAttributeList(attributes, 1, 0, &attributeSize) else { return failed() }
        defer { DeleteProcThreadAttributeList(attributes) }
        var handles = [inputHandle, outWrite!, errWrite!]
        return handles.withUnsafeMutableBytes { handleBytes in
            // PROC_THREAD_ATTRIBUTE_HANDLE_LIST = ProcThreadAttributeValue(2, FALSE, TRUE, FALSE).
            guard UpdateProcThreadAttribute(attributes, 0, DWORD_PTR(0x00020002), handleBytes.baseAddress,
                                            SIZE_T(handleBytes.count), nil, nil) else { return failed() }
            var startup = STARTUPINFOEXW()
            startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
            startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
            startup.StartupInfo.hStdInput = inputHandle
            startup.StartupInfo.hStdOutput = outWrite
            startup.StartupInfo.hStdError = errWrite
            startup.lpAttributeList = attributes
            var process = PROCESS_INFORMATION()
            var command = Array(([executable] + arguments).map(windowsQuote).joined(separator: " ").utf16) + [0]
            var environment = env.map(windowsEnvironment) ?? []
            let launch: (UnsafeMutableRawPointer?, UnsafePointer<WCHAR>?) -> Bool = { block, directory in
                executable.withCString(encodedAs: UTF16.self) { app in
                    command.withUnsafeMutableBufferPointer { line in
                        withUnsafeMutablePointer(to: &startup) { extended in
                            extended.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) {
                                CreateProcessW(app, line.baseAddress, nil, nil, true,
                                               DWORD(CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT),
                                               block, directory, $0, &process)
                            }
                        }
                    }
                }
            }
            let launchAtDirectory: (UnsafeMutableRawPointer?) -> Bool = { block in
                if let cwd { return cwd.withCString(encodedAs: UTF16.self) { launch(block, $0) } }
                return launch(block, nil)
            }
            let created = env == nil ? launchAtDirectory(nil) : environment.withUnsafeMutableBytes { launchAtDirectory($0.baseAddress) }
            guard created else { return failed() }
            CloseHandle(process.hThread)
            defer { CloseHandle(process.hProcess) }
            // Close child ends immediately: a parent's write handle would keep ReadFile waiting forever.
            CloseHandle(outWrite); outWrite = nil
            CloseHandle(errWrite); errWrite = nil
            CloseHandle(input); input = nil
            func drain(_ handle: HANDLE) -> Data {
                var result = Data(), buffer = [UInt8](repeating: 0, count: 16384)
                var count: DWORD = 0
                while buffer.withUnsafeMutableBytes({ ReadFile(handle, $0.baseAddress, DWORD($0.count), &count, nil) }), count > 0 {
                    result.append(contentsOf: buffer.prefix(Int(count)))
                }
                return result
            }
            var output = Data(), errors = Data()
            let group = DispatchGroup(), queue = DispatchQueue(label: "slashcommand.proc.windows", attributes: .concurrent)
            let outputHandle = outRead!, errorHandle = errRead!
            group.enter(); queue.async { output = drain(outputHandle); group.leave() }
            group.enter(); queue.async { errors = drain(errorHandle); group.leave() }
            let milliseconds = DWORD(min(Double(DWORD.max - 1), max(0, timeout * 1000)))
            let wait = WaitForSingleObject(process.hProcess, milliseconds)
            let timedOut = wait == WAIT_TIMEOUT
            if wait != WAIT_OBJECT_0 {
                terminateTree(Int32(bitPattern: process.dwProcessId))
                _ = TerminateProcess(process.hProcess, 1)
                _ = WaitForSingleObject(process.hProcess, 1000)
            }
            group.wait()
            var code: DWORD = 0
            let status = GetExitCodeProcess(process.hProcess, &code) ? Int32(bitPattern: code) : -1
            return ProcResult(status: status, out: String(decoding: output, as: UTF8.self),
                              err: String(decoding: errors, as: UTF8.self), timedOut: timedOut)
        }
    }

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
            guard let childHandle = handle(child), let parentHandle = handle(parent) else { return true }
            return skipsChild(childStart: startTime(childHandle), parentStart: startTime(parentHandle), snapshotTime: snapshotTime)
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
