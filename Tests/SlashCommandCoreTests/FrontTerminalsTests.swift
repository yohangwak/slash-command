import XCTest
@testable import SlashCommandCore

/// 맨 앞 세션 찾기(WezTerm · kitty · 그 안의 tmux). JSON 은 2026-10-12 집 맥 2 에서 받은 것을 줄인 것이다.
final class FrontTerminalsTests: XCTestCase {
    /// `foreground` 가 false 면 그 터미널의 앞 작업이 아니다(Ctrl-Z · `tmux suspend-client` 로 멈춰 둔 것).
    private func entry(_ pid: Int32, parent: Int32 = 1, device: UInt32, foreground: Bool = true, _ arguments: String...) -> ProcessTable.Entry {
        ProcessTable.Entry(pid: pid, parent: parent, hasTerminal: true, terminalDevice: device,
                           processGroup: pid, foregroundGroup: foreground ? pid : pid + 1000,
                           arguments: arguments, environment: [], executable: "")
    }

    // MARK: WezTerm

    private let wezPanes = """
    [{"window_id":0,"tab_id":0,"pane_id":0,"workspace":"default","title":"tmux","cwd":"file:///Users/me","is_active":true,"tty_name":"/dev/ttys000"},
     {"window_id":0,"tab_id":1,"pane_id":1,"workspace":"default","title":"Repos","cwd":"file:///Users/me/Repos","is_active":true,"tty_name":"/dev/ttys006"}]
    """

    private func wezClients(_ rows: [(pid: Int, focused: Int?, idle: Int)]) -> Data {
        let items = rows.map { row in
            "{\"username\":\"me\",\"pid\":\(row.pid),\"idle_time\":{\"secs\":\(row.idle),\"nanos\":5},\"workspace\":\"default\",\"focused_pane_id\":\(row.focused.map(String.init) ?? "null")}"
        }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }

    func testWezTermFocusedPane() {
        let pane = WezTermFront.focusedPane(clients: wezClients([(1667, 1, 3)]), panes: Data(wezPanes.utf8), frontPID: 1667)
        XCTAssertEqual(pane, WezTermFront.Pane(id: "1", tty: "/dev/ttys006", title: "Repos"))
        XCTAssertEqual(WezTermFront.focusedPane(clients: wezClients([(1667, 0, 3)]), panes: Data(wezPanes.utf8), frontPID: nil)?.tty, "/dev/ttys000",
                       "맨 앞 GUI 를 모를 때는 클라이언트가 하나뿐일 때만")
    }

    func testWezTermTakesTheFrontmostGUINotTheLastTypedIn() {
        // GUI 둘이 한 mux 를 같이 쓴다. A 에 글자를 치고 B 로 포커스만 옮기면 A 의 idle 이 더 짧다 — 맨 앞은 B 다(PR #25 리뷰).
        let clients = wezClients([(100, 0, 2), (200, 1, 900)])
        XCTAssertEqual(WezTermFront.focusedPane(clients: clients, panes: Data(wezPanes.utf8), frontPID: 200)?.id, "1")
        XCTAssertEqual(WezTermFront.focusedPane(clients: clients, panes: Data(wezPanes.utf8), frontPID: 100)?.id, "0")
        XCTAssertNil(WezTermFront.focusedPane(clients: clients, panes: Data(wezPanes.utf8), frontPID: nil), "어느 GUI 가 맨 앞인지 모르면 고르지 않는다")
        XCTAssertNil(WezTermFront.focusedPane(clients: clients, panes: Data(wezPanes.utf8), frontPID: 300), "맨 앞 GUI 의 클라이언트가 목록에 없다")
    }

    func testWezTermWithNothingToGoOn() {
        XCTAssertNil(WezTermFront.focusedPane(clients: wezClients([(1, 7, 1)]), panes: Data(wezPanes.utf8), frontPID: 1), "목록에 없는 pane")
        XCTAssertNil(WezTermFront.focusedPane(clients: wezClients([(1, nil, 1)]), panes: Data(wezPanes.utf8), frontPID: 1), "포커스 pane 을 모른다")
        XCTAssertNil(WezTermFront.focusedPane(clients: Data("[]".utf8), panes: Data(wezPanes.utf8), frontPID: nil))
        XCTAssertNil(WezTermFront.focusedPane(clients: Data("not json".utf8), panes: Data(wezPanes.utf8), frontPID: nil))
    }

