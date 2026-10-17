import XCTest
@testable import SlashCommandCore
#if os(Windows)
import WinSDK
import CWindowsConsoleFixture
#endif

final class WindowsTerminalTests: XCTestCase {
    private let three = "first\nsecond\nthird"
    func testEqualVisibleConsoleRowsMatch() { XCTAssertTrue(WindowsTerminalMatching.equal(console: three, visible: three)) }
    func testOneDifferentRowRefusesMatch() { XCTAssertFalse(WindowsTerminalMatching.equal(console: three, visible: "first\nDIFFERENT\nthird")) }
    func testTwoEqualConsolesAreAmbiguous() { XCTAssertNil(WindowsTerminalMatching.uniqueMatch(consoles: [three, three], visible: three)) }
    func testUniqueConsoleWins() { XCTAssertEqual(WindowsTerminalMatching.uniqueMatch(consoles: ["other\nrows\nhere", three], visible: three), 1) }
    func testNoConsoleMatches() { XCTAssertNil(WindowsTerminalMatching.uniqueMatch(consoles: [], visible: three)) }
    func testReplacementMatchesOneEmojiScalar() { XCTAssertTrue(WindowsTerminalMatching.equal(console: "first �\nsecond\nthird", visible: "first 😀\nsecond\nthird")) }
    func testReplacementMatchesItself() { XCTAssertTrue(WindowsTerminalMatching.equal(console: "first �\nsecond\nthird", visible: "first �\nsecond\nthird")) }
    func testReplacementDoesNotMatchBMP() { XCTAssertFalse(WindowsTerminalMatching.equal(console: "first �\nsecond\nthird", visible: "first 한\nsecond\nthird")) }
    func testReplacementIsNotBidirectional() { XCTAssertFalse(WindowsTerminalMatching.equal(console: "first 😀\nsecond\nthird", visible: "first �\nsecond\nthird")) }
    func testOneReplacementDoesNotMatchTwoScalars() { XCTAssertFalse(WindowsTerminalMatching.equal(console: "first �\nsecond\nthird", visible: "first 😀😀\nsecond\nthird")) }
    func testReplacementMatchesZWJSequenceScalarByScalar() {
        XCTAssertTrue(WindowsTerminalMatching.equal(console: "first �‍�\nsecond\nthird", visible: "first 👩‍💻\nsecond\nthird"))
    }
    func testFewerThanThreeNonblankRowsRefuses() {
        for text in ["", "one", "one\ntwo", "one\n \ntwo\n\n", " \n\t\n "] { XCTAssertFalse(WindowsTerminalMatching.equal(console: text, visible: text)) }
    }
    func testTrailingPaddingAndBlankRowsAreIgnored() {
        XCTAssertTrue(WindowsTerminalMatching.equal(console: "first   \r\nsecond\t\r\nthird \r\n  \r\n", visible: three + "\n\n"))
    }
    func testLeadingAndInteriorSpacesAreIgnored() {
        XCTAssertTrue(WindowsTerminalMatching.equal(console: " first\nsecond\nthird", visible: three))
        XCTAssertTrue(WindowsTerminalMatching.equal(console: "fi rst\nsecond\nthird", visible: three))
    }
    func testInteriorBlankRowsAreIgnored() { XCTAssertTrue(WindowsTerminalMatching.equal(console: "first\n\nsecond\nthird", visible: three)) }
    func testKoreanAndCombiningMarksPreserved() {
        let text = "한글\ne\u{301}\nthird"
        XCTAssertTrue(WindowsTerminalMatching.equal(console: text, visible: text))
        XCTAssertFalse(WindowsTerminalMatching.equal(console: text, visible: "한글\né\nthird"))
    }
    func testSoftWrapped162CharactersAt60ColumnsMatchOneUIARow() {
        let line = String(repeating: "0123456789", count: 16) + "ab"
        let console = [String(line.prefix(60)), String(line.dropFirst(60).prefix(60)), String(line.suffix(42))].joined(separator: "\n")
        XCTAssertTrue(WindowsTerminalMatching.equal(console: console, visible: line))
    }
    func testDifferentCharacterAnywhereInWrappedLineRefuses() {
        let line = String(repeating: "a", count: 162)
        for index in 0..<162 {
            var units = Array(line); units[index] = "b"
            XCTAssertFalse(WindowsTerminalMatching.equal(console: line, visible: String(units)), "offset \(index)")
        }
    }
    func testWrappedEqualConsolesRemainAmbiguous() {
        let line = String(repeating: "x", count: 162)
        XCTAssertNil(WindowsTerminalMatching.uniqueMatch(consoles: [line, String(line.prefix(60)) + "\n" + String(line.dropFirst(60))], visible: line))
    }
    func testSixtyNonWhitespaceCharactersSuffice() {
        let line = String(repeating: "x", count: 60)
        XCTAssertTrue(WindowsTerminalMatching.equal(console: line, visible: line))
    }
    func testFiftyNineNonWhitespaceCharactersDoNotSuffice() {
        let line = String(repeating: "x", count: 59)
        XCTAssertFalse(WindowsTerminalMatching.equal(console: line, visible: line))
    }
    func testWhitespaceDoesNotCountTowardMinimumContent() {
        let text = String(repeating: " ", count: 100) + "x\t\n\r"
        XCTAssertFalse(WindowsTerminalMatching.equal(console: text, visible: text))
    }
    func testMinimumRowsAreUIARowsRatherThanConsoleWraps() {
        XCTAssertFalse(WindowsTerminalMatching.equal(console: "a\nb\nc", visible: "abc"))
    }
    func testThreeShortUIARowsStillSufficeWhenConsoleJoinsThem() {
        XCTAssertTrue(WindowsTerminalMatching.equal(console: "abc", visible: "a\nb\nc"))
    }
    func testAllWhitespaceRemovedWhileReplacementRuleSurvivesWrapping() {
        XCTAssertTrue(WindowsTerminalMatching.equal(console: "f\ti r s t �\r\nsecond\nthird", visible: "first😀\nsecond\nthird"))
        XCTAssertFalse(WindowsTerminalMatching.equal(console: "first �\nsecond\nthird", visible: "firstA\nsecond\nthird"))
    }
    func testAppImageRecognizesWindowsTerminalOnly() {
        for image in ["WindowsTerminal.exe", #"C:\Program Files\WindowsApps\Microsoft.WindowsTerminal\WINDOWSTERMINAL.EXE"#] {
            XCTAssertEqual(WindowsAppModel.app(image: image), "windowsterminal")
        }
        for image in ["wt.exe", "OpenConsole.exe", "WindowsTerminal.exe.bak"] { XCTAssertNil(WindowsAppModel.app(image: image)) }
    }
    func testWindowsTerminalIdleTickDoesNotResolveTarget() {
        XCTAssertFalse(WindowsAppModel.looksUpTarget(app: "windowsterminal", reason: .tick))
        XCTAssertTrue(WindowsAppModel.looksUpTarget(app: "windowsterminal", reason: .menu))
        XCTAssertTrue(WindowsAppModel.looksUpTarget(app: "windowsterminal", reason: .foregroundChanged))
    }
    func testWhichCaptureTheMenuDescribes() {
        XCTAssertTrue(WindowsAppModel.adoptsForeground(stillFront: true, keepsSnapshot: false))
        XCTAssertFalse(WindowsAppModel.adoptsForeground(stillFront: true, keepsSnapshot: true), "the tray or hidden icons")
        // A terminal brought to the front, then the tray opened before its lookup finished.
        XCTAssertTrue(WindowsAppModel.adoptsForeground(stillFront: false, keepsSnapshot: false, supported: true,
                                                       replacedBySnapshotKeeper: true, windowExists: true))
        // A short-lived Explorer window seen on the way to the hidden icons.
        XCTAssertFalse(WindowsAppModel.adoptsForeground(stillFront: false, keepsSnapshot: false, supported: false,
                                                        replacedBySnapshotKeeper: true, windowExists: true))
        // A terminal another app has replaced, or one whose window has closed.
        XCTAssertFalse(WindowsAppModel.adoptsForeground(stillFront: false, keepsSnapshot: false, supported: true,
                                                        replacedBySnapshotKeeper: false, windowExists: true))
        XCTAssertFalse(WindowsAppModel.adoptsForeground(stillFront: false, keepsSnapshot: false, supported: true,
                                                        replacedBySnapshotKeeper: true, windowExists: false))
    }
    /// A tab or pane switch inside the window is seen by the next tick, so the menu resolves the pane as it is now.
    func testMenuUsesThePaneLastSeenInTheSameWindow() {
        XCTAssertEqual(WindowsAppModel.menuPane(seen: (7, "42/1/"), window: 7), "42/1/")
        XCTAssertNil(WindowsAppModel.menuPane(seen: (7, "42/1/"), window: 8))
        XCTAssertNil(WindowsAppModel.menuPane(seen: nil, window: 7))
        XCTAssertNil(WindowsAppModel.menuPane(seen: (7, "42/1/"), window: nil))
    }
    func testWindowsTerminalMenuHasStatusAndNinePresets() {
        L10n.use(language: "en", directory: nil)
        let lines = WindowsAppModel.menu(config: .starter, supported: true, agent: .claude, terminal: "Test", appName: "Windows Terminal")
        XCTAssertEqual(lines.first, "Windows Terminal · Claude Code · Test")
        XCTAssertEqual(lines.filter { $0.first?.isNumber == true }.count, 9)
        XCTAssertFalse(lines.contains { $0.contains("Orca") })
    }

