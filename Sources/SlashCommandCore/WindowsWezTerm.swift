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
}

#if os(Windows)
import WinSDK

extension Detector {
    public static var weztermExtraDirectories: [String] { [#"C:\Program Files\WezTerm"#] }

    static func windowsWezTerm(frontPID: Int32? = nil) throws -> Target {
        guard let executable = Proc.locate("wezterm", extra: weztermExtraDirectories) else {
            throw SlashCommandError(loc("The wezterm command was not found."))
        }
        let socket = try windowsWezTermSocket(frontPID: frontPID)
        let pane = try windowsWezTermPane(executable: executable, socket: socket, frontPID: frontPID)
        let io = WindowsWezTermIO(base: WezTermIO(wezterm: executable, socket: socket, pane: pane.id), frontPID: frontPID)
        guard let agent = WindowsWezTerm.agent(screen: io.screen()) else {
            throw SlashCommandError(loc("The frontmost %@ terminal (%@) is not a supported agent session (Claude Code · Codex · Grok · Cursor · Antigravity · OpenCode).", "WezTerm", pane.title))
        }
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
        return Target(host: .wezterm(socket: pinned, pane: pane.id), agent: agent, label: pane.title)
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

/// Hotkeys recheck foreground PID and focused pane before each read/write. Explicit
/// CLI pane targets have no frontPID and deliberately remain addressable offscreen.
struct WindowsWezTermIO: TerminalIO {
    let base: WezTermIO
    let frontPID: Int32?

    private func requireTarget() throws {
        guard let frontPID else { return }
        var pid: DWORD = 0
        guard let window = GetForegroundWindow() else { throw SlashCommandError(loc("Cannot tell which app is in front.")) }
        GetWindowThreadProcessId(window, &pid)
        guard Int32(bitPattern: pid) == frontPID,
              WindowsAppModel.app(image: ProcessTable.executablePath(of: frontPID)) == "wezterm",
              let pane = try? Detector.windowsWezTermPane(executable: base.wezterm, socket: base.socket, frontPID: frontPID),
              pane.id == base.pane else {
            throw SlashCommandError(loc("The foreground app changed. Press the shortcut again."))
        }
    }
    func type(_ text: String) throws { try requireTarget(); try base.type(text) }
    func press(_ key: Key) throws { try requireTarget(); try base.press(key) }
    func screen() -> [String]? { guard (try? requireTarget()) != nil else { return nil }; return base.screen() }
}
#endif
