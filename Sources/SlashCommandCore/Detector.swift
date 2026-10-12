import AppKit
import Foundation

public enum TerminalHost: Equatable, Sendable {
    case ghostty(terminalID: String)
    case orca(handle: String)
    /// tmux pane(`%3`, `세션:창.칸`). `socket` 은 `tmux -L` 의 이름이거나 `-S` 의 경로(`/` 가 들어 있으면 경로).
    case tmux(socket: String?, pane: String)
    /// kitty 창 id 와 원격 제어 소켓(`unix:/path`).
    case kitty(socket: String, window: String)
    /// WezTerm pane id. `socket` 은 그 GUI 의 mux 소켓 경로(없으면 `wezterm cli` 가 고르는 GUI).
    case wezterm(socket: String?, pane: String)
    /// iTerm2 세션의 `unique id`.
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
    /// 사람이 읽는 설명(터미널 제목 등).
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

    /// 지금 맨 앞 앱의 맨 앞 터미널과 그 안의 에이전트.
    public static func frontmost() throws -> Target {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            throw SlashCommandError(loc("Cannot tell which app is in front."))
        }
        return try target(bundleID: bundleID, appName: app.localizedName ?? bundleID)
    }

    public static func target(bundleID: String, appName: String) throws -> Target {
        switch bundleID {
        case ghosttyBundleID: return try ghostty()
        case orcaBundleID: return try orca()
        case itermBundleID: return try iterm()
        // 같은 앱을 둘 이상 띄웠을 수 있다 — 그 가운데 «맨 앞» 인 프로세스를 짚어 준다.
        case weztermBundleID: return try wezterm(frontPID: activeProcess(bundleID: weztermBundleID))
        case kittyBundleID: return try kitty(frontPID: activeProcess(bundleID: kittyBundleID))
        default:
            throw SlashCommandError(loc("%@ is not supported. Press it in a Ghostty, Orca, iTerm2, WezTerm or kitty terminal.", appName))
        }
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
        // 제목을 직접 바꿔 둔 탭은 제목으로 못 가린다. 그 폴더에서 도는 에이전트가 한 종류뿐이면 그것으로 본다.
        let kinds = AgentProcesses.kinds(inDirectory: cwd)
        // 같은 폴더에서 claude 와 codex 가 따로 도는 경우: 이 터미널 화면에 어느 쪽 입력창이 보이는지로 가린다.
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

    /// 화면에 입력창이 «보이는» 에이전트. 하나로 정해지지 않으면(둘 다 보이거나 하나도 안 보이면) nil.
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

    /// 핸들만 알 때 그 터미널에서 도는 에이전트.
    public static func orcaAgent(handle: String) -> Agent? {
        AgentProcesses.agent(orcaHandle: handle)
    }

    public static func orca() throws -> Target {
        let payload = try orcaTerminals()
        let active = try orcaActive(payload: payload).active
        return try OrcaState.target(in: payload, active: active, processAgent: AgentProcesses.agent(orcaHandle:))
    }

    /// 화면에 떠 있는 워크스페이스·탭과 «어디서 알았는가».
    /// 접근성으로 읽은 탭 줄(지연 없음)을 먼저 쓰고, 읽지 못하거나 맞는 워크스페이스가 없으면 상태 DB(1.3~2.5초 늦음)로 되돌아간다.
    /// 탭 줄이 둘 이상의 워크스페이스와 똑같으면 어느 쪽인지 모르므로 보내지 않는다.
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

    /// 터미널 목록과 화면 배치. Orca 앱에 직접 묻고, 안 되면 `orca` 명령으로 묻는다.
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

/// Orca 화면에 지금 보이는 워크스페이스·탭.
///
/// `orca` CLI 는 워크스페이스별 활성 탭까지만 알려 주고 「어느 워크스페이스가 화면에 떠 있나」는 주지 않는다
/// (핸들 없이 `terminal show` 를 부르면 화면과 무관한 터미널이 나온다 — 2026-10-05 실측). 그래서 그 한 가지만
/// Orca 의 상태 DB 에서 읽는다. 공개된 인터페이스가 아니므로 형식이 바뀌면 추측하지 않고 실패한다.
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

    /// `orca terminal list --include-visual-layouts` 결과에서 화면에 보이는 탭의 활성 터미널을 고른다.
    ///
    /// 목록의 `agentIdentity` 는 같은 세션에서도 상태에 따라 비어 온다(2026-10-06 실측: 대기 중 null, 작업 중 claude).
    /// 그래서 그 터미널에서 실제로 도는 프로세스(`processAgent`)를 먼저 보고, 못 찾을 때만 `agentIdentity` 를 쓴다.
    static func target(in payload: [String: Any], active: Active,
                       processAgent: (String) -> Agent? = { _ in nil }) throws -> Target {
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
        guard let agent = processAgent(handle) ?? (listed?["agentIdentity"] as? String).flatMap(Agent.init(rawValue:)) else {
            throw SlashCommandError(loc("The frontmost Orca terminal (%@) is not a supported agent session (Claude Code · Codex · Grok · Cursor · Antigravity · OpenCode).", label))
        }
        return Target(host: .orca(handle: handle), agent: agent, label: label)
    }

    /// 탭 묶음이 좌우로 나뉘어 있어도 찾도록 트리 전체에서 탭을 모은다.
    static func tabs(in node: Any?) -> [[String: Any]] {
        if let array = node as? [Any] { return array.flatMap { tabs(in: $0) } }
        guard let dict = node as? [String: Any] else { return [] }
        var found = dict["tabs"] as? [[String: Any]] ?? []
        for (key, value) in dict where key != "tabs" { found.append(contentsOf: tabs(in: value)) }
        return found
    }

    /// 한 탭 안의 분할된 터미널들.
    static func terminals(in node: Any?) -> [[String: Any]] {
        if let array = node as? [Any] { return array.flatMap { terminals(in: $0) } }
        guard let dict = node as? [String: Any] else { return [] }
        if dict["type"] as? String == "terminal", dict["handle"] != nil { return [dict] }
        return dict.values.flatMap { terminals(in: $0) }
    }
}

