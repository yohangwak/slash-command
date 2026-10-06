import XCTest
@testable import ModelSwitchCore

final class FakeIO: TerminalIO {
    var sent: [String] = []
    /// nil 이면 화면을 못 읽는 터미널.
    var screens: [[String]]?
    private var reads = 0
    var readCount: Int { reads }

    var onEnter: (() -> Void)?
    /// Orca 처럼 초안을 따로 주는 터미널 흉내. nil 이면 초안을 모른다.
    var drafts: [String?]?
    private var draftReads = 0
    var draftReadCount: Int { draftReads }

    var onType: ((String) -> Void)?

    func type(_ text: String) throws { sent.append(text); onType?(text) }
    func press(_ key: Key) throws {
        sent.append(key.bytes)
        if key == .enter { onEnter?() }
    }
    func screen() -> [String]? {
        guard let screens else { return nil }
        defer { reads += 1 }
        return screens[min(reads, screens.count - 1)]
    }
    func snapshot() -> ScreenSnapshot? {
        guard let lines = screen() else { return nil }
        guard let drafts else { return ScreenSnapshot(lines: lines, draft: nil) }
        defer { draftReads += 1 }
        return ScreenSnapshot(lines: lines, draft: drafts[min(draftReads, drafts.count - 1)])
    }
}

final class PlanTests: XCTestCase {
    func testKeyBytes() {
        XCTAssertEqual(Key.ctrl("s").bytes, "\u{13}")
        XCTAssertEqual(Key.ctrl("a").bytes, "\u{01}")
        XCTAssertEqual(Key.up.bytes, "\u{1B}[A")
        XCTAssertEqual(Key.enter.bytes, "\r")
    }

    func testClaudePlanStashesBeforeEachCommandAndWaitsForResult() {
        let steps = Plans.claude(AgentPreset(model: "opus", effort: "xhigh"))
        let inputs = steps.compactMap { step -> String? in
            if case .text(let text) = step { return text }
            return nil
        }
        XCTAssertEqual(inputs, ["\u{13}/model opus\r", "\u{13}/effort xhigh\r"])
        // 고정 대기 없이 결과 줄을 확인하고 넘어간다.
        XCTAssertFalse(steps.contains { if case .wait = $0 { return true } else { return false } })
        let prefixes = steps.compactMap { step -> String? in
            if case .expectResult(let prefix, _, _, _, _) = step { return prefix }
            return nil
        }
        XCTAssertEqual(prefixes, ["Set model to", "Set effort level"])
    }

    func testCodexPlanNeverPicksEffortByNumberAndConfirmsWithS() {
        let steps = Plans.codex(modelIndex: 2, displayName: "GPT-6-Astra", effortLabel: "High")
        let typed = steps.compactMap { step -> String? in
            if case .text(let text) = step { return text }
            return nil
        }
        // 숫자는 모델 번호 하나뿐이다 — effort 를 숫자 키로 고르면 기본값까지 저장된다.
        XCTAssertEqual(typed.filter { $0.allSatisfy(\.isNumber) }, ["2"])
        XCTAssertTrue(typed.contains("s"), "세션 한정(s)으로 확정해야 기본값을 안 건드린다")
        XCTAssertTrue(steps.contains { if case .selectRow(label: "High", via: "More reasoning", _, _, _) = $0 { return true } else { return false } })
        XCTAssertTrue(steps.contains { if case .expectPicker(header: "Select Reasoning Level for GPT-6-Astra", _, _, _, _) = $0 { return true } else { return false } })
        XCTAssertFalse(steps.contains { if case .wait = $0 { return true } else { return false } }, "고정 대기 없음")
        XCTAssertFalse(steps.contains(.key(.escape)), "Esc 는 선택창이 보일 때만(closePicker) — 작업 중 Esc 는 작업을 끊는다")
    }
}

final class CodexModelsTests: XCTestCase {
    let all = ["low", "medium", "high", "xhigh", "max", "ultra"]

    func models() -> CodexModels {
        CodexModels(models: [
            .init(slug: "gpt-old", priority: 13, efforts: ["low", "medium", "high", "xhigh"]),
            .init(slug: "gpt-sol", priority: 1, efforts: all),
            .init(slug: "gpt-hidden", visibility: "hide", priority: 2, efforts: all),
            .init(slug: "gpt-astra", priority: 2, efforts: all),
        ])
    }

    func testOrderSkipsHiddenAndSortsByPriority() {
        XCTAssertEqual(models().listed.map(\.slug), ["gpt-sol", "gpt-astra", "gpt-old"])
    }

    func testSelection() throws {
        let high = try models().selection(of: AgentPreset(model: "gpt-astra", effort: "high"))
        XCTAssertEqual(high.modelIndex, 2)
        XCTAssertEqual(high.effortLabel, "High")
        XCTAssertEqual(try models().selection(of: AgentPreset(model: "gpt-sol", effort: "xhigh")).effortLabel, "Extra high")
        // More reasoning… 하위(max·ultra)와 4단계뿐인 모델도 고를 수 있다 — 화면에서 행을 찾아가기 때문이다.
        XCTAssertEqual(try models().selection(of: AgentPreset(model: "gpt-sol", effort: "max")).effortLabel, "Max")
        XCTAssertEqual(try models().selection(of: AgentPreset(model: "gpt-old", effort: "high")).modelIndex, 3)
    }

    func testRejectsUnknownModelAndUnsupportedEffort() {
        XCTAssertThrowsError(try models().selection(of: AgentPreset(model: "gpt-hidden", effort: "high")))
        XCTAssertThrowsError(try models().selection(of: AgentPreset(model: "gpt-sol", effort: "turbo")))
        XCTAssertThrowsError(try models().selection(of: AgentPreset(model: "gpt-old", effort: "max")))
    }

    func testDecodesCacheFile() throws {
        let json = #"{"models":[{"slug":"m","display_name":"M","visibility":"list","priority":1,"supported_reasoning_levels":[{"effort":"low","description":"x"},{"effort":"high"}]}]}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("modelswitch-models-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try CodexModels.load(from: url).listed.first?.efforts, ["low", "high"])
    }
}

final class RunnerTests: XCTestCase {
    func run(_ steps: [Step], io: FakeIO) throws {
        try Runner(io: io, sleep: { _ in }).run(steps)
    }

    func testExpectPassesWhenScreenShowsNeedle() throws {
        let io = FakeIO()
        io.screens = [["nothing"], ["Select Model and Effort"]]
        try run([.text("a"), .expect(needle: "Select Model", timeoutMs: 1000, abort: [.text("X")], failure: "f"), .text("b")], io: io)
        XCTAssertEqual(io.sent, ["a", "b"])
    }

    func testExpectFailureRunsAbortAndStops() {
        let io = FakeIO()
        io.screens = [["nothing"]]
        XCTAssertThrowsError(try run([.text("a"), .expect(needle: "Select Model", timeoutMs: 400, abort: [.key(.escape)], failure: "열리지 않음"), .text("b")], io: io)) {
            XCTAssertEqual($0 as? ModelSwitchError, ModelSwitchError("열리지 않음"))
        }
        XCTAssertEqual(io.sent, ["a", "\u{1B}"])
    }

    private let rule = String(repeating: "─", count: 20)

    func testExpectResultWaitsForNewResultLineAndSignal() throws {
        let io = FakeIO()
        // 처음엔 이전 전환의 결과 줄이 남아 있고, 그다음 이번 명령의 결과가 뜬다.
        io.screens = [["  ⎿  Set effort level to high", rule, "❯"], ["  ⎿  Set model to Sonnet 5.5 and saved", rule, "❯"]]
        var stamps: [Int64?] = [1, 1, 2]
        let runner = Runner(io: io, sleep: { _ in }, stamp: { stamps.count > 1 ? stamps.removeFirst() : stamps[0] })
        let result = try runner.run([.arm, .text("go"), .expectResult(prefix: "Set model to", timeoutMs: 1000, failure: "f")])
        XCTAssertEqual(result, ["Set model to Sonnet 5.5 and saved"])
    }

    func testExpectResultDoesNotTrustAResultLineThatWasAlreadyThere() {
        let io = FakeIO()
        let stale = ["  ⎿  Set model to Sonnet 5.5", rule, "❯"]
        io.screens = [stale]
        // 같은 문구가 명령 전부터 떠 있었고 기본값 파일도 그대로다 — 이번 명령의 결과라는 근거가 없다.
        let runner = Runner(io: io, sleep: { _ in }, stamp: { 7 }, initial: ScreenSnapshot(lines: stale, draft: ""))
        XCTAssertThrowsError(try runner.run([.arm, .text("go"), .expectResult(prefix: "Set model to", timeoutMs: 300, failure: "응답 없음")])) {
            XCTAssertTrue("\($0)".hasPrefix("응답 없음"))
        }
    }

    func testExpectResultAcceptsAlreadyShownLineOnceTheFileChanges() throws {
        let io = FakeIO()
        let stale = ["  ⎿  Set model to Sonnet 5.5", rule, "❯"]
        io.screens = [stale]
        var stamps: [Int64?] = [7, 7, 7, 8]
        let runner = Runner(io: io, sleep: { _ in }, stamp: { stamps.count > 1 ? stamps.removeFirst() : stamps[0] },
                            initial: ScreenSnapshot(lines: stale, draft: ""))
        try runner.run([.arm, .text("go"), .expectResult(prefix: "Set model to", timeoutMs: 300, failure: "f")])
    }

    func testExpectResultAcceptsASecondIdenticalLine() throws {
        // 기본값 파일 신호가 없어도, 같은 문구의 줄이 하나 더 생기면 새 결과다.
        let io = FakeIO()
        let stale = ["  ⎿  Set model to Sonnet 5.5", rule, "❯"]
        io.screens = [stale, ["  ⎿  Set model to Sonnet 5.5", "❯ /model sonnet", "  ⎿  Set model to Sonnet 5.5", rule, "❯"]]
        let runner = Runner(io: io, sleep: { _ in }, initial: ScreenSnapshot(lines: stale, draft: ""))
        try runner.run([.arm, .text("go"), .expectResult(prefix: "Set model to", timeoutMs: 300, failure: "f")])
    }

    func testExpectResultStopsAtOnceWhenTheCommandWasRefused() {
        // 예전 전환의 줄이 화면에 남아 있어도, 이번 명령 바로 아래에 다른 답이 붙었으면 실패다(예전 줄을 성공으로 읽지 않는다).
        let io = FakeIO()
        let stale = ["❯ /model", "  ⎿  Set model to Opus 5 for this session only with low effort", rule, "❯"]
        io.screens = [stale, stale + [], ["  ⎿  Set model to Opus 5 for this session only with low effort",
                                           "❯ /model no-such", "  ⎿  Model 'no-such' not found", rule, "❯"]]
        let runner = Runner(io: io, sleep: { _ in }, stamp: { 7 }, initial: ScreenSnapshot(lines: stale, draft: ""))
        XCTAssertThrowsError(try runner.run([.arm, .text("go"), .expectResult(prefix: "Set model to", command: "/model", timeoutMs: 3000, failure: "응답 없음"), .text("next")])) {
            XCTAssertTrue("\($0)".contains("Model 'no-such' not found"), "\($0)")
        }
        XCTAssertEqual(io.sent, ["go"], "다음 명령을 보내지 않는다")
    }

    func testExpectResultWaitsUntilDraftIsBack() throws {
        let io = FakeIO()
        io.screens = [["  ⎿  Set model to X", rule, "❯"]]
        io.drafts = ["", "", "내 초안 그리고 더 친 글"]
        let runner = Runner(io: io, sleep: { _ in }, initial: ScreenSnapshot(lines: [rule, "❯"], draft: "내 초안"))
        try runner.run([.expectResult(prefix: "Set model to", timeoutMs: 1000, failure: "f")])
        XCTAssertEqual(io.draftReadCount, 3, "초안이 돌아오기 전에는 다음 단계로 가지 않는다(그 사이 더 친 글은 문제 삼지 않는다)")
    }

