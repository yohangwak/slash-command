#if os(macOS)
import Darwin
#endif
import Foundation

// Finding the front session: WezTerm and kitty, and tmux inside them.
//
// Measured 2026-10-12 on a test Mac (opened WezTerm, kitty and tmux on screen, then drove them over ssh):
// - WezTerm: `wezterm cli list-clients` gives the GUI's `focused_pane_id`, and `cli list` gives that pane's `tty_name`.
// - kitty: the remote-control socket is found from the Unix sockets that kitty process has open (`lsof`; the environment of processes inside a window could not be read).
//   `kitty @ ls` gives each OS window -> tab -> window with `is_focused`, and the pid of the foreground process in that window.
//   RED: the `env` in `ls` holds the window's entire environment (secrets may be mixed in) — never read it, never keep it.
// - WezTerm's `focused_pane_id` follows immediately when you switch tabs while WezTerm is frontmost. A change made with `cli activate-pane` while it was in the background
//   was not reflected until it came to the front — the hotkey only arrives when that app is frontmost, so the value at that moment is current.
// - tmux: it lives INSIDE the terminal app. Take the pid of the `tmux` client attached to that terminal's tty and find that client in `list-clients`;
//   `#{pane_id}` and `#{pane_tty}` are then the pane THAT CLIENT is looking at (it kept following after the panes were split).
// - RED: for terminals that give no tty (Ghostty etc.) we did not add a path that decides by tmux's focus flag (`focused` in `client_flags`).
//   The flag of a client attached WITH `focus-events on` follows app and tab switches (measured), but a client attached before it was turned on
//   stays `focused` even after going to the background (measured, tmux 3.7c) — trusting that flag alone could write into a pane in a background tab.

/// Processes attached to a terminal (tty).
enum TTYProcesses {
    #if os(macOS)
    /// The device number of `/dev/ttys004`. Same value as the process's `e_tdev`.
    static func device(ofTTY path: String) -> UInt32? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFCHR else { return nil }
        return UInt32(bitPattern: info.st_rdev)
    }

    static func isTmuxClient(_ entry: ProcessTable.Entry) -> Bool {
        guard let first = entry.arguments.first else { return false }
        return (first.split(separator: "/").last.map(String.init) ?? "") == "tmux"
    }

    #endif
    /// Whether the executable path is tmux (the server has no terminal, so it is not in `ProcessTable`'s list — judge by path).
    static func isTmux(executable path: String) -> Bool {
        (path.split(separator: "/").last.map(String.init) ?? "") == "tmux"
    }

    #if os(macOS)
    /// The agent of that terminal (agents launched by an agent are not counted). nil if they do not converge on one kind.
    static func agent(in entries: [ProcessTable.Entry], parents: [Int32: Int32]) -> Agent? {
        let candidates = entries.compactMap { entry -> (pid: String, agent: Agent)? in
            AgentProcesses.agent(forCommandLine: entry.arguments.joined(separator: " ")).map { (String(entry.pid), $0) }
        }
        let table = Dictionary(uniqueKeysWithValues: parents.map { (String($0.key), String($0.value)) })
        return AgentProcesses.outermostAgent(candidates, parents: table)
    }
    #endif

}

public enum WezTermFront {
    public struct Pane: Equatable, Sendable {
        public let id: String
        public let tty: String
        public let title: String
    }

    /// The focused pane from the JSON of `cli list-clients` and `cli list`. `frontPID` is the pid of the frontmost WezTerm GUI — only that GUI's clients are considered.
    /// When several GUIs share one mux there are several clients, and the one that "received characters most recently" is not necessarily frontmost (`idle_time` counts input only — PR #25 review).
    /// When `frontPID` is unknown (a test that asks while the app is not frontmost), answers only if there is exactly one client.
    static func focusedPane(clients: Data, panes: Data, frontPID: Int32?) -> Pane? {
        guard let clientList = try? JSONSerialization.jsonObject(with: clients) as? [[String: Any]],
              let paneList = try? JSONSerialization.jsonObject(with: panes) as? [[String: Any]] else { return nil }
        let client: [String: Any]?
        if let frontPID {
            client = clientList.first { ($0["pid"] as? Int).map(Int32.init) == frontPID }
        } else {
            client = clientList.count == 1 ? clientList.first : nil
        }
        guard let focused = client?["focused_pane_id"] as? Int,
              let pane = paneList.first(where: { $0["pane_id"] as? Int == focused }),
              let tty = pane["tty_name"] as? String, !tty.isEmpty else { return nil }
        return Pane(id: String(focused), tty: tty, title: pane["title"] as? String ?? "")
    }

