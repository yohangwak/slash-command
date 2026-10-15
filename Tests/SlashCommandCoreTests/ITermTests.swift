import XCTest
@testable import SlashCommandCore

final class ITermWriteTests: XCTestCase {
    func testExpressionKeepsControlBytes() {
        XCTAssertEqual(ITermIO.expression(for: "\u{13}/model\r"), "(ASCII character 19) & \"/model\" & (ASCII character 13)")
        XCTAssertEqual(ITermIO.expression(for: "한글s"), "\"한글s\"")
        XCTAssertEqual(ITermIO.expression(for: "a\"b\\c"), "\"a\\\"b\\\\c\"")
        XCTAssertEqual(ITermIO.expression(for: ""), "\"\"")
    }

    func testWritingLooksOnlyInTheFrontWindow() {
        // The broadcast menu reflects the frontmost window, so the script that writes only looks for the session in that window and returns `missing` without writing if it is not there.
        let write = ITermIO.script(sessionID: "ABC", frontWindowOnly: true, body: "write text \"x\" newline NO\nreturn \"true\"")
        XCTAssertTrue(write.contains("set groups to unique id of sessions of tabs of current window"))
        XCTAssertTrue(write.contains("tell session id \"ABC\" of tab i of current window"))
        XCTAssertFalse(write.contains("of windows\n"), "Does not look at other windows")
        XCTAssertFalse(write.contains("window k"))
        XCTAssertTrue(write.hasSuffix("return \"missing\"\nend tell"), "missing when not found")
        // Screen reads find the session in any window.
        let read = ITermIO.script(sessionID: "ABC", frontWindowOnly: false, body: "return contents")
        XCTAssertTrue(read.contains("set everything to unique id of sessions of tabs of windows"))
        XCTAssertTrue(read.contains("tell session id \"ABC\" of tab i of window k"))
        XCTAssertFalse(read.contains("current window"))
    }

    func testAsksForTheSessionIDsOnce() {
        // No per-window, per-tab, per-session lookups: the call count stays the same however many sessions there are.
        for front in [true, false] {
            let script = ITermIO.script(sessionID: "ABC", frontWindowOnly: front, body: "return \"true\"")
            XCTAssertEqual(script.components(separatedBy: "unique id of").count - 1, 1, script)
            XCTAssertFalse(script.contains("repeat with s in"))
        }
    }

    func testSessionIDIsQuoted() {
        let script = ITermIO.script(sessionID: "a\"b", frontWindowOnly: true, body: "return \"true\"")
        XCTAssertTrue(script.contains("contains \"a\\\"b\" then"))
        XCTAssertTrue(script.contains("tell session id \"a\\\"b\" of tab i"))
    }

    func testFrontSessionAnswer() {
        let found = Detector.itermSession(from: "4ED8\n/dev/ttys002\nRepos (codex)")
        XCTAssertEqual(found?.id, "4ED8")
        XCTAssertEqual(found?.tty, "/dev/ttys002")
        XCTAssertEqual(found?.name, "Repos (codex)")
        // The id and tty are intact even if the name contains a newline.
        XCTAssertEqual(Detector.itermSession(from: "4ED8\n/dev/ttys002\na\nb")?.name, "a\nb")
        XCTAssertNil(Detector.itermSession(from: ""), "No window")
        XCTAssertNil(Detector.itermSession(from: "4ED8\n/dev/ttys002"), "Does not guess when the format differs")
    }

    func testITermIsASupportedTerminal() {
        XCTAssertTrue(Detector.supportedBundleIDs.contains("com.googlecode.iterm2"))
        XCTAssertEqual(TerminalHost.iterm(sessionID: "x").appName, "iTerm2")
    }
}

final class ITermScreenTests: XCTestCase {
    private func output(rows: Int, columns: Int = 80, _ lines: [String]) -> String {
        "\(rows)\n\(columns)\n" + lines.joined(separator: "\n") + "\n"
    }

    /// The screen as read with iTerm2's default profile (ambiguous-width characters take 1 cell).
    private func visible(_ output: String, wide: Bool = false) -> [String]? {
        ITermIO.visibleLines(from: output, ambiguousIsDoubleWidth: wide)
    }

    func testKeepsOnlyTheVisibleRows() {
        let history = (1...5).map { "old \($0)" }
        XCTAssertEqual(visible(output(rows: 3, history + ["a", "b", "c"])), ["a", "b", "c"])
    }

