import AppKit
import Foundation

public enum TerminalHost: Equatable, Sendable {
    case ghostty(terminalID: String)
    case orca(handle: String)
    /// tmux pane (`%3`, `session:window.pane`). `socket` is the `tmux -L` name or the `-S` path (a path if it contains `/`).
    case tmux(socket: String?, pane: String)
    /// kitty window id and remote-control socket (`unix:/path`).
    case kitty(socket: String, window: String)
    /// WezTerm pane id. `socket` is the path of that GUI's mux socket (if none, the GUI `wezterm cli` picks).
    case wezterm(socket: String?, pane: String)
    /// The `unique id` of an iTerm2 session.
    case iterm(sessionID: String)

    public var appName: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .orca: return "Orca"
        case .tmux: return "tmux"
        case .kitty: return "kitty"
        case .wezterm: return "WezTerm"
        case .iterm: return "iTerm2"
        }
    }
}

public struct Target: Equatable, Sendable {
    public let host: TerminalHost
    public let agent: Agent
    /// A human-readable description (terminal title, etc.).
    public let label: String

    public init(host: TerminalHost, agent: Agent, label: String) {
        self.host = host
        self.agent = agent
        self.label = label
    }
}

public enum Detector {
    public static let ghosttyBundleID = "com.mitchellh.ghostty"
    public static let orcaBundleID = "com.stablyai.orca"
    public static let supportedBundleIDs: Set<String> = [ghosttyBundleID, orcaBundleID, itermBundleID, weztermBundleID, kittyBundleID]

