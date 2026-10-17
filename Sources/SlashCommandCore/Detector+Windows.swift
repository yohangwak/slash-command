#if os(Windows)
import Foundation
import WinSDK

extension Detector {
    public static func frontmost(willAskAutomation: @escaping () -> Void = {}) throws -> Target {
        guard let window = GetForegroundWindow() else { throw SlashCommandError(loc("Cannot tell which app is in front.")) }
        var pid: DWORD = 0
        GetWindowThreadProcessId(window, &pid)
        let image = WindowsPaths.normalized(ProcessTable.executablePath(of: Int32(bitPattern: pid)))
        return try target(app: image.split(separator: "/").last.map(String.init) ?? "", frontPID: pid)
    }

    public static func target(app: String) throws -> Target {
        if ["wezterm", "wezterm.exe", "wezterm-gui.exe"].contains(app.lowercased()) {
            return try windowsWezTerm()
        }
        guard ["orca", "orca.exe"].contains(app.lowercased()) else {
            throw SlashCommandError(loc("This is not supported on this operating system yet."))
        }
        let payload = try orcaTerminals()
        let active = try OrcaState.active()
        let handle = try OrcaState.pane(in: payload, active: active).handle
        let table = ProcessTable.snapshot()
        try AgentProcesses.requirePlainOrca(handle: handle, entries: table.entries)
        return try OrcaState.target(in: payload, active: active, processAgent: {
            AgentProcesses.agent(orcaHandle: $0, entries: table.entries, parents: table.parents)
        })
    }

    public static func orcaAgent(handle: String) -> Agent? { AgentProcesses.agent(orcaHandle: handle) }

    public static func orcaTmux(handle: String) throws -> Target? {
        try AgentProcesses.requirePlainOrca(handle: handle, entries: ProcessTable.snapshot().entries)
        return nil
    }
}

extension AgentProcesses {
    static func requirePlainOrca(handle: String, entries: [ProcessTable.Entry]) throws {
        let terminal = entries.filter { $0.environment.contains("ORCA_TERMINAL_HANDLE=\(handle)") }
        guard !terminal.isEmpty else {
            throw SlashCommandError(loc("Slash Command cannot read the processes of this terminal (it may run as administrator), so it does not send anything."))
        }
        if terminal.contains(where: isWindowsNestedTerminal) {
            throw SlashCommandError(loc("This terminal runs tmux or WSL, which Slash Command cannot follow on Windows yet."))
        }
    }

    /// CommandLineToArgvW treats apostrophes literally and handles double quotes/backslashes.
    static func commandTokens(_ line: String) -> [String] {
        guard !line.isEmpty else { return [] }
        var count: Int32 = 0
        guard let argv = line.withCString(encodedAs: UTF16.self, { CommandLineToArgvW($0, &count) }) else { return [] }
        defer { _ = LocalFree(UnsafeMutableRawPointer(argv)) }
        return (0..<Int(count)).compactMap { index in
            argv[index].map { String(decodingCString: $0, as: UTF16.self) }
        }
    }