    func testOldPromptInScrollbackIsNotTheCurrentScreen() {
        // Scrollback above the cleared screen (3 blank lines) still holds an old claude input box; it is not on the current screen.
        let scrollback = ["────────", "❯ ", "────────", "  ⏵⏵ auto mode on (shift+tab to cycle)"]
        for wide in [false, true] {
            let screen = visible(output(rows: 3, scrollback + ["", "", ""]), wide: wide)
            XCTAssertEqual(screen, ["", "", ""])
            XCTAssertFalse(Readiness.claudePromptVisible(screen ?? []), "An empty screen shows no input box")
        }
        // Positive control: the same text is visible when it really is at the bottom of the screen.
        let live = visible(output(rows: 4, scrollback))
        XCTAssertTrue(Readiness.claudePromptVisible(live ?? []))
    }

    func testWrappedLogicalLinesCountAsSeveralRows() {
        // One line is twice the column count so it takes 2 rows: 3-row screen = (long line, 2 rows) + 1 row. The old input box above that is off screen.
        let old = ["────────", "❯ ", "────────", "  ⏵⏵ auto mode on (shift+tab to cycle)"]
        let wrapped = String(repeating: "x", count: 160)
        let screen = visible(output(rows: 3, columns: 80, old + [wrapped, "END"]))
        XCTAssertEqual(screen, [wrapped, "END"])
        XCTAssertFalse(Readiness.claudePromptVisible(screen ?? []))
        // The answer is the same when soft wraps are emitted as line breaks (one line per physical row).
        let split = visible(output(rows: 3, columns: 80, old + [String(repeating: "x", count: 80), String(repeating: "x", count: 80), "END"]))
        XCTAssertEqual(split?.last, "END")
        XCTAssertEqual(split?.count, 3)
    }

    func testWideCharactersTakeTwoCells() {
        // 50 Korean characters = 100 cells -> 2 rows on an 80-column screen (independent of the profile setting).
        let korean = String(repeating: "한", count: 50)
        for wide in [false, true] {
            XCTAssertEqual(visible(output(rows: 3, columns: 80, ["위", "중간", korean, "끝"]), wide: wide), [korean, "끝"])
        }
    }

    func testAmbiguousWidthCharactersFollowTheProfile() {
        // Box rule of 80 characters: with the default profile (1 cell) it is one row on an 80-column screen. It used to be counted as 2 cells, so it looked like 2 rows and dropped the line above.
        let separator = String(repeating: "─", count: 80)
        let contents = ["scrollback", "위", separator, "❯ ", separator]
        XCTAssertEqual(visible(output(rows: 4, columns: 80, contents)), ["위", separator, "❯ ", separator])
        // With a 2-cell profile the same line takes 2 rows: 4-row screen = separator (2) + input line (1); the separator above it (2) does not fit.
        XCTAssertEqual(visible(output(rows: 4, columns: 80, contents), wide: true), ["❯ ", separator])
        XCTAssertEqual(ITermIO.displayWidth("› 1. GPT · x", ambiguousIsDoubleWidth: false), 12)
        // `·` (U+00B7) is ambiguous-width and so takes 2 cells, but `›` (U+203A) and `❯` (U+276F) are not; they stay 1 cell even with that setting on.
        XCTAssertEqual(ITermIO.displayWidth("› 1. GPT · x", ambiguousIsDoubleWidth: true), 13)
        XCTAssertEqual(ITermIO.displayWidth("❯ ›", ambiguousIsDoubleWidth: true), 3)
        XCTAssertEqual(ITermIO.displayWidth("─●…", ambiguousIsDoubleWidth: true), 6)
        XCTAssertEqual(ITermIO.displayWidth("─●…", ambiguousIsDoubleWidth: false), 3)
        XCTAssertEqual(ITermIO.displayWidth("🙂", ambiguousIsDoubleWidth: false), 2)
        XCTAssertEqual(ITermIO.displayWidth("한글 ok", ambiguousIsDoubleWidth: false), 7)
        XCTAssertEqual(ITermIO.displayWidth("e\u{301}", ambiguousIsDoubleWidth: true), 1, "A combining character takes no cell")
        XCTAssertEqual(ITermIO.displayWidth("全角ａ", ambiguousIsDoubleWidth: false), 6)
    }

