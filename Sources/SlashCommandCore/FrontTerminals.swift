import Darwin
import Foundation

// 맨 앞 세션 찾기 — WezTerm · kitty, 그리고 그 안의 tmux.
//
// 2026-10-12 집 맥 2 실측(WezTerm · kitty · tmux 를 그 화면에서 연 뒤 ssh 로):
// - WezTerm: `wezterm cli list-clients` 가 GUI 의 `focused_pane_id` 를, `cli list` 가 그 pane 의 `tty_name` 을 준다.
// - kitty: 원격 제어 소켓은 그 kitty 프로세스가 열어 둔 유닉스 소켓에서 안다(`lsof`. 창 안 프로세스의 환경변수는 읽히지 않았다).
//   `kitty @ ls` 가 OS 창 → 탭 → 창의 `is_focused` 와 그 창에서 앞에 도는 프로세스의 pid 를 준다.
//   🔴 `ls` 의 `env` 에는 그 창의 환경변수가 통째로 들어 있다(비밀이 섞일 수 있다) — 읽지도 남기지도 않는다.
// - WezTerm 의 `focused_pane_id` 는 WezTerm 이 맨 앞 앱일 때 탭을 바꾸면 바로 따라온다. 뒤에 있는 동안 `cli activate-pane` 으로 바꾼 것은
//   앞으로 올 때까지 반영되지 않았다 — 단축키는 그 앱이 맨 앞일 때만 오므로 그때의 값은 지금 것이다.
// - tmux: 터미널 앱 «안» 에 있다. 그 터미널의 tty 에 붙은 `tmux` 클라이언트의 pid 로 `list-clients` 에서 그 클라이언트를 찾으면
//   `#{pane_id}` · `#{pane_tty}` 가 «그 클라이언트가 보고 있는» 칸이다(칸을 나눈 뒤에도 따라왔다).
// - 🔴 tty 를 주지 않는 터미널(Ghostty 등)에서 tmux 의 포커스 표시(`client_flags` 의 `focused`)로 가리는 길은 넣지 않았다.
//   `focus-events on` 을 «켠 채로 붙은» 클라이언트의 표시는 앱·탭 전환을 따라오지만(실측), 켜기 전에 붙은 클라이언트는 뒤로 가도
//   계속 `focused` 로 남는다(실측, tmux 3.7c) — 그 표시만 믿으면 뒤에 있는 탭의 칸에 쓸 수 있다.

/// 터미널(tty)에 붙은 프로세스들.
enum TTYProcesses {
    /// `/dev/ttys004` 의 장치 번호. 프로세스의 `e_tdev` 와 같은 값이다.
    static func device(ofTTY path: String) -> UInt32? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFCHR else { return nil }
        return UInt32(bitPattern: info.st_rdev)
    }

    static func isTmuxClient(_ entry: ProcessTable.Entry) -> Bool {
        guard let first = entry.arguments.first else { return false }
        return (first.split(separator: "/").last.map(String.init) ?? "") == "tmux"
    }

    /// 그 터미널의 에이전트(에이전트가 띄운 다른 에이전트는 세지 않는다). 한 종류로 모이지 않으면 nil.
    static func agent(in entries: [ProcessTable.Entry], parents: [Int32: Int32]) -> Agent? {
        let candidates = entries.compactMap { entry -> (pid: String, agent: Agent)? in
            AgentProcesses.agent(forCommandLine: entry.arguments.joined(separator: " ")).map { (String(entry.pid), $0) }
        }
        let table = Dictionary(uniqueKeysWithValues: parents.map { (String($0.key), String($0.value)) })
        return AgentProcesses.outermostAgent(candidates, parents: table)
    }
}

public enum WezTermFront {
    public struct Pane: Equatable, Sendable {
        public let id: String
        public let tty: String
        public let title: String
    }

    /// `cli list-clients` 와 `cli list` 의 JSON 에서 포커스된 pane. `frontPID` 는 맨 앞 WezTerm GUI 의 pid — 그 GUI 의 클라이언트만 본다.
    /// GUI 여럿이 한 mux 를 같이 쓰면 클라이언트가 여럿인데, «가장 최근에 글자를 받은» 것이 맨 앞은 아니다(`idle_time` 은 입력만 센다 — PR #25 리뷰).
    /// `frontPID` 를 모를 때(그 앱이 맨 앞이 아닌 채로 묻는 시험)는 클라이언트가 하나뿐일 때만 답한다.
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