    /// That GUI's mux socket (`~/.local/share/wezterm/gui-sock-<pid>`). Left alone, `wezterm cli` picks "which" GUI to attach to by itself —
    /// if more than one GUI is running, point `WEZTERM_UNIX_SOCKET` at the frontmost one's socket. nil if the file is missing (then `wezterm cli` behaves by default).
    static func socket(ofGUI pid: Int32?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard let pid else { return nil }
        let path = home.appendingPathComponent(".local/share/wezterm/gui-sock-\(pid)").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func environment(socket: String?) -> [String: String]? {
        guard let socket else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["WEZTERM_UNIX_SOCKET"] = socket
        return environment
    }
}

public enum KittyFront {
    public struct Window: Equatable, Sendable {
        public let id: String
        public let title: String
        /// The shell in that window and the processes in its foreground.
        public let pids: [Int32]
    }

    /// The Unix sockets that kitty process has "actually opened" (entries with a path in the output of `lsof -a -p <pid> -U -Fn`).
    /// We do not guess by reading the config — the socket address can be anywhere: `--listen-on`, a file given with `--config`, or an `include`d file,
    /// and kitty expands environment variables, `~`, relative paths and `{kitty_pid}` when it opens it (PR #25 review). The environment variable of a process inside a window (`KITTY_LISTEN_ON`) cannot be read on macOS
    /// (measured 2026-10-12: kitty starts the shell through `login`, which hides the environment of that shell and its children).
    static func boundSockets(lsofOutput: String) -> [String] {
        var found: [String] = []
        for line in lsofOutput.split(separator: "\n") where line.hasPrefix("n/") {
            let socket = "unix:" + line.dropFirst()
            if !found.contains(socket) { found.append(socket) }
        }
        return found
    }

    #if os(macOS)
    /// The pids of the main kitty processes (the windowless helper `kitty +runpy …` is excluded).
    static func instances() -> [Int32] {
        ProcessTable.allPIDs().filter { pid in
            guard ProcessTable.executablePath(of: pid).hasSuffix("/Contents/MacOS/kitty"),
                  let arguments = ProcessTable.commandLine(of: pid)?.arguments else { return false }
            return arguments.count < 2 || !arguments[1].hasPrefix("+")
        }
    }

    static func sockets(of pids: [Int32]) -> [String] {
        var found: [String] = []
        for pid in pids {
            let listed = Proc.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-U", "-Fn"], timeout: 5)
            for socket in boundSockets(lsofOutput: listed.out) where !found.contains(socket) { found.append(socket) }
        }
        return found
    }

    #endif
    /// The focused OS window -> tab -> window from the JSON of `kitty @ ls`. If there is only one OS window, it is that window even when kitty is not the frontmost app (even with no focus flag).
    static func focusedWindow(ls: Data) -> Window? {
        guard let osWindows = try? JSONSerialization.jsonObject(with: ls) as? [[String: Any]] else { return nil }
        let focused = osWindows.filter { $0["is_focused"] as? Bool == true }
        guard let osWindow = focused.count == 1 ? focused.first : (osWindows.count == 1 ? osWindows.first : nil) else { return nil }
        func pick(_ items: [[String: Any]]) -> [String: Any]? {
            items.first { $0["is_focused"] as? Bool == true } ?? items.first { $0["is_active"] as? Bool == true }
        }
        guard let tab = pick(osWindow["tabs"] as? [[String: Any]] ?? []),
              let window = pick(tab["windows"] as? [[String: Any]] ?? []),
              let id = window["id"] as? Int else { return nil }
        var pids: [Int32] = []
        if let pid = window["pid"] as? Int { pids.append(Int32(pid)) }
        for process in window["foreground_processes"] as? [[String: Any]] ?? [] {
            if let pid = process["pid"] as? Int, !pids.contains(Int32(pid)) { pids.append(Int32(pid)) }
        }
        return Window(id: String(id), title: window["title"] as? String ?? "", pids: pids)
    }
}

public enum TmuxFront {
    public struct Client: Equatable, Sendable {
        public let pid: Int32
        public let pane: String
        public let paneTTY: String
        /// `session:window.pane`
        public let name: String
    }

