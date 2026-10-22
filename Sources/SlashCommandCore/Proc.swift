import Foundation

public struct ProcResult: Sendable {
    public let status: Int32
    public let out: String
    public let err: String
    public let timedOut: Bool

    public var ok: Bool { status == 0 && !timedOut }
}

public enum Proc {
    #if !os(Windows)
    /// Captures only data that is ready to read; a descendant holding the pipe open must not keep the caller waiting for EOF.
    private final class PipeCapture {
        let eof = DispatchSemaphore(value: 0)
        private let handle: FileHandle
        private let lock = NSLock()
        private var data = Data()
        private var closed = false

        init(_ handle: FileHandle) {
            self.handle = handle
            handle.readabilityHandler = { [self] handle in
                lock.lock()
                defer { lock.unlock() }
                guard !closed else { return }
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    eof.signal()
                } else {
                    data.append(chunk)
                }
            }
        }

        func finish() -> Data {
            handle.readabilityHandler = nil
            lock.lock()
            defer { lock.unlock() }
            closed = true
            try? handle.close()
            return data
        }
    }
    #endif

    /// Runs a child process and waits for it to finish. On timeout it terminates the child and sets `timedOut`.
    public static func run(_ exe: String,
                           _ args: [String],
                           env: [String: String]? = nil,
                           cwd: String? = nil,
                           timeout: TimeInterval = 10) -> ProcResult {
        #if os(Windows)
        return runWindows(exe, args, env: env, cwd: cwd, timeout: timeout)
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        if let env { process.environment = env }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Completion is learned through `terminationHandler`. `waitUntilExit()` waits by spinning that thread's run loop, and on the worker threads of a long-running app
        // it sometimes does not wake up even after the child has finished (2026-10-12 on a test Mac: `wezterm cli` finished its work but
        // we waited until the 5 s limit and ended with "could not read"; a sample showed a thread stuck in `waitUntilExit` with no child left).
        // Since the run loop is not spun, even a single call drops from about 65 ms to the time the child actually took.
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do {
            try process.run()
        } catch {
            return ProcResult(status: -1, out: "", err: "\(exe): \(error.localizedDescription)", timedOut: false)
        }

        // Drain both streams at the same time so the child does not stall on a full pipe buffer.
        let out = PipeCapture(outPipe.fileHandleForReading)
        let err = PipeCapture(errPipe.fileHandleForReading)

        var timedOut = false
        if !waitForExit(process, done, seconds: timeout) {
            timedOut = true
            #if os(Windows)
            // A batch shim runs the real program as a child of cmd.exe; that child keeps our pipes open,
            // so end the whole tree, not just the process we started.
            terminateTree(process.processIdentifier)
            #else
            process.terminate()
            #endif
            // If it ignores SIGTERM, kill it forcibly before collecting the remaining output.
            if !waitForExit(process, done, seconds: 2) {
                #if os(Windows)
                process.terminate()   // TerminateProcess: already forcible on Windows
                #else
                kill(process.processIdentifier, SIGKILL)
                #endif
                _ = waitForExit(process, done, seconds: 1)
            }
        }
        // Both streams share one deadline, so inherited pipes add at most one second after the child exits.
        let drainDeadline = DispatchTime.now() + 1
        _ = out.eof.wait(timeout: drainDeadline)
        _ = err.eof.wait(timeout: drainDeadline)
        let outData = out.finish()
        let errData = err.finish()

        // Reading `terminationStatus` of a process that is still alive raises an exception.
        return ProcResult(status: process.isRunning ? -1 : process.terminationStatus,
                          out: String(decoding: outData, as: UTF8.self),
                          err: String(decoding: errData, as: UTF8.self),
                          timedOut: timedOut)
        #endif
    }

    /// Waits up to `seconds` for the signal that it finished. In case the signal is missed it does not hang: it waits in short slices and also checks `isRunning`.
    private static func waitForExit(_ process: Process, _ done: DispatchSemaphore, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let slice = min(0.05, max(0, deadline.timeIntervalSinceNow))
            if done.wait(timeout: .now() + slice) == .success { return true }
            if !process.isRunning { return true }
            if Date() >= deadline { return false }
        }
    }

    /// Every descendant of `root` in a pid → parent pid table, deepest first. `startedBefore` drops a "child" that
    /// existed before its parent did (its parent pid was reused), so an unrelated process is never included.
    static func descendants(of root: Int32, parents: [Int32: Int32], startedBefore: (Int32, Int32) -> Bool = { _, _ in false }) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for (pid, parent) in parents where pid != parent && !startedBefore(pid, parent) { children[parent, default: []].append(pid) }
        var order: [Int32] = [], seen: Set<Int32> = [root]
        func walk(_ pid: Int32) {
            for child in children[pid, default: []].sorted() where seen.insert(child).inserted {
                walk(child); order.append(child)
            }
        }
        walk(root)
        return order
    }

    /// Whether a tree cleanup must leave a "child" alone: its start time is unknown, it started before its claimed
    /// parent (the parent's pid was reused), or it started after the snapshot (its own pid was reused before it was opened).
    static func skipsChild(childStart: UInt64?, parentStart: UInt64?, snapshotTime: UInt64) -> Bool {
        guard let childStart, let parentStart else { return true }
        return childStart < parentStart || childStart > snapshotTime
    }

    static func isBatchFile(_ path: String) -> Bool {
        ["cmd", "bat"].contains((path as NSString).pathExtension.lowercased())
    }

    /// The `cmd.exe` arguments that run a batch file, or nil when `exe` is not a batch file or an argument contains
    /// anything cmd.exe could treat as syntax (spaces, quotes, `&|<>^%!()`, line breaks). See "BatBadBut".
    /// Process quotes only the path (it may contain spaces); `cmd /c "<path>" args` keeps those quotes because the
    /// line has exactly two quote characters around an existing file and no special characters.
    static func batchArguments(_ exe: String, _ args: [String]) -> [String]? {
        guard isBatchFile(exe), !exe.contains("\""), !exe.contains("%"), !exe.contains("!") else { return nil }
        let unsafe = CharacterSet(charactersIn: "&|<>^()@,;")
        guard exe.unicodeScalars.allSatisfy({ !unsafe.contains($0) }) else { return nil }
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.=:/\\")
        guard args.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(plain.contains) }) else { return nil }
        return ["/d", "/c", exe] + args
    }

    /// MSVCRT argument encoding: double backslashes only before a quote or a closing quote.
    /// Works on Unicode scalars: a combining mark after a space or a quote makes one Character, which compares unequal to " " or "\"".
    static func windowsQuote(_ argument: String) -> String {
        guard argument.isEmpty || argument.unicodeScalars.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) else { return argument }
        var result = "\"", slashes = 0
        for scalar in argument.unicodeScalars {
            if scalar == "\\" { slashes += 1; continue }
            if scalar == "\"" {
                result += String(repeating: "\\", count: slashes * 2 + 1) + "\""
            } else {
                result += String(repeating: "\\", count: slashes) + String(scalar)
            }
            slashes = 0
        }
        return result + String(repeating: "\\", count: slashes * 2) + "\""
    }

    static func windowsEnvironment(_ environment: [String: String]) -> [UInt16] {
        let keys = environment.keys.sorted {
            let a = $0.uppercased(), b = $1.uppercased()
            return a == b ? $0 < $1 : a < b
        }
        let entries = keys.map { "\($0)=\(environment[$0]!)" }
        return Array((entries.joined(separator: "\0") + "\0\0").utf16)
    }

    /// GUI apps do not inherit the login shell's PATH, so look in the usual install locations directly.
    public static func locate(_ name: String, extra: [String] = []) -> String? {
        #if os(Windows)
        var dirs = extra
        // Environment keys are case-insensitive on Windows; Foundation's dictionary is not.
        let environment = ProcessInfo.processInfo.environment
        if let path = environment.first(where: { $0.key.uppercased() == "PATH" })?.value {
            // An entry may be quoted ("C:\Program Files\x"), as cmd.exe accepts.
            dirs.append(contentsOf: path.split(separator: ";").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) })
        }
        // Like cmd.exe: a bare name is tried only with the PATHEXT extensions, in that order. npm and Electron apps
        // put an extensionless shell script next to the .cmd shim, and that script cannot be started directly.
        let pathext = environment.first(where: { $0.key.uppercased() == "PATHEXT" })?.value ?? ".COM;.EXE;.BAT;.CMD"
        let extensions = pathext.split(separator: ";").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }.filter { !$0.isEmpty }
        let names = extensions.contains((name as NSString).pathExtension.lowercased())
            ? [name] : extensions.map { "\(name).\($0)" }
        for dir in dirs {
            for name in names {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name).path
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue {
                    return candidate
                }
            }
        }
        return nil
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["/usr/local/bin", "/opt/homebrew/bin", "\(home)/.local/bin", "/usr/bin", "/bin"] + extra
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        for dir in dirs {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
        #endif
    }
}