    func testExpectResultSeesTheNoticeLineShownWhileClaudeIsWorking() throws {
        let io = FakeIO()
        // 작업 중에는 결과가 대화 줄이 아니라 입력창 위의 오른쪽 정렬 알림으로 뜬다. 마지막 ⎿ 줄은 도구 출력이다.
        io.screens = [["  ⎿  $ sleep 20 (5s)", "✻ Beaming… (11s)", "                 Set model to Opus 5.5 and", rule, "❯"]]
        let result = try Runner(io: io, sleep: { _ in }).run([.expectResult(prefix: "Set model to", timeoutMs: 300, failure: "f")])
        XCTAssertEqual(result, ["Set model to Opus 5.5 and"])
    }

    func testExpectResultWaitsForDraftOnScreenWhenTheTerminalGivesNoDraft() throws {
        // Ghostty 는 초안을 따로 주지 않는다 — 입력창 줄에 글이 다시 «보임»으로 판단한다.
        let io = FakeIO()
        io.screens = [["  ⎿  Set model to X", rule, "❯ "], ["  ⎿  Set model to X", rule, "❯ "], ["  ⎿  Set model to X", rule, "❯ 쓰던 글"]]
        let runner = Runner(io: io, sleep: { _ in }, initial: ScreenSnapshot(lines: [rule, "❯ 쓰던 글"], draft: nil))
        try runner.run([.expectResult(prefix: "Set model to", timeoutMs: 1000, failure: "f"), .text("next")])
        XCTAssertEqual(io.readCount, 3)
        XCTAssertEqual(ClaudeScreen.promptText([rule, "❯ "]), "")
        XCTAssertNil(ClaudeScreen.promptText([" ❯ 1. Yes"]))
    }

    func testExpectResultStopsWhenADialogReplacedThePrompt() {
        let io = FakeIO()
        // 결과 줄은 떴지만 그 사이 권한 확인 창이 떴다 — 다음 명령의 Enter 가 그 창을 누르면 안 된다.
        io.screens = [["  ⎿  Set model to X", "╌╌╌╌", " Do you want to proceed?", " ❯ 1. Yes", "   2. No"]]
        XCTAssertThrowsError(try Runner(io: io, sleep: { _ in }).run([
            .text("a"), .expectResult(prefix: "Set model to", timeoutMs: 300, failure: "f"), .text("b"),
        ]))
        XCTAssertEqual(io.sent, ["a"])
    }

    func testExpectResultFailureCarriesWhatTheScreenSaid() {
        let io = FakeIO()
        io.screens = [["  ⎿  Model 'xyz' not found", rule, "❯"]]
        XCTAssertThrowsError(try Runner(io: io, sleep: { _ in }).run([.expectResult(prefix: "Set model to", timeoutMs: 200, failure: "응답 없음")])) {
            XCTAssertTrue("\($0)".contains("Model 'xyz' not found"))
        }
        // 명령 전부터 있던 줄은 이번 명령의 말이 아니다 — 붙이지 않는다.
        let old = ["  ⎿  $ sleep 20", rule, "❯"]
        io.screens = [old]
        XCTAssertThrowsError(try Runner(io: io, sleep: { _ in }, initial: ScreenSnapshot(lines: old, draft: "")).run([
            .arm, .expectResult(prefix: "Set model to", timeoutMs: 200, failure: "응답 없음"),
        ])) {
            XCTAssertEqual($0 as? ModelSwitchError, ModelSwitchError("응답 없음"))
        }
    }

    func testUnreadableScreenStopsInsteadOfSendingBlind() {
        let io = FakeIO()
        XCTAssertThrowsError(try run([.expect(needle: "x", timeoutMs: 400, abort: [.text("X")], failure: "f"), .text("b")], io: io))
        XCTAssertEqual(io.sent, [], "화면을 못 읽으면 뒤 단계도 정리 단계도 보내지 않는다")
    }
}

/// codex `/model` 선택창 흉내. 화면은 2026-10-06 codex 0.160.0 에서 받은 것과 같은 꼴로 그린다.
final class FakePicker: TerminalIO {
    enum Stage { case composer, models, efforts, advanced }
    var stage = Stage.composer
    var cursor = 0
    var sent: [String] = []
    /// 확정된 방식: "s"(이 세션만) 또는 "enter"/"number"(기본값까지 저장).
    var confirmedBy: String?
    /// 마지막으로 확정한 행(소문자).
    var chosen: String?
    /// 지금 effort(소문자 행 이름). `(current)` 표시가 여기에 붙는다.
    var current = "high"
    var efforts = ["Low", "Medium", "High", "Extra high"]
    var advanced = ["Max", "Ultra"]
    /// 참이면 화면이 한 박자 늦게 따라온다(키를 보낸 직후 읽으면 이전 화면).
    var lagging = false
    private var stale: [String]?
    private var commandTyped = false

    private var outer: [String] { efforts + (advanced.isEmpty ? [] : ["More reasoning…"]) }
    private var currentIsAdvanced: Bool { advanced.contains { $0.lowercased() == current } }

    private func mark(_ name: String) -> String {
        let isCurrent = name.lowercased() == current || (name.hasPrefix("More") && currentIsAdvanced)
        return name + (name == "Low" ? " (default)" : "") + (isCurrent ? " (current)" : "")
    }

    private func render() -> [String] {
        func list(_ header: [String], _ items: [String], footer: String) -> [String] {
            ["• Model changed to gpt-old high for this session only"] + header
                + items.enumerated().map { "\($0.offset == cursor ? "›" : " ") \($0.offset + 1). \(mark($0.element))   설명" }
                + ["  " + footer]
        }
        switch stage {
        case .composer:
            return (chosen.map { ["• Model changed to gpt-sol \($0) for this session only"] } ?? [])
                + [commandTyped ? "› /model  choose what model and reasoning effort to use" : "› Ask Codex to do anything", "  GPT-Sol · ~/x"]
        case .models:
            return ["  Select Model and Effort", "\(cursor == 0 ? "›" : " ") 1. GPT-Sol (current)   설명", "\(cursor == 1 ? "›" : " ") 2. GPT-Astra   설명", "  enter select · esc back"]
        case .efforts:
            let onMore = cursor == efforts.count
            return list(["  Select Reasoning Level for GPT-Sol"], outer,
                        footer: onMore ? "enter select · esc back" : "enter default · s session · esc back")
        case .advanced:
            return list(["  Advanced Reasoning", "  ⚠ Consumes usage limits faster"], advanced, footer: "enter default · s session · esc back")
        }
    }

    private func confirm(_ how: String) {
        let items = stage == .advanced ? advanced : efforts
        chosen = items[cursor].lowercased()
        current = items[cursor].lowercased()
        confirmedBy = how
        stage = .composer
    }

    private func openEfforts() {
        stage = .efforts
        cursor = currentIsAdvanced ? efforts.count : (efforts.firstIndex { $0.lowercased() == current } ?? 0)
    }

    func type(_ text: String) throws {
        sent.append(text)
        if lagging { stale = render() }
        if stage == .composer {
            if text.hasSuffix("/model") { commandTyped = true }
            if text == "\r", commandTyped { commandTyped = false; stage = .models; cursor = 0 }
            return
        }
        var rest = Substring(text)
        while !rest.isEmpty {
            if rest.hasPrefix("\u{1B}[A") { cursor = max(0, cursor - 1); rest = rest.dropFirst(3); continue }
            if rest.hasPrefix("\u{1B}[B") { cursor += 1; rest = rest.dropFirst(3); continue }
            let key = rest.removeFirst()
            let onMore = stage == .efforts && cursor == efforts.count
            switch (stage, key) {
            case (.models, "1"): openEfforts()
            case (.models, "\r") where cursor == 0: openEfforts()
            case (.efforts, "s") where !onMore: confirm("s")
            case (.advanced, "s"): confirm("s")
            case (.efforts, "\r") where onMore:
                stage = .advanced
                cursor = advanced.firstIndex { $0.lowercased() == current } ?? 0
            case (.efforts, "\r"), (.advanced, "\r"): confirm("enter")
            case (.efforts, _) where key.isNumber, (.advanced, _) where key.isNumber: confirm("number")
            case (.advanced, "\u{1B}"): stage = .efforts; cursor = efforts.count
            case (.efforts, "\u{1B}"): stage = .models; cursor = 0
            case (.models, "\u{1B}"): stage = .composer
            default: break
            }
        }
    }

    func press(_ key: Key) throws {
        try type(key.bytes)
    }

    func screen() -> [String]? {
        if let old = stale { stale = nil; return old }
        return render()
    }
}

final class PickerTests: XCTestCase {
    let efforts = [
        "• Model changed to gpt-6.1-sol high for this session only",
        "  Select Reasoning Level for GPT-6.1-Sol",
        "  1. Low (default)    Fast responses with lighter reasoning",
        "  2. Medium           Balances speed and reasoning depth for everyday tasks",
        "› 3. High (current)   Greater reasoning depth for complex problems",
        "  4. Extra high       Extra high reasoning depth for complex problems",
        "  5. More reasoning…  Max and Ultra consume usage limits faster",
        "  enter default · s session · esc back",
    ]

    func testReadsRowsAndCursor() {
        let rows = Picker.rows(efforts)
        XCTAssertEqual(rows.map(\.label), ["Low", "Medium", "High", "Extra high", "More reasoning…"])
        XCTAssertEqual(rows.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(rows.firstIndex(where: \.selected), 2)
        XCTAssertEqual(Picker.index(of: "high", in: rows), 2, "Extra high 는 High 가 아니다")
        XCTAssertEqual(Picker.index(of: "Extra high", in: rows), 3)
        XCTAssertEqual(Picker.index(of: "More reasoning", in: rows), 4)
        XCTAssertNil(Picker.index(of: "Max", in: rows))
        XCTAssertEqual(rows.map(\.current), [false, false, true, false, false])
    }

    func testReadsSubmenuBelowTheWarningLine() {
        let rows = Picker.rows(["  Advanced Reasoning", "  ⚠ Consumes usage limits faster",
                                     "› 1. Max    For difficult problems", "  2. Ultra  For demanding work",
                                     "  enter default · s session · esc back"])
        XCTAssertEqual(rows.map(\.label), ["Max", "Ultra"])
        XCTAssertEqual(rows.first?.selected, true)
    }

    func testNumberedRowsWithoutOurHeaderAreNotAPicker() throws {
        // 승인 창도 번호 행을 쓴다 — 거기에 위·아래·s·Esc 를 보내면 안 된다.
        XCTAssertFalse(Picker.isOpen(["  Would you like to run the following command?", "› 1. Yes, proceed", "  2. No"]))
        XCTAssertFalse(Picker.isOpen(["› Ask Codex to do anything"]))
        let url = try XCTUnwrap(Bundle.module.url(forResource: "codex-approval", withExtension: "json", subdirectory: "Fixtures"))
        struct Fixture: Decodable { let tail: [String] }
        XCTAssertFalse(Picker.isOpen(try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tail))
    }

    func run(_ effort: String, picker: FakePicker) throws -> [String] {
        try Runner(io: picker, sleep: { _ in }).run(Plans.codex(modelIndex: 1, displayName: "GPT-Sol", effortLabel: effort))
    }

    func testPicksEachEffortForThisSessionOnly() throws {
        for (label, expected) in [("Low", "low"), ("Medium", "medium"), ("High", "high"), ("Extra high", "extra high")] {
            let picker = FakePicker()
            let confirmations = try run(label, picker: picker)
            XCTAssertEqual(picker.chosen, expected, label)
            XCTAssertEqual(picker.confirmedBy, "s", "\(label): 기본값까지 저장하는 방식으로 확정하면 안 된다")
            XCTAssertEqual(picker.stage, .composer)
            XCTAssertEqual(confirmations.count, 1)
        }
    }

    func testGoesThroughMoreReasoningForMaxAndUltra() throws {
        for (label, expected) in [("Max", "max"), ("Ultra", "ultra")] {
            let picker = FakePicker()
            _ = try run(label, picker: picker)
            XCTAssertEqual(picker.chosen, expected)
            XCTAssertEqual(picker.confirmedBy, "s")
        }
    }

    func testDoesNotOvershootWhenTheScreenLagsBehind() throws {
        let picker = FakePicker()
        picker.lagging = true
        _ = try run("Low", picker: picker)
        XCTAssertEqual(picker.chosen, "low")
        XCTAssertEqual(picker.confirmedBy, "s")
    }

    func testMissingRowClosesThePickerWithoutConfirming() {
        let picker = FakePicker()
        XCTAssertThrowsError(try run("Turbo", picker: picker))
        XCTAssertNil(picker.confirmedBy)
        XCTAssertEqual(picker.stage, .composer, "선택창을 닫고 나온다")
        // More reasoning… 하위까지 들어가 찾아봤으므로 하위 → effort → 모델 목록, 세 번에 닫힌다. 입력창에서는 더 누르지 않는다.
        XCTAssertEqual(picker.sent.filter { $0 == "\u{1B}" }.count, 3)
    }
}

final class ProcessTableTests: XCTestCase {
    func procargs(argc: Int32, _ parts: [String], padding: Int = 3) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array("/path/to/exe".utf8) + [UInt8](repeating: 0, count: padding)
        for part in parts { bytes += Array(part.utf8) + [0] }
        return bytes + [0, 0]
    }