    /// The frontmost terminal of the frontmost app and the agent in it. For a terminal driven by AppleScript, it first checks automation permission
    /// (if a permission dialog appears it calls `willAskAutomation` and waits for the answer — `AutomationConsent.ensure`).
    /// If it showed a dialog to get permission, it continues only when that app is back in front.
    public static func frontmost(willAskAutomation: @escaping () -> Void = {}) throws -> Target {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            throw SlashCommandError(loc("Cannot tell which app is in front."))
        }
        let appName = app.localizedName ?? bundleID
        // If the user moved to another app while answering the permission dialog, do not change the terminal behind it.
        var frontPID = app.processIdentifier
        if try AutomationConsent.ensure(bundleID: bundleID, appName: appName, willAsk: willAskAutomation) {
            try AutomationConsent.requireFront(bundleID: bundleID, appName: appName)
            // While answering the dialog, another process of the same app may have come to the front.
            if let now = NSWorkspace.shared.frontmostApplication, now.bundleIdentifier == bundleID { frontPID = now.processIdentifier }
        }
        return try target(bundleID: bundleID, appName: appName, frontPID: frontPID)
    }

    /// `frontPID` is the pid of the frontmost app (as reported by `NSWorkspace.frontmostApplication`). It is used to pick the «frontmost» process when more than one instance of the same app is running.
    /// If unknown (`--bundle`, which asks as if that app were in front), it looks for the active one among the running ones.
    public static func target(bundleID: String, appName: String, frontPID: Int32? = nil) throws -> Target {
        switch bundleID {
        case ghosttyBundleID: return try ghostty()
        case orcaBundleID: return try orca()
        case itermBundleID: return try iterm()
        case weztermBundleID: return try wezterm(frontPID: frontProcess(known: frontPID, bundleID: weztermBundleID))
        case kittyBundleID: return try kitty(frontPID: frontProcess(known: frontPID, bundleID: kittyBundleID))
        default:
            throw SlashCommandError(loc("%@ is not supported. Press it in a Ghostty, Orca, iTerm2, WezTerm or kitty terminal.", appName))
        }
    }

    /// The frontmost process. If the caller knows a pid, use it — picking the «active» one from the running-app list
    /// can be wrong in a long-lived app (measured 2026-10-13: with two WezTerms running and the later-launched one in front, 2 of 4 shortcut presses
    /// went to the shell of the first-launched one. A list read by a freshly launched process at the same moment was right).
    static func frontProcess(known: Int32?, bundleID: String, active: (String) -> Int32? = Detector.activeProcess) -> Int32? {
        known ?? active(bundleID)
    }

    static func activeProcess(bundleID: String) -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: \.isActive)?.processIdentifier
    }

    // MARK: Ghostty

    public static func ghostty() throws -> Target {
        let script = """
        tell application "Ghostty"
            if (count of windows) is 0 then return ""
            set t to focused terminal of selected tab of front window
            return (id of t) & linefeed & (name of t) & linefeed & (working directory of t)
        end tell
        """
        let result = GhosttyIO.osascript(script)
        guard result.ok else {
            let detail = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SlashCommandError(loc("Could not read the frontmost Ghostty terminal: %@", detail))
        }
        let parts = result.out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else {
            throw SlashCommandError(loc("Ghostty has no open window."))
        }
        let id = parts[0]
        let name = parts[1]
        let cwd = parts.count > 2 ? parts[2] : ""

        if let agent = agent(inTitle: name) {
            return Target(host: .ghostty(terminalID: id), agent: agent, label: name)
        }
        // A tab whose title was changed by hand cannot be told apart by title. If only one kind of agent runs in that folder, take that one.
        let kinds = AgentProcesses.kinds(inDirectory: cwd)
        // If claude and codex run separately in the same folder: decide by which input box is visible on this terminal's screen.
        if kinds.count > 1, let lines = GhosttyIO(terminalID: id).screen(), let agent = agent(onScreen: lines) {
            return Target(host: .ghostty(terminalID: id), agent: agent, label: name)
        }
        guard kinds.count == 1, let agent = kinds.first else {
            throw SlashCommandError(kinds.isEmpty
                ? loc("The frontmost Ghostty terminal (%@) is not a supported agent session (Claude Code · Codex · Grok · Cursor · Antigravity · OpenCode).", name)
                : loc("The frontmost Ghostty terminal (%@) cannot be told apart: Claude Code and Codex are both running in the same folder.", name))
        }
        return Target(host: .ghostty(terminalID: id), agent: agent, label: name)
    }

    /// The agent whose input box is «visible» on screen. nil if it cannot be narrowed to one (both visible or neither visible).
    static func agent(onScreen lines: [String]) -> Agent? {
        let visible = Agent.allCases.filter { Readiness.inputVisible(agent: $0, screen: lines) }
        return visible.count == 1 ? visible.first : nil
    }

    static func agent(inTitle title: String) -> Agent? {
        let lower = title.lowercased()
        let hasClaude = lower.contains("claude")
        let hasCodex = lower.contains("codex")
        if hasClaude != hasCodex { return hasClaude ? .claude : .codex }
        return nil
    }

    // MARK: Orca

    /// The agent running in that terminal when only the handle is known.
    public static func orcaAgent(handle: String) -> Agent? {
        AgentProcesses.agent(orcaHandle: handle)
    }

    public static func orca() throws -> Target {
        let payload = try orcaTerminals()
        let active = try orcaActive(payload: payload).active
        // If tmux is running as the «foreground job» in that terminal, go into the tmux pane that client is looking at (write and read via tmux too).
        // Used as-is through Orca, the bottom of the screen is tmux's status line, and if panes are split the text of several panes is mixed on one screen.
        if let handle = try? OrcaState.pane(in: payload, active: active).handle, let inside = try orcaTmux(handle: handle) {
            return inside
        }
        return try OrcaState.target(in: payload, active: active, processAgent: AgentProcesses.agent(orcaHandle:))
    }

    /// If a tmux client is the foreground job in that Orca terminal, the tmux pane that client is looking at. Otherwise nil.
    public static func orcaTmux(handle: String) throws -> Target? {
        let table = ProcessTable.snapshot()
        let client = AgentProcesses.tmuxClient(orcaHandle: handle, entries: table.entries, parents: table.parents,
                                               isTmux: { TTYProcesses.isTmux(executable: ProcessTable.executablePath(of: $0)) })
        return try client.map { try TmuxFront.target(client: $0, table: table, outer: "Orca") }
    }

    /// The workspace and tab shown on screen, and «how it was learned».
    /// It first uses the tab lines read through accessibility (no delay), and falls back to the state DB (1.3–2.5 s late) if they cannot be read or no workspace matches.
    /// If the tab lines match more than one workspace, it cannot tell which, so nothing is sent.
    public static func orcaActive(payload: [String: Any]) throws -> (active: OrcaState.Active, source: String) {
        let database = try? OrcaState.active()
        guard let strip = OrcaView.readStrip() else {
            return (try OrcaState.active(), "state DB (could not read the tab strip through Accessibility)")
        }
        let layouts = payload["visualLayouts"] as? [[String: Any]] ?? []
        switch OrcaView.resolve(strip: strip, layouts: layouts) {
        case .tab(let active):
            let note = (database == active) ? "Accessibility (same as the DB)" : "Accessibility (differs from the DB — the DB still has the old value)"
            return (active, note)
        case .ambiguous:
            throw SlashCommandError(loc("Orca has two or more workspaces with the same tab titles in the same order, so the visible terminal cannot be told apart. Give the tabs different names."))
        case .noMatch:
            return (try OrcaState.active(), "state DB (the tab strip matches no workspace)")
        }
    }

    /// The terminal list and screen layout. Asks the Orca app directly, and if that fails asks through the `orca` command.
    public static func orcaTerminals() throws -> [String: Any] {
        if case .success(let payload) = OrcaRuntime.call("terminal.list", ["includeVisualLayouts": true]) {
            return payload
        }
        guard let orca = Proc.locate("orca") else {
            throw SlashCommandError(loc("Could not connect to the Orca app, and the orca command was not found either."))
        }
        let result = Proc.run(orca, ["terminal", "list", "--include-visual-layouts", "--json"],
                              env: OrcaIO.cleanEnv, cwd: "/", timeout: 10)
        guard result.ok,
              let json = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any],
              let payload = json["result"] as? [String: Any] else {
            throw SlashCommandError(loc("Could not read the Orca terminal list: %@", OrcaIO.errorSummary(result)))
        }
        return payload
    }
}

