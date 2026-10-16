import XCTest
@testable import SlashCommandCore

final class WindowsAppTests: XCTestCase {
    override func setUp() { super.setUp(); L10n.use(language: "en", directory: nil) }
    override func tearDown() { L10n.use(language: "en", directory: nil); super.tearDown() }
    func testAppVersionMatchesReleasePlist() throws {
        let data = try Data(contentsOf: L10nTests.root.appendingPathComponent("scripts/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(WindowsAppModel.version, plist["CFBundleShortVersionString"] as? String)
    }

    func testWindowsModifiersAndSafetyFallback() {
        XCTAssertEqual(WindowsAppModel.modifiers(["option", "shift"]).flags, 0x4005)
        XCTAssertEqual(WindowsAppModel.modifiers(["control", "shift"]).flags, 0x4006)
        XCTAssertEqual(WindowsAppModel.modifiers(["option", "option"]).flags, 0x4001)
        XCTAssertNil(WindowsAppModel.modifiers(["control"]).warning)
        for names in [[], ["shift"], ["unknown"], ["command"], ["command", "control"]] {
            XCTAssertEqual(WindowsAppModel.modifiers(names).flags, 0x4005)
            XCTAssertNotNil(WindowsAppModel.modifiers(names).warning)
        }
    }

    func testPhysicalKeyTableAndPressArguments() {
        XCTAssertEqual((1...9).compactMap(WindowsAppModel.scanCode), Array(UInt32(2)...UInt32(10)))
        XCTAssertEqual(WindowsAppModel.scanCode(for: 101), 0x0D)
        XCTAssertEqual(WindowsAppModel.scanCode(for: 102), 0x0C)
        for id in [-1, 0, 10, 100, 103] { XCTAssertNil(WindowsAppModel.scanCode(for: id)) }
        XCTAssertEqual(WindowsAppModel.pressID("up"), 101)
        XCTAssertEqual(WindowsAppModel.pressID("down"), 102)
        for id in 1...9 { XCTAssertEqual(WindowsAppModel.pressID(String(id)), id) }
        for text in ["0", "10", "01", "=", "-", "UP", ""] { XCTAssertNil(WindowsAppModel.pressID(text)) }
    }

    func testForegroundImageMustBeExactExecutableName() {
        for image in ["Orca.exe", "C:\\Users\\Me\\Programs\\orca\\Orca.exe", "C:/orca/ORCA.EXE"] {
            XCTAssertTrue(WindowsAppModel.supports(image: image))
        }
        for image in ["", "orca", "notOrca.exe", "Orca.exe.bak", "Orca.exe/other.exe"] {
            XCTAssertFalse(WindowsAppModel.supports(image: image))
        }
    }

    func testMenuShowsNineAgentSpecificDisplayRows() {
        let lines = WindowsAppModel.menu(config: .starter, supported: true, agent: .codex)
        XCTAssertTrue(lines[0].contains("Orca"))
        XCTAssertTrue(lines[1].contains("gpt-6-astra"))
        XCTAssertFalse(lines[1].contains("opus"))
        XCTAssertEqual(lines.count, 14)
        XCTAssertEqual(Array(lines.suffix(4)), ["Open presets file", "Open log folder", "Open at login", "Quit Slash Command"])
        XCTAssertEqual(lines[9], "9  Not set")
        XCTAssertEqual(WindowsAppModel.menu(config: .starter, supported: false, agent: nil)[0], "No supported terminal in front")
        XCTAssertTrue(WindowsAppModel.menu(config: .starter, supported: true, agent: nil, failures: [1, 101, 102]).contains { $0.contains("1, =, -") })
    }

    func testHUDUsesConfirmedResultAndWarning() {
        let target = Target(host: .orca(handle: "test"), agent: .claude, label: "test")
        let result = SwitchResult(target: target, slotName: "", preset: AgentPreset(model: "opus", effort: "high"),
                                  warning: "warning", confirmations: ["Set model to Opus 5.5 for this session only with high effort"], pendingRestore: nil)
        XCTAssertEqual(WindowsAppModel.hud(result: result).text, "Opus 5.5 · high\nClaude Code · Orca · test\n⚠️ warning")
        XCTAssertEqual(WindowsAppModel.hud(result: result).seconds, 1.6)
        XCTAssertEqual(WindowsAppModel.hud(result: result, tabLagNote: true).seconds, 4)
        XCTAssertTrue(WindowsAppModel.hud(result: result, tabLagNote: true).text.contains("wait 2.5 seconds"))
    }

    func testTraySnapshotSurvivesOnlyOurProcessAndExplorerTrayWindows() {
        XCTAssertTrue(WindowsAppModel.keepsSnapshot(pid: 42, ownPID: 42, image: "", windowClass: ""))
        for name in ["Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland"] {
            XCTAssertTrue(WindowsAppModel.keepsSnapshot(pid: 12, ownPID: 42, image: "C:\\Windows\\EXPLORER.EXE", windowClass: name))
            XCTAssertFalse(WindowsAppModel.keepsSnapshot(pid: 12, ownPID: 42, image: "Other.exe", windowClass: name))
        }
        for (pid, image, name) in [(UInt32(0), "", ""), (12, "explorer.exe", "CabinetWClass"), (12, "Orca.exe", "Orca"), (12, "", "Shell_TrayWnd")] {
            XCTAssertFalse(WindowsAppModel.keepsSnapshot(pid: pid, ownPID: 42, image: image, windowClass: name))
        }
    }
    func testNoticeDurationsMatchMacOS() {
        XCTAssertEqual(WindowsAppModel.seconds(.result), 1.6)
        XCTAssertEqual(WindowsAppModel.seconds(.error), 5)
        XCTAssertNil(WindowsAppModel.seconds(.awaiting))
        XCTAssertEqual(WindowsAppModel.seconds(.awaitingError), 6)
        XCTAssertEqual(WindowsAppModel.seconds(.unchanged), 2.5)
        XCTAssertEqual(WindowsAppModel.seconds(.multiline), 4)
    }
    func testLogFormattingUsesLocalOffsetAndMacActionWording() {
        XCTAssertEqual(WindowsAppModel.logLine("hotkey 1", date: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 32400)!), "1970-01-01T09:00:00+09:00 hotkey 1\n")
        XCTAssertEqual(WindowsAppModel.hotkeyLine(1), "hotkey 1")
        XCTAssertEqual(WindowsAppModel.hotkeyLine(101), "hotkey effort up")
        var error = SlashCommandError("test")
        XCTAssertEqual(WindowsAppModel.errorPrefix(error), "failed")
        error.nothingToDo = true
        XCTAssertEqual(WindowsAppModel.errorPrefix(error), "unchanged")
        error.awaitingUser = true
        XCTAssertEqual(WindowsAppModel.errorPrefix(error), "awaiting confirmation")
        let target = Target(host: .orca(handle: "test"), agent: .codex, label: "test")
        let result = SwitchResult(target: target, slotName: "", preset: AgentPreset(model: "gpt-6-astra", effort: "high"), warning: "warning", confirmations: [], pendingRestore: nil)
        XCTAssertEqual(WindowsAppModel.appliedLine(id: 1, result: result), "applied preset 1: \(result.summary) (no confirmation text) → codex@Orca ⚠️ warning")
    }
    func testPressRefusesUnsupportedBusyAndUnregisteredKeys() {
        XCTAssertEqual(WindowsAppModel.refusal(id: 1, supported: false, busy: false, registered: [1]), "no supported terminal in front")
        XCTAssertEqual(WindowsAppModel.refusal(id: 1, supported: true, busy: true, registered: [1]), "still switching")
        for id in [9, 101, 102, 999] {
            XCTAssertEqual(WindowsAppModel.refusal(id: id, supported: true, busy: false, registered: [1, 2]), "key not registered")
        }
        XCTAssertNil(WindowsAppModel.refusal(id: 1, supported: true, busy: false, registered: [1, 2]))
    }
    func testHotkeyStateIsLoggedOnlyWhenRegistrationChanges() {
        XCTAssertNil(WindowsAppModel.hotkeysLine(previous: [], registered: []))
        XCTAssertNil(WindowsAppModel.hotkeysLine(previous: [1, 101], registered: [1, 101]))
        XCTAssertEqual(WindowsAppModel.hotkeysLine(previous: [], registered: [1, 101]), "hotkeys on 1, =")
        XCTAssertEqual(WindowsAppModel.hotkeysLine(previous: [1], registered: []), "hotkeys off")
    }
    func testUnreadablePresetsMenuHasNoStarterRows() {
        let lines = WindowsAppModel.menu(config: nil, supported: true, agent: .codex)
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines[1], "The presets file could not be read — choose Open presets file to fix it.")
        XCTAssertFalse(lines.contains { $0.first?.isNumber == true })
        XCTAssertEqual(Array(lines.suffix(4)), ["Open presets file", "Open log folder", "Open at login", "Quit Slash Command"])
    }

    func testNoticeDropsLeadingStatusSymbolsFromTheTabTitle() {
        XCTAssertEqual(WindowsAppModel.displayLabel("✳ Claude Code · sctest-orca"), "Claude Code · sctest-orca")
        XCTAssertEqual(WindowsAppModel.displayLabel("⠐ Claude Code"), "Claude Code")
        XCTAssertEqual(WindowsAppModel.displayLabel("repo"), "repo")
        XCTAssertEqual(WindowsAppModel.displayLabel("한글 탭"), "한글 탭")
        XCTAssertEqual(WindowsAppModel.displayLabel("✳"), "✳", "Nothing left: keep the original")
    }
}
