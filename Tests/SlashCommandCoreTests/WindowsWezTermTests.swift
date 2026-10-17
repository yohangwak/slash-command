import XCTest
#if os(Windows)
import WinSDK
#endif
@testable import SlashCommandCore

final class WindowsWezTermTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
    }
    private func clients(_ json: String) -> Data { Data(json.utf8) }
    // Headless Windows capture has no GUI clients. Non-empty rows below are synthetic
    // variations of the installed version's list-clients serialization (pid/focused_pane_id).
    func testRealWindowsPaneHasNoTTYOrProcessID() throws {
        let data = try fixture("windows-wezterm-panes")
        XCTAssertEqual(WindowsWezTerm.pane(in: data, id: 0), .init(id: "0", title: "Test shell", cwd: "file:///C:/test/"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertTrue(rows[0]["tty_name"] is NSNull)
        XCTAssertNil(rows[0]["pid"])
        XCTAssertNil(rows[0]["process_id"])
    }
    func testRealHeadlessMuxHasNoFocusedGUI() throws {
        XCTAssertNil(WindowsWezTerm.focusedPane(clients: try fixture("windows-wezterm-clients"), panes: try fixture("windows-wezterm-panes"), frontPID: nil))
    }
    func testWindowsFocusWorksWithoutTTY() throws {
        let data = try fixture("windows-wezterm-panes")
        let rows = clients(#"[{"pid":42,"focused_pane_id":0,"idle_time":{"secs":1,"nanos":0}}]"#)
        XCTAssertEqual(WindowsWezTerm.focusedPane(clients: rows, panes: data, frontPID: 42)?.id, "0")
        XCTAssertEqual(WindowsWezTerm.focusedPane(clients: rows, panes: data, frontPID: nil)?.title, "Test shell")
    }
    func testFocusedGUIWinsOverInputRecencyAndActiveTabFlags() {
        let panes = clients(#"[{"pane_id":0,"title":"A","is_active":true},{"pane_id":1,"title":"B","is_active":true}]"#)
        let rows = clients(#"[{"pid":42,"focused_pane_id":0,"idle_time":{"secs":0}},{"pid":99,"focused_pane_id":1,"idle_time":{"secs":100}}]"#)
        XCTAssertEqual(WindowsWezTerm.focusedPane(clients: rows, panes: panes, frontPID: 99)?.title, "B")
        XCTAssertNil(WindowsWezTerm.focusedPane(clients: rows, panes: panes, frontPID: nil))
        XCTAssertNil(WindowsWezTerm.focusedPane(clients: rows, panes: panes, frontPID: 12))
    }
    func testNullOrInvalidFocusDoesNotGuessActivePane() throws {
        for focus in ["null", "true", "false", "-1", "0.5", "\"0\"", "999"] {
            XCTAssertNil(WindowsWezTerm.focusedPane(clients: clients("[{\"pid\":42,\"focused_pane_id\":\(focus)}]"), panes: try fixture("windows-wezterm-panes"), frontPID: 42), focus)
        }
    }
    func testDuplicateClientOrPaneIsAmbiguous() throws {
        let row = #"{"pid":42,"focused_pane_id":0}"#
        XCTAssertNil(WindowsWezTerm.focusedPane(clients: clients("[\(row),\(row)]"), panes: try fixture("windows-wezterm-panes"), frontPID: 42))
        XCTAssertNil(WindowsWezTerm.pane(in: clients(#"[{"pane_id":0},{"pane_id":0}]"#), id: 0))
    }
    func testMalformedJSONFailsClosed() throws {
        for json in ["", "{", "null", "{}", "[null]"] {
            XCTAssertNil(WindowsWezTerm.focusedPane(clients: clients(json), panes: try fixture("windows-wezterm-panes"), frontPID: 42))
            XCTAssertNil(WindowsWezTerm.pane(in: clients(json), id: 0))
        }
    }
    func testSocketSelectionUsesExactPIDAndNeverFallsBack() {
        let home = URL(fileURLWithPath: "/test-home")
        let expected = home.appendingPathComponent(".local/share/wezterm/gui-sock-42").path
        var checked: [String] = []
        XCTAssertEqual(WindowsWezTerm.socket(ofGUI: 42, home: home, exists: { checked.append($0); return $0 == expected }), expected)
        XCTAssertEqual(checked, [expected])
        XCTAssertNil(WindowsWezTerm.socket(ofGUI: 99, home: home, exists: { $0 == expected }))
        XCTAssertNil(WindowsWezTerm.socket(ofGUI: 0, home: home, exists: { _ in true }))
    }
    func testAgentDetectionRequiresVisibleUniqueInput() throws {
        func screen(_ name: String) throws -> [String] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
            return try XCTUnwrap(json["tail"] as? [String])
        }
        XCTAssertEqual(WindowsWezTerm.agent(screen: try screen("claude-idle")), .claude)
        XCTAssertEqual(WindowsWezTerm.agent(screen: try screen("codex-idle")), .codex)
        XCTAssertNil(WindowsWezTerm.agent(screen: try screen("claude-permission")))
        XCTAssertNil(WindowsWezTerm.agent(screen: ["C:\\test> echo claude codex", "claude codex", "C:\\test>"]))
        XCTAssertNil(WindowsWezTerm.agent(screen: []))
        XCTAssertNil(WindowsWezTerm.agent(screen: nil))
    }
    func testTrayIdentifiesOnlyGUIExecutable() {
        for image in ["wezterm-gui.exe", #"C:\Program Files\WezTerm\WEZTERM-GUI.EXE"#] {
            XCTAssertTrue(WindowsAppModel.supports(image: image))
            XCTAssertEqual(WindowsAppModel.app(image: image), "wezterm")
        }
        for image in ["wezterm.exe", "wezterm-mux-server.exe", "wezterm-gui.exe.bak"] { XCTAssertFalse(WindowsAppModel.supports(image: image)) }
    }
    func testWezTermMenuAndNoticeDoNotMentionOrcaLag() {
        L10n.use(language: "en", directory: nil)
        let target = Target(host: .wezterm(socket: "test", pane: "0"), agent: .claude, label: "Test shell")
        XCTAssertEqual(WindowsAppModel.targetLine(target), "Claude Code · WezTerm · Test shell")
        let menu = WindowsAppModel.menu(config: .starter, supported: true, agent: .claude, terminal: target.label, appName: "WezTerm")
        XCTAssertEqual(menu[0], "WezTerm · Claude Code · Test shell")
        XCTAssertEqual(menu.filter { $0.first?.isNumber == true }.count, 9)
        let result = SwitchResult(target: target, slotName: "", preset: .init(model: "opus", effort: "high"), warning: nil, confirmations: [], pendingRestore: nil)
        XCTAssertFalse(WindowsAppModel.hud(result: result, tabLagNote: true).text.contains("Orca"))
        XCTAssertTrue(WindowsAppModel.appliedLine(id: 1, result: result).contains("claude@WezTerm"))
    }

    #if os(Windows)
    func testAUnixSocketFileCountsAsPresent() throws {
        // WezTerm's gui-sock-<pid> is an AF_UNIX socket; on Windows that file is a reparse point.
        var data = WSADATA()
        XCTAssertEqual(WSAStartup(0x0202, &data), 0)
        defer { WSACleanup() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("gui-sock-1").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertNotEqual(fd, INVALID_SOCKET)
        defer { closesocket(fd) }
        var address = sockaddr_un()
        address.sun_family = ADDRESS_FAMILY(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in bytes.prefix(buffer.count - 1).enumerated() { buffer[i] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, Int32(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0, "bind an AF_UNIX socket file")
        XCTAssertTrue(WindowsWezTerm.pathExists(path), "the socket file must count as present")
        XCTAssertFalse(WindowsWezTerm.pathExists(path + "-missing"))
        print("FileManager.fileExists on the socket: \(FileManager.default.fileExists(atPath: path))")
    }
    #endif
}
