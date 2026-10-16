import Foundation
#if os(Windows)
import WinSDK
#endif

/// Windows 20240203 CLI has no pane PID and tty_name is null. Never attribute all
/// descendants of a GUI to one pane: each tab has its own shell under that GUI.
enum WindowsWezTerm {
    struct Pane: Equatable {
        let id: String
        let title: String
    }

    static func pane(in data: Data, id: Int) -> Pane? {
        guard id >= 0, let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let matches = rows.filter { integer($0["pane_id"]) == id }
        guard matches.count == 1, let row = matches.first else { return nil }
        return Pane(id: String(id), title: row["title"] as? String ?? "")
    }

    private static func integer(_ value: Any?) -> Int? {
        // JSON booleans bridge to NSNumber, too; they are not pane IDs.
        guard let number = value as? NSNumber, !["c", "B"].contains(String(cString: number.objCType)),
              number.doubleValue >= 0, number.doubleValue < Double(Int.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }

    static func focusedPane(clients: Data, panes: Data, frontPID: Int32?) -> Pane? {
        guard let rows = try? JSONSerialization.jsonObject(with: clients) as? [[String: Any]] else { return nil }
        let matches = frontPID.map { pid in rows.filter { integer($0["pid"]) == Int(pid) } } ?? rows
        guard matches.count == 1, let client = matches.first,
              let focused = integer(client["focused_pane_id"]) else { return nil }
        return pane(in: panes, id: focused)
    }

    static func focusedPaneID(clients: Data, frontPID: Int32) -> String? {
        guard let rows = try? JSONSerialization.jsonObject(with: clients) as? [[String: Any]] else { return nil }
        let matches = rows.filter { integer($0["pid"]) == Int(frontPID) }
        guard matches.count == 1, let client = matches.first,
              let pane = integer(client["focused_pane_id"]) else { return nil }
        return String(pane)
    }

    /// Known GUI PID is authoritative, including when its socket is missing.
    /// A caller must fail on nil rather than fall back to WezTerm's default GUI.
    static func socket(ofGUI pid: Int32, home: URL, exists: (String) -> Bool = WindowsWezTerm.pathExists) -> String? {
        guard pid > 0 else { return nil }
        let path = home.appendingPathComponent(".local/share/wezterm/gui-sock-\(pid)").path
        return exists(path) ? path : nil
    }

    /// Whether something exists at `path` without following it. On Windows an AF_UNIX socket file is a reparse point,
    /// and Foundation's `fileExists` follows it and answers false, so WezTerm's `gui-sock-<pid>` looked missing.
    static func pathExists(_ path: String) -> Bool {
        #if os(Windows)
        return path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) } != INVALID_FILE_ATTRIBUTES
        #else
        return FileManager.default.fileExists(atPath: path)
        #endif
    }

    static func agent(screen: [String]?) -> Agent? {
        screen.flatMap { Detector.agent(onScreen: $0) }
    }

    /// `gui-sock-<pid>` → pid. nil for any other socket name.
    static func guiPID(socket: String) -> Int32? {
        let name = socket.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        guard name.hasPrefix("gui-sock-"), let pid = Int32(name.dropFirst("gui-sock-".count)), pid > 0, name == "gui-sock-\(pid)" else { return nil }
        return pid
    }
}

#if os(Windows)
import WinSDK

extension WindowsWezTerm {
    enum Locality: Equatable { case local, mixed, noAgentProcess }

    /// Windows WezTerm does not say which process runs in which pane, so the agent comes from the screen.
    /// Defaults protection reads the Windows user's defaults file, which is that agent's own only when the agent runs on Windows:
    /// accept it only when nothing under the GUI runs WSL, tmux or a remote shell, and an agent process of that kind is under the GUI.
    static func locality(of agent: Agent, gui: Int32, entries: [ProcessTable.Entry]) -> Locality {
        var children: [Int32: [ProcessTable.Entry]] = [:]
        for entry in entries { children[entry.parent, default: []].append(entry) }
        var queue = children[gui] ?? [], seen: Set<Int32> = [gui], found = false
        while let entry = queue.popLast() {
            guard seen.insert(entry.pid).inserted else { continue }
            let name = WindowsPaths.normalized(entry.executable).split(separator: "/").last.map(String.init) ?? ""
            // A process that cannot be read could be any of these.
            if name.isEmpty || AgentProcesses.isWindowsNestedTerminal(entry) || remoteShells.contains(name) { return .mixed }
            if AgentProcesses.agent(forCommandLine: entry.arguments.joined(separator: " ")) == agent { found = true }
            queue += children[entry.pid] ?? []
        }
        return found ? .local : .noAgentProcess
    }

