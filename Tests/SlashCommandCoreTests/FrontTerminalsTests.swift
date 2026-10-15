import XCTest
@testable import SlashCommandCore

/// Finding the frontmost session (WezTerm, kitty, and tmux inside them). The JSON is a trimmed copy of what was captured on a test Mac on 2026-10-12.
final class FrontTerminalsTests: XCTestCase {
    /// If `foreground` is false it is not that terminal's foreground job (suspended with Ctrl-Z or `tmux suspend-client`).
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
                       "Without knowing the frontmost GUI, only when there is a single client")
    }

    func testWezTermTakesTheFrontmostGUINotTheLastTypedIn() {
        // Two GUIs share one mux. Type in A, then move only the focus to B: A's idle is shorter, but the frontmost is B (PR #25 review).
        let clients = wezClients([(100, 0, 2), (200, 1, 900)])
        XCTAssertEqual(WezTermFront.focusedPane(clients: clients, panes: Data(wezPanes.utf8), frontPID: 200)?.id, "1")
        XCTAssertEqual(WezTermFront.focusedPane(clients: clients, panes: Data(wezPanes.utf8), frontPID: 100)?.id, "0")
        XCTAssertNil(WezTermFront.focusedPane(clients: clients, panes: Data(wezPanes.utf8), frontPID: nil), "Does not pick when it does not know which GUI is in front")
        XCTAssertNil(WezTermFront.focusedPane(clients: clients, panes: Data(wezPanes.utf8), frontPID: 300), "The frontmost GUI's client is not in the list")
    }

    func testWezTermWithNothingToGoOn() {
        XCTAssertNil(WezTermFront.focusedPane(clients: wezClients([(1, 7, 1)]), panes: Data(wezPanes.utf8), frontPID: 1), "A pane not in the list")
        XCTAssertNil(WezTermFront.focusedPane(clients: wezClients([(1, nil, 1)]), panes: Data(wezPanes.utf8), frontPID: 1), "Does not know the focused pane")
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
        XCTAssertNil(WezTermFront.socket(ofGUI: 9, home: home), "Without that GUI's socket, wezterm cli's default")
        XCTAssertNil(WezTermFront.socket(ofGUI: nil, home: home))
        XCTAssertNil(WezTermFront.environment(socket: nil))
        XCTAssertEqual(WezTermFront.environment(socket: "/x/gui-sock-1")?["WEZTERM_UNIX_SOCKET"], "/x/gui-sock-1")
    }

    // MARK: kitty

    func testKittyBoundSockets() {
        // 2026-10-12 test Mac: `lsof -a -p <pid> -U -Fn`. A kitty with remote control on and one without.
        XCTAssertEqual(KittyFront.boundSockets(lsofOutput: "p33356\nf4\nn->0xd1dda1117d7f9d95\nf9\nn/tmp/sc-kitty\n"), ["unix:/tmp/sc-kitty"])
        XCTAssertEqual(KittyFront.boundSockets(lsofOutput: "p2111\nf4\nn->0xd1dda1117d7f9d95\n"), [], "Only unnamed sockets — remote control is off")
        XCTAssertEqual(KittyFront.boundSockets(lsofOutput: "p7\nf9\nn/Users/me/kitty.sock\nf10\nn/Users/me/kitty.sock\nf11\nn/private/tmp/kitty-7\n"),
                       ["unix:/Users/me/kitty.sock", "unix:/private/tmp/kitty-7"], "The address actually open, wherever the config is")
        XCTAssertEqual(KittyFront.boundSockets(lsofOutput: ""), [])
    }

    private func kittyLS(focusedOS: [Bool], focusedTab: Int = 0) -> Data {
        // The real output's `env` (the window's whole environment) is not included.
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
        XCTAssertNil(KittyFront.focusedWindow(ls: kittyLS(focusedOS: [false, false])), "Does not know which window is in front")
        XCTAssertEqual(KittyFront.focusedWindow(ls: kittyLS(focusedOS: [false]))?.id, "1", "With a single window, it is that window even if kitty is behind")
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
        XCTAssertEqual(TmuxFront.socket(clientArguments: ["tmux", "-f", "/tmp/-L.conf", "-L", "two"]), "two", "Skips the values of other options")
        XCTAssertNil(TmuxFront.socket(clientArguments: ["tmux", "new", "-s", "x", "-L"]), "What follows the command is not a tmux option")
    }

    func testTmuxSocketArguments() {
        XCTAssertEqual(TmuxFront.arguments(socket: nil), [])
        XCTAssertEqual(TmuxFront.arguments(socket: "scfront"), ["-L", "scfront"])
        XCTAssertEqual(TmuxFront.arguments(socket: "/tmp/my.sock"), ["-S", "/tmp/my.sock"])
    }

    func testTmuxWriteRefusesSynchronizedPanes() {
        // The check (`#{pane_synchronized}`) and the write are one tmux command — when it is on, it does not write and prints a marker.
        let arguments = TmuxIO.sendArguments(pane: "%5", bytes: "/m\r")
        XCTAssertEqual(arguments, ["if-shell", "-F", "-t", "%5", "#{pane_synchronized}",
                                   "display-message -p \(TmuxIO.synchronizedMark)", "send-keys -t '%5' -H 2f 6d 0d"])
        XCTAssertEqual(TmuxIO.sendArguments(pane: "my work:0.1", bytes: "a").last, "send-keys -t 'my work:0.1' -H 61")
        XCTAssertEqual(TmuxIO.quoted("it's"), "'it'\\''s'")
    }

    // MARK: Processes in that terminal

    func testAgentOnATerminal() {
        let shell = entry(10, device: 7, "-zsh")
        let claude = entry(11, parent: 10, device: 7, "claude")
        let inner = entry(12, parent: 11, device: 7, "codex", "exec", "x")
        let parents: [Int32: Int32] = [10: 1, 11: 10, 12: 11]
        XCTAssertEqual(TTYProcesses.agent(in: [shell, claude, inner], parents: parents), .claude, "An agent started by an agent is not counted")
        XCTAssertNil(TTYProcesses.agent(in: [shell], parents: parents))
        XCTAssertTrue(TTYProcesses.isTmuxClient(entry(20, device: 7, "/opt/homebrew/bin/tmux", "-L", "x", "attach")))
        XCTAssertFalse(TTYProcesses.isTmuxClient(claude))
    }

    func testSessionOfATerminal() throws {
        let table: (entries: [ProcessTable.Entry], parents: [Int32: Int32]) = (
            [entry(10, device: 7, "-zsh"), entry(11, parent: 10, device: 7, "codex"), entry(30, device: 9, "-zsh"), entry(31, parent: 30, device: 9, "claude")],
            [10: 1, 11: 10, 30: 1, 31: 30])
        let target = try Detector.session(host: .wezterm(socket: nil, pane: "1"), appName: "WezTerm", label: "Repos", table: table, device: 7)
        XCTAssertEqual(target, Target(host: .wezterm(socket: nil, pane: "1"), agent: .codex, label: "Repos"), "Agents in other terminals are ignored")
        XCTAssertThrowsError(try Detector.session(host: .wezterm(socket: nil, pane: "2"), appName: "WezTerm", label: "zsh", table: table, device: 8))
    }

    func testSuspendedTmuxClientIsNotTheSessionInFront() throws {
        // `tmux suspend-client` (or Ctrl-Z): the client stays on that tty but the screen shows a shell. Do not go into the tmux pane behind it (PR #25 review).
        let suspended = entry(21, parent: 20, device: 7, foreground: false, "tmux", "-L", "x", "attach")
        let shellOnly: (entries: [ProcessTable.Entry], parents: [Int32: Int32]) = ([entry(20, device: 7, "-zsh"), suspended], [20: 1, 21: 20])
        XCTAssertThrowsError(try Detector.session(host: .wezterm(socket: nil, pane: "0"), appName: "WezTerm", label: "zsh", table: shellOnly, device: 7)) { error in
            XCTAssertEqual((error as? SlashCommandError)?.message,
                           loc("The frontmost %@ terminal (%@) is not a supported agent session (Claude Code · Codex · Grok · Cursor · Antigravity · OpenCode).", "WezTerm", "zsh"))
        }
        // If an agent was started in that shell after suspending, what is visible is that agent — the outer terminal is the target.
        let withAgent: (entries: [ProcessTable.Entry], parents: [Int32: Int32]) = (shellOnly.entries + [entry(22, parent: 20, device: 7, "claude")], [20: 1, 21: 20, 22: 20])
        XCTAssertEqual(try Detector.session(host: .wezterm(socket: nil, pane: "0"), appName: "WezTerm", label: "zsh", table: withAgent, device: 7).host,
                       .wezterm(socket: nil, pane: "0"))
    }

    // MARK: Clipped picker in a short window

    struct Fixture: Decodable { let tail: [String] }

    func testPickerWhoseHintRowIsCutOff() throws {
        // 2026-10-12 test Mac, claude 2.1.295 in an 11-line tmux pane: the hint line at the bottom of the picker is not drawn.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "claude-picker-clipped", withExtension: "json", subdirectory: "Fixtures"))
        let lines = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tail
        XCTAssertNil(Picker.open(lines), "Without the hint line it is not read as an open picker")
        XCTAssertTrue(Picker.clipped(lines, header: "Select model"))
        XCTAssertFalse(Picker.clipped(lines, header: "Select Model and Effort"), "Header of a different picker")
        XCTAssertFalse(Picker.clipped(["  Select model", "  some text", "❯ "], header: "Select model"), "No row has the cursor")
        let whole = lines + ["   Enter to set as default · s to use this session only · Esc to cancel"]
        XCTAssertNotNil(Picker.open(whole))
        XCTAssertFalse(Picker.clipped(whole, header: "Select model"), "If the hint line is visible it is not clipped")
    }

    func testTerminalDevice() {
        XCTAssertNotNil(TTYProcesses.device(ofTTY: "/dev/null"), "Character device")
        XCTAssertNil(TTYProcesses.device(ofTTY: "/dev/ttys-nope"))
        XCTAssertNil(TTYProcesses.device(ofTTY: "/tmp"), "Not a device")
    }

    // MARK: tmux inside Orca

    private func orcaEntry(_ pid: Int32, parent: Int32, handle: String = "term_A", device: UInt32, foreground: Bool = true, _ arguments: String...) -> ProcessTable.Entry {
        ProcessTable.Entry(pid: pid, parent: parent, hasTerminal: true, terminalDevice: device,
                           processGroup: pid, foregroundGroup: foreground ? pid : pid + 1000,
                           arguments: arguments, environment: ["HOME=/Users/x", "ORCA_TERMINAL_HANDLE=\(handle)"], executable: "")
    }

    /// Terminal A (tty 1): shell 100 → tmux client 110. tmux server 200 (no terminal — not in the list) → pane shell 210 (tty 2) → claude 220,
    /// and a client 230 started again inside the pane. The server was started from A, so the pane's processes carry the same handle.
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
                       "That terminal's client, not the client (230) started again inside the pane")
        XCTAssertNil(AgentProcesses.tmuxClient(orcaHandle: "term_B", entries: t.entries, parents: t.parents, isTmux: t.isTmux), "Another terminal")
    }

    func testSuspendedOrDetachedTmuxIsNotFollowedInOrca() {
        var t = orcaTmux
        // A client stopped with Ctrl-Z: not the foreground job.
        t.entries[1] = orcaEntry(110, parent: 100, device: 1, foreground: false, "tmux", "-L", "work", "attach")
        XCTAssertNil(AgentProcesses.tmuxClient(orcaHandle: "term_A", entries: t.entries, parents: t.parents, isTmux: t.isTmux))
        // Then the claude inside the pane (which inherited the same handle) is not counted as this terminal's agent — the screen shows a shell.
        XCTAssertNil(AgentProcesses.agent(orcaHandle: "term_A", entries: t.entries, parents: t.parents, isTmux: t.isTmux))
        // Positive control: an agent running directly outside tmux is counted.
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

    /// When the same terminal app is launched twice: a frontmost pid known to the caller wins. The running-app list is consulted only when it is unknown
    /// (measured 2026-10-13 — the «active» process picked from the list was the one launched first, so the shortcut went to its shell).
    func testTheFrontProcessTheCallerKnowsWins() {
        var asked: [String] = []
        let active: (String) -> Int32? = { asked.append($0); return 1667 }
        XCTAssertEqual(Detector.frontProcess(known: 84481, bundleID: Detector.weztermBundleID, active: active), 84481)
        XCTAssertEqual(asked, [], "With a known pid the list is not consulted")
        XCTAssertEqual(Detector.frontProcess(known: nil, bundleID: Detector.kittyBundleID, active: active), 1667)
        XCTAssertEqual(asked, [Detector.kittyBundleID])
    }
}