/// 실행 중인 claude·codex 프로세스를 작업 폴더로 찾는다(Ghostty 제목으로 못 가릴 때의 보조 수단).
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

    /// Orca 는 터미널마다 `ORCA_TERMINAL_HANDLE` 을 환경변수로 준다. 그 값을 가진 프로세스 중 에이전트를 찾는다.
    /// 에이전트가 다른 에이전트를 자식으로 띄운 경우(예: claude 가 `codex exec` 실행)는 바깥쪽 것을 고른다.
    /// 환경변수에는 비밀이 섞여 있을 수 있으므로 이 출력은 어디에도 남기지 않는다.
    static func agent(orcaHandle handle: String) -> Agent? {
        let table = ProcessTable.snapshot()
        if !table.entries.isEmpty {
            let marker = "ORCA_TERMINAL_HANDLE=\(handle)"
            let candidates = table.entries.compactMap { entry -> (pid: String, agent: Agent)? in
                guard entry.environment.contains(marker),
                      let agent = agent(forCommandLine: entry.arguments.joined(separator: " ")) else { return nil }
                return (String(entry.pid), agent)
            }
            let parents = Dictionary(uniqueKeysWithValues: table.parents.map { (String($0.key), String($0.value)) })
            return outermostAgent(candidates, parents: parents)
        }
        // 프로세스 안에서 못 읽으면 `ps` 로 같은 정보를 읽는다.
        let ps = Proc.run("/bin/ps", ["-axEww", "-o", "pid=,ppid=,tty=,command="], timeout: 5)
        guard ps.ok else { return nil }
        return agent(orcaHandle: handle, psOutput: ps.out)
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

    /// 후보 중 다른 후보의 자손이 아닌 것(바깥쪽)의 종류. 한 종류로 모이지 않으면 nil.
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