    static func windowsAgent(forCommandLine commandLine: String) -> Agent? {
        let tokens = commandTokens(commandLine)
        guard let first = tokens.first else { return nil }
        func executableName(_ token: String) -> String {
            var name = WindowsPaths.normalized(token).split(separator: "/").last.map(String.init) ?? ""
            for suffix in [".exe", ".cmd"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
            return name
        }
        switch executableName(first) {
        case "claude": return .claude
        case "codex": return .codex
        case "grok": return .grok
        case "cursor-agent": return .cursor
        case "agy": return .antigravity
        case "opencode": return .opencode
        default: break
        }
        if WindowsPaths.normalized(first).contains("/claude/versions/") { return .claude }
        if ["node", "bun"].contains(executableName(first)), tokens.count > 1 {
            let script = WindowsPaths.normalized(tokens[1])
            if executableName(script) == "opencode" || script.hasSuffix("/opencode/bin/opencode") { return .opencode }
        }
        return nil
    }

    static func isWindowsWSLEntryPoint(_ image: String) -> Bool {
        let path = WindowsPaths.normalized(image)
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        if ["wsl.exe", "wslhost.exe", "wslrelay.exe"].contains(name) { return true }
        if path == "c:/windows/system32/bash.exe" { return true }
        guard path.contains("/windowsapps/"), name.hasSuffix(".exe") else { return false }
        if ["debian.exe", "kali.exe", "alpine.exe", "archlinux.exe"].contains(name) { return true }
        return ["ubuntu", "opensuse", "sles", "fedora", "oraclelinux"].contains { name.hasPrefix($0) }
    }

    static func isWindowsNestedTerminal(_ entry: ProcessTable.Entry) -> Bool {
        let name = WindowsPaths.normalized(entry.executable).split(separator: "/").last.map(String.init) ?? ""
        let tokens = commandTokens(entry.arguments.joined(separator: " "))
        return isWindowsWSLEntryPoint(entry.executable) || ["tmux", "tmux.exe"].contains(name) || tokens.contains {
            isWindowsWSLEntryPoint($0) || ["tmux", "tmux.exe"].contains(WindowsPaths.normalized($0).split(separator: "/").last.map(String.init) ?? "")
        }
    }

    static func agent(orcaHandle handle: String) -> Agent? {
        let table = ProcessTable.snapshot()
        return agent(orcaHandle: handle, entries: table.entries, parents: table.parents)
    }

    static func agent(orcaHandle handle: String, entries: [ProcessTable.Entry], parents: [Int32: Int32]) -> Agent? {
        guard (try? requirePlainOrca(handle: handle, entries: entries)) != nil else { return nil }
        let candidates = entries.compactMap { entry -> (pid: String, agent: Agent)? in
            guard entry.environment.contains("ORCA_TERMINAL_HANDLE=\(handle)"),
                  let kind = agent(forCommandLine: entry.arguments.joined(separator: " ")) else { return nil }
            return (String(entry.pid), kind)
        }
        return outermostAgent(candidates, parents: Dictionary(uniqueKeysWithValues: parents.map { (String($0.key), String($0.value)) }))
    }
}

/// Loads the OS SQLite DLL by absolute system path, opens only an existing DB read-only.
enum WindowsOrcaState {
    typealias Open = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?) -> Int32
    typealias Prepare = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    typealias Step = @convention(c) (OpaquePointer?) -> Int32
    typealias Text = @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?
    static func query(database: String, sql: String) -> ProcResult {
        let failure = ProcResult(status: 1, out: "", err: "", timedOut: false)
        var system = [WCHAR](repeating: 0, count: 32768)
        let length = GetSystemDirectoryW(&system, UInt32(system.count))
        guard length > 0, length < system.count else { return failure }
        let path = String(decoding: system.prefix(Int(length)), as: UTF16.self) + "\\winsqlite3.dll"
        guard let dll = path.withCString(encodedAs: UTF16.self, LoadLibraryW) else { return failure }
        defer { FreeLibrary(dll) }
        guard let o = GetProcAddress(dll, "sqlite3_open_v2"), let c = GetProcAddress(dll, "sqlite3_close"),
              let p = GetProcAddress(dll, "sqlite3_prepare_v2"), let s = GetProcAddress(dll, "sqlite3_step"),
              let t = GetProcAddress(dll, "sqlite3_column_text"), let f = GetProcAddress(dll, "sqlite3_finalize"),
              let b = GetProcAddress(dll, "sqlite3_busy_timeout") else { return failure }
        let open = unsafeBitCast(o, to: Open.self), close = unsafeBitCast(c, to: Step.self)
        let prepare = unsafeBitCast(p, to: Prepare.self), step = unsafeBitCast(s, to: Step.self)
        let text = unsafeBitCast(t, to: Text.self), finalize = unsafeBitCast(f, to: Step.self)
        let busy = unsafeBitCast(b, to: (@convention(c) (OpaquePointer?, Int32) -> Int32).self)
        var db: OpaquePointer?
        let status = database.withCString { open($0, &db, 1, nil) } // SQLITE_OPEN_READONLY
        defer { if db != nil { _ = close(db) } }
        guard status == 0 else { return failure }
        _ = busy(db, 1000)
        var statement: OpaquePointer?
        guard sql.withCString({ prepare(db, $0, -1, &statement, nil) }) == 0 else { return failure }
        defer { _ = finalize(statement) }
        guard step(statement) == 100, let value = text(statement, 0) else { return failure } // SQLITE_ROW
        let result = String(cString: value)
        guard step(statement) == 101 else { return failure } // exactly one workspaceSession document
        return ProcResult(status: 0, out: result, err: "", timedOut: false)
    }
}
#endif
