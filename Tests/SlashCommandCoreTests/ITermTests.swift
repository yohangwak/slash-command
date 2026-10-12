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
        // 방송 메뉴는 맨 앞 창의 상태다 — 쓰는 스크립트는 그 창 안에서만 세션을 찾고, 없으면 쓰지 않고 `missing` 을 돌려준다.
        let write = ITermIO.script(sessionID: "ABC", frontWindowOnly: true, body: "write text \"x\" newline NO\nreturn \"true\"")
        XCTAssertTrue(write.contains("set groups to unique id of sessions of tabs of current window"))
        XCTAssertTrue(write.contains("tell session id \"ABC\" of tab i of current window"))
        XCTAssertFalse(write.contains("of windows\n"), "다른 창은 보지 않는다")
        XCTAssertFalse(write.contains("window k"))
        XCTAssertTrue(write.hasSuffix("return \"missing\"\nend tell"), "못 찾으면 missing")
        // 화면 읽기는 어느 창의 세션이든 찾는다.
        let read = ITermIO.script(sessionID: "ABC", frontWindowOnly: false, body: "return contents")
        XCTAssertTrue(read.contains("set everything to unique id of sessions of tabs of windows"))
        XCTAssertTrue(read.contains("tell session id \"ABC\" of tab i of window k"))
        XCTAssertFalse(read.contains("current window"))
    }

    func testAsksForTheSessionIDsOnce() {
        // 창·탭·세션을 돌며 하나씩 묻지 않는다 — 세션이 많아도 호출 수가 같다.
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
        // 이름에 줄바꿈이 있어도 id·tty 는 그대로다.
        XCTAssertEqual(Detector.itermSession(from: "4ED8\n/dev/ttys002\na\nb")?.name, "a\nb")
        XCTAssertNil(Detector.itermSession(from: ""), "창이 없다")
        XCTAssertNil(Detector.itermSession(from: "4ED8\n/dev/ttys002"), "형식이 다르면 추측하지 않는다")
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

    /// iTerm2 의 기본 프로필(모호한 폭 글자 1칸)로 읽은 화면.
    private func visible(_ output: String, wide: Bool = false) -> [String]? {
        ITermIO.visibleLines(from: output, ambiguousIsDoubleWidth: wide)
    }

    func testKeepsOnlyTheVisibleRows() {
        let history = (1...5).map { "old \($0)" }
        XCTAssertEqual(visible(output(rows: 3, history + ["a", "b", "c"])), ["a", "b", "c"])
    }

    func testOldPromptInScrollbackIsNotTheCurrentScreen() {
        // 지워진 화면(빈 줄 3개) 위 스크롤백에 예전 claude 입력창이 남아 있다 — 지금 화면에는 없다.
        let scrollback = ["────────", "❯ ", "────────", "  ⏵⏵ auto mode on (shift+tab to cycle)"]
        for wide in [false, true] {
            let screen = visible(output(rows: 3, scrollback + ["", "", ""]), wide: wide)
            XCTAssertEqual(screen, ["", "", ""])
            XCTAssertFalse(Readiness.claudePromptVisible(screen ?? []), "화면이 비었으면 입력창이 보이지 않는다")
        }
        // 양성 대조군: 같은 글이 정말 화면 아래에 있으면 보인다.
        let live = visible(output(rows: 4, scrollback))
        XCTAssertTrue(Readiness.claudePromptVisible(live ?? []))
    }

    func testWrappedLogicalLinesCountAsSeveralRows() {
        // 한 줄이 칸 수의 두 배라 2행을 차지한다: 화면 3행 = (긴 줄 2행) + 1행. 그 위의 예전 입력창은 화면 밖이다.
        let old = ["────────", "❯ ", "────────", "  ⏵⏵ auto mode on (shift+tab to cycle)"]
        let wrapped = String(repeating: "x", count: 160)
        let screen = visible(output(rows: 3, columns: 80, old + [wrapped, "END"]))
        XCTAssertEqual(screen, [wrapped, "END"])
        XCTAssertFalse(Readiness.claudePromptVisible(screen ?? []))
        // 소프트 랩을 줄바꿈으로 내보내는 경우(물리 행마다 한 줄)에도 같은 답이다.
        let split = visible(output(rows: 3, columns: 80, old + [String(repeating: "x", count: 80), String(repeating: "x", count: 80), "END"]))
        XCTAssertEqual(split?.last, "END")
        XCTAssertEqual(split?.count, 3)
    }

    func testWideCharactersTakeTwoCells() {
        // 한글 50자 = 100칸 → 80칸 화면에서 2행(프로필 설정과 무관하다).
        let korean = String(repeating: "한", count: 50)
        for wide in [false, true] {
            XCTAssertEqual(visible(output(rows: 3, columns: 80, ["위", "중간", korean, "끝"]), wide: wide), [korean, "끝"])
        }
    }

    func testAmbiguousWidthCharactersFollowTheProfile() {
        // 상자 선 80자: 기본 프로필(1칸)에서는 80칸 화면의 한 행이다. 전에는 늘 2칸으로 세어 2행으로 보고 위쪽 줄을 버렸다.
        let separator = String(repeating: "─", count: 80)
        let contents = ["scrollback", "위", separator, "❯ ", separator]
        XCTAssertEqual(visible(output(rows: 4, columns: 80, contents)), ["위", separator, "❯ ", separator])
        // 2칸 프로필에서는 같은 줄이 2행씩이다: 4행 화면 = 구분선(2) + 입력 줄(1) — 그 위의 구분선(2)은 다 들어오지 않는다.
        XCTAssertEqual(visible(output(rows: 4, columns: 80, contents), wide: true), ["❯ ", separator])
        XCTAssertEqual(ITermIO.displayWidth("› 1. GPT · x", ambiguousIsDoubleWidth: false), 12)
        // `·`(U+00B7)는 모호한 폭이라 2칸이 되지만 `›`(U+203A) · `❯`(U+276F)는 아니다 — 그 설정을 켜도 1칸.
        XCTAssertEqual(ITermIO.displayWidth("› 1. GPT · x", ambiguousIsDoubleWidth: true), 13)
        XCTAssertEqual(ITermIO.displayWidth("❯ ›", ambiguousIsDoubleWidth: true), 3)
        XCTAssertEqual(ITermIO.displayWidth("─●…", ambiguousIsDoubleWidth: true), 6)
        XCTAssertEqual(ITermIO.displayWidth("─●…", ambiguousIsDoubleWidth: false), 3)
        XCTAssertEqual(ITermIO.displayWidth("🙂", ambiguousIsDoubleWidth: false), 2)
        XCTAssertEqual(ITermIO.displayWidth("한글 ok", ambiguousIsDoubleWidth: false), 7)
        XCTAssertEqual(ITermIO.displayWidth("e\u{301}", ambiguousIsDoubleWidth: true), 1, "결합 문자는 칸을 차지하지 않는다")
        XCTAssertEqual(ITermIO.displayWidth("全角ａ", ambiguousIsDoubleWidth: false), 6)
    }

    /// PR #27 리뷰 · 2026-10-12 집 맥 2 실측: 선택창이 칸에 «꼭 맞게» 들어찬 화면에서 머리말을 잃지 않는다.
    /// (칸 수에 꼭 맞게 채워진 행 `› 1. …` 과 안내 줄 `enter select · esc back` 을 2행으로 세어 맨 윗줄을 버렸다 → 선택창을 못 알아보고 열어 둔 채 끝났다.)
    func testAPickerThatExactlyFillsThePaneKeepsItsHeader() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "codex-38-models", withExtension: "json", subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let all = try XCTUnwrap(object["tail"] as? [String])
        let picker = Array(all.suffix(12))
        XCTAssertTrue(picker[0].contains("Select Model and Effort"))
        XCTAssertEqual(picker.filter { $0.count == 38 }.count, 2, "칸 수에 꼭 맞는 줄이 둘(커서 행 · 안내 줄)")
        // 위에 스크롤백이 있어도 12행 화면은 그 12줄이다.
        let screen = try XCTUnwrap(visible(output(rows: 12, columns: 38, ["• old output", "› old prompt"] + picker)))
        XCTAssertEqual(screen, picker)
        let open = try XCTUnwrap(Picker.open(screen))
        XCTAssertTrue(open.header.hasPrefix("Select Model and Effort"))
        XCTAssertEqual(open.rows.count, 7)
    }

    /// PR #27 세 번째 리뷰: 2칸 프로필(프로필을 모를 때도 이렇게 센다)에서도 화면에 다 보이는 선택창의 머리말을 잃지 않는다.
    /// 커서 행의 `›` 는 모호한 폭이 아니라 38칸 한 행이고, 안내 줄의 `·` 만 2칸이 되어 2행이다 — 선택창은 13행에 꼭 맞는다.
    func testAPickerKeepsItsHeaderInADoubleWidthProfileToo() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "codex-38-models", withExtension: "json", subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let picker = Array(try XCTUnwrap(object["tail"] as? [String]).suffix(12))
        let screen = try XCTUnwrap(visible(output(rows: 13, columns: 38, ["• old output", "› old prompt"] + picker), wide: true))
        XCTAssertEqual(screen, picker)
        XCTAssertTrue(try XCTUnwrap(Picker.open(screen)).header.hasPrefix("Select Model and Effort"))
        // 한 행 모자라면(12행) 맨 윗줄은 정말 화면 밖이다.
        XCTAssertEqual(visible(output(rows: 12, columns: 38, picker), wide: true)?.count, 11)
    }

    /// PR #27 네 번째 리뷰: 이 표의 판(유니코드 16)이 모르는 글자는 넓게 센다 — iTerm2 3.7.3 은 U+1FAEA(유니코드 17 의 이모지)를 2칸으로 그린다.
    /// 4행 × 80칸: 아래 두 줄이 81칸씩이라 2행씩 차지한다. 그 위의 codex 입력 줄은 화면 밖이다.
    func testCharactersNewerThanTheTableCountAsWide() throws {
        let newer = String(try XCTUnwrap(Unicode.Scalar(0x1FAEA as UInt32)))
        let long = " " + String(repeating: "x", count: 78) + newer
        for wide in [false, true] {
            XCTAssertEqual(ITermIO.displayWidth(long, ambiguousIsDoubleWidth: wide), 81)
            let screen = visible(output(rows: 4, columns: 80, ["› old prompt", long, long]), wide: wide)
            XCTAssertEqual(screen, [long, long])
            XCTAssertFalse(Readiness.codexComposerVisible(screen ?? []), "화면 밖의 입력 줄로 입력을 허락하지 않는다")
        }
        // 양성 대조군: 그 두 줄이 80칸씩이면 세 줄이 다 화면이고 입력 줄이 보인다.
        let short = " " + String(repeating: "x", count: 79)
        XCTAssertTrue(Readiness.codexComposerVisible(visible(output(rows: 4, columns: 80, ["› old prompt", short, short])) ?? []))
        // 이모지 표시 선택자가 붙은 글자도 넓게 센다(❤ U+2764 는 혼자면 1칸).
        XCTAssertEqual(ITermIO.displayWidth("\u{2764}", ambiguousIsDoubleWidth: false), 1)
        XCTAssertEqual(ITermIO.displayWidth("\u{2764}\u{FE0F}", ambiguousIsDoubleWidth: false), 2)
        XCTAssertEqual(ITermIO.displayWidth("\u{E0A0}", ambiguousIsDoubleWidth: false), 1, "사용자 영역 글자(아이콘 글꼴)는 모호한 폭")
        XCTAssertEqual(ITermIO.displayWidth("\u{E0A0}", ambiguousIsDoubleWidth: true), 2)
    }

    /// PR #27 재리뷰: 「Ambiguous characters are double-width」 프로필에서 화면 밖의 입력창을 화면으로 읽지 않는다.
    /// 4행 × 80칸 화면에 구분선 둘(2칸 프로필에서는 각각 2행)만 보인다 — 그 위의 `❯` 는 스크롤백이다.
    func testAnOffScreenPromptIsNotReadyInADoubleWidthProfile() {
        let rule = String(repeating: "─", count: 80)
        let contents = output(rows: 4, columns: 80, [rule, "❯ ", rule, rule])
        let screen = visible(contents, wide: true)
        XCTAssertEqual(screen, [rule, rule])
        XCTAssertFalse(Readiness.claudePromptVisible(screen ?? []), "보이지 않는 입력창으로 입력을 허락하지 않는다")
        // 프로필을 모를 때도 2칸으로 센다 — `screen()` 이 그렇게 부른다(`?? true`).
        // 양성 대조군: 1칸 프로필에서는 그 네 줄이 정말 화면이고 입력창이 보인다.
        XCTAssertTrue(Readiness.claudePromptVisible(visible(contents, wide: false) ?? []))
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
        XCTAssertEqual(ITermProfile.ambiguousIsDoubleWidth(named: "Plain", in: store(profiles)), false, "설정 파일의 프로필은 키가 없으면 꺼진 것")
        XCTAssertNil(ITermProfile.ambiguousIsDoubleWidth(named: "Gone", in: store(profiles)), "모르는 프로필은 모른다(부르는 쪽이 2칸으로 센다)")
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
        XCTAssertEqual(ITermProfile.ambiguousIsDoubleWidth(named: "Dyn child", in: all), true, "적지 않은 값은 부모 프로필의 것")
        XCTAssertEqual(ITermProfile.ambiguousIsDoubleWidth(named: "Dyn default", in: all), false, "부모를 적지 않으면 기본 프로필")
        XCTAssertNil(ITermProfile.ambiguousIsDoubleWidth(named: "Dyn orphan", in: all), "부모를 못 찾으면 모른다")
        XCTAssertTrue(ITermProfile.dynamicProfiles(in: Data("not a profile file".utf8)).isEmpty)
    }

    /// PR #27 세 번째 리뷰: 부모는 GUID 로 먼저 찾는다(iTerm2 와 같은 순서). 이름의 부모(1칸)와 GUID 의 부모(2칸)가 다르면 GUID 쪽이다.
    func testDynamicParentIsFoundByGUIDBeforeName() {
        let base: [[String: Any]] = [["Name": "Narrow", "Guid": "G-narrow", "Ambiguous Double Width": false],
                                     ["Name": "Wide", "Guid": "G-wide", "Ambiguous Double Width": true]]
        let json = #"{"Profiles":[{"Name":"Child","Guid":"D1","Dynamic Profile Parent Name":"Narrow","Dynamic Profile Parent GUID":"G-wide"},{"Name":"Stale guid","Guid":"D2","Dynamic Profile Parent Name":"Wide","Dynamic Profile Parent GUID":"G-gone"}]}"#
        let all = store(base + ITermProfile.dynamicProfiles(in: Data(json.utf8)))
        let wide = ITermProfile.ambiguousIsDoubleWidth(named: "Child", in: all)
        XCTAssertEqual(wide, true)
        XCTAssertEqual(ITermProfile.ambiguousIsDoubleWidth(named: "Stale guid", in: all), true, "GUID 로 못 찾으면 이름으로")
        // 그 답으로 화면을 자르면 화면 밖의 입력창은 들어오지 않는다.
        let rule = String(repeating: "─", count: 80)
        let screen = ITermIO.visibleLines(from: "4\n80\n" + [rule, "❯ ", rule, rule].joined(separator: "\n") + "\n", ambiguousIsDoubleWidth: wide ?? true)
        XCTAssertEqual(screen, [rule, rule])
        XCTAssertFalse(Readiness.claudePromptVisible(screen ?? []))
    }
}