    func testParsesArgumentsThenEnvironment() throws {
        let parsed = try XCTUnwrap(ProcessTable.parse(procargs: procargs(argc: 2, ["claude", "--model", "A=1", "ORCA_TERMINAL_HANDLE=term_x"])))
        XCTAssertEqual(parsed.arguments, ["claude", "--model"])
        XCTAssertEqual(parsed.environment, ["A=1", "ORCA_TERMINAL_HANDLE=term_x"])
    }

    func testKeepsEmptyArgumentsAndRejectsTruncatedData() throws {
        let parsed = try XCTUnwrap(ProcessTable.parse(procargs: procargs(argc: 3, ["codex", "", "x", "E=1"])))
        XCTAssertEqual(parsed.arguments, ["codex", "", "x"])
        XCTAssertEqual(parsed.environment, ["E=1"])
        XCTAssertNil(ProcessTable.parse(procargs: procargs(argc: 5, ["only", "two"])))
        XCTAssertNil(ProcessTable.parse(procargs: [1, 0]))
    }

    /// 양성 대조군: 이 테스트 프로세스 자신은 반드시 읽혀야 한다 — 못 읽으면 「에이전트 없음」이 거짓으로 나온다.
    func testReadsThisProcess() throws {
        let own = try XCTUnwrap(ProcessTable.commandLine(of: getpid()))
        XCTAssertEqual(own.arguments.first, CommandLine.arguments.first)
        XCTAssertTrue(own.environment.contains { $0.hasPrefix("PATH=") })
        XCTAssertTrue(ProcessTable.allPIDs().contains(getpid()))
        XCTAssertNotNil(ProcessTable.snapshot().parents[getpid()])
    }
}