/// The workspace and tab currently shown on the Orca screen.
///
/// The `orca` CLI only tells the active tab per workspace and does not say "which workspace is on screen"
/// (calling `terminal show` without a handle returns a terminal unrelated to the screen — measured 2026-10-05). So only that one thing
/// is read from Orca's state DB. It is not a public interface, so if the format changes it fails instead of guessing.
public enum OrcaState {
    public struct Active: Equatable, Sendable {
        public let worktreeID: String
        public let tabID: String

        public init(worktreeID: String, tabID: String) {
            self.worktreeID = worktreeID
            self.tabID = tabID
        }
    }

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/orca")
    }

    static func databaseURL() -> URL {
        var profile = "local-default"
        let index = supportDirectory.appendingPathComponent("orca-profile-index.json")
        if let data = try? Data(contentsOf: index),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let active = json["activeProfileId"] as? String, !active.isEmpty {
            profile = active
        }
        return supportDirectory.appendingPathComponent("profiles/\(profile)/profile-state.db")
    }

    public static func active() throws -> Active {
        let database = databaseURL()
        let query = """
        select json_object('worktree', json_extract(payload, '$.activeWorktreeId'), \
        'tab', json_extract(payload, '$.activeTabId')) \
        from profile_state_documents where domain = 'workspaceSession'
        """
        let result = Proc.run("/usr/bin/sqlite3", ["-readonly", "file:\(database.path)?mode=ro", query], timeout: 5)
        let unknown = SlashCommandError(loc("Could not work out which Orca workspace is on screen (an Orca update may have changed how it stores its state)."))
        guard result.ok,
              let json = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any],
              let worktree = json["worktree"] as? String, !worktree.isEmpty else {
            throw unknown
        }
        guard let tab = json["tab"] as? String, !tab.isEmpty else {
            throw SlashCommandError(loc("The frontmost Orca tab is not a terminal."))
        }
        return Active(worktreeID: worktree, tabID: tab)
    }

    /// Picks the active terminal of the tab visible on screen from the result of `orca terminal list --include-visual-layouts`.
    ///
    /// `agentIdentity` in the list comes back empty depending on state even for the same session (measured 2026-10-06: null while idle, claude while working).
    /// So first look at the process actually running in that terminal (`processAgent`), and use `agentIdentity` only when it is not found.
    static func target(in payload: [String: Any], active: Active,
                       processAgent: (String) -> Agent? = { _ in nil }) throws -> Target {
        let pane = try pane(in: payload, active: active)
        guard let agent = processAgent(pane.handle) ?? pane.listedAgent else {
            throw SlashCommandError(loc("The frontmost Orca terminal (%@) is not a supported agent session (Claude Code · Codex · Grok · Cursor · Antigravity · OpenCode).", pane.label))
        }
        return Target(host: .orca(handle: pane.handle), agent: agent, label: pane.label)
    }

    /// The active terminal of the tab visible on screen: handle, human-readable name, and the agent the list records (may be absent).
    static func pane(in payload: [String: Any], active: Active) throws -> (handle: String, label: String, listedAgent: Agent?) {
        let layouts = payload["visualLayouts"] as? [[String: Any]] ?? []
        guard let layout = layouts.first(where: { $0["worktreeId"] as? String == active.worktreeID }) else {
            throw SlashCommandError(loc("The frontmost Orca workspace has no open terminal."))
        }
        guard let tab = tabs(in: layout["root"]).first(where: { $0["tabId"] as? String == active.tabID }) else {
            throw SlashCommandError(loc("The frontmost Orca tab is not a terminal."))
        }
        let leaves = terminals(in: tab["panes"])
        let activeLeaf = tab["activeLeafId"] as? String
        guard let pane = leaves.first(where: { $0["leafId"] as? String == activeLeaf })
                ?? leaves.first(where: { $0["active"] as? Bool == true }),
              let handle = pane["handle"] as? String else {
            throw SlashCommandError(loc("Could not find the active terminal in the frontmost Orca tab."))
        }
        let listed = (payload["terminals"] as? [[String: Any]] ?? []).first { $0["handle"] as? String == handle }
        let title = (listed?["title"] as? String) ?? (pane["title"] as? String) ?? handle
        let folder = (layout["worktreePath"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        let label = [title, folder].compactMap { $0 }.joined(separator: " · ")
        return (handle, label, (listed?["agentIdentity"] as? String).flatMap(Agent.init(rawValue:)))
    }

    /// Collects tabs from the whole tree so they are found even when the tab group is split left and right.
    static func tabs(in node: Any?) -> [[String: Any]] {
        if let array = node as? [Any] { return array.flatMap { tabs(in: $0) } }
        guard let dict = node as? [String: Any] else { return [] }
        var found = dict["tabs"] as? [[String: Any]] ?? []
        for (key, value) in dict where key != "tabs" { found.append(contentsOf: tabs(in: value)) }
        return found
    }

    /// The split terminals inside one tab.
    static func terminals(in node: Any?) -> [[String: Any]] {
        if let array = node as? [Any] { return array.flatMap { terminals(in: $0) } }
        guard let dict = node as? [String: Any] else { return [] }
        if dict["type"] as? String == "terminal", dict["handle"] != nil { return [dict] }
        return dict.values.flatMap { terminals(in: $0) }
    }
}

/// Finds running claude and codex processes by working directory (a fallback for when the Ghostty title cannot tell).
enum AgentProcesses {
    static func kinds(inDirectory directory: String) -> Set<Agent> {
        guard !directory.isEmpty else { return [] }
        let wanted = URL(fileURLWithPath: directory).standardizedFileURL.path
        let ps = Proc.run("/bin/ps", ["-axo", "pid=,tty=,args="], timeout: 5)
        guard ps.ok else { return [] }
        var candidates: [(pid: String, agent: Agent)] = []
        for line in ps.out.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, fields[1] != "??",
                  let agent = agent(forCommandLine: String(fields[2])) else { continue }
            candidates.append((String(fields[0]), agent))
        }
        guard !candidates.isEmpty else { return [] }
        let lsof = Proc.run("/usr/sbin/lsof",
                            ["-a", "-d", "cwd", "-Fpn", "-p", candidates.map(\.pid).joined(separator: ",")],
                            timeout: 5)
        var cwdByPID: [String: String] = [:]
        var current: String?
        for line in lsof.out.split(separator: "\n") {
            if line.hasPrefix("p") {
                current = String(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = current {
                cwdByPID[pid] = URL(fileURLWithPath: String(line.dropFirst())).standardizedFileURL.path
            }
        }
        return Set(candidates.filter { cwdByPID[$0.pid] == wanted }.map(\.agent))
    }

    /// Orca gives each terminal `ORCA_TERMINAL_HANDLE` as an environment variable. Among the processes that have that value, find the agent.
    /// If an agent started another agent as a child (e.g. claude runs `codex exec`), pick the outer one.
    /// The environment may contain secrets, so this output is not kept anywhere.
    static func agent(orcaHandle handle: String) -> Agent? {
        let table = ProcessTable.snapshot()
        if !table.entries.isEmpty {
            return agent(orcaHandle: handle, entries: table.entries, parents: table.parents,
                         isTmux: { TTYProcesses.isTmux(executable: ProcessTable.executablePath(of: $0)) })
        }
        // If it cannot be read inside the process, read the same information with `ps`.
        let ps = Proc.run("/bin/ps", ["-axEww", "-o", "pid=,ppid=,tty=,command="], timeout: 5)
        guard ps.ok else { return nil }
        return agent(orcaHandle: handle, psOutput: ps.out)
    }

    static func agent(orcaHandle handle: String, entries: [ProcessTable.Entry], parents: [Int32: Int32], isTmux: (Int32) -> Bool) -> Agent? {
        let marker = "ORCA_TERMINAL_HANDLE=\(handle)"
        let candidates = entries.compactMap { entry -> (pid: String, agent: Agent)? in
            // A process inside a tmux pane has the same handle inherited from the server, but it is not on this terminal's screen (detach the client and only a shell shows).
            guard entry.environment.contains(marker), !hasAncestor(of: entry.pid, parents: parents, where: isTmux),
                  let agent = agent(forCommandLine: entry.arguments.joined(separator: " ")) else { return nil }
            return (String(entry.pid), agent)
        }
        let table = Dictionary(uniqueKeysWithValues: parents.map { (String($0.key), String($0.value)) })
        return outermostAgent(candidates, parents: table)
    }

    /// The tmux client running as the «foreground job» in Orca terminal `handle`. nil if it cannot be narrowed to one.
    ///
    /// If the tmux server was first started in that terminal, the server inherits that environment variable, so processes in every pane carry the same `ORCA_TERMINAL_HANDLE`.
    /// So a tmux client started again inside a pane (tmux is among its ancestors) is not that terminal's — count only those with no tmux among ancestors.
    static func tmuxClient(orcaHandle handle: String, entries: [ProcessTable.Entry], parents: [Int32: Int32],
                           isTmux: (Int32) -> Bool) -> ProcessTable.Entry? {
        let marker = "ORCA_TERMINAL_HANDLE=\(handle)"
        let found = entries.filter { entry in
            entry.environment.contains(marker) && TTYProcesses.isTmuxClient(entry) && entry.isForeground
                && !hasAncestor(of: entry.pid, parents: parents, where: isTmux)
        }
        return found.count == 1 ? found.first : nil
    }

    static func hasAncestor(of pid: Int32, parents: [Int32: Int32], where matches: (Int32) -> Bool) -> Bool {
        var current = parents[pid]
        var hops = 0
        while let ancestor = current, ancestor > 1, hops < 64 {
            if matches(ancestor) { return true }
            current = parents[ancestor]
            hops += 1
        }
        return false
    }

    static func agent(orcaHandle handle: String, psOutput: String) -> Agent? {
        var parents: [String: String] = [:]
        var candidates: [(pid: String, agent: Agent)] = []
        let marker = "ORCA_TERMINAL_HANDLE=\(handle)"
        for line in psOutput.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4 else { continue }
            let pid = String(fields[0])
            parents[pid] = String(fields[1])
            let rest = String(fields[3])
            guard fields[2] != "??", let range = rest.range(of: marker) else { continue }
            let after = rest[range.upperBound...].first
            guard after == nil || after == " ", let agent = agent(forCommandLine: rest) else { continue }
            candidates.append((pid, agent))
        }
        return outermostAgent(candidates, parents: parents)
    }

    /// Of the candidates, the kind of those that are not descendants of another candidate (the outer ones). nil if they do not collapse to one kind.
    static func outermostAgent(_ candidates: [(pid: String, agent: Agent)], parents: [String: String]) -> Agent? {
        let pids = Set(candidates.map(\.pid))
        let outermost = candidates.filter { candidate in
            var current = parents[candidate.pid]
            var hops = 0
            while let pid = current, hops < 64 {
                if pids.contains(pid) { return false }
                current = parents[pid]
                hops += 1
            }
            return true
        }
        let kinds = Set(outermost.map(\.agent))
        return kinds.count == 1 ? kinds.first : nil
    }

    static func agent(forCommandLine commandLine: String) -> Agent? {
        guard let first = commandLine.split(separator: " ").first else { return nil }
        let name = first.split(separator: "/").last.map(String.init) ?? ""
        if name == "claude" || first.contains("/claude/versions/") { return .claude }
        if name == "codex" { return .codex }
        if name == "grok" { return .grok }
        if name == "cursor-agent" { return .cursor }
        if name == "agy" { return .antigravity }
        if name == "opencode" { return .opencode }
        return nil
    }
}