final class ITermBroadcastTests: XCTestCase {
    /// iTerm2 3.7.3 의 Shell ▸ Broadcast Input 메뉴(2026-10-12 집 맥 2 에서 읽은 그대로).
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
        // 방송 표시가 같이 켜져 있어도 방송이다.
        XCTAssertFalse(ITermBroadcast.classify(menu(marked: ["Broadcast Input to All Panes in All Tabs", "Show Background Pattern Indicator"])).allowsSending)
    }

    func testUnreadableOrUnrecognizedIsNeverOff() {
        XCTAssertFalse(ITermBroadcast.classify([]).allowsSending, "메뉴를 못 찾으면 보내지 않는다")
        XCTAssertFalse(ITermBroadcast.classify(menu(marked: [])).allowsSending, "체크된 것이 없으면 모른다")
        XCTAssertFalse(ITermBroadcast.classify(menu(marked: ["Toggle Broadcast Input to Current Session"])).allowsSending, "칸을 골라 묶은 방송")
        XCTAssertFalse(ITermBroadcast.State.notTrusted.allowsSending, "권한이 없어 못 읽었으면 보내지 않는다")
    }
}

final class WrappedNeedleTests: XCTestCase {
    private let needle = "choose what model and reasoning effort"

    func testFindsANeedleOnOneLine() {
        XCTAssertTrue(Runner.contains(needle, in: ["› /model", "  /model   choose what model and reasoning effort to use"]))
    }