    /// PR #27 review, measured 2026-10-12 on a test Mac: do not lose the header on a screen where the picker fills the columns «exactly».
    /// (A row filled exactly to the column count, `› 1. …`, and the hint line `enter select · esc back` were counted as 2 rows each, so the top line was dropped → the picker was not recognized and was left open.)
    func testAPickerThatExactlyFillsThePaneKeepsItsHeader() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "codex-38-models", withExtension: "json", subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let all = try XCTUnwrap(object["tail"] as? [String])
        let picker = Array(all.suffix(12))
        XCTAssertTrue(picker[0].contains("Select Model and Effort"))
        XCTAssertEqual(picker.filter { $0.count == 38 }.count, 2, "Two lines fit the column count exactly (cursor row and hint line)")
        // Even with scrollback above, a 12-row screen is those 12 lines.
        let screen = try XCTUnwrap(visible(output(rows: 12, columns: 38, ["• old output", "› old prompt"] + picker)))
        XCTAssertEqual(screen, picker)
        let open = try XCTUnwrap(Picker.open(screen))
        XCTAssertTrue(open.header.hasPrefix("Select Model and Effort"))
        XCTAssertEqual(open.rows.count, 7)
    }

    /// PR #27 third review: on a 2-cell profile (also how it counts when the profile is unknown), do not lose the header of a picker that is fully visible on screen.
    /// `›` on the cursor row is not ambiguous-width and takes one 38-cell row; only `·` in the hint line takes 2 cells, making it 2 rows — the picker fits in exactly 13 rows.
    func testAPickerKeepsItsHeaderInADoubleWidthProfileToo() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "codex-38-models", withExtension: "json", subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let picker = Array(try XCTUnwrap(object["tail"] as? [String]).suffix(12))
        let screen = try XCTUnwrap(visible(output(rows: 13, columns: 38, ["• old output", "› old prompt"] + picker), wide: true))
        XCTAssertEqual(screen, picker)
        XCTAssertTrue(try XCTUnwrap(Picker.open(screen)).header.hasPrefix("Select Model and Effort"))
        // One row short (12 rows) and the top line really is off screen.
        XCTAssertEqual(visible(output(rows: 12, columns: 38, picker), wide: true)?.count, 11)
    }

    /// PR #27 fourth review: characters unknown to this table's version (Unicode 16) are counted as wide — iTerm2 3.7.3 draws U+1FAEA (an emoji from Unicode 17) in 2 cells.
    /// 4 rows × 80 columns: the two lines below are 81 cells each, so they take 2 rows each. The codex input line above them is off screen.
    func testCharactersNewerThanTheTableCountAsWide() throws {
        let newer = String(try XCTUnwrap(Unicode.Scalar(0x1FAEA as UInt32)))
        let long = " " + String(repeating: "x", count: 78) + newer
        for wide in [false, true] {
            XCTAssertEqual(ITermIO.displayWidth(long, ambiguousIsDoubleWidth: wide), 81)
            let screen = visible(output(rows: 4, columns: 80, ["› old prompt", long, long]), wide: wide)
            XCTAssertEqual(screen, [long, long])
            XCTAssertFalse(Readiness.codexComposerVisible(screen ?? []), "Does not allow input based on an off-screen input line")
        }
        // Positive control: if those two lines are 80 cells each, all three lines are on screen and the input line is visible.
        let short = " " + String(repeating: "x", count: 79)
        XCTAssertTrue(Readiness.codexComposerVisible(visible(output(rows: 4, columns: 80, ["› old prompt", short, short])) ?? []))
        // A character followed by an emoji variation selector is also counted as wide (❤ U+2764 alone is 1 cell).
        XCTAssertEqual(ITermIO.displayWidth("\u{2764}", ambiguousIsDoubleWidth: false), 1)
        XCTAssertEqual(ITermIO.displayWidth("\u{2764}\u{FE0F}", ambiguousIsDoubleWidth: false), 2)
        XCTAssertEqual(ITermIO.displayWidth("\u{E0A0}", ambiguousIsDoubleWidth: false), 1, "Private-use characters (icon fonts) are ambiguous-width")
        XCTAssertEqual(ITermIO.displayWidth("\u{E0A0}", ambiguousIsDoubleWidth: true), 2)
    }

    /// PR #27 re-review: with the "Ambiguous characters are double-width" profile, do not read an off-screen input box as being on screen.
    /// Only two separators are visible on a 4-row × 80-column screen (2 rows each on a 2-cell profile) — the `❯` above them is scrollback.
    func testAnOffScreenPromptIsNotReadyInADoubleWidthProfile() {
        let rule = String(repeating: "─", count: 80)
        let contents = output(rows: 4, columns: 80, [rule, "❯ ", rule, rule])
        let screen = visible(contents, wide: true)
        XCTAssertEqual(screen, [rule, rule])
        XCTAssertFalse(Readiness.claudePromptVisible(screen ?? []), "Does not allow input based on an invisible input box")
        // Counted as 2 cells even when the profile is unknown — `screen()` calls it that way (`?? true`).
        // Positive control: on a 1-cell profile those four lines really are the screen and the input box is visible.
        XCTAssertTrue(Readiness.claudePromptVisible(visible(contents, wide: false) ?? []))
    }

    /// PR #27 review (left unresolved): the profile says 1 cell but that one session was switched to 2 cells (Edit Session…), which cannot be known from the profile name.
    /// If the input box exists only on the screen counted at 1 cell (off screen when counted at 2), input is not allowed.
    func testAPromptSeenOnlyUnderTheNarrowReadingDoesNotAuthorizeInput() throws {
        let rule = String(repeating: "─", count: 80)
        let stale = output(rows: 4, columns: 80, [rule, "❯ ", rule, rule])
        let screen = try XCTUnwrap(ITermIO.screenLines(from: stale, profileIsDoubleWidth: false))
        XCTAssertEqual(screen, [rule, rule], "Returns the screen counted at 2 cells even if the profile says 1 cell")
        XCTAssertFalse(Readiness.claudePromptVisible(screen))
        // Positive control: an input box that is visible even when counted at 2 cells (7 rows hold separator 2+2, input 1, status 2) is still allowed — using the 1-cell screen.
        let live = output(rows: 9, columns: 80, ["old", rule, "❯ ", rule, "  status | Opus 5.5 · high", "  ⏵⏵ auto mode on (shift+tab to cycle)"])
        let ready = try XCTUnwrap(ITermIO.screenLines(from: live, profileIsDoubleWidth: false))
        XCTAssertTrue(Readiness.claudePromptVisible(ready))
        XCTAssertEqual(ready.first, "old", "Screen counted at 1 cell (including the top line)")
    }

    func testPickerScreensStayOnTheNarrowReadingAndUnknownProfilesOnTheWideOne() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "codex-38-models", withExtension: "json", subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let picker = Array(try XCTUnwrap(object["tail"] as? [String]).suffix(12))
        let contents = output(rows: 12, columns: 38, ["• old output"] + picker)
        // 1-cell profile: a screen without an input box (a picker) stays as counted at 1 cell — the header remains.
        XCTAssertEqual(ITermIO.screenLines(from: contents, profileIsDoubleWidth: false), picker)
        // 2-cell profile or unknown profile: the screen counted at 2 cells (12 rows is one line short).
        XCTAssertEqual(ITermIO.screenLines(from: contents, profileIsDoubleWidth: true)?.count, 11)
        XCTAssertEqual(ITermIO.screenLines(from: contents, profileIsDoubleWidth: nil)?.count, 11)
        XCTAssertNil(ITermIO.screenLines(from: "x\n80\nhello", profileIsDoubleWidth: false))
    }

    func testRefusesWhenRowsOrColumnsAreUnknown() {
        XCTAssertNil(visible("x\n80\nhello"))
        XCTAssertNil(visible("0\n80\nhello"))
        XCTAssertNil(visible("25\nhello"))
        XCTAssertNil(visible(""))
    }
}

