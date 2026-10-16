#if os(macOS)
import AppKit
import Foundation

extension Detector {
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

}

extension AgentProcesses {
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


}
#endif
