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

    func testKeepsOnlyTheVisibleRows() {
        let history = (1...5).map { "old \($0)" }
        XCTAssertEqual(ITermIO.visibleLines(from: output(rows: 3, history + ["a", "b", "c"])), ["a", "b", "c"])
    }

    func testOldPromptInScrollbackIsNotTheCurrentScreen() {
        // 지워진 화면(빈 줄 3개) 위 스크롤백에 예전 claude 입력창이 남아 있다 — 지금 화면에는 없다.
        let scrollback = ["────────", "❯ ", "────────", "  ⏵⏵ auto mode on (shift+tab to cycle)"]
        let screen = ITermIO.visibleLines(from: output(rows: 3, scrollback + ["", "", ""]))
        XCTAssertEqual(screen, ["", "", ""])
        XCTAssertFalse(Readiness.claudePromptVisible(screen ?? []), "화면이 비었으면 입력창이 보이지 않는다")
        // 양성 대조군: 같은 글이 정말 화면 아래에 있으면 보인다.
        let live = ITermIO.visibleLines(from: output(rows: 4, scrollback))
        XCTAssertTrue(Readiness.claudePromptVisible(live ?? []))
    }

    func testWrappedLogicalLinesCountAsSeveralRows() {
        // 한 줄이 칸 수의 두 배라 2행을 차지한다: 화면 3행 = (긴 줄 2행) + 1행. 그 위의 예전 입력창은 화면 밖이다.
        let old = ["────────", "❯ ", "────────", "  ⏵⏵ auto mode on (shift+tab to cycle)"]
        let wrapped = String(repeating: "x", count: 160)
        let screen = ITermIO.visibleLines(from: output(rows: 3, columns: 80, old + [wrapped, "END"]))
        XCTAssertEqual(screen, [wrapped, "END"])
        XCTAssertFalse(Readiness.claudePromptVisible(screen ?? []))
        // 소프트 랩을 줄바꿈으로 내보내는 경우(물리 행마다 한 줄)에도 같은 답이다.
        let split = ITermIO.visibleLines(from: output(rows: 3, columns: 80, old + [String(repeating: "x", count: 80), String(repeating: "x", count: 80), "END"]))
        XCTAssertEqual(split?.last, "END")
        XCTAssertEqual(split?.count, 3)
    }

    func testWideCharactersTakeTwoCells() {
        // 한글 50자 = 100칸 → 80칸 화면에서 2행.
        let korean = String(repeating: "한", count: 50)
        let screen = ITermIO.visibleLines(from: output(rows: 3, columns: 80, ["위", "중간", korean, "끝"]))
        XCTAssertEqual(screen, [korean, "끝"])
    }

    func testAmbiguousWidthCharactersTakeOneCell() {
        // 상자 선 80자는 80칸 화면에서 한 행이다(iTerm2 기본 설정). 전에는 2칸씩 세어 2행으로 보고 위쪽 줄을 버렸다.
        let separator = String(repeating: "─", count: 80)
        let screen = ITermIO.visibleLines(from: output(rows: 4, columns: 80, ["scrollback", "위", separator, "❯ ", separator]))
        XCTAssertEqual(screen, ["위", separator, "❯ ", separator])
        XCTAssertEqual(ITermIO.displayWidth("› 1. GPT · x"), 12)
        XCTAssertEqual(ITermIO.displayWidth("한글 ok"), 7)
        XCTAssertEqual(ITermIO.displayWidth("e\u{301}"), 1, "결합 문자는 칸을 차지하지 않는다")
        XCTAssertEqual(ITermIO.displayWidth("全角ａ"), 6)
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
        let screen = try XCTUnwrap(ITermIO.visibleLines(from: output(rows: 12, columns: 38, ["• old output", "› old prompt"] + picker)))
        XCTAssertEqual(screen, picker)
        let open = try XCTUnwrap(Picker.open(screen))
        XCTAssertTrue(open.header.hasPrefix("Select Model and Effort"))
        XCTAssertEqual(open.rows.count, 7)
    }

    func testRefusesWhenRowsOrColumnsAreUnknown() {
        XCTAssertNil(ITermIO.visibleLines(from: "x\n80\nhello"))
        XCTAssertNil(ITermIO.visibleLines(from: "0\n80\nhello"))
        XCTAssertNil(ITermIO.visibleLines(from: "25\nhello"))
        XCTAssertNil(ITermIO.visibleLines(from: ""))
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
