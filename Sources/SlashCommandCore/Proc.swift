import Foundation

public struct ProcResult: Sendable {
    public let status: Int32
    public let out: String
    public let err: String
    public let timedOut: Bool

    public var ok: Bool { status == 0 && !timedOut }
}

public enum Proc {
    /// Runs a child process and waits for it to finish. On timeout it terminates the child and sets `timedOut`.
    public static func run(_ exe: String,
                           _ args: [String],
                           env: [String: String]? = nil,
                           cwd: String? = nil,
                           timeout: TimeInterval = 10) -> ProcResult {
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

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "slashcommand.proc", attributes: .concurrent)

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
        group.enter()
        queue.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        queue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        var timedOut = false
        if !waitForExit(process, done, seconds: timeout) {
            timedOut = true
            process.terminate()
            // If it ignores SIGTERM, kill it forcibly: the pipes must close for the reads below to finish.
            if !waitForExit(process, done, seconds: 2) {
                #if os(Windows)
                process.terminate()   // TerminateProcess: already forcible on Windows
                #else
                kill(process.processIdentifier, SIGKILL)
                #endif
                _ = waitForExit(process, done, seconds: 1)
            }
        }
        group.wait()

        // Reading `terminationStatus` of a process that is still alive raises an exception.
        return ProcResult(status: process.isRunning ? -1 : process.terminationStatus,
                          out: String(decoding: outData, as: UTF8.self),
                          err: String(decoding: errData, as: UTF8.self),
                          timedOut: timedOut)
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
