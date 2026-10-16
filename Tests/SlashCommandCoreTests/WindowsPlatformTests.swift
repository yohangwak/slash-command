import XCTest
@testable import SlashCommandCore

final class WindowsPlatformTests: XCTestCase {
    func testNonWindowsCommandLinesMatchHEAD() {
        let samples: [(String, Agent?)] = [
            ("/Applications/Claude.app/Contents/MacOS/Claude", nil),
            ("/Applications/Claude Helper.app/Contents/MacOS/Claude Helper --type=gpu", nil),
            ("/Applications/Codex.app/Contents/MacOS/Codex", nil),
            ("node /opt/homebrew/bin/opencode", nil),
            ("CODEX -m x", nil),
            ("/opt/it's/bin/claude --model opus", .claude)
        ]
        for (command, expected) in samples {
            XCTAssertEqual(AgentProcesses.nonWindowsAgent(forCommandLine: command), expected)
            #if !os(Windows)
            XCTAssertEqual(AgentProcesses.agent(forCommandLine: command), expected)
            #endif
        }
    }

    func testNonWindowsExecutableNamesRemainCaseAndSuffixSensitive() {
        for command in ["claude.exe", "codex.cmd", "CLAUDE", #"C:\tools\claude.exe"#, "bun /opt/bin/opencode"] {
            XCTAssertNil(AgentProcesses.nonWindowsAgent(forCommandLine: command))
        }
        XCTAssertEqual(AgentProcesses.nonWindowsAgent(forCommandLine: "/opt/claude/versions/2.1.296"), .claude)
    }

