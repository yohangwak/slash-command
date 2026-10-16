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
    #if os(Windows)
    var windowsFrontPID: Int32? = nil
    #endif

    public init(host: TerminalHost, agent: Agent, label: String) {
        self.host = host
        self.agent = agent
        self.label = label
    }
}

public enum Detector {
    public static let itermBundleID = "com.googlecode.iterm2"
    public static let ghosttyBundleID = "com.mitchellh.ghostty"
    public static let orcaBundleID = "com.stablyai.orca"
    public static let supportedBundleIDs: Set<String> = [ghosttyBundleID, orcaBundleID, itermBundleID, weztermBundleID, kittyBundleID]

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

    #if os(Windows)
    public static var orcaExtraDirectories: [String] {
        get throws { [try WindowsPaths.requiredEnvironment("LOCALAPPDATA") + "/Programs/orca/resources/bin"] }
    }
    #else
    public static var orcaExtraDirectories: [String] { [] }
    #endif

    // MARK: Orca

    /// The terminal list and screen layout. Asks the Orca app directly, and if that fails asks through the `orca` command.
    public static func orcaTerminals() throws -> [String: Any] {
        #if os(Windows)
        switch OrcaRuntime.call("terminal.list", ["includeVisualLayouts": true]) {
        case .success(let payload): return payload
        case .failure(.failed(let message)): throw SlashCommandError(message)
        case .failure(.unavailable): break
        }
        #else
        if case .success(let payload) = OrcaRuntime.call("terminal.list", ["includeVisualLayouts": true]) {
            return payload
        }
        #endif
        #if os(Windows)
        let orcaCommand = try Proc.locate("orca", extra: orcaExtraDirectories)
        #else
        let orcaCommand = Proc.locate("orca")
        #endif
        guard let orca = orcaCommand else {
            throw SlashCommandError(loc("Could not connect to the Orca app, and the orca command was not found either."))
        }
        let result = Proc.run(orca, ["terminal", "list", "--include-visual-layouts", "--json"],
                              env: OrcaIO.cleanEnv, cwd: OrcaIO.runtimeWorkingDirectory, timeout: 10)
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

    #if os(Windows)
    static var supportDirectory: URL {
        get throws { URL(fileURLWithPath: try WindowsPaths.requiredEnvironment("APPDATA")).appendingPathComponent("orca") }
    }

    static func databaseURL() throws -> URL {
        try databaseURL(in: supportDirectory)
    }
    #else
    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/orca")
    }

    static func databaseURL() -> URL { databaseURL(in: supportDirectory) }
    #endif

    private static func databaseURL(in supportDirectory: URL) -> URL {
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
        #if os(Windows)
        let database = try databaseURL()
        #else
        let database = databaseURL()
        #endif
        let query = """
        select json_object('worktree', json_extract(payload, '$.activeWorktreeId'), \
        'tab', json_extract(payload, '$.activeTabId')) \
        from profile_state_documents where domain = 'workspaceSession'
        """
        #if os(Windows)
        let result = WindowsOrcaState.query(database: database.path, sql: query)
        #else
        let result = Proc.run("/usr/bin/sqlite3", ["-readonly", "file:\(database.path)?mode=ro", query], timeout: 5)
        #endif
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
        guard let layout = layouts.first(where: {
            #if os(Windows)
            return ($0["worktreeId"] as? String).map { WindowsPaths.normalized($0) == WindowsPaths.normalized(active.worktreeID) } ?? false
            #else
            return $0["worktreeId"] as? String == active.worktreeID
            #endif
        }) else {
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
    #if os(macOS)
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

    #endif

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
        #if os(Windows)
        return windowsAgent(forCommandLine: commandLine)
        #else
        return nonWindowsAgent(forCommandLine: commandLine)
        #endif
    }

    static func nonWindowsAgent(forCommandLine commandLine: String) -> Agent? {
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

#if !os(macOS) && !os(Windows)
extension Detector {
    public static func frontmost(willAskAutomation: @escaping () -> Void = {}) throws -> Target {
        throw SlashCommandError(loc("This is not supported on this operating system yet."))
    }

    public static func target(bundleID: String, appName: String, frontPID: Int32? = nil) throws -> Target {
        throw SlashCommandError(loc("This is not supported on this operating system yet."))
    }
}
#endif