    static let format = "#{client_pid}\t#{pane_id}\t#{pane_tty}\t#{session_name}:#{window_index}.#{pane_index}"

    static func clients(listOutput: String) -> [Client] {
        listOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, let pid = Int32(fields[0]), fields[1].hasPrefix("%") else { return nil }
            return Client(pid: pid, pane: fields[1], paneTTY: fields[2], name: fields[3])
        }
    }

    /// `-L name` and `-S path` on the client command line (also when written together like `-Lname`). nil if absent (default socket).
    static func socket(clientArguments arguments: [String]) -> String? {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            for flag in ["-L", "-S"] where argument.hasPrefix(flag) {
                if argument.count > 2 { return String(argument.dropFirst(2)) }
                return index + 1 < arguments.count ? arguments[index + 1] : nil
            }
            // After the options end and the command (`new`, `attach` …) starts, a later `-L` does not belong to tmux.
            if !argument.hasPrefix("-") { break }
            index += ["-c", "-f", "-T"].contains(argument) ? 2 : 1
        }
        return nil
    }

    static func arguments(socket: String?) -> [String] {
        guard let socket else { return [] }
        return [socket.contains("/") ? "-S" : "-L", socket]
    }

    private static func run(_ tmux: String, socket: String?, _ arguments: [String]) -> ProcResult {
        Proc.run(tmux, self.arguments(socket: socket) + arguments, timeout: 5)
    }

    #if os(macOS)
    /// The agent in the pane the tmux client process is looking at.
    static func target(client: ProcessTable.Entry, table: (entries: [ProcessTable.Entry], parents: [Int32: Int32]), outer: String) throws -> Target {
        guard let tmux = Proc.locate("tmux") else { throw SlashCommandError(loc("The tmux command was not found.")) }
        let socket = self.socket(clientArguments: client.arguments)
        let listed = run(tmux, socket: socket, ["list-clients", "-F", format])
        guard listed.ok, let found = clients(listOutput: listed.out).first(where: { $0.pid == client.pid }) else {
            throw SlashCommandError(loc("Could not read the frontmost %@ terminal: %@", "tmux", listed.err.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return try target(found, socket: socket, table: table, outer: outer)
    }

    static func target(_ client: Client, socket: String?, table: (entries: [ProcessTable.Entry], parents: [Int32: Int32]), outer: String) throws -> Target {
        let label = "\(client.name) · \(outer)"
        guard let device = TTYProcesses.device(ofTTY: client.paneTTY),
              let agent = TTYProcesses.agent(in: table.entries.filter { $0.terminalDevice == device }, parents: table.parents) else {
            throw SlashCommandError(loc("The frontmost %@ terminal (%@) is not a supported agent session (Claude Code · Codex · Grok · Cursor · Antigravity · OpenCode).", "tmux", label))
        }
        return Target(host: .tmux(socket: socket, pane: client.pane), agent: agent, label: label)
    }
    #endif

}

extension Detector {
    public static let weztermBundleID = "com.github.wez.wezterm"
    public static let kittyBundleID = "net.kovidgoyal.kitty"

    #if os(macOS)
    /// Finds the agent from "the processes of that session" the terminal app reported. If tmux is running there, goes into the pane that client is looking at.
    static func session(host: TerminalHost, appName: String, label: String,
                        table: (entries: [ProcessTable.Entry], parents: [Int32: Int32]), device: UInt32) throws -> Target {
        let attached = table.entries.filter { $0.terminalDevice == device }
        // Goes into tmux only when the tmux client is the terminal's "foreground job". A client stopped with `suspend-client` or Ctrl-Z
        // stays on that tty but the screen shows a shell — the tmux pane behind it is an invisible session (PR #25 review).
        if let client = attached.first(where: { TTYProcesses.isTmuxClient($0) && $0.isForeground }) {
            return try TmuxFront.target(client: client, table: table, outer: appName)
        }
        guard let agent = TTYProcesses.agent(in: attached, parents: table.parents) else {
            throw SlashCommandError(loc("The frontmost %@ terminal (%@) is not a supported agent session (Claude Code · Codex · Grok · Cursor · Antigravity · OpenCode).", appName, label))
        }
        return Target(host: host, agent: agent, label: label)
    }

    /// `frontPID` is the pid of the frontmost WezTerm GUI.
    public static func wezterm(frontPID: Int32? = nil) throws -> Target {
        guard let wezterm = Proc.locate("wezterm", extra: ["/Applications/WezTerm.app/Contents/MacOS"]) else {
            throw SlashCommandError(loc("The wezterm command was not found."))
        }
        let socket = WezTermFront.socket(ofGUI: frontPID)
        let environment = WezTermFront.environment(socket: socket)
        let clients = Proc.run(wezterm, ["cli", "list-clients", "--format", "json"], env: environment, timeout: 5)
        let panes = Proc.run(wezterm, ["cli", "list", "--format", "json"], env: environment, timeout: 5)
        guard clients.ok, panes.ok,
              let pane = WezTermFront.focusedPane(clients: Data(clients.out.utf8), panes: Data(panes.out.utf8), frontPID: frontPID),
              let device = TTYProcesses.device(ofTTY: pane.tty) else {
            let detail = (clients.ok ? panes.err : clients.err).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SlashCommandError(loc("Could not read the frontmost %@ terminal: %@", "WezTerm", String(detail.suffix(160))))
        }
        return try session(host: .wezterm(socket: socket, pane: pane.id), appName: "WezTerm", label: pane.title, table: ProcessTable.snapshot(), device: device)
    }

    /// `frontPID` is the pid of the frontmost kitty (picks that kitty's socket when more than one kitty is running).
    public static func kitty(frontPID: Int32? = nil) throws -> Target {
        guard let kitty = Proc.locate("kitty", extra: ["/Applications/kitty.app/Contents/MacOS"]) else {
            throw SlashCommandError(loc("The kitty command was not found."))
        }
        let table = ProcessTable.snapshot()
        // If the frontmost kitty is known, only its socket is consulted — so when a kitty started without remote control is frontmost, we do not end up in another kitty's window.
        let sockets = KittyFront.sockets(of: frontPID.map { [$0] } ?? KittyFront.instances())
        guard !sockets.isEmpty else {
            throw SlashCommandError(loc("kitty remote control is off. Add `allow_remote_control socket-only` and `listen_on unix:/tmp/kitty` to kitty.conf, then restart kitty."))
        }
        var found: [(socket: String, window: KittyFront.Window)] = []
        for socket in sockets {
            let listed = Proc.run(kitty, ["@", "--to", socket, "ls"], timeout: 5)
            if listed.ok, let window = KittyFront.focusedWindow(ls: Data(listed.out.utf8)) { found.append((socket, window)) }
        }
        guard found.count == 1, let (socket, window) = found.first else {
            throw SlashCommandError(loc("Could not read the frontmost %@ terminal: %@", "kitty", found.isEmpty ? "kitty @ ls" : "\(found.count) kitty"))
        }
        // The window's tty: the terminal its processes are attached to.
        guard let device = table.entries.first(where: { window.pids.contains($0.pid) })?.terminalDevice else {
            throw SlashCommandError(loc("The frontmost %@ terminal (%@) is not a supported agent session (Claude Code · Codex · Grok · Cursor · Antigravity · OpenCode).", "kitty", window.title))
        }
        return try session(host: .kitty(socket: socket, window: window.id), appName: "kitty", label: window.title, table: table, device: device)
    }
    #endif

}