final class OrcaRuntimeTests: XCTestCase {
    func testMetadataNeedsUnixSocketAndCredential() {
        // 인증 값 자리에는 시험용 한 글자를 넣는다.
        func file(_ fields: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: fields) }
        let field = OrcaRuntime.credentialField
        let unix: [String: Any] = ["kind": "unix", "endpoint": "/tmp/o.sock"]
        let web: [String: Any] = ["kind": "websocket", "endpoint": "ws://x"]
        XCTAssertEqual(OrcaRuntime.metadata(from: file(["runtimeId": "r1", field: "t", "transports": [web, unix]]))?.socketPath, "/tmp/o.sock")
        XCTAssertEqual(OrcaRuntime.metadata(from: file([field: "t", "transport": ["kind": "unix", "endpoint": "/tmp/old.sock"]]))?.socketPath, "/tmp/old.sock")
        XCTAssertNil(OrcaRuntime.metadata(from: file([field: "t", "transports": [web]])), "유닉스 소켓이 없다")
        XCTAssertNil(OrcaRuntime.metadata(from: file(["transports": [unix]])), "인증 값이 없다")
        XCTAssertNil(OrcaRuntime.metadata(from: Data("not json".utf8)))
    }

    func outcome(_ line: String, runtimeID: String? = "r1") -> Result<[String: Any], OrcaRuntime.Failure>? {
        if case .done(let result) = OrcaRuntime.frame(Data(line.utf8), expectingID: "abc", runtimeID: runtimeID) { return result }
        return nil
    }

    func testFrameSkipsKeepalivesAndBlankLines() {
        XCTAssertNil(outcome(#"{"_keepalive":true}"#))
        XCTAssertNil(outcome("  "))
    }

    func testFrameReturnsResultOnlyForOurRequest() throws {
        let ok = try XCTUnwrap(outcome(#"{"id":"abc","ok":true,"result":{"send":{"accepted":true}},"_meta":{"runtimeId":"r1"}}"#)).get()
        XCTAssertEqual((ok["send"] as? [String: Any])?["accepted"] as? Bool, true)
        // 응답이 왔다는 것은 요청이 전달됐다는 뜻이다 — 전부 「다시 보내지 않는」 실패여야 한다.
        for line in [#"{"id":"other","ok":true,"result":{}}"#,
                     #"{"id":"abc","ok":true,"result":{},"_meta":{"runtimeId":"r2"}}"#,
                     #"{"id":"abc","ok":false,"error":{"code":"terminal_not_found","message":"없음"}}"#,
                     "garbage"] {
            guard case .failure(.failed) = try XCTUnwrap(outcome(line)) else { return XCTFail(line) }
        }
    }
}

final class ReadinessTests: XCTestCase {
    struct Fixture: Decodable { let tail: [String] }

    func screen(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tail
    }

    func testClaudePromptVisibleOnlyWhenInputBoxIsShown() throws {
        for name in ["claude-idle", "claude-draft", "claude-after-deny"] {
            XCTAssertTrue(Readiness.inputVisible(agent: .claude, screen: try screen(name)), name)
        }
        // 권한 확인 창: 여기서 Enter 를 보내면 "1. Yes" 가 눌린다.
        XCTAssertFalse(Readiness.inputVisible(agent: .claude, screen: try screen("claude-permission")))
        XCTAssertFalse(Readiness.inputVisible(agent: .claude, screen: try screen("codex-idle")))
        XCTAssertFalse(Readiness.inputVisible(agent: .claude, screen: []))
    }

    func testCodexComposerVisibleOnlyWhenNoChoiceListIsShown() throws {
        for name in ["codex-idle", "codex-draft", "codex-multiline", "codex-after-deny", "codex-ultra-idle"] {
            XCTAssertTrue(Readiness.inputVisible(agent: .codex, screen: try screen(name)), name)
        }
        for name in ["codex-approval", "codex-picker", "claude-idle"] {
            XCTAssertFalse(Readiness.inputVisible(agent: .codex, screen: try screen(name)), name)
        }
        XCTAssertTrue(Readiness.inputVisible(agent: .codex, screen: ["› 쓰던 글 2. 번호가 뒤에 있는 경우"]))
        XCTAssertFalse(Readiness.inputVisible(agent: .codex, screen: ["›12. 선택지"]))
    }
}

final class ClaudeDefaultsTests: XCTestCase {
    let original = """
    {
      "model": "opus",
      "effortLevel": "high",
      "hooks": {
        "x": "model"
      },
      "modelSettings": {
        "claude-opus-5-5": {
          "effortLevel": "high"
        },
        "claude-sonnet-5-5": {
          "effortLevel": "medium"
        }
      }
    }
    """

    func decide(_ current: String) -> ClaudeDefaults.Decision {
        ClaudeDefaults.restoredContents(original: Data(original.utf8), current: Data(current.utf8))
    }

    func testUnchanged() {
        XCTAssertEqual(decide(original), .unchanged)
        XCTAssertEqual(decide(original.replacingOccurrences(of: "\"x\": \"model\"", with: "\"x\": \"other\"")), .unchanged)
    }

    func testRestoresOriginalBytesWhenOnlyDefaultsChanged() {
        let current = original
            .replacingOccurrences(of: "\"model\": \"opus\"", with: "\"model\": \"sonnet\"")
            .replacingOccurrences(of: "\"effortLevel\": \"medium\"", with: "\"effortLevel\": \"xhigh\"")
        XCTAssertEqual(decide(current), .write(Data(original.utf8)))
    }

    func testPatchesOnlyDefaultsWhenOtherSettingsAlsoChanged() throws {
        let current = original
            .replacingOccurrences(of: "\"model\": \"opus\"", with: "\"model\": \"sonnet\"")
            .replacingOccurrences(of: "\"effortLevel\": \"medium\"", with: "\"effortLevel\": \"xhigh\"")
            .replacingOccurrences(of: "\"x\": \"model\"", with: "\"x\": \"changed-elsewhere\"")
        guard case .write(let data) = decide(current) else { return XCTFail("고쳐 써야 한다") }
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(text, original.replacingOccurrences(of: "\"x\": \"model\"", with: "\"x\": \"changed-elsewhere\""))
    }

    let newEntry = (of: "\"claude-sonnet-5-5\": {",
                    with: "\"claude-fable-5-1\": {\n      \"effortLevel\": \"max\"\n    },\n    \"claude-sonnet-5-5\": {")

    func testRemovesNewlyAddedDefaultByRestoringOriginalBytes() {
        // 처음 써 보는 모델로 바꾸면 modelSettings 에 새 항목이 생긴다. 다른 변경이 없으면 원래 바이트로 되돌려 없앤다.
        let current = original.replacingOccurrences(of: newEntry.of, with: newEntry.with)
        XCTAssertEqual(decide(current), .write(Data(original.utf8)))
    }

    func testFailsRatherThanGuessWhenNewDefaultAppearsAlongsideOtherChanges() {
        let current = original
            .replacingOccurrences(of: newEntry.of, with: newEntry.with)
            .replacingOccurrences(of: "\"x\": \"model\"", with: "\"x\": \"changed-elsewhere\"")
        guard case .failed = decide(current) else { return XCTFail("없던 항목을 줄 단위로 지우는 추측은 하지 않는다") }
    }

    func testRestoreWritesFileAndKeepsPermissions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("modelswitch-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(original.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let defaults = ClaudeDefaults(url: url)
        let before = try XCTUnwrap(defaults.snapshot())
        try Data(original.replacingOccurrences(of: "\"model\": \"opus\"", with: "\"model\": \"fable\"").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        XCTAssertEqual(defaults.restore(to: before), .restored)
        XCTAssertEqual(try Data(contentsOf: url), before)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(defaults.restore(to: before), .unchanged)
    }
}

final class ConfigTests: XCTestCase {
    func testDecodeAppliesDefaults() throws {
        let json = #"{"slots":[{"name":"a","claude":{"model":"opus","effort":"high"}}]}"#
        let config = try JSONDecoder().decode(ModelSwitchConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.keepDefaults)
        XCTAssertEqual(config.modifiers, ["option", "shift"])
        XCTAssertEqual(config.modifierSymbols, "⌥⇧")
        XCTAssertEqual(config.slots[0].preset(for: .claude), AgentPreset(model: "opus", effort: "high"))
        XCTAssertNil(config.slots[0].preset(for: .codex))
    }

    func testStoreCreatesStarterAndRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("modelswitch-\(UUID().uuidString)/presets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ConfigStore(url: url)
        XCTAssertEqual(try store.load(), .starter)
        var edited = ModelSwitchConfig.starter
        edited.slots.removeLast()
        try store.save(edited)
        XCTAssertEqual(try store.load(), edited)
    }

    func testSwitcherPlanErrors() throws {
        let switcher = Switcher(config: .starter, codexModels: { CodexModels(models: []) })
        XCTAssertThrowsError(try switcher.plan(slot: 0, agent: .claude))
        XCTAssertThrowsError(try switcher.plan(slot: 9, agent: .claude))
        XCTAssertThrowsError(try switcher.plan(slot: 3, agent: .codex), "3번에는 codex 설정이 없다")
        XCTAssertEqual(try switcher.plan(slot: 1, agent: .claude).preset, AgentPreset(model: "opus", effort: "high"))
    }
}

final class GhosttyEscapeTests: XCTestCase {
    func testEscapesControlBytesOnly() {
        XCTAssertEqual(GhosttyIO.actionEscaped("/model opus"), "/model opus")
        XCTAssertEqual(GhosttyIO.actionEscaped("\u{13}"), "\\x13")
        XCTAssertEqual(GhosttyIO.actionEscaped("\u{1B}[A"), "\\x1b[A")
        XCTAssertEqual(GhosttyIO.actionEscaped("a\\b"), "a\\\\b")
        XCTAssertEqual(GhosttyIO.quoted("say \"hi\" \\x13"), "\"say \\\"hi\\\" \\\\x13\"")
    }

    func testAgentFromTitle() {
        XCTAssertEqual(Detector.agent(inTitle: "claude"), .claude)
        XCTAssertEqual(Detector.agent(inTitle: "✳ Codex — repo"), .codex)
        XCTAssertNil(Detector.agent(inTitle: "zsh"))
        XCTAssertNil(Detector.agent(inTitle: "claude vs codex"))
        // 제목으로도 폴더로도 못 가릴 때는 화면에 보이는 입력창으로 가린다.
        let rule = String(repeating: "─", count: 12)
        XCTAssertEqual(Detector.agent(onScreen: [rule, "❯ ", rule]), .claude)
        XCTAssertEqual(Detector.agent(onScreen: ["› Ask Codex to do anything", "  GPT-6-Sol high · ~/x"]), .codex)
        XCTAssertNil(Detector.agent(onScreen: ["  Select Model and Effort", "› 1. GPT-6-Sol (current)"]), "선택창이 떠 있으면 가리지 않는다")
        XCTAssertNil(Detector.agent(onScreen: ["yohan@Mac ~ % "]))
        XCTAssertEqual(AgentProcesses.agent(forCommandLine: "/Users/x/.local/share/claude/versions/2.1.289 --model opus"), .claude)
        XCTAssertEqual(AgentProcesses.agent(forCommandLine: "/Users/x/.codex/packages/standalone/releases/0.160.0/bin/codex -m x"), .codex)
        XCTAssertNil(AgentProcesses.agent(forCommandLine: "/bin/zsh -l"))
    }
}

final class OrcaStateTests: XCTestCase {
    func payload() -> [String: Any] {
        func pane(_ handle: String, leaf: String, active: Bool) -> [String: Any] {
            ["type": "terminal", "handle": handle, "leafId": leaf, "active": active, "title": handle]
        }
        return [
            "terminals": [
                ["handle": "term_a", "title": "💬 payment", "agentIdentity": "claude"],
                ["handle": "term_b", "title": "⏳ update-2", "agentIdentity": "claude"],
                ["handle": "term_c", "title": "review", "agentIdentity": "codex"],
                ["handle": "term_d", "title": "zsh", "agentIdentity": NSNull()],
            ],
            "visualLayouts": [
                ["worktreeId": "r1::/w/payment", "worktreePath": "/w/payment",
                 "root": ["type": "group", "activeTabId": "t1",
                          "tabs": [["tabId": "t1", "activeLeafId": "l1", "panes": pane("term_a", leaf: "l1", active: true)]]]],
                ["worktreeId": "r2::/w/update-2", "worktreePath": "/w/update-2",
                 "root": ["type": "split", "children": [
                    ["type": "group", "activeTabId": "t2",
                     "tabs": [["tabId": "t2", "activeLeafId": "l3",
                               "panes": ["type": "split", "children": [pane("term_b", leaf: "l2", active: false),
                                                                       pane("term_c", leaf: "l3", active: true)]]],
                              ["tabId": "t3", "activeLeafId": "l4", "panes": pane("term_d", leaf: "l4", active: true)]]],
                 ]]],
            ],
        ]
    }

    func testPicksActiveLeafOfVisibleTabNotFirstTerminal() throws {
        let target = try OrcaState.target(in: payload(), active: .init(worktreeID: "r2::/w/update-2", tabID: "t2"))
        XCTAssertEqual(target.host, .orca(handle: "term_c"))
        XCTAssertEqual(target.agent, .codex)
        XCTAssertEqual(target.label, "review · update-2")
    }

    func testProcessLookupWinsWhenAgentIdentityIsMissing() throws {
        // term_d 는 목록에서 agentIdentity 가 null 이다 — 대기 중인 claude 세션이 실제로 이렇게 온다.
        let active = OrcaState.Active(worktreeID: "r2::/w/update-2", tabID: "t3")
        let target = try OrcaState.target(in: payload(), active: active, processAgent: { $0 == "term_d" ? .claude : nil })
        XCTAssertEqual(target.agent, .claude)
        XCTAssertEqual(target.host, .orca(handle: "term_d"))
    }

    func testFindsOutermostAgentProcessForHandle() {
        let ps = """
          100     1 ttys001 /bin/zsh -l ORCA_TERMINAL_HANDLE=term_a HOME=/Users/x
          101   100 ttys001 claude --model opus ORCA_TERMINAL_HANDLE=term_a HOME=/Users/x
          102   101 ttys001 /Users/x/.local/bin/codex exec - ORCA_TERMINAL_HANDLE=term_a
          103   101 ttys001 /usr/bin/python3 x.py ORCA_TERMINAL_HANDLE=term_a
          200     1 ttys002 /Users/x/.codex/bin/codex ORCA_TERMINAL_HANDLE=term_ab OTHER=1
          300     1 ??      claude ORCA_TERMINAL_HANDLE=term_c
        """
        XCTAssertEqual(AgentProcesses.agent(orcaHandle: "term_a", psOutput: ps), .claude, "claude 가 띄운 codex 가 아니라 바깥쪽 claude")
        XCTAssertEqual(AgentProcesses.agent(orcaHandle: "term_ab", psOutput: ps), .codex)
        XCTAssertNil(AgentProcesses.agent(orcaHandle: "term_c", psOutput: ps), "터미널 없는 프로세스는 세지 않는다")
        XCTAssertNil(AgentProcesses.agent(orcaHandle: "term_zz", psOutput: ps))
    }

    func testRejectsNonAgentBrowserTabAndUnknownWorkspace() {
        XCTAssertThrowsError(try OrcaState.target(in: payload(), active: .init(worktreeID: "r2::/w/update-2", tabID: "t3")), "셸 터미널")
        XCTAssertThrowsError(try OrcaState.target(in: payload(), active: .init(worktreeID: "r2::/w/update-2", tabID: "browser-tab")))
        XCTAssertThrowsError(try OrcaState.target(in: payload(), active: .init(worktreeID: "r9::/w/none", tabID: "t1")))
    }
}

/// claude 흉내. 화면은 2026-10-06 claude 2.1.289 에서 받은 것과 같은 꼴로 그린다.
final class FakeClaude: TerminalIO {
    enum Stage: Equatable { case prompt, picker, confirm }
    var stage = Stage.prompt
    var rows = ["Default (recommended)", "Opus 5.5", "Fable 5.1", "Sonnet 5.5", "Haiku 4.5", "Opus 5"]
    var efforts = ["low", "medium", "high", "xhigh", "max"]
    var model = "Opus 5.5"
    var effort = "high"
    var cursor = 0
    var pickerEffort = 0
    var draft = ""
    var stashed: String?
    var line = ""
    /// 대화 줄들. 한가할 때 명령은 `❯ /model …` 과 그 아래 `⎿ 결과` 로 남는다.
    var transcript: [String] = []
    /// 작업 중에는 결과가 입력창 위의 알림 줄로만 뜬다.
    var notice: String?
    private var command = "/model"

    private func say(_ text: String) {
        if busy { notice = text } else { transcript += ["❯ \(command)", "  ⎿  \(text)"] }
    }
    var sent: [String] = []
    /// 참이면 들어온 글자를 전부 버린다(입력이 이 세션에 닿지 않은 상황).
    var ignoresInput = false
    /// 대화 도중 모델을 바꿀 때 한 번 더 묻는다("Switch model?").
    var asksBeforeSwitching = false
    /// 대화 도중 effort 만 바꿀 때도 한 번 더 묻는다("Change effort level?").
    var asksBeforeEffortChange = false
    private var askingAboutEffort = false
    /// 작업 중에는 결과가 대화 줄이 아니라 알림 줄로 뜬다.
    var busy = false
    /// 확정 방식: "s"(이 세션만) · "enter"(기본값으로 저장) · "command"(/model X)
    var confirmedBy: String?
    /// `/model X`·`/effort Y`·Enter 확정이 기본값을 쓰는 파일.
    var settings: URL?
    private var writes = 0
    private let rule = String(repeating: "─", count: 30)

    private func saveDefault(_ model: String) {
        guard let settings else { return }
        writes += 1
        try? Data("{\n  \"model\": \"\(model)\"\n}".utf8).write(to: settings)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000 + Double(writes))],
                                               ofItemAtPath: settings.path)
    }

    private func supportsEffort(_ model: String) -> Bool { !model.hasPrefix("Haiku") }

    private func finishCommand() {
        stage = .prompt
        if let stashed { draft = stashed }
        stashed = nil
    }

    private func confirm(session: Bool) {
        model = rows[cursor]
        var text = "Set model to \(model)" + (session ? " for this session only" : "")
        if supportsEffort(model) {
            effort = efforts[pickerEffort]
            text += " with \(effort) effort"
        }
        if !session { text += " and saved as your default for new sessions"; saveDefault(model) }
        say(text)
        confirmedBy = session ? "s" : "enter"
        finishCommand()
    }

    private var askedByCommand = false

    private func applyCommand(_ found: String) {
        model = found
        say("Set model to \(found) and saved as your default for new sessions")
        saveDefault(found)
        confirmedBy = "command"
    }

    private func run(_ command: String) {
        self.command = command
        if command == "/model" {
            stage = .picker
            cursor = rows.firstIndex(of: model) ?? 0
            pickerEffort = efforts.firstIndex(of: effort) ?? 0
        } else if command.hasPrefix("/model ") {
            let wanted = String(command.dropFirst("/model ".count)).lowercased()
            if let found = rows.first(where: { $0.lowercased().hasPrefix(wanted) }) {
                if asksBeforeSwitching, found != model {
                    // 명령으로 바꿀 때도 같은 확인 창이 뜬다. 답하기 전에는 아무것도 쓰지 않는다.
                    cursor = rows.firstIndex(of: found) ?? 0
                    askedByCommand = true
                    stage = .confirm
                    return
                }
                applyCommand(found)
            } else {
                say("Model '\(wanted)' not found")
            }
            finishCommand()
        } else if command.hasPrefix("/effort ") {
            effort = String(command.dropFirst("/effort ".count))
            if effort == "max" {
                // max 는 이 세션에만 적용되고 기본값 파일은 다시 쓰지 않는다(2.1.283 실측).
                say("Set effort level to max (this session only): …")
            } else {
                say("Set effort level to \(effort) (saved as your default for new sessions): …")
                saveDefault(model)
            }
            finishCommand()
        }
    }

    func type(_ text: String) throws {
        sent.append(text)
        if ignoresInput { return }
        var rest = Substring(text)
        while !rest.isEmpty {
            let arrows: [(String, () -> Void)] = [
                ("\u{1B}[A", { self.cursor = max(0, self.cursor - 1) }),
                ("\u{1B}[B", { self.cursor = min(self.rows.count - 1, self.cursor + 1) }),
                ("\u{1B}[C", { self.pickerEffort = (self.pickerEffort + 1) % self.efforts.count }),
                ("\u{1B}[D", { self.pickerEffort = (self.pickerEffort + self.efforts.count - 1) % self.efforts.count }),
            ]
            if let arrow = arrows.first(where: { rest.hasPrefix($0.0) }) {
                if stage == .picker { arrow.1() }
                rest = rest.dropFirst(arrow.0.count)
                continue
            }
            let key = rest.removeFirst()
            switch (stage, key) {
            case (.prompt, "\u{13}"): stashed = draft; draft = ""
            case (.prompt, "\r"): let command = line; line = ""; run(command)
            case (.prompt, _): line.append(key)
            case (.picker, "s"), (.picker, "\r"):
                if asksBeforeSwitching, rows[cursor] != model, key == "s" {
                    askingAboutEffort = false
                    stage = .confirm
                } else if asksBeforeEffortChange, rows[cursor] == model, efforts[pickerEffort] != effort, key == "s" {
                    askingAboutEffort = true
                    stage = .confirm
                } else {
                    confirm(session: key == "s")
                }
            case (.picker, "\u{1B}"): say("Kept model as \(model)"); finishCommand()
            case (.confirm, "\r") where askedByCommand: askedByCommand = false; applyCommand(rows[cursor]); finishCommand()
            case (.confirm, "\r"): confirm(session: true)
            case (.confirm, "2"), (.confirm, "\u{1B}"):
                // 선택창에서 온 질문이면 선택창으로 되돌아간다(2.1.289 실측). 명령에서 온 질문이면 그대로 끝난다.
                if askedByCommand { askedByCommand = false; say("Kept model as \(model)"); finishCommand() } else { stage = .picker }
            default: break
            }
        }
    }

    func press(_ key: Key) throws { try type(key.bytes) }

    func screen() -> [String]? {
        let shown = Array(transcript.suffix(6)) + (notice.map { [String(repeating: " ", count: 20) + $0] } ?? [])
        switch stage {
        case .prompt:
            return shown + [rule, "❯", rule, "  ⏵⏵ auto mode on"]
        case .picker:
            let list = rows.enumerated().map { index, name in
                "   \(index == cursor ? "❯" : " ") \(index + 1).  \(name)\(name == model ? " ✔" : "")             설명"
            }
            let level = efforts[pickerEffort]
            let effortLine = supportsEffort(rows[cursor])
                ? "   ● \(level == "xhigh" ? "xHigh" : level.capitalized) effort ←/→ to adjust"
                : "   ○ Effort not supported for \(rows[cursor])"
            return shown + ["   Select model", "   Switch between Claude models. Your pick becomes the default for new sessions."]
                + list + [effortLine, "   Enter to set as default · s to use this session only · Esc to cancel"]
        case .confirm:
            return shown + [askingAboutEffort ? "   Change effort level?" : "   Switch model?",
                            "   Your next response will be slower and use more tokens",
                            "   ❯ 1. Yes, switch to \(askingAboutEffort ? efforts[pickerEffort] : rows[cursor])", "     2. No, go back"]
        }
    }

    func snapshot() -> ScreenSnapshot? {
        screen().map { ScreenSnapshot(lines: $0, draft: draft) }
    }
}

final class SwitcherApplyTests: XCTestCase {
    let target = Target(host: .orca(handle: "term_x"), agent: .claude, label: "x")

    func config(_ model: String, _ effort: String, keepDefaults: Bool = true, accept: Bool = false) -> ModelSwitchConfig {
        ModelSwitchConfig(keepDefaults: keepDefaults, acceptSwitchPrompt: accept,
                          slots: [Slot(claude: AgentPreset(model: model, effort: effort))])
    }

    func switcher(_ config: ModelSwitchConfig, io: TerminalIO, settings: URL) -> Switcher {
        Switcher(config: config, claudeDefaults: ClaudeDefaults(url: settings),
                 codexModels: { CodexModels(models: []) }, makeIO: { _ in io }, sleep: { _ in })
    }

    func tempSettings(_ text: String = "{\n  \"model\": \"opus\"\n}") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("modelswitch-apply-\(UUID().uuidString).json")
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSendsNothingWhenPermissionDialogIsShowing() throws {
        let io = FakeIO()
        io.screens = [["╌╌╌╌", " Do you want to proceed?", " ❯ 1. Yes", "   2. No"]]
        XCTAssertThrowsError(try switcher(config("sonnet", "high"), io: io, settings: tempSettings()).apply(slot: 1, to: target))
        XCTAssertEqual(io.sent, [])
    }

    func testSendsNothingWhenScreenIsUnreadable() throws {
        let io = FakeIO()
        XCTAssertThrowsError(try switcher(config("sonnet", "high"), io: io, settings: tempSettings()).apply(slot: 1, to: target))
        XCTAssertEqual(io.sent, [])
    }

    func testPicksModelAndEffortForThisSessionOnly() throws {
        let settings = try tempSettings()
        let claude = FakeClaude()
        claude.settings = settings
        claude.draft = "쓰던 글"
        let result = try switcher(config("sonnet", "medium"), io: claude, settings: settings).apply(slot: 1, to: target)
        XCTAssertEqual(claude.model, "Sonnet 5.5")
        XCTAssertEqual(claude.effort, "medium")
        XCTAssertEqual(claude.confirmedBy, "s", "기본값까지 저장하는 방식으로 확정하면 안 된다")
        XCTAssertEqual(claude.draft, "쓰던 글")
        XCTAssertEqual(result.summary, "Sonnet 5.5 · medium")
        XCTAssertNil(result.pendingRestore, "기본값을 건드리지 않았으니 되돌릴 것도 없다")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{\n  \"model\": \"opus\"\n}")
    }

    func testEffortWrapsAroundToReachALowerLevel() throws {
        let claude = FakeClaude()
        claude.effort = "max"
        _ = try switcher(config("opus", "low"), io: claude, settings: tempSettings()).apply(slot: 1, to: target)
        XCTAssertEqual(claude.effort, "low")
        XCTAssertEqual(claude.model, "Opus 5.5")
    }

    func testFullModelIDPicksThatVersionNotTheNewest() throws {
        let claude = FakeClaude()
        _ = try switcher(config("claude-opus-5", "high"), io: claude, settings: tempSettings()).apply(slot: 1, to: target)
        XCTAssertEqual(claude.model, "Opus 5", "Opus 5.5 가 아니라")
    }

    func testModelWithoutEffortStillSwitches() throws {
        let claude = FakeClaude()
        let result = try switcher(config("haiku", "high"), io: claude, settings: tempSettings()).apply(slot: 1, to: target)
        XCTAssertEqual(claude.model, "Haiku 4.5")
        XCTAssertEqual(result.summary, "Haiku 4.5", "적용되지 않은 effort 를 알림에 쓰지 않는다")
    }

    func testSavesAsDefaultWhenAskedTo() throws {
        let settings = try tempSettings()
        let claude = FakeClaude()
        claude.settings = settings
        _ = try switcher(config("fable", "xhigh", keepDefaults: false), io: claude, settings: settings).apply(slot: 1, to: target)
        XCTAssertEqual(claude.confirmedBy, "enter")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{\n  \"model\": \"Fable 5.1\"\n}")
    }

    func testLeavesTheSwitchConfirmationToTheUserWhenTurnedOff() throws {
        let claude = FakeClaude()
        claude.asksBeforeSwitching = true
        XCTAssertThrowsError(try switcher(config("sonnet", "high"), io: claude, settings: tempSettings()).apply(slot: 1, to: target)) {
            XCTAssertEqual(($0 as? ModelSwitchError)?.awaitingUser, true)
            XCTAssertTrue("\($0)".contains("Sonnet 5.5"))
        }
        XCTAssertEqual(claude.stage, .confirm, "확인 창은 그대로 둔다")
        XCTAssertEqual(claude.sent.last, "s", "확인 창에는 아무것도 보내지 않았다")
        XCTAssertEqual(claude.model, "Opus 5.5")
    }

    func testFinishesAfterTheUserConfirmsThemselves() throws {
        let claude = FakeClaude()
        claude.asksBeforeSwitching = true
        claude.draft = "쓰던 글"
        var switcher = switcher(config("sonnet", "medium"), io: claude, settings: try tempSettings())
        var asked: [String] = []
        // 알림을 본 사용자가 Enter 를 누른다.
        switcher.onAwaitingUser = { model in asked.append(model); try? claude.type("\r") }
        let result = try switcher.apply(slot: 1, to: target)
        XCTAssertEqual(asked, ["Sonnet 5.5"])
        XCTAssertEqual(claude.model, "Sonnet 5.5")
        XCTAssertEqual(result.summary, "Sonnet 5.5 · medium", "사용자가 고른 뒤의 결과를 알린다")
        XCTAssertEqual(claude.draft, "쓰던 글")
    }

    func testReportsThatNothingChangedWhenTheUserSaysNo() throws {
        let claude = FakeClaude()
        claude.asksBeforeSwitching = true
        var switcher = switcher(config("sonnet", "medium"), io: claude, settings: try tempSettings())
        switcher.onAwaitingUser = { _ in try? claude.type("2") }
        XCTAssertThrowsError(try switcher.apply(slot: 1, to: target)) {
            XCTAssertEqual(($0 as? ModelSwitchError)?.nothingToDo, true, "\($0)")
        }
        XCTAssertEqual(claude.model, "Opus 5.5")
        XCTAssertEqual(claude.stage, .prompt, "되돌아온 선택창은 닫아 준다")
    }

    func testAcceptsTheSwitchConfirmationForTheChosenModel() throws {
        let claude = FakeClaude()
        claude.asksBeforeSwitching = true
        let result = try switcher(config("sonnet", "high", accept: true), io: claude, settings: tempSettings()).apply(slot: 1, to: target)
        XCTAssertEqual(claude.model, "Sonnet 5.5")
        XCTAssertEqual(claude.sent.filter { $0 == "\r" }.count, 1)
        XCTAssertEqual(result.summary, "Sonnet 5.5 · high")
    }

    func testNeverAcceptsAConfirmationForAnotherModel() throws {
        let io = FakeIO()
        io.screens = [["   Switch model?", "   ❯ 1. Yes, switch to Sonnet 5.5", "     2. No, go back"]]
        XCTAssertThrowsError(try Runner(io: io, sleep: { _ in }).run([
            .expectInput(agent: .claude, acceptSwitchTo: ["opus", "high"], timeoutMs: 200, abort: [], failure: "f"),
        ]))
        XCTAssertEqual(io.sent, [])
        // 커서가 No 에 있으면 그 창으로 보지 않는다.
        XCTAssertNil(ClaudeScreen.switchPrompt(["   Switch model?", "     1. Yes, switch to Opus 5.5", "   ❯ 2. No, go back"]))
        XCTAssertEqual(ClaudeScreen.switchPrompt(io.screens![0]), "Sonnet 5.5")
    }

    func testWorksWhileClaudeIsBusy() throws {
        let claude = FakeClaude()
        claude.busy = true
        let result = try switcher(config("fable", "max"), io: claude, settings: tempSettings()).apply(slot: 1, to: target)
        XCTAssertEqual(result.summary, "Fable 5.1 · max")
    }

    func testFallsBackToCommandsWhenThePickerLacksTheModelAndRestoresDefaults() throws {
        let original = "{\n  \"model\": \"opus\"\n}"
        let settings = try tempSettings(original)
        let claude = FakeClaude()
        claude.settings = settings
        claude.draft = "쓰던 글"
        // 선택창 목록에는 없지만 `/model` 명령은 아는 모델(목록 아래로 밀려난 옛 모델을 흉내).
        let hidden = "Opus 4.7"
        claude.rows.removeAll { $0 == hidden }
        let io = HidingRows(claude: claude, hidden: hidden)
        let result = try switcher(config("opus 4.7", "high"), io: io, settings: settings).apply(slot: 1, to: target)
        XCTAssertEqual(claude.model, hidden)
        XCTAssertEqual(claude.confirmedBy, "command")
        XCTAssertEqual(claude.draft, "쓰던 글")
        XCTAssertEqual(result.summary, "Opus 4.7 · high")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original, "명령은 기본값을 바꾸므로 되돌린다")
        XCTAssertEqual(claude.sent.filter { $0 == "\u{1B}" }.count, 1, "선택창은 Esc 한 번으로 닫는다")
    }

    func testReportsWhatClaudeSaidWhenTheModelDoesNotExist() throws {
        let original = "{\n  \"model\": \"opus\"\n}"
        let settings = try tempSettings(original)
        let claude = FakeClaude()
        claude.settings = settings
        XCTAssertThrowsError(try switcher(config("no-such", "high"), io: claude, settings: settings).apply(slot: 1, to: target)) {
            XCTAssertTrue("\($0)".contains("not found"), "\($0)")
        }
        XCTAssertEqual(claude.model, "Opus 5.5")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original)
    }

    func testSummaryUsesWhatTheAgentReported() {
        func summary(_ lines: [String]) -> String {
            SwitchResult(target: target, slotName: "", preset: AgentPreset(model: "opus", effort: "xhigh"),
                         warning: nil, confirmations: lines, pendingRestore: nil).summary
        }
        XCTAssertEqual(summary(["Set model to Opus 5.5 for this session only with xhigh effort"]), "Opus 5.5 · xhigh")
        // 작업 중 알림 줄은 잘려 온다.
        XCTAssertEqual(summary(["Set model to Opus 5.5 and", "Set effort level to high (saved as your default for new sessions): Compre"]),
                       "Opus 5.5 · high")
        XCTAssertEqual(summary(["Set model to Opus 5.5 and saved as your default for new sessions"]), "Opus 5.5 · xhigh")
        XCTAssertEqual(summary(["Effort not supported for Haiku 4.5", "Set model to Haiku 4.5 for this session only"]), "Haiku 4.5")
        XCTAssertEqual(summary(["Set model to Opus 5.5 for this session only"]), "Opus 5.5 · xhigh", "effort 가 그대로면 claude 는 말하지 않는다")
        XCTAssertEqual(summary(["Kept model as Opus 5.5"]), "Opus 5.5 · xhigh")
        XCTAssertEqual(summary(["Model changed to gpt-6.1-sol max for this session only"]), "gpt-6.1-sol · max")
        XCTAssertEqual(summary([]), "opus · xhigh", "확인 문구가 없으면 프리셋 값")
    }
}