    func testWezTermSocketOfAGUI() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("wez-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".local/share/wezterm")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("gui-sock-1667"))
        XCTAssertEqual(WezTermFront.socket(ofGUI: 1667, home: home), folder.appendingPathComponent("gui-sock-1667").path)
        XCTAssertNil(WezTermFront.socket(ofGUI: 9, home: home), "그 GUI 의 소켓이 없으면 wezterm cli 의 기본대로")
        XCTAssertNil(WezTermFront.socket(ofGUI: nil, home: home))
        XCTAssertNil(WezTermFront.environment(socket: nil))
        XCTAssertEqual(WezTermFront.environment(socket: "/x/gui-sock-1")?["WEZTERM_UNIX_SOCKET"], "/x/gui-sock-1")
    }

    // MARK: kitty

    func testKittyBoundSockets() {
        // 2026-10-12 집 맥 2: `lsof -a -p <pid> -U -Fn`. 원격 제어를 켠 kitty 와 켜지 않은 kitty.
        XCTAssertEqual(KittyFront.boundSockets(lsofOutput: "p33356\nf4\nn->0xd1dda1117d7f9d95\nf9\nn/tmp/sc-kitty\n"), ["unix:/tmp/sc-kitty"])
        XCTAssertEqual(KittyFront.boundSockets(lsofOutput: "p2111\nf4\nn->0xd1dda1117d7f9d95\n"), [], "이름 없는 소켓뿐 — 원격 제어가 꺼져 있다")
        XCTAssertEqual(KittyFront.boundSockets(lsofOutput: "p7\nf9\nn/Users/me/kitty.sock\nf10\nn/Users/me/kitty.sock\nf11\nn/private/tmp/kitty-7\n"),
                       ["unix:/Users/me/kitty.sock", "unix:/private/tmp/kitty-7"], "설정이 어디에 있든, 실제로 열린 주소")
        XCTAssertEqual(KittyFront.boundSockets(lsofOutput: ""), [])
    }

    private func kittyLS(focusedOS: [Bool], focusedTab: Int = 0) -> Data {
        // 실제 출력의 `env`(그 창의 환경변수 전체)는 넣지 않았다.
        let windows = focusedOS.enumerated().map { index, focused -> String in
            let base = index * 10
            return """
            {"id":\(index + 1),"is_focused":\(focused),"is_active":true,"tabs":[
              {"id":\(base + 1),"is_focused":\(focused && focusedTab == 0),"is_active":\(focusedTab == 0),"windows":[
                {"id":\(base + 1),"is_focused":\(focused && focusedTab == 0),"is_active":true,"pid":\(3000 + base),"title":"sc-front",
                 "foreground_processes":[{"cmdline":["codex"],"cwd":"/tmp","pid":\(3001 + base)}]}]},
              {"id":\(base + 2),"is_focused":\(focused && focusedTab == 1),"is_active":\(focusedTab == 1),"windows":[
                {"id":\(base + 2),"is_focused":\(focused && focusedTab == 1),"is_active":true,"pid":\(3005 + base),"title":"/tmp",
                 "foreground_processes":[{"cmdline":["-zsh"],"cwd":"/tmp","pid":\(3005 + base)}]}]}]}
            """
        }
        return Data("[\(windows.joined(separator: ","))]".utf8)
    }

    func testKittyFocusedWindowFollowsTheFocusedTab() {
        XCTAssertEqual(KittyFront.focusedWindow(ls: kittyLS(focusedOS: [true])), KittyFront.Window(id: "1", title: "sc-front", pids: [3000, 3001]))
        XCTAssertEqual(KittyFront.focusedWindow(ls: kittyLS(focusedOS: [true], focusedTab: 1)), KittyFront.Window(id: "2", title: "/tmp", pids: [3005]))
    }