    /// Programs whose sessions keep their defaults on another machine or in a container.
    static let remoteShells: Set<String> = ["ssh.exe", "plink.exe", "mosh-client.exe", "docker.exe", "podman.exe", "kubectl.exe"]
}

extension Detector {
    public static var weztermExtraDirectories: [String] { [#"C:\Program Files\WezTerm"#] }

    static func windowsWezTerm(frontPID: Int32? = nil) throws -> Target {
        guard let executable = Proc.locate("wezterm", extra: weztermExtraDirectories) else {
            throw SlashCommandError(loc("The wezterm command was not found."))
        }
        let socket = try windowsWezTermSocket(frontPID: frontPID)
        let pane = try windowsWezTermPane(executable: executable, socket: socket, frontPID: frontPID)
        let io = WindowsWezTermIO(base: WezTermIO(wezterm: executable, socket: socket, pane: pane.id), frontPID: frontPID)
        guard let agent = WindowsWezTerm.agent(screen: io.base.screen()) else {
            throw SlashCommandError(loc("The frontmost %@ terminal (%@) is not a supported agent session (Claude Code · Codex · Grok · Cursor · Antigravity · OpenCode).", "WezTerm", pane.title))
        }
        try requireWindowsLocal(agent, socket: socket, label: pane.title)
        var target = Target(host: .wezterm(socket: socket, pane: pane.id), agent: agent, label: pane.title)
        target.windowsFrontPID = frontPID
        return target
    }

    static func windowsWezTermSocket(frontPID: Int32?) throws -> String {
        let home = URL(fileURLWithPath: try WindowsPaths.requiredEnvironment("USERPROFILE"))
        if let frontPID {
            if let pinned = WindowsWezTerm.socket(ofGUI: frontPID, home: home) { return pinned }
        } else {
            if let socket = ProcessInfo.processInfo.environment.first(where: { $0.key.uppercased() == "WEZTERM_UNIX_SOCKET" })?.value, !socket.isEmpty { return socket }
            let folder = home.appendingPathComponent(".local/share/wezterm")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let sockets = names.compactMap { name -> String? in
                guard name.hasPrefix("gui-sock-"), let pid = Int32(name.dropFirst("gui-sock-".count)),
                      name == "gui-sock-\(pid)",
                      WindowsAppModel.app(image: ProcessTable.executablePath(of: pid)) == "wezterm" else { return nil }
                return WindowsWezTerm.socket(ofGUI: pid, home: home)
            }
            if sockets.count == 1 { return sockets[0] }
        }
        throw SlashCommandError(loc("Could not read the frontmost %@ terminal: %@", "WezTerm", "GUI socket"))
    }

    public static func windowsWezTermExplicit(pane id: String, agent: Agent, socket: String?) throws -> Target {
        guard let executable = Proc.locate("wezterm", extra: weztermExtraDirectories) else {
            throw SlashCommandError(loc("The wezterm command was not found."))
        }
        let pinned = try socket ?? windowsWezTermSocket(frontPID: nil)
        let panes = Proc.run(executable, ["cli", "--no-auto-start", "list", "--format", "json"], env: WezTermFront.environment(socket: pinned), timeout: 5)
        guard panes.ok, let number = Int(id), String(number) == id,
              let pane = WindowsWezTerm.pane(in: Data(panes.out.utf8), id: number) else {
            throw SlashCommandError(loc("Could not read the frontmost %@ terminal: %@", "WezTerm", "cli list"))
        }
        try requireWindowsLocal(agent, socket: pinned, label: pane.title)
        return Target(host: .wezterm(socket: pinned, pane: pane.id), agent: agent, label: pane.title)
    }

    /// See `WindowsWezTerm.locality`. The processes are those of the GUI that owns the socket.
    static func requireWindowsLocal(_ agent: Agent, socket: String, label: String) throws {
        let locality = WindowsWezTerm.guiPID(socket: socket).map { WindowsWezTerm.locality(of: agent, gui: $0, entries: ProcessTable.descendants(of: $0)) } ?? .mixed
        switch locality {
        case .local: return
        case .mixed:
            throw SlashCommandError(loc("Not switched: this WezTerm window also runs WSL, tmux or a remote shell, and WezTerm does not say which pane runs which program, so the agent's own defaults cannot be protected."))
        case .noAgentProcess:
            throw SlashCommandError(loc("The frontmost %@ terminal (%@) is not a supported agent session (Claude Code · Codex · Grok · Cursor · Antigravity · OpenCode).", "WezTerm", label))
        }
    }

    static func windowsWezTermPane(executable: String, socket: String?, frontPID: Int32?) throws -> WindowsWezTerm.Pane {
        let environment = WezTermFront.environment(socket: socket)
        let clients = Proc.run(executable, ["cli", "--no-auto-start", "list-clients", "--format", "json"], env: environment, timeout: 5)
        let panes = Proc.run(executable, ["cli", "--no-auto-start", "list", "--format", "json"], env: environment, timeout: 5)
        guard clients.ok, panes.ok, let pane = WindowsWezTerm.focusedPane(clients: Data(clients.out.utf8), panes: Data(panes.out.utf8), frontPID: frontPID) else {
            // CLI error text can contain paths or terminal data. Keep diagnostics to the operation.
            throw SlashCommandError(loc("Could not read the frontmost %@ terminal: %@", "WezTerm", "cli list / list-clients"))
        }
        return pane
    }
}

/// Reads stay pinned to one pane. Writes additionally verify the GUI client's focus.
final class WindowsWezTermIO: TerminalIO {
    let base: WezTermIO
    let frontPID: Int32?
    private(set) var lastFailure: String?

    private let foregroundPID: () -> Int32?
    private let readClients: (WezTermIO) -> ProcResult

    init(base: WezTermIO, frontPID: Int32?,
         foregroundPID: @escaping () -> Int32? = WindowsWezTermIO.currentForegroundPID,
         readClients: @escaping (WezTermIO) -> ProcResult = WindowsWezTermIO.clients) {
        self.base = base; self.frontPID = frontPID
        self.foregroundPID = foregroundPID; self.readClients = readClients
    }

    private static func currentForegroundPID() -> Int32? {
        guard let window = GetForegroundWindow() else { return nil }
        var pid: DWORD = 0
        GetWindowThreadProcessId(window, &pid)
        return Int32(bitPattern: pid)
    }
    private static func clients(_ base: WezTermIO) -> ProcResult {
        Proc.run(base.wezterm, ["cli", "--no-auto-start", "list-clients", "--format", "json"],
                 env: WezTermFront.environment(socket: base.socket), timeout: 5)
    }

    private func requireTarget(writing: Bool) throws {
        if let lastFailure { throw SlashCommandError(lastFailure) }
        guard let frontPID else { return }
        var valid = foregroundPID() == frontPID
        if valid && writing {
            let clients = readClients(base)
            valid = clients.ok && WindowsWezTerm.focusedPaneID(clients: Data(clients.out.utf8), frontPID: frontPID) == base.pane
            // Focus may have moved while the CLI was running.
            valid = valid && foregroundPID() == frontPID
        }
        guard valid else {
            let reason = loc("The foreground app changed. Press the shortcut again.")
            lastFailure = reason
            throw SlashCommandError(reason)
        }
        lastFailure = nil
    }
    func type(_ text: String) throws { try requireTarget(writing: true); try base.type(text) }
    func press(_ key: Key) throws { try requireTarget(writing: true); try base.press(key) }
    func screen() -> [String]? {
        do { try requireTarget(writing: false) } catch { return nil }
        return base.screen()
    }
}
#endif