final class EffortStepTests: XCTestCase {
    let target = Target(host: .orca(handle: "term_x"), agent: .claude, label: "x")

    func switcher(io: TerminalIO, keepDefaults: Bool = true, accept: Bool = false) -> Switcher {
        Switcher(config: ModelSwitchConfig(keepDefaults: keepDefaults, acceptSwitchPrompt: accept, slots: []),
                 claudeDefaults: ClaudeDefaults(url: URL(fileURLWithPath: "/nonexistent/settings.json")),
                 codexModels: { CodexModels(models: []) }, makeIO: { _ in io }, sleep: { _ in })
    }

    func testClaudeMovesOneLevelAndKeepsTheModel() throws {
        let claude = FakeClaude()
        claude.model = "Fable 5.1"
        claude.effort = "high"
        claude.draft = "쓰던 글"
        let up = try switcher(io: claude).stepEffort(up: true, on: target)
        XCTAssertEqual(claude.effort, "xhigh")
        XCTAssertEqual(claude.model, "Fable 5.1", "모델은 그대로")
        XCTAssertEqual(claude.confirmedBy, "s")
        XCTAssertEqual(claude.draft, "쓰던 글")
        XCTAssertEqual(up.summary, "Fable 5.1 · xhigh")
        _ = try switcher(io: claude).stepEffort(up: false, on: target)
        _ = try switcher(io: claude).stepEffort(up: false, on: target)
        XCTAssertEqual(claude.effort, "medium")
    }

