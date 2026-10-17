import XCTest
#if os(Windows)
import WinSDK
#endif
@testable import SlashCommandCore

final class WindowsReviewFixTests: XCTestCase {
    override func setUp() { super.setUp(); L10n.use(language: "en", directory: nil) }

    func testWindowsQuotingEmptySpacesAndTabs() {
        XCTAssertEqual(Proc.windowsQuote(""), #""""#)
        XCTAssertEqual(Proc.windowsQuote("a b"), #""a b""#)
        XCTAssertEqual(Proc.windowsQuote("a\tb"), "\"a\tb\"")
        XCTAssertEqual(Proc.windowsQuote("plain"), "plain")
    }

    func testWindowsQuotingQuotesAndBackslashes() {
        XCTAssertEqual(Proc.windowsQuote(#"a"b"#), #""a\"b""#)
        XCTAssertEqual(Proc.windowsQuote(#"a\"b"#), #""a\\\"b""#)
        XCTAssertEqual(Proc.windowsQuote(#"a\\"b"#), #""a\\\\\"b""#)
        XCTAssertEqual(Proc.windowsQuote(#"C:\space here\"#), #""C:\space here\\""#)
        XCTAssertEqual(Proc.windowsQuote(#"C:\plain\"#), #"C:\plain\"#)
    }

    func testWindowsEnvironmentSortedAndDoubleTerminated() {
        XCTAssertEqual(Proc.windowsEnvironment(["z": "last", "Alpha": "first", "beta": "a=b"]),
                       Array("Alpha=first\0beta=a=b\0z=last\0\0".utf16))
        XCTAssertEqual(Proc.windowsEnvironment([:]), [0, 0])
        XCTAssertEqual(Proc.windowsEnvironment(["X": "한글"]), Array("X=한글\0\0".utf16))
    }

    func testWezTermTicksNeverLookUpTargetButMenuAndChangesDo() {
        XCTAssertFalse(WindowsAppModel.looksUpTarget(app: "wezterm", reason: .tick))
        XCTAssertTrue(WindowsAppModel.looksUpTarget(app: "wezterm", reason: .menu))
        XCTAssertTrue(WindowsAppModel.looksUpTarget(app: "wezterm", reason: .foregroundChanged))
        for reason: WindowsAppModel.RefreshReason in [.tick, .menu, .foregroundChanged] {
            XCTAssertTrue(WindowsAppModel.looksUpTarget(app: "orca", reason: reason))
            XCTAssertFalse(WindowsAppModel.looksUpTarget(app: "other", reason: reason))
        }
    }

    func testFocusedPaneWriteCheckRequiresExactlyOneClientForPID() {
        func focus(_ json: String) -> String? { WindowsWezTerm.focusedPaneID(clients: Data(json.utf8), frontPID: 42) }
        XCTAssertEqual(focus(#"[{"pid":42,"focused_pane_id":7},{"pid":99,"focused_pane_id":8}]"#), "7")
        for json in ["[]", "{}", "[null]", #"[{"pid":99,"focused_pane_id":7}]"#,
                     #"[{"pid":42,"focused_pane_id":7},{"pid":42,"focused_pane_id":7}]"#,
                     #"[{"pid":42,"focused_pane_id":null}]"#,
                     #"[{"pid":42,"focused_pane_id":true}]"#,
                     #"[{"pid":42,"focused_pane_id":1.5}]"#] { XCTAssertNil(focus(json)) }
    }

    private final class FailedIO: TerminalIO {
        var lastFailure: String?
        var keys: [Key] = []
        func type(_ text: String) throws { XCTFail("Must not type after losing the target") }
        func press(_ key: Key) throws { keys.append(key) }
        func screen() -> [String]? {
            lastFailure = "The foreground app changed. Press the shortcut again."
            return nil
        }
    }

    func testSwitcherPreservesTargetFailureThroughTracingIO() {
        let io = FailedIO()
        var switcher = Switcher(config: .starter, makeIO: { _ in io })
        switcher.trace = Trace()
        let target = Target(host: .wezterm(socket: "test", pane: "7"), agent: .claude, label: "test")
        XCTAssertThrowsError(try switcher.apply(slot: 1, to: target)) {
            XCTAssertEqual(String(describing: $0), io.lastFailure)
        }
        XCTAssertTrue(io.keys.isEmpty)
    }

    func testQuotingTreatsCombiningMarksAfterSpaceOrQuoteAsSeparateScalars() {
        XCTAssertEqual(Proc.windowsQuote("a \u{301}b"), "\"a \u{301}b\"")
        XCTAssertEqual(Proc.windowsQuote("x\"\u{301}y"), "\"x\\\"\u{301}y\"")
    }

    func testOnlyALocalDrivePathCountsAsALocalPane() {
        for cwd in ["file:///C:/test/", "file:///d:/", "file://MYPC/C:/repo/", "file://mypc/C:/repo/", "file://localhost/C:/x"] {
            XCTAssertTrue(WindowsWezTerm.isLocalWindowsDirectory(cwd, computerName: "MYPC"), cwd)
        }
        // SSH and mux domains: another host, a POSIX path or no directory at all.
        for cwd in ["file://devbox/home/u/", "file://devbox/C:/repo/", "file:///home/u/", "file://wsl.localhost/Ubuntu/home/u",
                    "file://MYPC/home/u", "", "C:/test", "file:///1:/x", "file://MYPC"] {
            XCTAssertFalse(WindowsWezTerm.isLocalWindowsDirectory(cwd, computerName: "MYPC"), cwd)
        }
        XCTAssertFalse(WindowsWezTerm.isLocalWindowsDirectory("file://MYPC/C:/repo/", computerName: ""))
        let pane = WindowsWezTerm.pane(in: Data(#"[{"pane_id":3,"title":"t","cwd":"file://devbox/home/u/"}]"#.utf8), id: 3)
        XCTAssertEqual(pane?.cwd, "file://devbox/home/u/")
    }

    func testGUIPIDComesOnlyFromAGUISocketName() {
        XCTAssertEqual(WindowsWezTerm.guiPID(socket: #"C:\Users\u\.local\share\wezterm\gui-sock-6708"#), 6708)
        XCTAssertNil(WindowsWezTerm.guiPID(socket: #"C:\Users\u\.local\share\wezterm\sock"#))
        XCTAssertNil(WindowsWezTerm.guiPID(socket: "gui-sock-+1"))
        XCTAssertNil(WindowsWezTerm.guiPID(socket: "gui-sock-0012"))
    }

    #if os(Windows)
    private func entry(_ pid: Int32, _ parent: Int32, _ exe: String, _ command: String? = nil) -> ProcessTable.Entry {
        ProcessTable.Entry(pid: pid, parent: parent, arguments: [command ?? "\"\(exe)\""], environment: [], executable: exe)
    }

    func testWezTermAgentMustBeAWindowsProcessUnderThatGUI() {
        let gui: Int32 = 100
        let shell = entry(101, gui, #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#)
        let claude = entry(102, 101, #"C:\Users\u\.local\bin\claude.exe"#)
        let other = entry(201, 200, #"C:\Users\u\.local\bin\claude.exe"#)
        XCTAssertEqual(WindowsWezTerm.locality(of: .claude, gui: gui, entries: [shell, claude]), .local)
        // An agent of another kind, or one under a different GUI, does not count.
        XCTAssertEqual(WindowsWezTerm.locality(of: .codex, gui: gui, entries: [shell, claude]), .noAgentProcess)
        XCTAssertEqual(WindowsWezTerm.locality(of: .claude, gui: gui, entries: [shell, other]), .noAgentProcess)
        // WSL, tmux or a remote shell in any pane of that GUI: the screen's agent may live elsewhere.
        for nested in [entry(103, 101, #"C:\Windows\System32\wsl.exe"#), entry(103, gui, #"C:\Windows\System32\OpenSSH\ssh.exe"#),
                       entry(103, 101, #"C:\Program Files\Docker\docker.exe"#)] {
            XCTAssertEqual(WindowsWezTerm.locality(of: .claude, gui: gui, entries: [shell, claude, nested]), .mixed)
        }
    }
    #endif

    func testCaptureAfterTheSwitchIsNotTurnedIntoAFailure() throws {
        let io = FailedIO()
        let runner = Runner(io: io, sleep: { _ in })
        // The switch steps already ran; only the result capture lost the target.
        XCTAssertEqual(try runner.run([.capture(prefixes: ["Set model to"])]), [])
        XCTAssertTrue(io.keys.isEmpty)
    }

    func testAbortedStepReportsTheTargetFailure() {
        let io = FailedIO()
        let runner = Runner(io: io, sleep: { _ in })
        XCTAssertThrowsError(try runner.run([.expectCurrentRow(abort: [.closePicker], failure: "cursor is not on the current model")])) {
            XCTAssertEqual(String(describing: $0), io.lastFailure)
        }
        XCTAssertTrue(io.keys.isEmpty)
    }

    func testDefaultsWritingSwitchNeedsALocalAgentWhenDefaultsAreKept() {
        for agent in [Agent.grok, .cursor, .antigravity, .opencode] {
            let io = FailedIO()
            let switcher = Switcher(config: .starter, makeIO: { _ in io })
            var target = Target(host: .wezterm(socket: "test", pane: "7"), agent: agent, label: "test")
            target.defaultsAreLocal = false
            XCTAssertThrowsError(try switcher.stepEffort(up: true, on: target)) {
                XCTAssertTrue(String(describing: $0).contains("that default could not be put back"), "\(agent)")
            }
            XCTAssertTrue(io.keys.isEmpty)
        }
        XCTAssertTrue(Target(host: .wezterm(socket: "test", pane: "7"), agent: .grok, label: "test").defaultsAreLocal)
    }

    func testRunnerPreservesTargetFailureAndDoesNotEscape() {
        let io = FailedIO()
        let runner = Runner(io: io, sleep: { _ in })
        XCTAssertThrowsError(try runner.run([.expectPicker(header: nil, footer: nil, timeoutMs: 30,
                                                          abort: [.closePicker], failure: "picker failed")])) {
            XCTAssertEqual(String(describing: $0), io.lastFailure)
        }
        XCTAssertThrowsError(try runner.run([.closePicker])) {
            XCTAssertEqual(String(describing: $0), io.lastFailure)
        }
        XCTAssertTrue(io.keys.isEmpty)
    }

    #if os(Windows)
    func testPaneReadsDoNotRunClientLookupAndFailedWriteLatchesReason() {
        var checks = 0, queries = 0
        let io = WindowsWezTermIO(base: WezTermIO(wezterm: "missing-test-program.exe", socket: "test", pane: "7"), frontPID: 42,
            foregroundPID: { checks += 1; return 42 }, readClients: { _ in
                queries += 1
                return ProcResult(status: 0, out: #"[{"pid":42,"focused_pane_id":8}]"#, err: "", timedOut: false)
            })
        XCTAssertNil(io.screen())
        XCTAssertNil(io.screen())
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(queries, 0)
        XCTAssertThrowsError(try io.type("test"))
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(io.lastFailure, "The foreground app changed. Press the shortcut again.")
        XCTAssertNil(io.screen())
        XCTAssertThrowsError(try io.press(.escape))
        XCTAssertEqual(queries, 1, "An uncertain target must not be retried by picker cleanup")
    }

    func testChangedForegroundSkipsClientLookupAndPreservesReason() {
        let io = WindowsWezTermIO(base: WezTermIO(wezterm: "missing-test-program.exe", socket: "test", pane: "7"), frontPID: 42,
            foregroundPID: { 99 }, readClients: { _ in
                XCTFail("Foreground check must happen before starting a process")
                return ProcResult(status: 0, out: "", err: "", timedOut: false)
            })
        XCTAssertNil(io.screen())
        XCTAssertEqual(io.lastFailure, "The foreground app changed. Press the shortcut again.")
        XCTAssertThrowsError(try io.press(.enter))
    }

    func testUnsupportedForegroundKeepsOriginalUnsupportedError() {
        for app in ["notepad.exe", "explorer.exe", ""] {
            XCTAssertThrowsError(try Detector.target(app: app, frontPID: 0)) {
                XCTAssertEqual(String(describing: $0), "This is not supported on this operating system yet.")
            }
        }
    }

    func testQuotingRoundTripsThroughWindowsArgumentParser() {
        let arguments = ["", "plain", "a b", "a\tb", #"a"b"#, #"a\"b"#, #"a\\"b"#, #"C:\space here\"#, #"C:\plain\"#]
        let line = ([#"C:\Program Files\test.exe"#] + arguments).map(Proc.windowsQuote).joined(separator: " ")
        XCTAssertEqual(Array(AgentProcesses.commandTokens(line).dropFirst()), arguments)
    }

    func testChildHasNoConsoleWindow() throws {
        let powershell = try XCTUnwrap(Proc.locate("powershell"))
        let script = #"Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class SCConsole { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'; [SCConsole]::GetConsoleWindow().ToInt64()"#
        let result = Proc.run(powershell, ["-NoProfile", "-Command", script], timeout: 15)
        XCTAssertTrue(result.ok, result.err)
        XCTAssertEqual(result.out.trimmingCharacters(in: .whitespacesAndNewlines), "0")
    }

    func testTimeoutEndsSleepingProcessAndChildWithinTwoSeconds() throws {
        let powershell = try XCTUnwrap(Proc.locate("powershell"))
        let script = #"$child = Start-Process powershell.exe -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 30' -NoNewWindow -PassThru; [Console]::WriteLine($child.Id); Start-Sleep -Seconds 30"#
        let started = Date()
        let result = Proc.run(powershell, ["-NoProfile", "-Command", script], timeout: 3)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let pid = try XCTUnwrap(DWORD(result.out.trimmingCharacters(in: .whitespacesAndNewlines)))
        if let handle = OpenProcess(DWORD(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION), false, pid) {
            defer { CloseHandle(handle) }
            XCTAssertEqual(WaitForSingleObject(handle, 0), WAIT_OBJECT_0, "Our sleeping child must have exited")
        }
    }

    func testNativeProcessDrainsBothPipesAndPassesEnvironmentAndDirectory() throws {
        let powershell = try XCTUnwrap(Proc.locate("powershell"))
        let directory = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["SC_PROC_TEST"] = "present"
        let result = Proc.run(powershell, ["-NoProfile", "-Command",
            #"[Console]::Out.WriteLine($env:SC_PROC_TEST); [Console]::Out.WriteLine((Get-Location).Path); [Console]::Out.Write(('o' * 100000)); [Console]::Error.Write(('e' * 100000)); exit 7"#], env: env, cwd: directory.path)
        XCTAssertEqual(result.status, 7)
        XCTAssertFalse(result.timedOut)
        let lines = result.out.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines.first, "present")
        XCTAssertEqual(lines.dropFirst().first.map(WindowsPaths.normalized), WindowsPaths.normalized(directory.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        XCTAssertEqual(result.err, String(repeating: "e", count: 100000))
        XCTAssertTrue(result.out.hasSuffix(String(repeating: "o", count: 100000)))
    }
    #endif
}
