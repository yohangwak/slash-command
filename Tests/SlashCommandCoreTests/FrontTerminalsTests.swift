import XCTest
@testable import SlashCommandCore

/// 맨 앞 세션 찾기(WezTerm · kitty · 그 안의 tmux). JSON 은 2026-10-12 집 맥 2 에서 받은 것을 줄인 것이다.
final class FrontTerminalsTests: XCTestCase {
    private func entry(_ pid: Int32, parent: Int32 = 1, device: UInt32, _ arguments: String...) -> ProcessTable.Entry {
        ProcessTable.Entry(pid: pid, parent: parent, hasTerminal: true, terminalDevice: device, arguments: arguments, environment: [], executable: "")
    }

    // MARK: WezTerm

    private let wezPanes = """
    [{"window_id":0,"tab_id":0,"pane_id":0,"workspace":"default","title":"tmux","cwd":"file:///Users/me","is_active":true,"tty_name":"/dev/ttys000"},
     {"window_id":0,"tab_id":1,"pane_id":1,"workspace":"default","title":"Repos","cwd":"file:///Users/me/Repos","is_active":true,"tty_name":"/dev/ttys006"}]
    """

    private func wezClients(_ rows: [(focused: Int?, idle: Int)]) -> Data {
        let items = rows.map { row in
            "{\"username\":\"me\",\"pid\":1667,\"idle_time\":{\"secs\":\(row.idle),\"nanos\":5},\"workspace\":\"default\",\"focused_pane_id\":\(row.focused.map(String.init) ?? "null")}"
        }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }

    func testWezTermFocusedPane() {
        let pane = WezTermFront.focusedPane(clients: wezClients([(1, 3)]), panes: Data(wezPanes.utf8))
        XCTAssertEqual(pane, WezTermFront.Pane(id: "1", tty: "/dev/ttys006", title: "Repos"))
        XCTAssertEqual(WezTermFront.focusedPane(clients: wezClients([(0, 3)]), panes: Data(wezPanes.utf8))?.tty, "/dev/ttys000")
    }

    func testWezTermPicksTheMostRecentlyUsedClient() {
        let pane = WezTermFront.focusedPane(clients: wezClients([(0, 900), (1, 2), (nil, 0)]), panes: Data(wezPanes.utf8))
        XCTAssertEqual(pane?.id, "1", "포커스 pane 을 모르는 클라이언트는 세지 않는다")
    }

    func testWezTermWithNothingToGoOn() {
        XCTAssertNil(WezTermFront.focusedPane(clients: wezClients([(7, 1)]), panes: Data(wezPanes.utf8)), "목록에 없는 pane")
        XCTAssertNil(WezTermFront.focusedPane(clients: Data("[]".utf8), panes: Data(wezPanes.utf8)))
        XCTAssertNil(WezTermFront.focusedPane(clients: Data("not json".utf8), panes: Data(wezPanes.utf8)))
    }

    // MARK: kitty

    func testKittySocketFromLaunchArguments() {
        let instances: [(pid: Int32, arguments: [String])] = [
            (2111, ["/Applications/kitty.app/Contents/MacOS/kitty"]),
            (33356, ["/Applications/kitty.app/Contents/MacOS/kitty", "-o", "allow_remote_control=yes", "--listen-on", "unix:/tmp/sc-kitty", "-d", "/tmp"]),
            (400, ["kitty", "--listen-on=unix:/tmp/k-{kitty_pid}"]),
        ]
        XCTAssertEqual(KittyFront.sockets(instances: instances, conf: nil, frontPID: nil), ["unix:/tmp/sc-kitty", "unix:/tmp/k-400"])
        XCTAssertEqual(KittyFront.sockets(instances: instances, conf: nil, frontPID: 33356), ["unix:/tmp/sc-kitty"])
        XCTAssertEqual(KittyFront.sockets(instances: instances, conf: nil, frontPID: 2111), [], "맨 앞 kitty 는 원격 제어 없이 떴다 — 다른 kitty 의 소켓을 쓰지 않는다")
    }

    func testKittySocketFromConf() {
        let instances: [(pid: Int32, arguments: [String])] = [(2111, ["kitty"])]
        let conf = "font_size 13\n# listen_on unix:/tmp/old\nallow_remote_control socket-only\nlisten_on   unix:/tmp/kitty\n"
        XCTAssertEqual(KittyFront.sockets(instances: instances, conf: conf, frontPID: nil), ["unix:/tmp/kitty-2111"], "설정 파일의 값에는 kitty 가 -<pid> 를 붙인다")
        XCTAssertEqual(KittyFront.sockets(instances: instances, conf: "listen_on unix:/tmp/k-{kitty_pid}.sock\n", frontPID: nil), ["unix:/tmp/k-2111.sock"])
        XCTAssertEqual(KittyFront.sockets(instances: instances, conf: "listen_on none\n", frontPID: nil), [])
        XCTAssertEqual(KittyFront.sockets(instances: instances, conf: "listen_on tcp:localhost:5000\n", frontPID: nil), [], "유닉스 소켓만")
        XCTAssertEqual(KittyFront.sockets(instances: [(5, ["kitty", "--listen-on", "unix:/tmp/a"])], conf: conf, frontPID: nil), ["unix:/tmp/a"], "인자가 설정 파일을 이긴다")
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
        let target = try Detector.session(host: .wezterm(pane: "1"), appName: "WezTerm", label: "Repos", table: table, device: 7)
        XCTAssertEqual(target, Target(host: .wezterm(pane: "1"), agent: .codex, label: "Repos"), "다른 터미널의 에이전트는 보지 않는다")
        XCTAssertThrowsError(try Detector.session(host: .wezterm(pane: "2"), appName: "WezTerm", label: "zsh", table: table, device: 8))
    }

    func testTerminalDevice() {
        XCTAssertNotNil(TTYProcesses.device(ofTTY: "/dev/null"), "문자 장치")
        XCTAssertNil(TTYProcesses.device(ofTTY: "/dev/ttys-nope"))
        XCTAssertNil(TTYProcesses.device(ofTTY: "/tmp"), "장치가 아니다")
    }

    func testNewTerminalsAreHandled() {
        XCTAssertTrue(Detector.supportedBundleIDs.contains(Detector.weztermBundleID))
        XCTAssertTrue(Detector.supportedBundleIDs.contains(Detector.kittyBundleID))
        XCTAssertThrowsError(try Detector.target(bundleID: "com.apple.TextEdit", appName: "TextEdit"))
    }
}