    func testClaudeEffortConfirmationIsLeftToTheUserWhenTurnedOff() throws {
        let claude = FakeClaude()
        claude.asksBeforeEffortChange = true
        var switcher = switcher(io: claude)
        var asked: [String] = []
        switcher.onAwaitingUser = { value in asked.append(value); try? claude.type("\r") }
        let result = try switcher.stepEffort(up: true, on: target)
        XCTAssertEqual(asked, ["xhigh"], "「Change effort level?」 창은 사용자가 고른다")
        XCTAssertEqual(claude.effort, "xhigh")
        XCTAssertEqual(result.summary, "Opus 5.5 · xhigh")
    }

    func testClaudeEffortConfirmationIsAcceptedOnlyForTheLevelWeMovedTo() throws {
        let claude = FakeClaude()
        claude.asksBeforeEffortChange = true
        let accepting = Switcher(config: ModelSwitchConfig(acceptSwitchPrompt: true, slots: []),
                                 claudeDefaults: ClaudeDefaults(url: URL(fileURLWithPath: "/nonexistent/settings.json")),
                                 codexModels: { CodexModels(models: []) }, makeIO: { _ in claude }, sleep: { _ in })
        _ = try accepting.stepEffort(up: false, on: target)
        XCTAssertEqual(claude.effort, "medium")
        XCTAssertEqual(claude.sent.filter { $0 == "\r" }.count, 1)
        XCTAssertEqual(ClaudeScreen.switchPrompt(["   Change effort level?", "   ❯ 1. Yes, switch to high", "     2. No, go back"]), "high")
    }

    func testClaudeDoesNotWrapAtTheEnds() {
        for (start, up) in [("max", true), ("low", false)] {
            let claude = FakeClaude()
            claude.effort = start
            XCTAssertThrowsError(try switcher(io: claude).stepEffort(up: up, on: target)) {
                XCTAssertEqual(($0 as? ModelSwitchError)?.nothingToDo, true, "\($0)")
            }
            XCTAssertEqual(claude.effort, start, "끝에서 누르면 반대쪽 끝으로 돈다 — 누르지 않는다")
            XCTAssertNil(claude.confirmedBy)
            XCTAssertEqual(claude.stage, .prompt, "선택창을 닫고 나온다")
        }
    }

    func testClaudeStopsWhereAModelHasFewerLevels() {
        let claude = FakeClaude()
        claude.efforts = ["low", "medium", "high"]   // 이 모델에는 xhigh·max 가 없다
        claude.effort = "high"
        XCTAssertThrowsError(try switcher(io: claude).stepEffort(up: true, on: target)) {
            XCTAssertEqual(($0 as? ModelSwitchError)?.nothingToDo, true)
        }
        XCTAssertEqual(claude.effort, "high")
        XCTAssertNil(claude.confirmedBy, "low 로 넘어간 것을 확정하면 안 된다")
    }

    func testClaudeLeavesAModelThatIsNotInThePickerAlone() {
        let claude = FakeClaude()
        claude.model = "Custom Model"   // 목록에 없는 모델 — 커서가 다른 행에 가 있다
        XCTAssertThrowsError(try switcher(io: claude).stepEffort(up: true, on: target))
        XCTAssertNil(claude.confirmedBy, "여기서 확정하면 모델이 커서 행으로 바뀐다")
        XCTAssertEqual(claude.model, "Custom Model")
    }

    let codex = Target(host: .orca(handle: "term_c"), agent: .codex, label: "c")

    func testCodexWalksEveryLevelUpAndDownThroughMoreReasoning() throws {
        let picker = FakePicker()
        picker.current = "low"
        var seen: [String] = []
        for _ in 0..<5 {
            _ = try switcher(io: picker).stepEffort(up: true, on: codex)
            XCTAssertEqual(picker.confirmedBy, "s")
            seen.append(picker.current)
        }
        XCTAssertEqual(seen, ["medium", "high", "extra high", "max", "ultra"])
        XCTAssertThrowsError(try switcher(io: picker).stepEffort(up: true, on: codex)) {
            XCTAssertEqual(($0 as? ModelSwitchError)?.nothingToDo, true, "\($0)")
        }
        XCTAssertEqual(picker.stage, .composer, "끝이면 선택창을 닫고 나온다")
        seen = []
        for _ in 0..<5 {
            _ = try switcher(io: picker).stepEffort(up: false, on: codex)
            seen.append(picker.current)
        }
        XCTAssertEqual(seen, ["max", "extra high", "high", "medium", "low"])
        XCTAssertThrowsError(try switcher(io: picker).stepEffort(up: false, on: codex)) {
            XCTAssertEqual(($0 as? ModelSwitchError)?.nothingToDo, true)
        }
        XCTAssertEqual(picker.current, "low")
    }

    func testCodexStopsAtTheLastRowOfAModelWithoutMoreReasoning() {
        let picker = FakePicker()
        picker.advanced = []
        picker.current = "extra high"
        XCTAssertThrowsError(try switcher(io: picker).stepEffort(up: true, on: codex)) {
            XCTAssertEqual(($0 as? ModelSwitchError)?.nothingToDo, true)
        }
        XCTAssertNil(picker.confirmedBy)
    }

    func testCodexNeverConfirmsWithANumberOrEnter() throws {
        let picker = FakePicker()
        picker.current = "extra high"
        _ = try switcher(io: picker).stepEffort(up: true, on: codex)   // More reasoning… 으로 들어가는 Enter 는 확정이 아니다
        XCTAssertEqual(picker.current, "max")
        XCTAssertEqual(picker.confirmedBy, "s")
    }
}

final class LaggingTerminalTests: XCTestCase {
    let target = Target(host: .ghostty(terminalID: "T"), agent: .claude, label: "x")

    /// 화면이 0.5초 늦게 따라오는 터미널(Ghostty)에 claude 를 얹는다. 시간은 `sleep` 이 돌린다.
    func setUp(_ claude: FakeClaude, settings: URL, accept: Bool = false) -> (Switcher, LaggingIO) {
        var clock = 0
        let io = LaggingIO(base: claude, lagMs: 500)
        io.now = { clock }
        let config = ModelSwitchConfig(acceptSwitchPrompt: accept, slots: [Slot(claude: AgentPreset(model: "sonnet", effort: "medium"))])
        let switcher = Switcher(config: config, claudeDefaults: ClaudeDefaults(url: settings),
                                codexModels: { CodexModels(models: []) }, makeIO: { _ in io }, sleep: { clock += $0 })
        return (switcher, io)
    }