final class ITermProfileTests: XCTestCase {
    private func store(_ profiles: [[String: Any]], defaultGUID: String? = "G-default") -> ITermProfile.Store {
        ITermProfile.Store(profiles: profiles, defaultGUID: defaultGUID)
    }

    func testReadsTheProfileSetting() {
        let profiles: [[String: Any]] = [["Name": "Default", "Guid": "G-default", "Ambiguous Double Width": false],
                                         ["Name": "CJK", "Guid": "G-cjk", "Ambiguous Double Width": true],
                                         ["Name": "Plain", "Guid": "G-plain"]]
        XCTAssertEqual(ITermProfile.ambiguousIsDoubleWidth(named: "Default", in: store(profiles)), false)
        XCTAssertEqual(ITermProfile.ambiguousIsDoubleWidth(named: "CJK", in: store(profiles)), true)
        XCTAssertEqual(ITermProfile.ambiguousIsDoubleWidth(named: "Plain", in: store(profiles)), false, "A profile in the settings file is off when the key is missing")
        XCTAssertNil(ITermProfile.ambiguousIsDoubleWidth(named: "Gone", in: store(profiles)), "An unknown profile is unknown (the caller counts it at 2 cells)")
        XCTAssertNil(ITermProfile.ambiguousIsDoubleWidth(named: "Default", in: store([])))
    }