    func testKittyWithSeveralOSWindows() {
        XCTAssertEqual(KittyFront.focusedWindow(ls: kittyLS(focusedOS: [false, true]))?.id, "11")
        XCTAssertNil(KittyFront.focusedWindow(ls: kittyLS(focusedOS: [false, false])), "어느 창이 맨 앞인지 모른다")
        XCTAssertEqual(KittyFront.focusedWindow(ls: kittyLS(focusedOS: [false]))?.id, "1", "창이 하나뿐이면 kitty 가 뒤에 있어도 그 창이다")
        XCTAssertNil(KittyFront.focusedWindow(ls: Data("{}".utf8)))
    }

    // MARK: tmux

    func testTmuxClientList() {
        let output = "53911\t%1\t/dev/ttys005\tsc:0.1\n700\t%4\t/dev/ttys009\twork:2.0\nbroken line\n"
        XCTAssertEqual(TmuxFront.clients(listOutput: output), [
            TmuxFront.Client(pid: 53911, pane: "%1", paneTTY: "/dev/ttys005", name: "sc:0.1"),
            TmuxFront.Client(pid: 700, pane: "%4", paneTTY: "/dev/ttys009", name: "work:2.0"),
        ])
    }

    func testTmuxSocketOfAClient() {
        XCTAssertNil(TmuxFront.socket(clientArguments: ["tmux"]))
        XCTAssertNil(TmuxFront.socket(clientArguments: ["tmux", "attach", "-t", "work"]))
        XCTAssertEqual(TmuxFront.socket(clientArguments: ["tmux", "-L", "scfront", "new", "-s", "sc"]), "scfront")
        XCTAssertEqual(TmuxFront.socket(clientArguments: ["/opt/homebrew/bin/tmux", "-Lscfront", "attach"]), "scfront")
        XCTAssertEqual(TmuxFront.socket(clientArguments: ["tmux", "-u", "-S", "/tmp/my.sock", "attach"]), "/tmp/my.sock")
        XCTAssertEqual(TmuxFront.socket(clientArguments: ["tmux", "-f", "/tmp/-L.conf", "-L", "two"]), "two", "다른 옵션의 값은 건너뛴다")
        XCTAssertNil(TmuxFront.socket(clientArguments: ["tmux", "new", "-s", "x", "-L"]), "명령 뒤의 것은 tmux 의 옵션이 아니다")
    }

    func testTmuxSocketArguments() {
        XCTAssertEqual(TmuxFront.arguments(socket: nil), [])
        XCTAssertEqual(TmuxFront.arguments(socket: "scfront"), ["-L", "scfront"])
        XCTAssertEqual(TmuxFront.arguments(socket: "/tmp/my.sock"), ["-S", "/tmp/my.sock"])
    }

    func testTmuxWriteRefusesSynchronizedPanes() {
        // 확인(`#{pane_synchronized}`)과 쓰기가 tmux 의 한 명령이다 — 켜져 있으면 쓰지 않고 표지를 찍는다.
        let arguments = TmuxIO.sendArguments(pane: "%5", bytes: "/m\r")
        XCTAssertEqual(arguments, ["if-shell", "-F", "-t", "%5", "#{pane_synchronized}",
                                   "display-message -p \(TmuxIO.synchronizedMark)", "send-keys -t '%5' -H 2f 6d 0d"])
        XCTAssertEqual(TmuxIO.sendArguments(pane: "my work:0.1", bytes: "a").last, "send-keys -t 'my work:0.1' -H 61")
        XCTAssertEqual(TmuxIO.quoted("it's"), "'it'\\''s'")
    }

    // MARK: 그 터미널의 프로세스

    func testAgentOnATerminal() {
        let shell = entry(10, device: 7, "-zsh")
        let claude = entry(11, parent: 10, device: 7, "claude")
        let inner = entry(12, parent: 11, device: 7, "codex", "exec", "x")
        let parents: [Int32: Int32] = [10: 1, 11: 10, 12: 11]
        XCTAssertEqual(TTYProcesses.agent(in: [shell, claude, inner], parents: parents), .claude, "에이전트가 띄운 에이전트는 세지 않는다")
        XCTAssertNil(TTYProcesses.agent(in: [shell], parents: parents))
        XCTAssertTrue(TTYProcesses.isTmuxClient(entry(20, device: 7, "/opt/homebrew/bin/tmux", "-L", "x", "attach")))
        XCTAssertFalse(TTYProcesses.isTmuxClient(claude))
    }