    func tempSettings() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("modelswitch-lag-\(UUID().uuidString).json")
        try Data("{\n  \"model\": \"opus\"\n}".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testUsesCommandsAndTheFileSignalInsteadOfThePicker() throws {
        let settings = try tempSettings()
        let claude = FakeClaude()
        claude.settings = settings
        claude.draft = "쓰던 글"
        let (switcher, _) = setUp(claude, settings: settings)
        let result = try switcher.apply(slot: 1, to: target)
        XCTAssertEqual(claude.model, "Sonnet 5.5")
        XCTAssertEqual(claude.effort, "medium")
        XCTAssertEqual(claude.confirmedBy, "command", "선택창은 단계마다 0.5초씩 걸려서 쓰지 않는다")
        XCTAssertEqual(claude.sent, ["\u{13}/model sonnet\r", "\u{13}/effort medium\r"])
        XCTAssertEqual(claude.draft, "쓰던 글")
        XCTAssertEqual(result.summary, "Sonnet 5.5 · medium", "끝난 뒤 새 화면에서 claude 의 말을 읽는다")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{\n  \"model\": \"opus\"\n}", "기본값은 되돌린다")
    }

    func testAcceptsAResultThatDidNotTouchTheSettingsFile() throws {
        let settings = try tempSettings()
        let claude = FakeClaude()
        claude.settings = settings
        var clock = 0
        let io = LaggingIO(base: claude, lagMs: 500)
        io.now = { clock }
        let config = ModelSwitchConfig(slots: [Slot(claude: AgentPreset(model: "fable", effort: "max"))])
        let switcher = Switcher(config: config, claudeDefaults: ClaudeDefaults(url: settings),
                                codexModels: { CodexModels(models: []) }, makeIO: { _ in io }, sleep: { clock += $0 })
        let result = try switcher.apply(slot: 1, to: target)
        XCTAssertEqual(claude.effort, "max")
        XCTAssertEqual(result.summary, "Fable 5.1 · max", "/effort max 는 파일을 안 쓴다 — 화면의 새 결과 줄로 확인한다")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{\n  \"model\": \"opus\"\n}")
    }

    func testReportsARefusalFromTheFreshScreen() throws {
        let settings = try tempSettings()
        let claude = FakeClaude()
        claude.settings = settings
        claude.rows.removeAll { $0.hasPrefix("Sonnet") }
        let (switcher, _) = setUp(claude, settings: settings)
        XCTAssertThrowsError(try switcher.apply(slot: 1, to: target)) {
            XCTAssertTrue("\($0)".contains("not found"), "\($0)")
        }
        XCTAssertEqual(claude.sent, ["\u{13}/model sonnet\r"], "거절당했으면 다음 명령을 보내지 않는다")
    }

    func testWaitsForTheUsersAnswerThenFinishesAndRestoresDefaults() throws {
        let settings = try tempSettings()
        let claude = FakeClaude()
        claude.settings = settings
        claude.asksBeforeSwitching = true
        var (switcher, _) = setUp(claude, settings: settings)
        var asked = 0
        switcher.onAwaitingUser = { _ in asked += 1; try? claude.type("\r") }
        let result = try switcher.apply(slot: 1, to: target)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(claude.model, "Sonnet 5.5")
        XCTAssertEqual(claude.effort, "medium", "사용자가 확정한 뒤 effort 까지 마저 맞춘다")
        XCTAssertEqual(result.summary, "Sonnet 5.5 · medium")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{\n  \"model\": \"opus\"\n}", "확정 뒤에 쓰인 기본값도 되돌린다")
    }

    func testStopsWhenTheUserDeclinesAndSendsNothingMore() throws {
        let settings = try tempSettings()
        let claude = FakeClaude()
        claude.settings = settings
        claude.asksBeforeSwitching = true
        var (switcher, _) = setUp(claude, settings: settings)
        switcher.onAwaitingUser = { _ in try? claude.type("2") }
        XCTAssertThrowsError(try switcher.apply(slot: 1, to: target)) {
            XCTAssertEqual(($0 as? ModelSwitchError)?.nothingToDo, true, "\($0)")
        }
        XCTAssertEqual(claude.model, "Opus 5.5")
        XCTAssertEqual(claude.sent.filter { $0.contains("/effort") }, [], "모델을 안 바꿨는데 effort 만 바꾸지 않는다")
    }

    /// 레드팀(codex) 주장 확인: 그 설정 파일은 다른 claude 세션도 쓴다. 우리 명령은 실행되지 않았는데
    /// 남이 파일을 건드린 것만으로 성공으로 치면 안 된다.
    func testAnotherSessionWritingTheSettingsFileIsNotOurSuccess() throws {
        let settings = try tempSettings()
        let claude = FakeClaude()
        claude.settings = settings
        claude.ignoresInput = true      // 우리 명령이 먹지 않는 상황(예: 입력이 다른 곳으로 갔다)
        var clock = 0
        let io = LaggingIO(base: claude, lagMs: 500)
        io.now = { clock }
        var touches = 0
        let config = ModelSwitchConfig(slots: [Slot(claude: AgentPreset(model: "sonnet", effort: "medium"))])
        let switcher = Switcher(config: config, claudeDefaults: ClaudeDefaults(url: settings),
                                codexModels: { CodexModels(models: []) }, makeIO: { _ in io },
                                sleep: { ms in
                                    clock += ms
                                    // 다른 세션이 같은 파일을 다시 쓴다(내용은 그 세션의 것).
                                    touches += 1
                                    try? Data("{\n  \"model\": \"fable\"\n}".utf8).write(to: settings)
                                    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000_000 + Double(touches))],
                                                                           ofItemAtPath: settings.path)
                                })
        XCTAssertThrowsError(try switcher.apply(slot: 1, to: target), "남이 쓴 파일을 우리 명령의 성공으로 읽었다")
        XCTAssertEqual(claude.model, "Opus 5.5")
    }

    func testRepeatingTheSameSwitchIsStillConfirmedByTheEchoedCommand() throws {
        let settings = try tempSettings()
        let claude = FakeClaude()
        claude.settings = settings
        let (switcher, _) = setUp(claude, settings: settings)
        // 같은 전환을 여러 번 — 화면(마지막 6줄)이 같은 줄로 가득 차서 줄 수로는 새 결과를 못 가린다.
        for _ in 0..<4 {
            XCTAssertEqual(try switcher.apply(slot: 1, to: target).summary, "Sonnet 5.5 · medium")
        }
        XCTAssertEqual(ClaudeScreen.reply(toCommand: "/model sonnet", in: ["❯ /model sonnet", "  ⎿  Set model to Sonnet 5.5", "❯ "]), "Set model to Sonnet 5.5")
        XCTAssertNil(ClaudeScreen.reply(toCommand: "/model opus", in: ["❯ /model sonnet", "  ⎿  Set model to Sonnet 5.5"]))
    }

    func testReadinessUsesAFreshScreenNotTheCachedOne() throws {
        let settings = try tempSettings()
        let claude = FakeClaude()
        let (switcher, io) = setUp(claude, settings: settings)
        _ = io.snapshot()               // 입력창이 보이는 화면이 보관된다
        claude.stage = .picker          // 그 직후에 선택창이 떴다(보관된 화면에는 아직 입력창이 보인다)
        XCTAssertThrowsError(try switcher.apply(slot: 1, to: target))
        XCTAssertEqual(claude.sent, [], "낡은 화면을 믿고 선택창에 Enter 를 보내면 그 행이 기본값으로 저장된다")
    }
}

/// 선택창 목록에는 없지만 `/model` 명령으로는 고를 수 있는 모델을 만든다.
final class HidingRows: TerminalIO {
    let claude: FakeClaude
    let hidden: String
    init(claude: FakeClaude, hidden: String) { self.claude = claude; self.hidden = hidden }

    func type(_ text: String) throws {
        // 명령으로 올 때만 그 모델을 알게 한다.
        if text.contains("/model \(hidden.lowercased())") { claude.rows.append(hidden) }
        try claude.type(text)
    }
    func press(_ key: Key) throws { try type(key.bytes) }
    func screen() -> [String]? { claude.screen() }
    func snapshot() -> ScreenSnapshot? { claude.snapshot() }
}

/// 레드팀(codex) 주장 확인: 대화 내용에 선택창·입력창처럼 보이는 글이 있을 때.
/// 표본은 2026-10-06 실제 claude 2.1.291 화면 — 대답 안에 선택창 모양 글이 있고, 그 아래에 진짜 권한 확인 창이 떠 있다.
final class SpoofedScreenTests: XCTestCase {
    struct Fixture: Decodable { let tail: [String] }

    func screen(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tail
    }

    func testTextThatLooksLikeAPickerIsNotAPicker() throws {
        let lines = try screen("claude-permission-fake-picker")
        XCTAssertTrue(lines.contains { $0.contains("Select model") }, "표본에 가짜 선택창 글이 있어야 한다")
        XCTAssertFalse(Readiness.claudePromptVisible(lines), "권한 확인 창이 떠 있다")
        XCTAssertEqual(Picker.rows(lines), [], "대화 속 글을 선택창으로 읽으면 그 행을 보고 화살표와 s 를 보낸다")
        XCTAssertFalse(Picker.isOpen(lines))
    }
}

final class AnchoredPickerTests: XCTestCase {
    struct Fixture: Decodable { let tail: [String] }

    func screen(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tail
    }

    /// 실제 화면: 대화 속에 가짜 선택창 글이 있고, 그 아래에 진짜 선택창이 열려 있다.
    func testReadsTheRealPickerAtTheBottomNotTheLookalikeAbove() throws {
        let open = try XCTUnwrap(Picker.open(try screen("claude-picker-below-fake-picker")))
        XCTAssertEqual(open.rows.count, 10, "가짜는 2행, 진짜는 10행")
        XCTAssertEqual(open.rows.first(where: \.selected)?.label, "Sonnet 5.5", "가짜의 커서는 Opus 5.5 에 있다")
        XCTAssertTrue(open.header.hasPrefix("Select model"))
        XCTAssertTrue(open.footer.contains("s to use this session only"))
    }