    func testProfilesWithTheSameNameMustAgree() {
        let same: [[String: Any]] = [["Name": "Work", "Ambiguous Double Width": true], ["Name": "Work", "Ambiguous Double Width": true]]
        XCTAssertEqual(ITermProfile.ambiguousIsDoubleWidth(named: "Work", in: store(same)), true)
        let differ: [[String: Any]] = [["Name": "Work", "Ambiguous Double Width": true], ["Name": "Work", "Ambiguous Double Width": false]]
        XCTAssertNil(ITermProfile.ambiguousIsDoubleWidth(named: "Work", in: store(differ)))
    }

    func testDynamicProfilesInheritFromTheirParent() throws {
        let json = #"{"Profiles":[{"Name":"Dyn wide","Guid":"D1","Ambiguous Double Width":true},{"Name":"Dyn child","Guid":"D2","Dynamic Profile Parent Name":"CJK"},{"Name":"Dyn default","Guid":"D3"},{"Name":"Dyn orphan","Guid":"D4","Dynamic Profile Parent Name":"Nope"}]}"#
        let dynamic = ITermProfile.dynamicProfiles(in: Data(json.utf8))
        XCTAssertEqual(dynamic.count, 4)
        let base: [[String: Any]] = [["Name": "Default", "Guid": "G-default"], ["Name": "CJK", "Guid": "G-cjk", "Ambiguous Double Width": true]]
        let all = store(base + dynamic)
        XCTAssertEqual(ITermProfile.ambiguousIsDoubleWidth(named: "Dyn wide", in: all), true)
        XCTAssertEqual(ITermProfile.ambiguousIsDoubleWidth(named: "Dyn child", in: all), true, "A value not written comes from the parent profile")
        XCTAssertEqual(ITermProfile.ambiguousIsDoubleWidth(named: "Dyn default", in: all), false, "Without a parent, the default profile")
        XCTAssertNil(ITermProfile.ambiguousIsDoubleWidth(named: "Dyn orphan", in: all), "Unknown when the parent is not found")
        XCTAssertTrue(ITermProfile.dynamicProfiles(in: Data("not a profile file".utf8)).isEmpty)
    }

    /// PR #27 third review: the parent is looked up by GUID first (same order as iTerm2). If the parent by name (1 cell) and the parent by GUID (2 cells) differ, the GUID one wins.
    func testDynamicParentIsFoundByGUIDBeforeName() {
        let base: [[String: Any]] = [["Name": "Narrow", "Guid": "G-narrow", "Ambiguous Double Width": false],
                                     ["Name": "Wide", "Guid": "G-wide", "Ambiguous Double Width": true]]
        let json = #"{"Profiles":[{"Name":"Child","Guid":"D1","Dynamic Profile Parent Name":"Narrow","Dynamic Profile Parent GUID":"G-wide"},{"Name":"Stale guid","Guid":"D2","Dynamic Profile Parent Name":"Wide","Dynamic Profile Parent GUID":"G-gone"}]}"#
        let all = store(base + ITermProfile.dynamicProfiles(in: Data(json.utf8)))
        let wide = ITermProfile.ambiguousIsDoubleWidth(named: "Child", in: all)
        XCTAssertEqual(wide, true)
        XCTAssertEqual(ITermProfile.ambiguousIsDoubleWidth(named: "Stale guid", in: all), true, "Falls back to the name when the GUID is not found")
        // Cutting the screen with that answer keeps the off-screen input box out.
        let rule = String(repeating: "─", count: 80)
        let screen = ITermIO.visibleLines(from: "4\n80\n" + [rule, "❯ ", rule, rule].joined(separator: "\n") + "\n", ambiguousIsDoubleWidth: wide ?? true)
        XCTAssertEqual(screen, [rule, rule])
        XCTAssertFalse(Readiness.claudePromptVisible(screen ?? []))
    }
}