    #if os(Windows)
    func testWindowsAgentExecutableNames() {
        let samples: [(String, Agent)] = [
            (#""C:\Users\x\.local\bin\claude.exe" --model opus"#, .claude),
            (#""C:\Program Files\Agent\CODEX.EXE" -m x"#, .codex),
            (#"C:\Users\O'Brien\.local\bin\claude.exe --model opus"#, .claude),
            (#"C:\tools\grok.cmd"#, .grok),
            (#"C:\tools\CURSOR-AGENT.EXE"#, .cursor),
            (#"C:\tools\agy.cmd"#, .antigravity),
            (#"C:/tools/OpenCode.exe"#, .opencode),
            (#""C:\Program Files\nodejs\node.exe" "C:\Users\x\node_modules\opencode\bin\opencode""#, .opencode),
            (#"C:\Users\x\claude\versions\2.1.296"#, .claude)
        ]
        for (command, agent) in samples { XCTAssertEqual(AgentProcesses.agent(forCommandLine: command), agent) }
    }

    #endif

    func testCommandArgumentsCannotImpersonateAgent() {
        for command in [#"cmd.exe /c claude.exe"#, #"powershell.exe -Command codex"#, #"node.exe unrelated.js opencode"#, #"C:\tools\notclaude.exe"#, ""] {
            XCTAssertNil(AgentProcesses.agent(forCommandLine: command))
        }
    }

    func testPipeDescriptorRequiresLocalPipePIDAndCredential() throws {
        func descriptor(_ fields: [String: Any]) -> OrcaRuntime.PipeMetadata? {
            OrcaRuntime.pipeMetadata(from: try! JSONSerialization.data(withJSONObject: fields))
        }
        let pipe: [String: Any] = ["kind": "named-pipe", "endpoint": #"\\.\pipe\orca-test"#]
        var fields: [String: Any] = [OrcaRuntime.credentialField: "t", "pid": 42, "runtimeId": "r", "transports": [["kind": "websocket", "endpoint": "ws://x"], pipe]]
        let meta = try XCTUnwrap(descriptor(fields))
        XCTAssertEqual(meta.pid, 42)
        XCTAssertEqual(meta.endpoint, #"\\.\pipe\orca-test"#)
        XCTAssertEqual(meta.runtimeID, "r")
        for bad: Any in [0, -1, 1.5, true, "42", Double(UInt32.max) + 1] {
            fields["pid"] = bad
            XCTAssertNil(descriptor(fields))
        }
        fields["pid"] = 42
        fields["transports"] = [["kind": "named-pipe", "endpoint": #"\\remote\pipe\orca"#]]
        XCTAssertNil(descriptor(fields))
        fields["transports"] = [pipe]
        fields[OrcaRuntime.credentialField] = ""
        XCTAssertNil(descriptor(fields))
    }

    func testPipeBindingMismatchNeverWrites() {
        var writes = 0
        let base = #"C:\Users\x\AppData\Local"#
        let image = base + #"\Programs\orca\Orca.exe"#
        XCTAssertFalse(OrcaRuntime.withVerifiedPipeServer(descriptorPID: 42, serverPID: 43, image: image, localAppData: base) { writes += 1 })
        XCTAssertFalse(OrcaRuntime.withVerifiedPipeServer(descriptorPID: 42, serverPID: nil, image: image, localAppData: base) { writes += 1 })
        for wrong in [base + #"\Programs\orca-other\Orca.exe"#, base + #"\Programs\orca\evil.exe"#, #"C:\other\Orca.exe"#, ""] {
            XCTAssertFalse(OrcaRuntime.withVerifiedPipeServer(descriptorPID: 42, serverPID: 42, image: wrong, localAppData: base) { writes += 1 })
        }
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(OrcaRuntime.withVerifiedPipeServer(descriptorPID: 42, serverPID: 42, image: image.uppercased().replacingOccurrences(of: "\\", with: "/"), localAppData: base) { writes += 1 })
        XCTAssertEqual(writes, 1, "Positive control proves the guarded write can run")
    }

    #if os(Windows)
    func testNativeProcessReadRetainsOnlyExactOrcaMarker() throws {
        let child = Process()
        let systemRoot = WindowsPaths.environment("SystemRoot") ?? #"C:\Windows"#
        child.executableURL = URL(fileURLWithPath: systemRoot + "/System32/WindowsPowerShell/v1.0/powershell.exe")
        child.arguments = ["-NoProfile", "-Command", "Start-Sleep -Seconds 20"]
        let marker = "ORCA_TERMINAL_HANDLE=term_sc_test_" + UUID().uuidString
        child.environment = ["ORCA_TERMINAL_HANDLE": String(marker.dropFirst("ORCA_TERMINAL_HANDLE=".count)),
                             "SystemRoot": systemRoot, "PATH": #"C:\Windows\System32"#]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let table = ProcessTable.snapshot()
        let entry = try XCTUnwrap(table.entries.first { $0.pid == child.processIdentifier })
        XCTAssertEqual(entry.environment.count, 1)
        XCTAssertEqual(entry.environment.first, marker)
        XCTAssertTrue(entry.arguments.joined(separator: " ").contains("Start-Sleep"))
        XCTAssertTrue(WindowsPaths.normalized(entry.executable).hasSuffix("/powershell.exe"))
        XCTAssertEqual(table.parents[entry.pid], Int32(ProcessInfo.processInfo.processIdentifier))
    }

    func testWSLAndTmuxStopBeforeAgentSelection() throws {
        func entry(_ pid: Int32, _ handle: String, _ image: String, _ command: String) -> ProcessTable.Entry {
            .init(pid: pid, parent: 1, arguments: [command], environment: ["ORCA_TERMINAL_HANDLE=\(handle)"], executable: image)
        }
        for (image, command) in [(#"C:\Windows\System32\wsl.exe"#, "wsl.exe"), (#"C:\Windows\System32\wslhost.exe"#, "wslhost.exe"), (#"C:\tools\tmux.exe"#, "tmux.exe attach"), (#"C:\tools\bash.exe"#, "bash -c tmux")] {
            let entries = [entry(10, "term_a", image, command), entry(11, "term_a", "claude.exe", "claude.exe")]
            XCTAssertThrowsError(try AgentProcesses.requirePlainOrca(handle: "term_a", entries: entries))
            XCTAssertNil(AgentProcesses.agent(orcaHandle: "term_a", entries: entries, parents: [:]))
            let otherShell = entry(12, "term_ab", "powershell.exe", "powershell.exe")
            XCTAssertNoThrow(try AgentProcesses.requirePlainOrca(handle: "term_ab", entries: entries + [otherShell]))
        }
        let plain = [entry(10, "term_a", "claude.exe", "claude.exe"), entry(11, "term_a", "codex.exe", "codex.exe"), entry(12, "term_ab", "codex.exe", "codex.exe")]
        XCTAssertEqual(AgentProcesses.agent(orcaHandle: "term_a", entries: plain, parents: [11: 10]), .claude)
        XCTAssertEqual(AgentProcesses.agent(orcaHandle: "term_ab", entries: plain, parents: [:]), .codex)
    }

    func testUnreadableTerminalProcessesStop() {
        let shell = ProcessTable.Entry(pid: 10, parent: 1, arguments: ["powershell.exe"],
                                       environment: ["ORCA_TERMINAL_HANDLE=term_ab"], executable: "powershell.exe")
        for entries in [[], [shell]] {
            XCTAssertThrowsError(try AgentProcesses.requirePlainOrca(handle: "term_a", entries: entries))
            XCTAssertNil(AgentProcesses.agent(orcaHandle: "term_a", entries: entries, parents: [:]))
        }
        XCTAssertNoThrow(try AgentProcesses.requirePlainOrca(handle: "term_ab", entries: [shell]))
    }

    func testWSLEntryPointNames() {
        let names = ["ubuntu.exe", "Ubuntu2404.exe", "debian.exe", "kali.exe", "openSUSE-Leap.exe",
                     "sles15.exe", "fedora42.exe", "alpine.exe", "archlinux.exe", "oraclelinux9.exe"]
        for name in names {
            let image = #"C:\Users\x\AppData\Local\Microsoft\WindowsApps\"# + name
            XCTAssertTrue(AgentProcesses.isWindowsWSLEntryPoint(image))
            let entry = ProcessTable.Entry(pid: 10, parent: 1, arguments: [image],
                                          environment: ["ORCA_TERMINAL_HANDLE=term_a"], executable: image)
            XCTAssertThrowsError(try AgentProcesses.requirePlainOrca(handle: "term_a", entries: [entry]))
            XCTAssertFalse(AgentProcesses.isWindowsWSLEntryPoint(#"C:\tools\"# + name))
        }
        for image in [#"C:\Windows\System32\bash.exe"#, "wsl.exe", "wslhost.exe", "wslrelay.exe"] {
            XCTAssertTrue(AgentProcesses.isWindowsWSLEntryPoint(image))
        }
        for image in [#"C:\tools\bash.exe"#, #"C:\WindowsApps\code.exe"#, #"C:\NotWindowsApps\ubuntu.exe"#,
                      #"C:\WindowsApps\ubuntu.exe.bak"#] {
            XCTAssertFalse(AgentProcesses.isWindowsWSLEntryPoint(image))
        }
    }

    func testRemoteAddressOverflowStops() {
        XCTAssertNil(ProcessTable.adding(UInt.max, 0x20))
        XCTAssertNil(ProcessTable.adding(UInt.max - 0x7f, 0x80))
        XCTAssertNil(ProcessTable.adding(UInt.max - 1, 4096))
        XCTAssertEqual(ProcessTable.adding(0x1000, 0x20), 0x1020)
        XCTAssertEqual(ProcessTable.adding(UInt.max - 1, 1), UInt.max)
    }

    func testAppDataMustBePresentAndNonempty() throws {
        for name in ["APPDATA", "LOCALAPPDATA"] {
            XCTAssertThrowsError(try WindowsPaths.requiredEnvironment(name, in: [:]))
            XCTAssertThrowsError(try WindowsPaths.requiredEnvironment(name, in: [name: ""]))
            XCTAssertEqual(try WindowsPaths.requiredEnvironment(name, in: [name.lowercased(): #"C:\Users\x\AppData"#]), #"C:\Users\x\AppData"#)
        }
    }

    func testWindowsStateMatchesSlashAndCaseDifferences() throws {
        let payload: [String: Any] = ["visualLayouts": [["worktreeId": #"repo::C:/Users/X/repo"#, "root": ["tabs": [["tabId": "tab", "activeLeafId": "leaf", "panes": ["type": "terminal", "leafId": "leaf", "handle": "term_a"]]]]]]]
        let pane = try OrcaState.pane(in: payload, active: .init(worktreeID: #"repo::c:\users\x\repo"#, tabID: "tab"))
        XCTAssertEqual(pane.handle, "term_a")
    }
    #endif
}