    func testSessionOfATerminal() throws {
        let table: (entries: [ProcessTable.Entry], parents: [Int32: Int32]) = (
            [entry(10, device: 7, "-zsh"), entry(11, parent: 10, device: 7, "codex"), entry(30, device: 9, "-zsh"), entry(31, parent: 30, device: 9, "claude")],
            [10: 1, 11: 10, 30: 1, 31: 30])
        let target = try Detector.session(host: .wezterm(socket: nil, pane: "1"), appName: "WezTerm", label: "Repos", table: table, device: 7)
        XCTAssertEqual(target, Target(host: .wezterm(socket: nil, pane: "1"), agent: .codex, label: "Repos"), "다른 터미널의 에이전트는 보지 않는다")
        XCTAssertThrowsError(try Detector.session(host: .wezterm(socket: nil, pane: "2"), appName: "WezTerm", label: "zsh", table: table, device: 8))
    }

    func testSuspendedTmuxClientIsNotTheSessionInFront() throws {
        // `tmux suspend-client`(또는 Ctrl-Z): 클라이언트는 그 tty 에 남아 있지만 화면에는 셸이 보인다. 그 뒤의 tmux 칸으로 들어가지 않는다(PR #25 리뷰).
        let suspended = entry(21, parent: 20, device: 7, foreground: false, "tmux", "-L", "x", "attach")
        let shellOnly: (entries: [ProcessTable.Entry], parents: [Int32: Int32]) = ([entry(20, device: 7, "-zsh"), suspended], [20: 1, 21: 20])
        XCTAssertThrowsError(try Detector.session(host: .wezterm(socket: nil, pane: "0"), appName: "WezTerm", label: "zsh", table: shellOnly, device: 7)) { error in
            XCTAssertEqual((error as? SlashCommandError)?.message,
                           loc("The frontmost %@ terminal (%@) is not a supported agent session (Claude Code · Codex · Grok · Cursor · Antigravity · OpenCode).", "WezTerm", "zsh"))
        }
        // 멈춰 둔 뒤 그 셸에서 에이전트를 띄웠으면, 보이는 것은 그 에이전트다 — 바깥 터미널이 대상이다.
        let withAgent: (entries: [ProcessTable.Entry], parents: [Int32: Int32]) = (shellOnly.entries + [entry(22, parent: 20, device: 7, "claude")], [20: 1, 21: 20, 22: 20])
        XCTAssertEqual(try Detector.session(host: .wezterm(socket: nil, pane: "0"), appName: "WezTerm", label: "zsh", table: withAgent, device: 7).host,
                       .wezterm(socket: nil, pane: "0"))
    }

    // MARK: 낮은 창의 잘린 선택창

    struct Fixture: Decodable { let tail: [String] }

    func testPickerWhoseHintRowIsCutOff() throws {
        // 2026-10-12 집 맥 2, 11줄짜리 tmux 칸의 claude 2.1.295: 선택창의 맨 아래 안내 줄이 그려지지 않는다.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "claude-picker-clipped", withExtension: "json", subdirectory: "Fixtures"))
        let lines = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tail
        XCTAssertNil(Picker.open(lines), "안내 줄이 없어 열린 선택창으로는 읽히지 않는다")
        XCTAssertTrue(Picker.clipped(lines, header: "Select model"))
        XCTAssertFalse(Picker.clipped(lines, header: "Select Model and Effort"), "다른 선택창의 머리말")
        XCTAssertFalse(Picker.clipped(["  Select model", "  some text", "❯ "], header: "Select model"), "커서가 놓인 행이 없다")
        let whole = lines + ["   Enter to set as default · s to use this session only · Esc to cancel"]
        XCTAssertNotNil(Picker.open(whole))
        XCTAssertFalse(Picker.clipped(whole, header: "Select model"), "안내 줄이 보이면 잘린 것이 아니다")
    }

    func testTerminalDevice() {
        XCTAssertNotNil(TTYProcesses.device(ofTTY: "/dev/null"), "문자 장치")
        XCTAssertNil(TTYProcesses.device(ofTTY: "/dev/ttys-nope"))
        XCTAssertNil(TTYProcesses.device(ofTTY: "/tmp"), "장치가 아니다")
    }

    // MARK: Orca 안의 tmux