    #if os(Windows)
    func testUIASuccessWithNullOutPointersRefusesWithoutDereference() {
        for stage in 1...9 { XCTAssertEqual(sc_test_uia_null(Int32(stage)), 1, "NULL stage \(stage)") }
    }
    func testUIASelectsPaneByRuntimeIDWithoutFocusAndReadsIdentityAlone() { XCTAssertEqual(sc_test_uia_select(), 1) }
    func testUIAClientIsReusedAndReleasedOncePerIO() {
        var milliseconds: Double = 0
        XCTAssertEqual(sc_test_uia_reuse(1000, &milliseconds), 1)
        print("B13 fake-provider focus check ms/write=\(milliseconds) (1000 reads, one COM client; excludes desktop provider latency)")
    }
    private final class FakeConsole: WindowsConsoleReading {
        var text = "first\nsecond\nthird"
        var writes: [WindowsConsoleKey] = []
        var chunks = 0
        let member = WindowsConsoleMember(pid: 7, start: 11)
        func read() throws -> WindowsConsoleScreen { .init(text: text, members: [member]) }
        func members() throws -> [WindowsConsoleMember] { [member] }
        func pin(pid: Int32, start: UInt64) throws {
            guard UInt32(bitPattern: pid) == member.pid, start == member.start else { throw WindowsTerminal.changed }
        }
        func write(_ keys: [WindowsConsoleKey]) throws { writes += keys; chunks += 1 }
    }
    func testIdenticalHiddenConsolePlusUnreadableCandidateRefuses() throws {
        let hidden = FakeConsole()
        var read: [Int32] = []
        XCTAssertThrowsError(try WindowsTerminal.matchedConsole(candidates: [1, 2], visible: hidden.text) { pid in
            read.append(pid)
            if pid == 2 { throw WindowsTerminal.unreadable }
            return try hidden.read()
        }) { XCTAssertEqual(String(describing: $0), String(describing: WindowsTerminal.unmatched)) }
        XCTAssertEqual(read, [1, 2]); XCTAssertTrue(hidden.writes.isEmpty)
    }
    func testFirstUnreadableCandidateStopsEnumeration() throws {
        var calls = 0
        XCTAssertThrowsError(try WindowsTerminal.matchedConsole(candidates: [1, 2], visible: three) { _ in
            calls += 1; throw WindowsTerminal.unreadable
        })
        XCTAssertEqual(calls, 1)
    }
    func testDuplicateProbesOfOneConsoleAreDeduplicated() throws {
        let fake = FakeConsole()
        XCTAssertEqual(try WindowsTerminal.matchedConsole(candidates: [1, 2], visible: three, read: { _ in try fake.read() }).text, three)
    }
    private final class Count { var n = 0 }
    private func paneIO(_ fake: FakeConsole, settles: Count = Count(),
                        focused: @escaping (Int) -> WindowsTerminal.Pane) throws -> WindowsConsoleIO {
        var target = Target(host: .windowsConsole(pid: 7, start: 11), agent: .claude, label: "fake")
        target.windowsWindow = 123; target.windowsPaneIdentity = "pane"
        var checks = 0
        return try WindowsConsoleIO(target: target, bridge: fake, focused: { _ in checks += 1; return focused(checks) },
                                    settle: { settles.n += 1 }, validate: { _, agent, _ in (.init(agent: agent, pid: 7), 11) })
    }
    /// A chunk such as Claude's Ctrl+S, "/model", Enter is checked once and written whole, never stopped halfway.
    func testChunkIsCheckedOnceAndWrittenWhole() throws {
        let fake = FakeConsole()
        var checks = 0
        let io = try paneIO(fake) { n in checks = n; return .init(text: fake.text, identity: "pane") }
        try io.type("\u{13}/m\r")
        XCTAssertEqual(fake.writes, [.character(0x13), .character(47), .character(109), .character(13)])
        XCTAssertEqual(fake.chunks, 1); XCTAssertEqual(checks, 1)
    }
    func testNextChunkIsRefusedOnceTheTextStopsMatching() throws {
        let fake = FakeConsole()
        let settles = Count()
        let io = try paneIO(fake, settles: settles) { n in .init(text: n == 1 ? fake.text : "different\nsecond\nthird", identity: "pane") }
        try io.type("ab")
        XCTAssertThrowsError(try io.press(.enter))
        XCTAssertEqual(fake.writes, [.character(97), .character(98)])
        XCTAssertEqual(settles.n, WindowsConsoleIO.textAttempts - 1)
        XCTAssertThrowsError(try io.press(.enter)); XCTAssertEqual(fake.chunks, 1)
    }
    /// UI Automation shows the agent's echo a few milliseconds after the console has it.
    func testTextThatCatchesUpWithinTheAttemptsIsAccepted() throws {
        let fake = FakeConsole()
        let settles = Count()
        let io = try paneIO(fake, settles: settles) { n in .init(text: n < 3 ? "lagging\nsecond\nthird" : fake.text, identity: "pane") }
        try io.press(.enter)
        XCTAssertEqual(fake.writes, [.key(.enter)]); XCTAssertEqual(settles.n, 2)
    }
    func testPaneChangeIsNotWaitedFor() throws {
        let fake = FakeConsole()
        let settles = Count()
        var checks = 0
        let io = try paneIO(fake, settles: settles) { n in checks = n; return .init(text: fake.text, identity: "other pane") }
        XCTAssertThrowsError(try io.press(.enter))
        XCTAssertTrue(fake.writes.isEmpty); XCTAssertEqual(settles.n, 0); XCTAssertEqual(checks, 1)
    }
    func testFirstTextMismatchSendsNoKeyEvenForExplicitAppTarget() throws {
        let fake = FakeConsole()
        var target = Target(host: .windowsConsole(pid: 7, start: 11), agent: .claude, label: "fake")
        target.windowsWindow = 123; target.windowsPaneIdentity = "pane"
        let io = try WindowsConsoleIO(target: target, bridge: fake, focused: { _ in .init(text: "other\nsecond\nthird", identity: "pane") },
                                     settle: {}, validate: { _, agent, _ in (.init(agent: agent, pid: 7), 11) })
        XCTAssertThrowsError(try io.press(.enter)); XCTAssertTrue(fake.writes.isEmpty)
    }
    func testExitedMemberIsRecheckedAndDropped() throws {
        let members = [WindowsConsoleMember(pid: 2, start: 10), .init(pid: 3, start: 20)]
        var refreshed = 0
        let identity = try WindowsTerminal.requireWindowsLocal(members: members, refresh: { refreshed += 1; return [members[0]] }, read: {
            $0.pid == 2 ? self.entry(2, 1, "claude.exe") : nil
        })
        XCTAssertEqual(identity.0, .init(agent: .claude, pid: 2)); XCTAssertEqual(identity.1, 10); XCTAssertEqual(refreshed, 1)
    }
    func testCurrentUnreadableMemberRefusesAsUnreadable() {
        let members = [WindowsConsoleMember(pid: 2, start: 10)]
        XCTAssertThrowsError(try WindowsTerminal.requireWindowsLocal(members: members, refresh: { members }, read: { _ in nil })) {
            XCTAssertEqual(String(describing: $0), String(describing: WindowsTerminal.unreadable))
        }
    }
    func testReusedMemberPIDRefusesWithChangedStartTime() {
        XCTAssertThrowsError(try WindowsTerminal.requireWindowsLocal(members: [.init(pid: 2, start: 10)], refresh: { [.init(pid: 2, start: 20)] }, read: { _ in nil })) {
            XCTAssertEqual(String(describing: $0), String(describing: WindowsTerminal.changed))
        }
    }
    func testUnreadableMemberWithoutStartTimeCannotBecomeIdentity() {
        XCTAssertThrowsError(try WindowsTerminal.requireWindowsLocal(members: [.init(pid: 2, start: 0)], refresh: { [.init(pid: 2, start: 0)] }, read: { _ in XCTFail("no start time must never be read"); return nil }))
    }
    func testMissingInputBoxExplainsNotSwitchedRatherThanStopped() {
        L10n.use(language: "en", directory: nil)
        XCTAssertThrowsError(try WindowsTerminal.requireInput(text: "Permission required\n1. Allow\n2. Deny", agent: .claude)) {
            XCTAssertEqual(String(describing: $0), "Not switched: the Claude Code input box is not visible. If a permission prompt or a picker is showing, deal with that first.")
        }
    }
    func testMissingWTWindowHasSpecificDiagnostic() {
        L10n.use(language: "en", directory: nil)
        XCTAssertThrowsError(try WindowsTerminal.requireWindow(nil)) { XCTAssertEqual(String(describing: $0), "No Windows Terminal window is open.") }
    }
    private func entry(_ pid: Int32, _ parent: Int32, _ command: String, _ image: String? = nil) -> ProcessTable.Entry {
        .init(pid: pid, parent: parent, arguments: [command], environment: [], executable: image ?? command.split(separator: " ").first.map(String.init) ?? "")
    }
    func testAgentSelectionUsesOutermostAgent() {
        XCTAssertEqual(WindowsTerminal.identity(entries: [entry(1, 0, "cmd.exe"), entry(2, 1, "claude.exe"), entry(3, 2, "codex.exe")]), .init(agent: .claude, pid: 2))
    }
    func testAgentSelectionRefusesSiblingKinds() { XCTAssertNil(WindowsTerminal.identity(entries: [entry(2, 1, "claude.exe"), entry(3, 1, "codex.exe")])) }
    func testAgentSelectionAllowsSameKindWrapper() { XCTAssertEqual(WindowsTerminal.identity(entries: [entry(2, 1, "codex.exe"), entry(3, 2, "codex.exe")])?.pid, 2) }
    func testAgentSelectionRequiresAnAgent() { XCTAssertNil(WindowsTerminal.identity(entries: [entry(1, 0, "cmd.exe")])) }
    func testAgentSelectionRefusesUnreadableMember() { XCTAssertNil(WindowsTerminal.identity(entries: [entry(2, 1, "claude.exe"), entry(3, 1, "", "")])) }
    func testAgentSelectionRefusesWSLAndTmuxAndRemoteClients() {
        for name in ["wsl.exe", "wslhost.exe", "tmux.exe", "ssh.exe", "plink.exe", "mosh-client.exe", "docker.exe", "podman.exe", "kubectl.exe"] {
            XCTAssertNil(WindowsTerminal.identity(entries: [entry(2, 1, "claude.exe"), entry(3, 1, name)]), name)
        }
    }
    func testAgentSelectionRefusesNestedLaunchCommand() { XCTAssertNil(WindowsTerminal.identity(entries: [entry(2, 1, "claude.exe"), entry(3, 1, "cmd.exe /c wsl.exe")])) }
    func testControlCharactersMapToControlLetters() {
        for c in "abcdefghijklmnopqrstuvwxyz" {
            let key = WindowsConsoleKey.key(.ctrl(c)), value = UInt16(c.asciiValue! - 96)
            XCTAssertEqual(key.vk, value + 64); XCTAssertEqual(key.character, value)
            XCTAssertEqual(key.modifiers, UInt32(LEFT_CTRL_PRESSED))
            XCTAssertEqual(key.scan, UInt16(MapVirtualKeyW(UInt32(value + 64), UInt32(MAPVK_VK_TO_VSC))))
        }
        let save = WindowsConsoleKey.character(0x13)
        XCTAssertEqual(save.vk, 0x53); XCTAssertEqual(save.character, 0x13); XCTAssertEqual(save.modifiers, UInt32(LEFT_CTRL_PRESSED))
    }
    func testNavigationKeysUseEnhancedFlag() {
        let keys: [(Key, UInt16)] = [(.up,0x26),(.down,0x28),(.left,0x25),(.right,0x27),(.home,0x24),(.end,0x23),(.pageUp,0x21),(.pageDown,0x22)]
        for (key, vk) in keys {
            let mapped = WindowsConsoleKey.key(key)
            XCTAssertEqual(mapped.vk, vk); XCTAssertEqual(mapped.character, 0); XCTAssertEqual(mapped.modifiers, UInt32(ENHANCED_KEY))
            XCTAssertEqual(mapped.scan, UInt16(MapVirtualKeyW(UInt32(vk), UInt32(MAPVK_VK_TO_VSC))))
        }
    }
    func testSpecialKeysHaveTheirOwnVKAndCharacter() {
        for (key, vk, ch): (Key, UInt16, UInt16) in [(.enter,0x0D,13),(.escape,0x1B,27),(.tab,0x09,9),(.backspace,0x08,8)] {
            let mapped = WindowsConsoleKey.key(key)
            XCTAssertEqual(mapped.vk, vk); XCTAssertEqual(mapped.character, ch); XCTAssertEqual(mapped.modifiers, 0)
            XCTAssertEqual(mapped.scan, UInt16(MapVirtualKeyW(UInt32(vk), UInt32(MAPVK_VK_TO_VSC))))
        }
    }
    func testEveryPlannedCharacterAndKeyHasConsoleMapping() throws {
        var texts = "", keys: [Key] = []
        var config = SlashCommandConfig.starter
        for slot in config.slots.indices {
            for agent in Agent.allCases where config.slots[slot].preset(for: agent) == nil {
                config.slots[slot].presets[agent] = .init(model: "test-model", effort: "high")
            }
        }
        func collect(_ steps: [Step]) {
            for step in steps {
                switch step {
                case .text(let text): texts += text
                case .key(let key): keys.append(key)
                default: break
                }
            }
        }
        for agent in Agent.allCases {
            for slot in 1...3 {
                let cache = CodexModels(models: config.slots.compactMap(\.codex).map {
                    .init(slug: $0.model, efforts: ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"])
                })
                let plan = try Switcher(config: config, codexModels: { cache }).plan(slot: slot, agent: agent)
                collect(plan.steps); collect(plan.fallback ?? [])
            }
        }
        XCTAssertFalse(texts.isEmpty); XCTAssertFalse(keys.isEmpty)
        // Fixed US physical VK table, independent of the mapper's implementation.
        let punctuation: [UInt16: (UInt16, UInt32)] = [32:(0x20,0), 45:(0xBD,0), 46:(0xBE,0), 47:(0xBF,0), 58:(0xBA,16), 95:(0xBD,16)]
        for ch in Set(texts.utf16) {
            let mapped = WindowsConsoleKey.character(ch)
            let expected: (UInt16, UInt32)
            if ch == 13 { expected = (13,0) }
            else if ch == 9 { expected = (9,0) }
            else if ch == 8 || ch == 127 { expected = (8,0) }
            else if ch == 27 { expected = (27,0) }
            else if (1...26).contains(ch) { expected = (ch + 64,8) }
            else if (97...122).contains(ch) { expected = (ch - 32, 0) }
            else if (65...90).contains(ch) { expected = (ch, UInt32(SHIFT_PRESSED)) }
            else if (48...57).contains(ch) { expected = (ch, 0) }
            else { expected = try XCTUnwrap(punctuation[ch], "Add explicit expectation for planned scalar \(ch)") }
            XCTAssertEqual(mapped.vk, expected.0); XCTAssertEqual(mapped.modifiers, expected.1); XCTAssertEqual(mapped.character, ch == 127 ? 8 : ch)
            XCTAssertEqual(mapped.scan, UInt16(MapVirtualKeyW(UInt32(expected.0), UInt32(MAPVK_VK_TO_VSC))))
        }
        for key in keys {
            let expected: (UInt16, UInt16, UInt32)
            switch key {
            case .enter: expected = (0x0D,13,0)
            case .escape: expected = (0x1B,27,0)
            case .tab: expected = (0x09,9,0)
            case .backspace: expected = (0x08,8,0)
            case .up: expected = (0x26,0,256)
            case .down: expected = (0x28,0,256)
            case .left: expected = (0x25,0,256)
            case .right: expected = (0x27,0,256)
            case .home: expected = (0x24,0,256)
            case .end: expected = (0x23,0,256)
            case .pageUp: expected = (0x21,0,256)
            case .pageDown: expected = (0x22,0,256)
            case .ctrl(let c):
                let unit = UInt16(c.asciiValue! & 31)
                expected = (unit + 64,unit,8)
            }
            let mapped = WindowsConsoleKey.key(key)
            XCTAssertEqual(mapped.vk, expected.0); XCTAssertEqual(mapped.character, expected.1); XCTAssertEqual(mapped.modifiers, expected.2)
            XCTAssertEqual(mapped.scan, UInt16(MapVirtualKeyW(UInt32(expected.0), UInt32(MAPVK_VK_TO_VSC))))
        }
    }
    func testWindowsTerminalNoticeDoesNotMentionOrcaLag() {
        let target = Target(host: .windowsConsole(pid: 123, start: 456), agent: .codex, label: "Test")
        XCTAssertEqual(WindowsAppModel.targetLine(target), "Codex · Windows Terminal · Test")
        let result = SwitchResult(target: target, slotName: "", preset: .init(model: "gpt", effort: "high"), warning: nil, confirmations: [], pendingRestore: nil)
        XCTAssertFalse(WindowsAppModel.hud(result: result, tabLagNote: true).text.contains("Orca"))
        XCTAssertEqual(Launch.targetArguments(host: target.host, agent: .codex), ["--console","123","--agent","codex"])
    }
    private func fixture(records: Int32) throws -> (OpaquePointer, URL) {
        let directory = URL(fileURLWithPath: WindowsConsoleBridge.executable).deletingLastPathComponent()
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("sc-b13-\(UUID().uuidString).keys")
        let child = directory.appendingPathComponent("WindowsConsoleFixture.exe").path.withCString(encodedAs: UTF16.self) { exe in
            result.path.withCString(encodedAs: UTF16.self) { sc_test_console_start(exe, $0, records) }
        }
        return (try XCTUnwrap(child, "create our own pseudoconsole"), result)
    }
    private func waitReady(_ bridge: WindowsConsoleBridge) throws -> WindowsConsoleScreen {
        for _ in 0..<100 {
            if let screen = try? bridge.read(), screen.text.contains("READY") { return screen }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw WindowsTerminal.unreadable
    }
    private func testTarget(_ console: OpaquePointer) throws -> Target {
        let pid = sc_test_console_pid(console)
        let process = try XCTUnwrap(OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid))
        defer { CloseHandle(process) }
        return Target(host: .windowsConsole(pid: Int32(bitPattern: pid), start: try XCTUnwrap(Proc.startTime(process))), agent: .claude, label: "fixture")
    }
    private func fixtureIO(_ target: Target, bridge: WindowsConsoleBridge, foreground: @escaping () -> UInt?,
                           focused: @escaping (UInt) throws -> WindowsTerminal.Pane) throws -> WindowsConsoleIO {
        try WindowsConsoleIO(target: target, bridge: bridge, foreground: foreground, focused: focused, validate: { members, agent, _ in
            guard case .windowsConsole(let pid, let start) = target.host, members.contains(where: { $0.pid == UInt32(bitPattern: pid) }) else { throw WindowsTerminal.changed }
            return (.init(agent: agent, pid: pid), start)
        })
    }
    func testRealBridgeMembersIncludeTheOwnedProcessStartTime() throws {
        let (console, result) = try fixture(records: 2)
        defer { sc_test_console_close(console); try? FileManager.default.removeItem(at: result) }
        let bridge = try WindowsConsoleBridge(pid: Int32(bitPattern: sc_test_console_pid(console)))
        defer { bridge.close() }
        let screen = try waitReady(bridge)
        guard case .windowsConsole(let pid, let start) = try testTarget(console).host else { return XCTFail("console target") }
        let member = try XCTUnwrap(screen.members.first { $0.pid == UInt32(bitPattern: pid) })
        XCTAssertGreaterThan(member.start, 0); XCTAssertEqual(member.start, start)
        XCTAssertEqual(try bridge.members(), screen.members)
    }
    func testIORechecksFocusedPaneBeforeEveryChunk() throws {
        let (console, result) = try fixture(records: 2)
        defer { sc_test_console_close(console); try? FileManager.default.removeItem(at: result) }
        let bridge = try WindowsConsoleBridge(pid: Int32(bitPattern: sc_test_console_pid(console)))
        defer { bridge.close() }
        _ = try waitReady(bridge)
        var target = try testTarget(console)
        target.windowsWindow = 123; target.windowsPaneIdentity = "pane"; target.windowsRequiresForeground = true
        var checks = 0
        let io = try fixtureIO(target, bridge: bridge, foreground: { 123 }, focused: { _ in
            checks += 1; return .init(text: try bridge.read().text, identity: checks == 1 ? "pane" : "other")
        })
        try io.type("a")
        XCTAssertThrowsError(try io.type("b"))
        XCTAssertEqual(checks, 2); XCTAssertEqual(io.lastFailure, String(describing: WindowsTerminal.changed))
        XCTAssertNil(io.screen()); XCTAssertThrowsError(try io.press(.enter))
        XCTAssertEqual(checks, 2, "target failure is sticky")
        bridge.close()
        let records = try String(contentsOf: result, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(records.count, 2, "only the first chunk's pair was written")
        XCTAssertTrue(records.allSatisfy { $0.contains(",97,") })
    }
    func testIORefusesForegroundWindowChangeBeforeReadingOrWriting() throws {
        let (console, result) = try fixture(records: 2)
        defer { sc_test_console_close(console); try? FileManager.default.removeItem(at: result) }
        let bridge = try WindowsConsoleBridge(pid: Int32(bitPattern: sc_test_console_pid(console)))
        defer { bridge.close() }
        _ = try waitReady(bridge)
        var target = try testTarget(console)
        target.windowsWindow = 123; target.windowsPaneIdentity = "pane"; target.windowsRequiresForeground = true
        let io = try fixtureIO(target, bridge: bridge, foreground: { 456 }, focused: { _ in XCTFail("must stop before UIA"); throw WindowsTerminal.changed })
        XCTAssertNil(io.screen()); XCTAssertThrowsError(try io.press(.enter))
        XCTAssertNotNil(io.lastFailure)
        bridge.close()
        XCTAssertEqual(try Data(contentsOf: result).count, 0)
    }
    func testIORefusesUnreadableUIAFocusBeforeWriting() throws {
        let (console, result) = try fixture(records: 2)
        defer { sc_test_console_close(console); try? FileManager.default.removeItem(at: result) }
        let bridge = try WindowsConsoleBridge(pid: Int32(bitPattern: sc_test_console_pid(console)))
        defer { bridge.close() }
        _ = try waitReady(bridge)
        var target = try testTarget(console)
        target.windowsWindow = 123; target.windowsPaneIdentity = "pane"; target.windowsRequiresForeground = true
        let io = try fixtureIO(target, bridge: bridge, foreground: { 123 }, focused: { _ in throw WindowsTerminal.unreadable })
        XCTAssertThrowsError(try io.press(.enter)); XCTAssertNotNil(io.lastFailure)
        bridge.close(); XCTAssertEqual(try Data(contentsOf: result).count, 0)
    }
    func testExplicitConsoleSkipsForegroundAndUIA() throws {
        let (console, result) = try fixture(records: 2)
        defer { sc_test_console_close(console); try? FileManager.default.removeItem(at: result) }
        let bridge = try WindowsConsoleBridge(pid: Int32(bitPattern: sc_test_console_pid(console)))
        defer { bridge.close() }
        _ = try waitReady(bridge)
        let io = try fixtureIO(testTarget(console), bridge: bridge, foreground: { XCTFail("explicit console needs no foreground"); return nil },
                               focused: { _ in XCTFail("explicit console needs no UIA"); throw WindowsTerminal.unreadable })
        XCTAssertNotNil(io.screen()); try io.press(.enter); XCTAssertTrue(bridge.close())
        for _ in 0..<100 {
            if (try? Data(contentsOf: result).count) ?? 0 > 0 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8).split(separator: "\n").count, 2)
    }
    func testRealBridgeReadsAndWritesOnlyItsOwnPseudoConsoleAndExitsAtEOF() throws {
        let text = Array("/model".utf16).map(WindowsConsoleKey.character)
        let keys = text + [Key.enter,.escape,.up,.down,.left,.right,.home,.end,.pageUp,.pageDown,.tab,.backspace,.ctrl("s")].map(WindowsConsoleKey.key)
        let (console, result) = try fixture(records: Int32(keys.count * 2))
        defer { sc_test_console_close(console); try? FileManager.default.removeItem(at: result) }
        let bridge = try WindowsConsoleBridge(pid: Int32(bitPattern: sc_test_console_pid(console)))
        defer { bridge.close() }
        let screen = try waitReady(bridge)
        XCTAssertTrue(screen.text.contains("B13 synthetic console")); XCTAssertTrue(screen.text.contains("한글")); XCTAssertTrue(screen.text.contains("e\u{301}"))
        XCTAssertTrue(screen.members.contains { $0.pid == sc_test_console_pid(console) })
        try bridge.write(keys)   // one chunk, Escape included: the bridge still pauses after it
        XCTAssertTrue(bridge.close(), "bridge must exit normally after stdin EOF")
        for _ in 0..<200 {
            if sc_test_console_finished(console) == 1 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(sc_test_console_finished(console), 1)
        let records = try String(contentsOf: result, encoding: .utf8).split(separator: "\n").map(String.init)
        let expected = keys.flatMap { key in [1,0].map { "\($0),\(key.vk),\(key.scan),\(key.character),\(key.modifiers),1" } }
        XCTAssertEqual(records, expected, "every down/up record exactly once, with no extras")
    }
    func testBridgeRejectsRequestsAfterPinnedChildExits() throws {
        let (console, result) = try fixture(records: 2)
        defer { sc_test_console_close(console); try? FileManager.default.removeItem(at: result) }
        let bridge = try WindowsConsoleBridge(pid: Int32(bitPattern: sc_test_console_pid(console)))
        defer { bridge.close() }
        _ = try waitReady(bridge)
        try bridge.write([.key(.enter)])
        for _ in 0..<200 {
            if sc_test_console_finished(console) == 1 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(sc_test_console_finished(console), 1)
        XCTAssertThrowsError(try bridge.request("members")) { XCTAssertEqual(String(describing: $0), String(describing: WindowsTerminal.changed)) }
        XCTAssertTrue(bridge.close())
    }
    #endif
}