    /// 그 GUI 의 mux 소켓(`~/.local/share/wezterm/gui-sock-<pid>`). `wezterm cli` 는 가만두면 «어느» GUI 에 붙을지 스스로 고른다 —
    /// GUI 를 둘 이상 띄웠으면 맨 앞 것의 소켓을 `WEZTERM_UNIX_SOCKET` 으로 짚어 준다. 파일이 없으면 nil(그때는 `wezterm cli` 의 기본대로).
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
        /// 그 창의 셸과 앞에서 도는 프로세스들.
        public let pids: [Int32]
    }

    /// 그 kitty 프로세스가 «실제로 열어 둔» 유닉스 소켓들(`lsof -a -p <pid> -U -Fn` 의 출력에서 경로가 있는 것).
    /// 설정을 읽어 추측하지 않는다 — 소켓 주소는 `--listen-on` · `--config` 로 준 파일 · `include` 한 파일 어디에나 있을 수 있고,
    /// kitty 가 환경변수 · `~` · 상대 경로 · `{kitty_pid}` 를 풀어서 연다(PR #25 리뷰). 창 안 프로세스의 환경변수(`KITTY_LISTEN_ON`)는 맥에서
    /// 읽히지 않는다(2026-10-12 실측: kitty 가 셸을 `login` 으로 띄워, 그 셸과 자식들의 환경이 가려진다).
    static func boundSockets(lsofOutput: String) -> [String] {
        var found: [String] = []
        for line in lsofOutput.split(separator: "\n") where line.hasPrefix("n/") {
            let socket = "unix:" + line.dropFirst()
            if !found.contains(socket) { found.append(socket) }
        }
        return found
    }

    /// kitty 본체 프로세스들의 pid(창 없는 도우미 `kitty +runpy …` 는 뺀다).
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

    /// `kitty @ ls` 의 JSON 에서 포커스된 OS 창 → 탭 → 창. OS 창이 하나뿐이면 kitty 가 맨 앞 앱이 아니어도(포커스 표시가 없어도) 그 창이다.
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
        /// `세션:창.칸`
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

    /// 클라이언트 명령줄의 `-L 이름` · `-S 경로`(`-L이름` 처럼 붙여 쓴 것도). 없으면 nil(기본 소켓).
    static func socket(clientArguments arguments: [String]) -> String? {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            for flag in ["-L", "-S"] where argument.hasPrefix(flag) {
                if argument.count > 2 { return String(argument.dropFirst(2)) }
                return index + 1 < arguments.count ? arguments[index + 1] : nil
            }
            // 옵션이 끝나고 명령(`new` · `attach` …)이 시작되면 그 뒤의 `-L` 은 tmux 의 것이 아니다.
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

    /// tmux 클라이언트 프로세스가 보고 있는 칸의 에이전트.
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
}

extension Detector {
    public static let weztermBundleID = "com.github.wez.wezterm"
    public static let kittyBundleID = "net.kovidgoyal.kitty"

    /// 터미널 앱이 알려 준 «그 세션의 프로세스들» 로 에이전트를 안다. 거기서 tmux 가 돌고 있으면 그 클라이언트가 보고 있는 칸으로 들어간다.
    static func session(host: TerminalHost, appName: String, label: String,
                        table: (entries: [ProcessTable.Entry], parents: [Int32: Int32]), device: UInt32) throws -> Target {
        let attached = table.entries.filter { $0.terminalDevice == device }
        // tmux 클라이언트가 그 터미널의 «앞 작업» 일 때만 tmux 로 들어간다. `suspend-client` 나 Ctrl-Z 로 멈춰 둔 클라이언트는
        // 그 tty 에 남아 있지만 화면에는 셸이 보인다 — 그 뒤의 tmux 칸은 보이지 않는 세션이다(PR #25 리뷰).
        if let client = attached.first(where: { TTYProcesses.isTmuxClient($0) && $0.isForeground }) {
            return try TmuxFront.target(client: client, table: table, outer: appName)
        }
        guard let agent = TTYProcesses.agent(in: attached, parents: table.parents) else {
            throw SlashCommandError(loc("The frontmost %@ terminal (%@) is not a supported agent session (Claude Code · Codex · Grok · Cursor · Antigravity · OpenCode).", appName, label))
        }
        return Target(host: host, agent: agent, label: label)
    }

    /// `frontPID` 는 맨 앞 WezTerm GUI 의 pid.
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

    /// `frontPID` 는 맨 앞 kitty 의 pid(kitty 를 둘 이상 띄웠을 때 그 kitty 의 소켓을 고른다).
    public static func kitty(frontPID: Int32? = nil) throws -> Target {
        guard let kitty = Proc.locate("kitty", extra: ["/Applications/kitty.app/Contents/MacOS"]) else {
            throw SlashCommandError(loc("The kitty command was not found."))
        }
        let table = ProcessTable.snapshot()
        // 맨 앞 kitty 를 알면 그 kitty 의 소켓만 본다 — 원격 제어 없이 뜬 kitty 가 맨 앞일 때 다른 kitty 의 창으로 가지 않는다.
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
        // 그 창의 tty: 창의 프로세스들이 붙어 있는 터미널.
        guard let device = table.entries.first(where: { window.pids.contains($0.pid) })?.terminalDevice else {
            throw SlashCommandError(loc("The frontmost %@ terminal (%@) is not a supported agent session (Claude Code · Codex · Grok · Cursor · Antigravity · OpenCode).", "kitty", window.title))
        }
        return try session(host: .kitty(socket: socket, window: window.id), appName: "kitty", label: window.title, table: table, device: device)
    }
}