    func testFindsANeedleFoldedOverTwoLines() {
        // 38칸으로 나뉜 iTerm2 칸의 codex(2026-10-12 실측): 명령 설명이 둘로 접힌다.
        let narrow = ["› /model  choose what model and       ", "          reasoning effort to use     ", "› /model ", "  GPT-6-Astra high · ~/Repos "]
        XCTAssertTrue(Runner.contains(needle, in: narrow))
    }

    func testDoesNotJoinLinesThatAreNotNeighbours() {
        XCTAssertFalse(Runner.contains(needle, in: ["choose what model and", "something else", "reasoning effort to use"]))
        XCTAssertFalse(Runner.contains(needle, in: []))
        XCTAssertFalse(Runner.contains(needle, in: ["choose what model and"]))
    }
}

/// 38칸으로 나뉜 iTerm2 칸의 codex 0.162.0(2026-10-12 집 맥 2 에서 뜬 화면).
final class NarrowCodexTests: XCTestCase {
    private func lines(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(object["tail"] as? [String])
    }

    func testFindsTheFoldedCommandHint() throws {
        let shown = try lines("codex-38-slash-model").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertFalse(shown.contains { $0.contains("choose what model and reasoning effort") }, "한 줄에는 없다 — 접혔다")
        XCTAssertTrue(Runner.contains("choose what model and reasoning effort", in: Array(shown.suffix(5))))
    }

    func testReadsTheFoldedEffortHeader() throws {
        let open = try XCTUnwrap(Picker.open(try lines("codex-38-effort")))
        XCTAssertTrue(open.header.hasPrefix("Select Reasoning Level for GPT-6-Astra"), open.header)
        XCTAssertFalse(open.header.hasPrefix("Select Reasoning Level for GPT-6.1-Sol"), "다른 모델의 목록으로 읽지 않는다")
        XCTAssertEqual(open.rows.count, 5)
        XCTAssertTrue(open.footer.contains("s session"))
    }

    func testReadsTheModelList() throws {
        let open = try XCTUnwrap(Picker.open(try lines("codex-38-models")))
        XCTAssertTrue(open.header.hasPrefix("Select Model and Effort"))
        XCTAssertEqual(open.rows.count, 7)
    }
}