final class ITermBroadcastTests: XCTestCase {
    /// iTerm2 3.7.3's Shell ▸ Broadcast Input menu (exactly as read on a test Mac on 2026-10-12).
    static let titles = ["Send Input to Current Session Only", "Broadcast Input to All Panes in All Tabs",
                         "Broadcast Input to All Panes in Current Tab", "Toggle Broadcast Input to Current Session",
                         "Show Background Pattern Indicator", "Current Session is Broadcast Source"]

    private func menu(marked: Set<String>) -> [ITermBroadcast.MenuItem] {
        ITermBroadcastTests.titles.map { ITermBroadcast.MenuItem(title: $0, marked: marked.contains($0)) }
    }

    func testOnlyCurrentSessionChecked_IsOff() {
        XCTAssertEqual(ITermBroadcast.classify(menu(marked: ["Send Input to Current Session Only"])), .off)
        XCTAssertTrue(ITermBroadcast.classify(menu(marked: ["Send Input to Current Session Only"])).allowsSending)
    }

    func testAnyAllPanesModeIsOn() {
        for mode in ["Broadcast Input to All Panes in Current Tab", "Broadcast Input to All Panes in All Tabs"] {
            let state = ITermBroadcast.classify(menu(marked: [mode]))
            XCTAssertEqual(state, .on(mode))
            XCTAssertFalse(state.allowsSending)
        }
        // It is still a broadcast when the broadcast indicator is on as well.
        XCTAssertFalse(ITermBroadcast.classify(menu(marked: ["Broadcast Input to All Panes in All Tabs", "Show Background Pattern Indicator"])).allowsSending)
    }

    func testUnreadableOrUnrecognizedIsNeverOff() {
        XCTAssertFalse(ITermBroadcast.classify([]).allowsSending, "Does not send when the menu is not found")
        XCTAssertFalse(ITermBroadcast.classify(menu(marked: [])).allowsSending, "Unknown when nothing is checked")
        XCTAssertFalse(ITermBroadcast.classify(menu(marked: ["Toggle Broadcast Input to Current Session"])).allowsSending, "Broadcast to a chosen group of panes")
        XCTAssertFalse(ITermBroadcast.State.notTrusted.allowsSending, "Does not send when it could not be read for lack of permission")
    }
}

final class WrappedNeedleTests: XCTestCase {
    private let needle = "choose what model and reasoning effort"

    func testFindsANeedleOnOneLine() {
        XCTAssertTrue(Runner.contains(needle, in: ["› /model", "  /model   choose what model and reasoning effort to use"]))
    }

    func testFindsANeedleFoldedOverTwoLines() {
        // codex in an iTerm2 pane split to 38 cells (measured 2026-10-12): the command description wraps onto two lines.
        let narrow = ["› /model  choose what model and       ", "          reasoning effort to use     ", "› /model ", "  GPT-6-Astra high · ~/Repos "]
        XCTAssertTrue(Runner.contains(needle, in: narrow))
    }

    func testDoesNotJoinLinesThatAreNotNeighbours() {
        XCTAssertFalse(Runner.contains(needle, in: ["choose what model and", "something else", "reasoning effort to use"]))
        XCTAssertFalse(Runner.contains(needle, in: []))
        XCTAssertFalse(Runner.contains(needle, in: ["choose what model and"]))
    }
}

/// codex 0.162.0 in an iTerm2 pane split to 38 cells (screen captured on a test Mac on 2026-10-12).
final class NarrowCodexTests: XCTestCase {
    private func lines(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(object["tail"] as? [String])
    }

    func testFindsTheFoldedCommandHint() throws {
        let shown = try lines("codex-38-slash-model").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertFalse(shown.contains { $0.contains("choose what model and reasoning effort") }, "Not on one line — it wrapped")
        XCTAssertTrue(Runner.contains("choose what model and reasoning effort", in: Array(shown.suffix(5))))
    }

    func testReadsTheFoldedEffortHeader() throws {
        let open = try XCTUnwrap(Picker.open(try lines("codex-38-effort")))
        XCTAssertTrue(open.header.hasPrefix("Select Reasoning Level for GPT-6-Astra"), open.header)
        XCTAssertFalse(open.header.hasPrefix("Select Reasoning Level for GPT-6.1-Sol"), "Does not read it as another model's list")
        XCTAssertEqual(open.rows.count, 5)
        XCTAssertTrue(open.footer.contains("s session"))
    }