    /// 실제 화면: 62칸으로 좁힌 claude 선택창 — 행 설명과 맨 아랫줄 안내가 다음 줄로 접힌다.
    func testReadsAClaudePickerWhoseLinesWrap() throws {
        let open = try XCTUnwrap(Picker.open(try screen("claude-picker-narrow")))
        XCTAssertEqual(open.rows.map(\.number), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(open.rows.first(where: \.selected)?.label, "Sonnet 5.5")
        XCTAssertTrue(open.footer.contains("s to use this session only"), open.footer)
        XCTAssertEqual(Picker.claudeEffort(try screen("claude-picker-narrow")), "high")
    }

    /// 실제 화면: 58칸으로 좁힌 codex effort 목록.
    func testReadsACodexPickerWhoseLinesWrap() throws {
        let open = try XCTUnwrap(Picker.open(try screen("codex-efforts-narrow")))
        XCTAssertEqual(open.rows.map(\.label), ["Low", "Medium", "High", "Extra high", "More reasoning…"])
        XCTAssertEqual(open.rows.firstIndex(where: \.selected), 2)
        XCTAssertTrue(open.header.hasPrefix("Select Reasoning Level for GPT-6.1-Sol"))
        XCTAssertTrue(open.footer.contains("s session"))
    }

    func testLatestResultIsTheReplyToTheLastCommandNotAnOlderLine() {
        let rule = String(repeating: "─", count: 20)
        let prefixes = ["Set model to", "Kept model as"]
        // 62칸 실제 화면 꼴: 예전 줄들이 위에 있고, 마지막 명령의 답은 다음 줄로 접혀 있다.
        let idle = ["❯ /model", "  ⎿  Kept model as Sonnet 5.5",
                    "❯ /model", "  ⎿  Set model to Fable 5.1 for this session only with max", "     effort",
                    "                    ◈ max · /effort", rule, "❯", rule, "  상태 줄"]
        XCTAssertEqual(ClaudeScreen.latestResult(idle, command: "/model", prefixes: prefixes),
                       "Set model to Fable 5.1 for this session only with max effort")
        // 작업 중: 입력창 위의 알림 줄.
        let busy = ["❯ /model", "  ⎿  Kept model as Sonnet 5.5", "✳ Nucleating… (8s)",
                    "            Set model to Opus 5.5 for this session only with high effort", rule, "❯", rule]
        XCTAssertEqual(ClaudeScreen.latestResult(busy, command: "/model", prefixes: prefixes),
                       "Set model to Opus 5.5 for this session only with high effort")
        XCTAssertNil(ClaudeScreen.latestResult(["⏺ 대답", rule, "❯", rule], command: "/model", prefixes: prefixes))
    }

    func testPromptAndComposerMustBeAtTheBottom() {
        let rule = String(repeating: "─", count: 20)
        // 위쪽에 입력창 모양이 남아 있고 아래에는 다른 것이 떠 있다.
        let stale = [rule, "❯ ", rule] + (1...9).map { " 창의 \($0)번째 줄" }
        XCTAssertFalse(Readiness.claudePromptVisible(stale))
        XCTAssertTrue(Readiness.claudePromptVisible([rule, "❯ 첫 줄", "  둘째 줄", "  셋째 줄", rule, "  상태 줄", "  ⏵⏵ auto mode on"]), "여러 줄 초안")
        // codex: 지난 대화의 `› 내가 보낸 글` 은 입력창이 아니다.
        XCTAssertFalse(Readiness.codexComposerVisible(["› 아까 보낸 글", "• 대답", "  Would you like to run this?", "■ 번호 없는 창"]))
        XCTAssertTrue(Readiness.codexComposerVisible(["› 아까 보낸 글", "• 대답", "› ", "  GPT-6-Sol high · ~/x", "  ? for shortcuts"]))
        XCTAssertTrue(Readiness.codexComposerVisible(["› 첫 줄", "  둘째 줄", "  GPT-6-Sol high · ~/x"]), "여러 줄 초안")
    }
}

final class ClaudePickerTests: XCTestCase {
    /// 2026-10-06 claude 2.1.289 화면 그대로.
    let picker = [
        "   Select model",
        "   Switch between Claude models. Your pick becomes the default for new sessions. For other/previous model names, specify with --model.",
        "     1.  Default (recommended)  Sonnet 5.5 · Efficient for routine tasks",
        "   ❯ 2.  Opus 5.5 ✔             For complex work and everyday tasks",
        "     3.  Fable 5.1              For your toughest challenges",
        "     4.  Sonnet 5.5             Most efficient for simpler tasks",
        "     5.  Haiku 4.5              Fastest for quick answers",
        "     6.  Sonnet 5               Efficient for routine tasks",
        "     7.  Opus 5                 Best for everyday, complex tasks",
        "   ↓ 10. Opus 4.7               Best for everyday, complex tasks",
        "      … +2 models",
        "   ◉ xHigh effort ←/→ to adjust",
        "   Enter to set as default · s to use this session only · Esc to cancel",
    ]

    func testReadsRowsCursorAndCurrentMark() {
        let rows = Picker.rows(picker)
        XCTAssertEqual(rows.map(\.label), ["Default (recommended)", "Opus 5.5", "Fable 5.1", "Sonnet 5.5", "Haiku 4.5", "Sonnet 5", "Opus 5", "Opus 4.7"])
        XCTAssertEqual(rows.map(\.number), [1, 2, 3, 4, 5, 6, 7, 10])
        XCTAssertEqual(rows.firstIndex(where: \.selected), 1)
        XCTAssertEqual(rows.firstIndex(where: \.current), 1)
    }

    func testFindsTheRowForAPresetModel() {
        let rows = Picker.rows(picker)
        XCTAssertEqual(Picker.index(of: ClaudeModels.rowLabel("opus"), in: rows), 1, "별칭은 맨 위(최신) 행")
        XCTAssertEqual(Picker.index(of: ClaudeModels.rowLabel("sonnet"), in: rows), 3, "Default 행이 아니라 Sonnet 5.5 행")
        XCTAssertEqual(Picker.index(of: ClaudeModels.rowLabel("claude-opus-5"), in: rows), 6, "Opus 5.5 가 아니라 Opus 5")
        XCTAssertEqual(Picker.index(of: ClaudeModels.rowLabel("claude-sonnet-5-5"), in: rows), 3)
        XCTAssertEqual(Picker.index(of: ClaudeModels.rowLabel("claude-haiku-4-5-20251001"), in: rows), 4)
        XCTAssertEqual(Picker.index(of: ClaudeModels.rowLabel("Opus 4.7"), in: rows), 7)
        XCTAssertNil(Picker.index(of: ClaudeModels.rowLabel("opus[1m]"), in: rows))
        XCTAssertNil(Picker.index(of: ClaudeModels.rowLabel("gpt-6"), in: rows))
    }

    func testReadsTheEffortLine() {
        XCTAssertEqual(Picker.claudeEffort(picker), "xhigh")
        XCTAssertEqual(Picker.claudeEffort(["   ◐ Medium effort (default) ←/→ to adjust"]), "medium")
        XCTAssertEqual(Picker.claudeEffort(["   ◈ Max effort ←/→ to adjust", "   May use excessive tokens resulting in long response times."]), "max")
        XCTAssertNil(Picker.claudeEffort(["   ○ Effort not supported for Haiku 4.5"]))
        XCTAssertTrue(Picker.claudeEffortUnsupported(["   ○ Effort not supported for Haiku 4.5"]))
    }
}

final class LaunchTests: XCTestCase {
    func testBuildsSessionOnlyFlags() {
        XCTAssertEqual(Launch.command(agent: .claude, preset: AgentPreset(model: "opus", effort: "high"), extra: ["-c"]),
                       ["claude", "--model", "opus", "--effort", "high", "-c"])
        XCTAssertEqual(Launch.command(agent: .codex, preset: AgentPreset(model: "gpt-6.1-sol", effort: "xhigh")),
                       ["codex", "-m", "gpt-6.1-sol", "-c", "model_reasoning_effort=\"xhigh\""])
    }
}

final class SlotTests: XCTestCase {
    func testNameIsOptionalInTheFile() throws {
        let config = try JSONDecoder().decode(ModelSwitchConfig.self, from: Data(#"{"slots":[{"claude":{"model":"opus","effort":"high"}},{"name":"밤샘","codex":{"model":"gpt-x","effort":"max"}}]}"#.utf8))
        XCTAssertEqual(config.slots[0].name, "")
        XCTAssertTrue(config.effortKeys, "옛 파일에 없는 항목은 기본값")
        XCTAssertTrue(config.acceptSwitchPrompt, "확인 창은 기본으로 받아들인다(우리가 고른 값을 물을 때만)")
        let off = try JSONDecoder().decode(ModelSwitchConfig.self, from: Data(#"{"acceptSwitchPrompt":false,"slots":[]}"#.utf8))
        XCTAssertFalse(off.acceptSwitchPrompt)
        XCTAssertEqual(config.slots[0].listing, "claude opus · high")
        XCTAssertEqual(config.slots[1].listing, "codex gpt-x · max   — 밤샘")
        let saved = String(data: try JSONEncoder().encode(config.slots[0]), encoding: .utf8) ?? ""
        XCTAssertFalse(saved.contains("name"), "빈 이름은 파일에 쓰지 않는다")
        XCTAssertEqual(try JSONDecoder().decode(Slot.self, from: JSONEncoder().encode(config.slots[1])), config.slots[1])
    }
}

final class AgentVersionTests: XCTestCase {
    func testParsesVersionOutputOfBothAgents() {
        XCTAssertEqual(AgentVersions.parse(versionOutput: "2.1.291 (Claude Code)\n"), "2.1.291")
        XCTAssertEqual(AgentVersions.parse(versionOutput: "codex-cli 0.160.1\n"), "0.160.1")
        XCTAssertNil(AgentVersions.parse(versionOutput: "command not found"), "숫자 세 토막이 없으면 판을 지어내지 않는다")
        XCTAssertNil(AgentVersions.parse(versionOutput: "1.2 beta"))
    }

    func testReadsVersionFromInstallPath() {
        XCTAssertEqual(AgentVersions.version(inCommandLine: "/Users/x/.local/share/claude/versions/2.1.289 --model opus"), "2.1.289")
        XCTAssertEqual(AgentVersions.version(inCommandLine: "/Users/x/.codex/packages/standalone/releases/0.160.0/bin/codex -m x"), "0.160.0")
        XCTAssertEqual(AgentVersions.version(inCommandLine: "/Users/x/.codex/packages/standalone/releases/0.160.1-aarch64-apple-darwin/bin/codex"), "0.160.1")
        XCTAssertNil(AgentVersions.version(inCommandLine: "/Users/x/.codex/packages/standalone/releases/latest/bin/codex"))
        XCTAssertEqual(AgentVersions.version(inCommandLine: "/Users/x/.codex/packages/standalone/releases/0.160.0-alpha.6-aarch64-apple-darwin/bin/codex"), "0.160.0-alpha.6")
        let prerelease = AgentVersions.Report(agent: .codex, installed: "0.160.0", running: ["0.160.0-alpha.6"])
        XCTAssertEqual(prerelease.untested, ["0.160.0-alpha.6"], "시험판은 확인한 안정판이 아니다")
        XCTAssertNil(AgentVersions.version(inCommandLine: "/opt/homebrew/bin/codex -m x"), "경로에 판이 없으면 모른다고 한다")
    }

    func testFlagsVersionsWeNeverSaw() {
        let seen = AgentVersions.Report(agent: .claude, installed: "2.1.289", running: ["2.1.283"])
        XCTAssertEqual(seen.untested, [])
        let newer = AgentVersions.Report(agent: .claude, installed: "2.1.999", running: ["2.1.289"])
        XCTAssertEqual(newer.untested, ["2.1.999"], "양성 대조군: 확인 안 한 판은 반드시 걸린다")
        XCTAssertTrue(newer.lines.contains { $0.contains("2.1.999") && $0.contains("확인 못 한 판") })
        let unknown = AgentVersions.Report(agent: .codex, installed: nil, running: [])
        XCTAssertEqual(unknown.untested, [], "설치 판을 못 읽은 것과 확인 못 한 판은 다르다")
        XCTAssertFalse(unknown.lines.contains { $0.contains("확인한 판입니다") }, "근거가 없으면 확인했다고 말하지 않는다")
        XCTAssertTrue(unknown.lines.contains { $0.contains("판을 읽지 못한 것") })
        let hidden = AgentVersions.Report(agent: .claude, installed: "2.1.289", running: ["알 수 없음"])
        XCTAssertFalse(hidden.lines.contains { $0.contains("확인한 판입니다") }, "설치 판이 확인된 판이어도 실행 중인 세션의 판을 모르면 확인했다고 하지 않는다")
        XCTAssertTrue(hidden.lines.contains { $0.contains("실행 중인 claude 일부") })
        let clean = AgentVersions.Report(agent: .claude, installed: "2.1.289", running: ["2.1.288"])
        XCTAssertTrue(clean.lines.contains { $0.contains("확인한 판입니다") }, "양성 대조군: 모두 읽혔고 확인한 판이면 그렇게 말한다")
    }
}