    private func orcaEntry(_ pid: Int32, parent: Int32, handle: String = "term_A", device: UInt32, foreground: Bool = true, _ arguments: String...) -> ProcessTable.Entry {
        ProcessTable.Entry(pid: pid, parent: parent, hasTerminal: true, terminalDevice: device,
                           processGroup: pid, foregroundGroup: foreground ? pid : pid + 1000,
                           arguments: arguments, environment: ["HOME=/Users/x", "ORCA_TERMINAL_HANDLE=\(handle)"], executable: "")
    }

    /// 터미널 A(tty 1): 셸 100 → tmux 클라이언트 110. tmux 서버 200(터미널 없음 — 목록에 없다) → 칸의 셸 210(tty 2) → claude 220,
    /// 그리고 칸 안에서 다시 띄운 클라이언트 230. 서버를 A 에서 띄워 칸의 프로세스도 같은 핸들을 갖는다.
    private var orcaTmux: (entries: [ProcessTable.Entry], parents: [Int32: Int32], isTmux: (Int32) -> Bool) {
        let entries = [
            orcaEntry(100, parent: 50, device: 1, foreground: false, "-zsh"),
            orcaEntry(110, parent: 100, device: 1, "tmux", "-L", "work", "attach"),
            orcaEntry(210, parent: 200, device: 2, foreground: false, "-zsh"),
            orcaEntry(220, parent: 210, device: 2, "claude"),
            orcaEntry(230, parent: 210, device: 2, "tmux", "attach"),
        ]
        return (entries, [100: 50, 110: 100, 200: 1, 210: 200, 220: 210, 230: 210, 50: 1], { $0 == 200 })
    }

    func testOrcaTerminalRunningTmuxLeadsToItsClient() {
        let t = orcaTmux
        XCTAssertEqual(AgentProcesses.tmuxClient(orcaHandle: "term_A", entries: t.entries, parents: t.parents, isTmux: t.isTmux)?.pid, 110,
                       "칸 안에서 다시 띄운 클라이언트(230)가 아니라 그 터미널의 클라이언트")
        XCTAssertNil(AgentProcesses.tmuxClient(orcaHandle: "term_B", entries: t.entries, parents: t.parents, isTmux: t.isTmux), "다른 터미널")
    }

    func testSuspendedOrDetachedTmuxIsNotFollowedInOrca() {
        var t = orcaTmux
        // Ctrl-Z 로 멈춰 둔 클라이언트: 앞 작업이 아니다.
        t.entries[1] = orcaEntry(110, parent: 100, device: 1, foreground: false, "tmux", "-L", "work", "attach")
        XCTAssertNil(AgentProcesses.tmuxClient(orcaHandle: "term_A", entries: t.entries, parents: t.parents, isTmux: t.isTmux))
        // 그때 칸 안의 claude(같은 핸들을 물려받았다)를 이 터미널의 에이전트로 세지 않는다 — 화면에는 셸이 보인다.
        XCTAssertNil(AgentProcesses.agent(orcaHandle: "term_A", entries: t.entries, parents: t.parents, isTmux: t.isTmux))
        // 양성 대조군: tmux 밖에서 바로 도는 에이전트는 센다.
        let plain = [orcaEntry(100, parent: 50, device: 1, foreground: false, "-zsh"), orcaEntry(120, parent: 100, device: 1, "codex")]
        XCTAssertEqual(AgentProcesses.agent(orcaHandle: "term_A", entries: plain, parents: [100: 50, 120: 100], isTmux: { _ in false }), .codex)
    }

    func testTmuxExecutable() {
        XCTAssertTrue(TTYProcesses.isTmux(executable: "/opt/homebrew/Cellar/tmux/3.8/bin/tmux"))
        XCTAssertFalse(TTYProcesses.isTmux(executable: "/bin/zsh"))
        XCTAssertFalse(TTYProcesses.isTmux(executable: ""))
    }

    func testNewTerminalsAreHandled() {
        XCTAssertTrue(Detector.supportedBundleIDs.contains(Detector.weztermBundleID))
        XCTAssertTrue(Detector.supportedBundleIDs.contains(Detector.kittyBundleID))
        XCTAssertThrowsError(try Detector.target(bundleID: "com.apple.TextEdit", appName: "TextEdit"))
    }
}