    func testReadsTheModelList() throws {
        let open = try XCTUnwrap(Picker.open(try lines("codex-38-models")))
        XCTAssertTrue(open.header.hasPrefix("Select Model and Effort"))
        XCTAssertEqual(open.rows.count, 7)
    }
}

final class LaunchTerminalTests: XCTestCase {
    func testKnowsTheTerminalItRunsIn() {
        XCTAssertEqual(Launch.currentTerminal(environment: ["ORCA_TERMINAL_HANDLE": "term_1"]), .orca(handle: "term_1"))
        XCTAssertEqual(Launch.currentTerminal(environment: ["ITERM_SESSION_ID": "w0t1p0:5B1E-AA"]), .iterm(sessionID: "5B1E-AA"))
        XCTAssertEqual(Launch.currentTerminal(environment: ["WEZTERM_PANE": "3", "WEZTERM_UNIX_SOCKET": "/tmp/gui-sock-1"]),
                       .wezterm(socket: "/tmp/gui-sock-1", pane: "3"))
        XCTAssertEqual(Launch.currentTerminal(environment: ["WEZTERM_PANE": "3"]), .wezterm(socket: nil, pane: "3"))
        XCTAssertEqual(Launch.currentTerminal(environment: ["KITTY_WINDOW_ID": "7", "KITTY_LISTEN_ON": "unix:/tmp/kitty"]),
                       .kitty(socket: "unix:/tmp/kitty", window: "7"))
        XCTAssertNil(Launch.currentTerminal(environment: ["KITTY_WINDOW_ID": "7"]), "A kitty started without remote control cannot be targeted")
        XCTAssertNil(Launch.currentTerminal(environment: ["TERM_PROGRAM": "ghostty"]), "Ghostty cannot be detected from environment variables")
        XCTAssertNil(Launch.currentTerminal(environment: ["ITERM_SESSION_ID": "garbage"]))
        XCTAssertNil(Launch.currentTerminal(environment: ["ORCA_TERMINAL_HANDLE": ""]))
    }

    func testTmuxInsideAnotherTerminalIsTheInnermostOne() {
        let inside = ["TMUX": "/private/tmp/tmux-501/work,4242,0", "TMUX_PANE": "%3", "ORCA_TERMINAL_HANDLE": "term_1", "ITERM_SESSION_ID": "w0t0p0:X"]
        XCTAssertEqual(Launch.currentTerminal(environment: inside), .tmux(socket: "/private/tmp/tmux-501/work", pane: "%3"))
        XCTAssertEqual(Launch.currentTerminal(environment: ["TMUX": "/tmp/x,1,0", "ORCA_TERMINAL_HANDLE": "term_1"]), .orca(handle: "term_1"),
                       "Without a pane id it is not treated as tmux")
    }

    func testTargetArgumentsRoundTrip() {
        XCTAssertEqual(Launch.targetArguments(host: .orca(handle: "term_1"), agent: .opencode), ["--orca", "term_1", "--agent", "opencode"])
        XCTAssertEqual(Launch.targetArguments(host: .tmux(socket: "/tmp/s", pane: "%3"), agent: .opencode),
                       ["--tmux", "%3", "--tmux-socket", "/tmp/s", "--agent", "opencode"])
        XCTAssertEqual(Launch.targetArguments(host: .tmux(socket: nil, pane: "%3"), agent: .codex), ["--tmux", "%3", "--agent", "codex"])
        XCTAssertEqual(Launch.targetArguments(host: .wezterm(socket: "/tmp/g", pane: "3"), agent: .opencode),
                       ["--wezterm", "3", "--wezterm-socket", "/tmp/g", "--agent", "opencode"])
        XCTAssertEqual(Launch.targetArguments(host: .kitty(socket: "unix:/tmp/k", window: "7"), agent: .opencode),
                       ["--kitty", "7", "--kitty-socket", "unix:/tmp/k", "--agent", "opencode"])
        XCTAssertEqual(Launch.targetArguments(host: .iterm(sessionID: "X"), agent: .opencode), ["--iterm", "X", "--agent", "opencode"])
        XCTAssertEqual(Launch.targetArguments(host: .ghostty(terminalID: "G"), agent: .opencode), ["--ghostty", "G", "--agent", "opencode"])
    }
}

final class FollowTests: XCTestCase {
    func testWaitsUntilTheInputBoxIsSeenTwiceInARow() {
        var reads = [false, true, false, true, true]
        var slept = 0
        var applied = 0
        let outcome = Follow.run(timeoutMs: 5000, pollMs: 100, sleep: { slept += $0 },
                                 ready: { reads.isEmpty ? true : reads.removeFirst() }, apply: { applied += 1; return "GLM · high" })
        XCTAssertEqual(outcome, "applied — GLM · high")
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(slept, 400, "Does not start after seeing it once — starts on the fifth read")
    }

    func testGivesUpWithoutSendingWhenTheInputBoxNeverShows() {
        var applied = 0
        let outcome = Follow.run(timeoutMs: 1000, pollMs: 250, sleep: { _ in }, ready: { false }, apply: { applied += 1; return "" })
        XCTAssertTrue(outcome.hasPrefix("not applied — the input box did not appear"), outcome)
        XCTAssertEqual(applied, 0)
    }

    /// PR #29 review: once the session it opened has ended (failed or closed by the user) the worker gives up — even if another session in the same terminal shows an input box, it does not write.
    func testStopsWhenTheLaunchedSessionIsGone() {
        var alive = [true, true, false]
        var applied = 0
        let outcome = Follow.run(timeoutMs: 5000, pollMs: 100, sleep: { _ in },
                                 alive: { alive.isEmpty ? false : alive.removeFirst() }, ready: { false }, apply: { applied += 1; return "" })
        XCTAssertTrue(outcome.hasPrefix("not applied — the session this was opened for is no longer running"), outcome)
        XCTAssertEqual(applied, 0)
        // The same applies when it ends right before applying, after the input box was seen twice.
        var checks = 0
        let late = Follow.run(timeoutMs: 5000, pollMs: 100, sleep: { _ in }, alive: { checks += 1; return checks <= 2 }, ready: { true },
                              apply: { applied += 1; return "" })
        XCTAssertTrue(late.hasPrefix("not applied — the session this was opened for"), late)
        XCTAssertEqual(applied, 0)
        // If it never became that agent (opening failed), it gives up after 5 seconds — meanwhile it does not write even if another session's input box is visible.
        var slept = 0
        let never = Follow.run(timeoutMs: 30_000, pollMs: 250, sleep: { slept += $0 }, alive: { false }, ready: { true }, apply: { applied += 1; return "" })
        XCTAssertTrue(never.hasPrefix("not applied — the session this was opened for"), never)
        XCTAssertEqual(slept, 5000)
        XCTAssertEqual(applied, 0)
    }

    func testTheLaunchedProcessIsKnownByPIDAndStartTime() {
        let launched = Follow.Launched(pid: 4242, started: 1_791_000_000_123_456)
        XCTAssertEqual(Follow.Launched(argument: launched.argument), launched)
        XCTAssertNil(Follow.Launched(argument: "4242"))
        XCTAssertNil(Follow.Launched(argument: "x:y"))
        func entry(_ pid: Int32, foreground: Bool = true, _ arguments: String...) -> ProcessTable.Entry {
            ProcessTable.Entry(pid: pid, parent: 1, hasTerminal: true, terminalDevice: 1, processGroup: pid, foregroundGroup: foreground ? pid : 1,
                               arguments: arguments, environment: [], executable: "")
        }
        let same: (Int32) -> UInt64? = { $0 == 4242 ? 1_791_000_000_123_456 : nil }
        XCTAssertTrue(launched.isRunning(.opencode, entries: [entry(4242, "opencode")], startTime: same))
        XCTAssertFalse(launched.isRunning(.opencode, entries: [entry(4242, "slashcommand", "run", "2", "opencode")], startTime: same), "Not yet exec'd")
        XCTAssertFalse(launched.isRunning(.opencode, entries: [entry(4242, "opencode")], startTime: { _ in 7 }), "A different process with the same pid")
        XCTAssertFalse(launched.isRunning(.opencode, entries: [entry(4242, foreground: false, "opencode")], startTime: same), "A session stopped with Ctrl-Z")
        XCTAssertFalse(launched.isRunning(.opencode, entries: [entry(9, "opencode")], startTime: same), "Another opencode is not that session")
        XCTAssertFalse(launched.isRunning(.opencode, entries: [], startTime: { _ in nil }), "Ended")
    }

    func testReportsWhyTheSwitchFailed() {
        let outcome = Follow.run(timeoutMs: 1000, pollMs: 250, sleep: { _ in }, ready: { true },
                                 apply: { throw SlashCommandError("no such row") })
        XCTAssertEqual(outcome, "not applied — no such row")
    }
}
