import XCTest
@testable import SlashCommandCore

final class FakeIO: TerminalIO {
    var sent: [String] = []
    /// nil means a terminal whose screen cannot be read.
    var screens: [[String]]?
    private var reads = 0
    var readCount: Int { reads }

    var onEnter: (() -> Void)?
    /// Fakes a terminal such as Orca that supplies the draft separately. nil means the draft is unknown.
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

final class PlanTests: KoreanMessagesTestCase {
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
        // Checks the result line and moves on, with no fixed wait.
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
        // The only digit is the model number: choosing effort with a digit key would save the default as well.
        XCTAssertEqual(typed.filter { $0.allSatisfy(\.isNumber) }, ["2"])
        XCTAssertTrue(typed.contains("s"), "Must confirm for this session only (s) so the default is not touched")
        XCTAssertTrue(steps.contains { if case .selectRow(label: "High", via: "More reasoning", _, _, _) = $0 { return true } else { return false } })
        XCTAssertTrue(steps.contains { if case .expectPicker(header: "Select Reasoning Level for GPT-6-Astra", _, _, _, _) = $0 { return true } else { return false } })
        XCTAssertFalse(steps.contains { if case .wait = $0 { return true } else { return false } }, "No fixed wait")
        XCTAssertFalse(steps.contains(.key(.escape)), "Esc only when the picker is visible (closePicker); Esc during work interrupts the work")
    }
}

final class CodexModelsTests: KoreanMessagesTestCase {
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
        // Models in the More reasoning… submenu (max, ultra) and models with only four levels can also be chosen, because the row is found on screen.
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("slashcommand-models-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try CodexModels.load(from: url).listed.first?.efforts, ["low", "high"])
    }
}

final class RunnerTests: KoreanMessagesTestCase {
    func run(_ steps: [Step], io: FakeIO) throws {
        try Runner(io: io, sleep: { _ in }).run(steps)
    }

    /// PR #39 review: if the effort line has disappeared from the screen (the picker closed or another window took over), do not send more arrows the other way —
    /// putting the value back to the last one seen and trying the other direction would press arrows where nothing is visible.
    func testStopsAdjustingTheEffortOnceTheEffortRowIsGone() {
        let io = FakeIO()
        let picker = ["   Select model", "   ❯ 1.  Opus 5.5 ✔   설명", "   ● High effort ←/→ to adjust",
                      "   Enter to set as default · s to use this session only · Esc to cancel"]
        let prompt = ["────", "❯", "────", "  ⏵⏵ auto mode on"]
        io.screens = [picker, prompt]
        XCTAssertThrowsError(try run([.setEffort(level: "xhigh", timeoutMs: 500, abort: [], failure: "effort")], io: io))
        XCTAssertEqual(io.sent, [Key.right.bytes], "Presses once at first and does not press after the line has disappeared")
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
            XCTAssertEqual($0 as? SlashCommandError, SlashCommandError("열리지 않음"))
        }
        XCTAssertEqual(io.sent, ["a", "\u{1B}"])
    }

    private let rule = String(repeating: "─", count: 20)

    func testExpectResultWaitsForNewResultLineAndSignal() throws {
        let io = FakeIO()
        // At first the previous switch's result line is still there, then this command's result appears.
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
        // The same text was on screen before the command and the defaults file is unchanged — there is no evidence it is this command's result.
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
        // Even without a defaults-file signal, one more line with the same text is a new result.
        let io = FakeIO()
        let stale = ["  ⎿  Set model to Sonnet 5.5", rule, "❯"]
        io.screens = [stale, ["  ⎿  Set model to Sonnet 5.5", "❯ /model sonnet", "  ⎿  Set model to Sonnet 5.5", rule, "❯"]]
        let runner = Runner(io: io, sleep: { _ in }, initial: ScreenSnapshot(lines: stale, draft: ""))
        try runner.run([.arm, .text("go"), .expectResult(prefix: "Set model to", timeoutMs: 300, failure: "f")])
    }

    func testExpectResultStopsAtOnceWhenTheCommandWasRefused() {
        // Even if an earlier switch's line remains on screen, it is a failure when a different reply sits right under this command (an earlier line is not read as success).
        let io = FakeIO()
        let stale = ["❯ /model", "  ⎿  Set model to Opus 5 for this session only with low effort", rule, "❯"]
        io.screens = [stale, stale + [], ["  ⎿  Set model to Opus 5 for this session only with low effort",
                                           "❯ /model no-such", "  ⎿  Model 'no-such' not found", rule, "❯"]]
        let runner = Runner(io: io, sleep: { _ in }, stamp: { 7 }, initial: ScreenSnapshot(lines: stale, draft: ""))
        XCTAssertThrowsError(try runner.run([.arm, .text("go"), .expectResult(prefix: "Set model to", command: "/model", timeoutMs: 3000, failure: "응답 없음"), .text("next")])) {
            XCTAssertTrue("\($0)".contains("Model 'no-such' not found"), "\($0)")
        }
        XCTAssertEqual(io.sent, ["go"], "The next command is not sent")
    }

    func testExpectResultWaitsUntilDraftIsBack() throws {
        let io = FakeIO()
        io.screens = [["  ⎿  Set model to X", rule, "❯"]]
        io.drafts = ["", "", "내 초안 그리고 더 친 글"]
        let runner = Runner(io: io, sleep: { _ in }, initial: ScreenSnapshot(lines: [rule, "❯"], draft: "내 초안"))
        try runner.run([.expectResult(prefix: "Set model to", timeoutMs: 1000, failure: "f")])
        XCTAssertEqual(io.draftReadCount, 3, "Does not move to the next step until the draft is back (text typed in the meantime is not an issue)")
    }

    func testExpectResultSeesTheNoticeLineShownWhileClaudeIsWorking() throws {
        let io = FakeIO()
        // While working, the result appears not as a conversation line but as a right-aligned notice above the input box. The last ⎿ line is tool output.
        io.screens = [["  ⎿  $ sleep 20 (5s)", "✻ Beaming… (11s)", "                 Set model to Opus 5.5 and", rule, "❯"]]
        let result = try Runner(io: io, sleep: { _ in }).run([.expectResult(prefix: "Set model to", timeoutMs: 300, failure: "f")])
        XCTAssertEqual(result, ["Set model to Opus 5.5 and"])
    }

    func testExpectResultWaitsForDraftOnScreenWhenTheTerminalGivesNoDraft() throws {
        // Ghostty does not supply the draft separately — it judges by text becoming visible again on the input box line.
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
        // The result line appeared, but a permission prompt came up in between — the next command's Enter must not press it.
        io.screens = [["  ⎿  Set model to X", "╌╌╌╌", " Do you want to proceed?", " ❯ 1. Yes", "   2. No"]]
        XCTAssertThrowsError(try Runner(io: io, sleep: { _ in }).run([
            .text("a"), .expectResult(prefix: "Set model to", timeoutMs: 300, failure: "f"), .text("b"),
        ]))
        XCTAssertEqual(io.sent, ["a"])
    }

    func testExpectResultFailureCarriesWhatTheScreenSaid() {
        let io = FakeIO()
        io.screens = [["❯ /model xyz", "  ⎿  Model 'xyz' not found", rule, "❯"]]
        XCTAssertThrowsError(try Runner(io: io, sleep: { _ in }).run([.expectResult(prefix: "Set model to", command: "/model", timeoutMs: 200, failure: "응답 없음")])) {
            XCTAssertTrue("\($0)".contains("Model 'xyz' not found"))
        }
        // A result elsewhere in the conversation is not a reply to our command.
        io.screens = [["  ⎿  Model 'xyz' not found", rule, "❯"]]
        XCTAssertThrowsError(try Runner(io: io, sleep: { _ in }).run([.expectResult(prefix: "Set model to", command: "/model", timeoutMs: 200, failure: "응답 없음")])) {
            XCTAssertEqual($0 as? SlashCommandError, SlashCommandError("응답 없음"))
        }
        // A line that was there before the command is not this command's reply — do not attach it.
        let old = ["  ⎿  $ sleep 20", rule, "❯"]
        io.screens = [old]
        XCTAssertThrowsError(try Runner(io: io, sleep: { _ in }, initial: ScreenSnapshot(lines: old, draft: "")).run([
            .arm, .expectResult(prefix: "Set model to", timeoutMs: 200, failure: "응답 없음"),
        ])) {
            XCTAssertEqual($0 as? SlashCommandError, SlashCommandError("응답 없음"))
        }
    }

    func testUnreadableScreenStopsInsteadOfSendingBlind() {
        let io = FakeIO()
        XCTAssertThrowsError(try run([.expect(needle: "x", timeoutMs: 400, abort: [.text("X")], failure: "f"), .text("b")], io: io))
        XCTAssertEqual(io.sent, [], "If the screen cannot be read, neither later steps nor cleanup steps are sent")
    }
}

/// Fakes the codex `/model` picker. The screen is drawn in the same form as received from codex 0.160.0 on 2026-10-06.
final class FakePicker: TerminalIO {
    enum Stage { case composer, models, efforts, advanced }
    var stage = Stage.composer
    var cursor = 0
    var sent: [String] = []
    /// Confirmation method: "s" (this session only) or "enter"/"number" (saves to the default as well).
    var confirmedBy: String?
    /// Last confirmed row (lowercase).
    var chosen: String?
    /// Current effort (lowercase row name). The `(current)` marker is attached to it.
    var current = "high"
    var efforts = ["Low", "Medium", "High", "Extra high"]
    var advanced = ["Max", "Ultra"]
    /// When true, the screen follows one beat late (reading right after sending a key gives the previous screen).
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

final class PickerTests: KoreanMessagesTestCase {
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
        XCTAssertEqual(Picker.index(of: "high", in: rows), 2, "Extra high is not High")
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
        // The approval window also uses numbered rows — Up, Down, s, and Esc must not be sent there.
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
            XCTAssertEqual(picker.confirmedBy, "s", "\(label): must not confirm in a way that also saves to the default")
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
        XCTAssertEqual(picker.stage, .composer, "Closes the picker and leaves")
        // More reasoning… was entered and searched, so it closes in three steps: submenu, effort, model list. No more presses at the input box.
        XCTAssertEqual(picker.sent.filter { $0 == "\u{1B}" }.count, 3)
    }
}

final class ProcessTableTests: KoreanMessagesTestCase {
    func procargs(argc: Int32, _ parts: [String], padding: Int = 3) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array("/path/to/exe".utf8) + [UInt8](repeating: 0, count: padding)
        for part in parts { bytes += Array(part.utf8) + [0] }
        return bytes + [0, 0]
    }

    #if os(macOS)
    func testParsesArgumentsThenEnvironment() throws {
        let parsed = try XCTUnwrap(ProcessTable.parse(procargs: procargs(argc: 2, ["claude", "--model", "A=1", "ORCA_TERMINAL_HANDLE=term_x"])))
        XCTAssertEqual(parsed.arguments, ["claude", "--model"])
        XCTAssertEqual(parsed.environment, ["A=1", "ORCA_TERMINAL_HANDLE=term_x"])
    }
    #endif

    #if os(macOS)
    func testKeepsEmptyArgumentsAndRejectsTruncatedData() throws {
        let parsed = try XCTUnwrap(ProcessTable.parse(procargs: procargs(argc: 3, ["codex", "", "x", "E=1"])))
        XCTAssertEqual(parsed.arguments, ["codex", "", "x"])
        XCTAssertEqual(parsed.environment, ["E=1"])
        XCTAssertNil(ProcessTable.parse(procargs: procargs(argc: 5, ["only", "two"])))
        XCTAssertNil(ProcessTable.parse(procargs: [1, 0]))
    }
    #endif

    /// Positive control: this test process itself must be read — if it cannot be read, "no agent" comes out falsely.
    #if os(macOS)
    func testReadsThisProcess() throws {
        let own = try XCTUnwrap(ProcessTable.commandLine(of: getpid()))
        XCTAssertEqual(own.arguments.first, CommandLine.arguments.first)
        XCTAssertTrue(own.environment.contains { $0.hasPrefix("PATH=") })
        XCTAssertTrue(ProcessTable.allPIDs().contains(getpid()))
        XCTAssertNotNil(ProcessTable.snapshot().parents[getpid()])
    }
    #endif
}

final class OrcaRuntimeTests: KoreanMessagesTestCase {
    func testMetadataNeedsUnixSocketAndCredential() {
        // Put a single test character in the place of the auth value.
        func file(_ fields: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: fields) }
        let field = OrcaRuntime.credentialField
        let unix: [String: Any] = ["kind": "unix", "endpoint": "/tmp/o.sock"]
        let web: [String: Any] = ["kind": "websocket", "endpoint": "ws://x"]
        XCTAssertEqual(OrcaRuntime.metadata(from: file(["runtimeId": "r1", field: "t", "transports": [web, unix]]))?.socketPath, "/tmp/o.sock")
        XCTAssertEqual(OrcaRuntime.metadata(from: file([field: "t", "transport": ["kind": "unix", "endpoint": "/tmp/old.sock"]]))?.socketPath, "/tmp/old.sock")
        XCTAssertNil(OrcaRuntime.metadata(from: file([field: "t", "transports": [web]])), "No Unix socket")
        XCTAssertNil(OrcaRuntime.metadata(from: file(["transports": [unix]])), "No auth value")
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
        // A response arriving means the request was delivered — all of these must be failures that are not resent.
        for line in [#"{"id":"other","ok":true,"result":{}}"#,
                     #"{"id":"abc","ok":true,"result":{},"_meta":{"runtimeId":"r2"}}"#,
                     #"{"id":"abc","ok":false,"error":{"code":"terminal_not_found","message":"없음"}}"#,
                     "garbage"] {
            guard case .failure(.failed) = try XCTUnwrap(outcome(line)) else { return XCTFail(line) }
        }
    }
}

final class ReadinessTests: KoreanMessagesTestCase {
    struct Fixture: Decodable { let tail: [String] }

    func screen(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tail
    }

    func testClaudePromptVisibleOnlyWhenInputBoxIsShown() throws {
        for name in ["claude-idle", "claude-draft", "claude-after-deny"] {
            XCTAssertTrue(Readiness.inputVisible(agent: .claude, screen: try screen(name)), name)
        }
        // Permission prompt: sending Enter here presses "1. Yes".
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

final class ClaudeDefaultsTests: KoreanMessagesTestCase {
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

    func testRestoresOriginalBytesWhenOtherSettingsHoldBooleansAndNumbers() throws {
        // Booleans and numbers are where Foundation's dictionary equality differs between platforms.
        let original = self.original.replacingOccurrences(of: "\"model\": \"opus\",", with: "\"model\": \"opus\",\n  \"alwaysThinkingEnabled\": true,\n  \"cleanupPeriodDays\": 30,")
        let current = original.replacingOccurrences(of: "\"model\": \"opus\"", with: "\"model\": \"sonnet\"")
        XCTAssertEqual(ClaudeDefaults.restoredContents(original: Data(original.utf8), current: Data(current.utf8)), .write(Data(original.utf8)))
        let elsewhere = current.replacingOccurrences(of: "\"x\": \"model\"", with: "\"x\": \"changed-elsewhere\"")
        guard case .write(let data) = ClaudeDefaults.restoredContents(original: Data(original.utf8), current: Data(elsewhere.utf8)) else {
            return XCTFail("Must patch the file")
        }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), original.replacingOccurrences(of: "\"x\": \"model\"", with: "\"x\": \"changed-elsewhere\""))
    }

    func testPatchesOnlyDefaultsWhenOtherSettingsAlsoChanged() throws {
        let current = original
            .replacingOccurrences(of: "\"model\": \"opus\"", with: "\"model\": \"sonnet\"")
            .replacingOccurrences(of: "\"effortLevel\": \"medium\"", with: "\"effortLevel\": \"xhigh\"")
            .replacingOccurrences(of: "\"x\": \"model\"", with: "\"x\": \"changed-elsewhere\"")
        guard case .write(let data) = decide(current) else { return XCTFail("Must rewrite the file") }
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(text, original.replacingOccurrences(of: "\"x\": \"model\"", with: "\"x\": \"changed-elsewhere\""))
    }

    let newEntry = (of: "\"claude-sonnet-5-5\": {",
                    with: "\"claude-fable-5-1\": {\n      \"effortLevel\": \"max\"\n    },\n    \"claude-sonnet-5-5\": {")

    func testRemovesNewlyAddedDefaultByRestoringOriginalBytes() {
        // Switching to a model used for the first time adds a new entry to modelSettings. If nothing else changed, restore the original bytes to remove it.
        let current = original.replacingOccurrences(of: newEntry.of, with: newEntry.with)
        XCTAssertEqual(decide(current), .write(Data(original.utf8)))
    }

    func testFailsRatherThanGuessWhenNewDefaultAppearsAlongsideOtherChanges() {
        let current = original
            .replacingOccurrences(of: newEntry.of, with: newEntry.with)
            .replacingOccurrences(of: "\"x\": \"model\"", with: "\"x\": \"changed-elsewhere\"")
        guard case .failed = decide(current) else { return XCTFail("Does not guess by deleting, line by line, an entry that was not there") }
    }

    func testRestoreWritesFileAndKeepsPermissions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("slashcommand-settings-\(UUID().uuidString).json")
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

final class ConfigTests: KoreanMessagesTestCase {
    func testDecodeAppliesDefaults() throws {
        let json = #"{"slots":[{"name":"a","claude":{"model":"opus","effort":"high"}}]}"#
        let config = try JSONDecoder().decode(SlashCommandConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.keepDefaults)
        XCTAssertEqual(config.modifiers, ["option", "shift"])
        XCTAssertEqual(config.modifierSymbols, "⌥⇧")
        XCTAssertEqual(config.slots[0].preset(for: .claude), AgentPreset(model: "opus", effort: "high"))
        XCTAssertNil(config.slots[0].preset(for: .codex))
    }

    func testStoreCreatesStarterAndRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("slashcommand-\(UUID().uuidString)/presets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ConfigStore(url: url)
        XCTAssertEqual(try store.load(), .starter)
        var edited = SlashCommandConfig.starter
        edited.slots.removeLast()
        try store.save(edited)
        XCTAssertEqual(try store.load(), edited)
    }

    func testAdoptsNearestLegacyPresetsOnlyWhenMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slashcommand-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("new/presets.json")
        let modelswitch = root.appendingPathComponent("modelswitch/presets.json")
        let gear = root.appendingPathComponent("gear/presets.json")
        var older = SlashCommandConfig.starter
        older.slots.removeLast()
        try ConfigStore(url: gear).save(older)

        // If there is no file with the nearest name, take the next one.
        try ConfigStore.adoptLegacy(into: url, from: [modelswitch, gear])
        XCTAssertEqual(try ConfigStore(url: url).load(), older)

        // If one already exists, do not overwrite it.
        try ConfigStore(url: modelswitch).save(.starter)
        try ConfigStore.adoptLegacy(into: url, from: [modelswitch, gear])
        XCTAssertEqual(try ConfigStore(url: url).load(), older)

        // If both exist, the nearest name wins and the old file stays.
        try FileManager.default.removeItem(at: url)
        try ConfigStore.adoptLegacy(into: url, from: [modelswitch, gear])
        XCTAssertEqual(try ConfigStore(url: url).load(), .starter)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelswitch.path))

        // If there is no old file at all, create nothing.
        let untouched = root.appendingPathComponent("none/presets.json")
        try ConfigStore.adoptLegacy(into: untouched, from: [root.appendingPathComponent("absent.json")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: untouched.path))
    }

    func testSavingThroughALinkKeepsTheLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slashcommand-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("managed/presets.json")
        let link = root.appendingPathComponent("config/presets.json")
        try ConfigStore(url: real).save(.starter)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        var edited = SlashCommandConfig.starter
        edited.slots.removeLast()
        try ConfigStore(url: link).save(edited)

        #if os(Windows)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path.replacingOccurrences(of: "/", with: "\\"), "A link must not be replaced by a regular file")
        #else
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path, "A link must not be replaced by a regular file")
        #endif
        XCTAssertEqual(try ConfigStore(url: real).load(), edited, "Must write to the file the link points to")
    }

    func testShiftAloneIsNotAUsableShortcut() throws {
        XCTAssertFalse(SlashCommandConfig.modifiersAreUsable([]))
        XCTAssertFalse(SlashCommandConfig.modifiersAreUsable(["shift"]))
        XCTAssertTrue(SlashCommandConfig.modifiersAreUsable(["option"]))
        XCTAssertTrue(SlashCommandConfig.modifiersAreUsable(["shift", "control"]))
        // If the file lists only Shift (even after filtering out unknown names), read it as the default combination — it must be possible to type `!` in a terminal.
        for written in [#"["shift"]"#, #"["hyper", "shift"]"#, "[]"] {
            let json = #"{"version": 1, "modifiers": \#(written), "slots": []}"#
            let config = try JSONDecoder().decode(SlashCommandConfig.self, from: Data(json.utf8))
            XCTAssertEqual(config.modifiers, SlashCommandConfig.defaultModifiers, written)
        }
    }

    func testMenuTitleShowsOnlyWhatTheFrontAgentWouldGet() {
        var slot = Slot(claude: AgentPreset(model: "opus", effort: "high"), codex: AgentPreset(model: "gpt-6-astra", effort: "xhigh"),
                        grok: AgentPreset(model: "grok-4.7", effort: "low"))
        XCTAssertEqual(slot.menuTitle(for: .claude), "opus · high")
        XCTAssertEqual(slot.menuTitle(for: .codex), "gpt-6-astra · xhigh")
        XCTAssertNil(slot.menuTitle(for: .cursor), "Without that agent's settings, that number does nothing")
        XCTAssertEqual(slot.menuTitle(for: nil), "Claude Code opus · high, Codex gpt-6-astra · xhigh +1")
        XCTAssertEqual(slot.agents, [.claude, .codex, .grok])
        slot.name = "밤샘"
        XCTAssertEqual(slot.menuTitle(for: .claude), "밤샘 — opus · high")
        XCTAssertEqual(slot.menuTitle(for: nil), "밤샘")
        XCTAssertEqual(Slot().summary(), loc("No agents set"))
    }

    #if os(macOS)
    func testAppleScriptIsTimeLimited() {
        let wrapped = GhosttyIO.timeLimited("tell application \"Ghostty\"\n    return 1\nend tell")
        XCTAssertTrue(wrapped.hasPrefix("with timeout of \(GhosttyIO.replySeconds) seconds\n"))
        XCTAssertTrue(wrapped.hasSuffix("\nend timeout"))
        XCTAssertLessThanOrEqual(GhosttyIO.replySeconds, 10, "The main thread would hang while waiting for an unresponsive Ghostty")
    }
    #endif

    func testSwitcherPlanErrors() throws {
        let switcher = Switcher(config: .starter, codexModels: { CodexModels(models: []) })
        XCTAssertThrowsError(try switcher.plan(slot: 0, agent: .claude))
        XCTAssertThrowsError(try switcher.plan(slot: 9, agent: .claude))
        XCTAssertThrowsError(try switcher.plan(slot: 3, agent: .codex), "Slot 3 has no codex settings")
        XCTAssertEqual(try switcher.plan(slot: 1, agent: .claude).preset, AgentPreset(model: "opus", effort: "high"))
    }
}

final class GhosttyEscapeTests: KoreanMessagesTestCase {
    #if os(macOS)
    func testEscapesControlBytesOnly() {
        XCTAssertEqual(GhosttyIO.actionEscaped("/model opus"), "/model opus")
        XCTAssertEqual(GhosttyIO.actionEscaped("\u{13}"), "\\x13")
        XCTAssertEqual(GhosttyIO.actionEscaped("\u{1B}[A"), "\\x1b[A")
        XCTAssertEqual(GhosttyIO.actionEscaped("a\\b"), "a\\\\b")
        XCTAssertEqual(GhosttyIO.quoted("say \"hi\" \\x13"), "\"say \\\"hi\\\" \\\\x13\"")
    }
    #endif

    func testAgentFromTitle() {
        XCTAssertEqual(Detector.agent(inTitle: "claude"), .claude)
        XCTAssertEqual(Detector.agent(inTitle: "✳ Codex — repo"), .codex)
        XCTAssertNil(Detector.agent(inTitle: "zsh"))
        XCTAssertNil(Detector.agent(inTitle: "claude vs codex"))
        // When neither the title nor the folder can tell, tell by the input box visible on screen.
        let rule = String(repeating: "─", count: 12)
        XCTAssertEqual(Detector.agent(onScreen: [rule, "❯ ", rule]), .claude)
        XCTAssertEqual(Detector.agent(onScreen: ["› Ask Codex to do anything", "  GPT-6-Sol high · ~/x"]), .codex)
        XCTAssertNil(Detector.agent(onScreen: ["  Select Model and Effort", "› 1. GPT-6-Sol (current)"]), "Does not tell while a picker is open")
        XCTAssertNil(Detector.agent(onScreen: ["yohan@Mac ~ % "]))
        XCTAssertEqual(AgentProcesses.agent(forCommandLine: "/Users/x/.local/share/claude/versions/2.1.289 --model opus"), .claude)
        XCTAssertEqual(AgentProcesses.agent(forCommandLine: "/Users/x/.codex/packages/standalone/releases/0.160.0/bin/codex -m x"), .codex)
        XCTAssertNil(AgentProcesses.agent(forCommandLine: "/bin/zsh -l"))
    }
}

final class OrcaStateTests: KoreanMessagesTestCase {
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
        // term_d has agentIdentity null in the list — a waiting claude session really arrives like this.
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
        XCTAssertEqual(AgentProcesses.agent(orcaHandle: "term_a", psOutput: ps), .claude, "The outer claude, not the codex that claude launched")
        XCTAssertEqual(AgentProcesses.agent(orcaHandle: "term_ab", psOutput: ps), .codex)
        XCTAssertNil(AgentProcesses.agent(orcaHandle: "term_c", psOutput: ps), "Processes without a terminal are not counted")
        XCTAssertNil(AgentProcesses.agent(orcaHandle: "term_zz", psOutput: ps))
    }

    func testRejectsNonAgentBrowserTabAndUnknownWorkspace() {
        XCTAssertThrowsError(try OrcaState.target(in: payload(), active: .init(worktreeID: "r2::/w/update-2", tabID: "t3")), "Shell terminal")
        XCTAssertThrowsError(try OrcaState.target(in: payload(), active: .init(worktreeID: "r2::/w/update-2", tabID: "browser-tab")))
        XCTAssertThrowsError(try OrcaState.target(in: payload(), active: .init(worktreeID: "r9::/w/none", tabID: "t1")))
    }
}

/// Fakes claude. The screen is drawn in the same form as received from claude 2.1.289 on 2026-10-06.
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
    /// Conversation lines. When idle, a command remains as `❯ /model …` with `⎿ result` below it.
    var transcript: [String] = []
    /// While working, the result appears only as a notice line above the input box.
    var notice: String?
    private var command = "/model"

    private func say(_ text: String) {
        if busy { notice = text } else { transcript += ["❯ \(command)", "  ⎿  \(text)"] }
    }
    var sent: [String] = []
    /// When true, discards all incoming characters (a situation where input does not reach this session).
    var ignoresInput = false
    /// Asks once more when changing the model mid-conversation ("Switch model?").
    var asksBeforeSwitching = false
    /// Also asks once more when changing only effort mid-conversation ("Change effort level?").
    var asksBeforeEffortChange = false
    private var askingAboutEffort = false
    /// While working, the result appears as a notice line, not a conversation line.
    var busy = false
    /// Confirmation method: "s" (this session only) · "enter" (save as default) · "command" (/model X)
    var confirmedBy: String?
    /// File where `/model X`, `/effort Y`, and Enter confirmation write the default.
    var settings: URL?
    /// Short window: the picker shows only this many rows from the cursor row, and the rest below folds into `… +N models` (measured: 1 row at 90×14).
    var windowRows: Int?
    /// Shorter window: the picker is cut off down to its bottom hint line (measured: 11 rows).
    var hintCutOff = false
    /// When false, effort does not wrap from the end to the other side (measured on 2.1.296). True is how 2.1.289 behaves.
    var effortWraps = true
    /// When true and effort is `max`, two more description lines are added and push the hint line off the screen (short window, measured on 2.1.296).
    var maxNoteHidesHint = false
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
                    // Changing by command also shows the same confirmation window. Nothing is written before it is answered.
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
                // max applies to this session only and the defaults file is not rewritten (measured on 2.1.283).
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
                ("\u{1B}[C", {
                    if self.effortWraps { self.pickerEffort = (self.pickerEffort + 1) % self.efforts.count }
                    else { self.pickerEffort = min(self.efforts.count - 1, self.pickerEffort + 1) }
                }),
                ("\u{1B}[D", {
                    if self.effortWraps { self.pickerEffort = (self.pickerEffort + self.efforts.count - 1) % self.efforts.count }
                    else { self.pickerEffort = max(0, self.pickerEffort - 1) }
                }),
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
                // If the question came from the picker, return to the picker (measured on 2.1.289). If it came from a command, it just ends.
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
            var list = rows.enumerated().map { index, name in
                "   \(index == cursor ? "❯" : " ") \(index + 1).  \(name)\(name == model ? " ✔" : "")             설명"
            }
            if let windowRows {
                let start = min(cursor, max(0, rows.count - windowRows))
                let end = min(rows.count, start + windowRows)
                list = Array(list[start..<end]) + (end < rows.count ? ["      … +\(rows.count - end) models"] : [])
            }
            let level = efforts[pickerEffort]
            let effortLine = supportsEffort(rows[cursor])
                ? "   ● \(level == "xhigh" ? "xHigh" : level.capitalized) effort ←/→ to adjust"
                : "   ○ Effort not supported for \(rows[cursor])"
            return shown + ["   Select model", "   Switch between Claude models. Your pick becomes the default for new sessions."]
                + list + [effortLine]
                + (maxNoteHidesHint && level == "max" ? ["   May use excessive tokens resulting in long response times or", "   overthinking. Use sparingly for the hardest tasks."] : [])
                + (hintCutOff || (maxNoteHidesHint && level == "max") ? [] : ["   Enter to set as default · s to use this session only · Esc to cancel"])
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

final class SwitcherApplyTests: KoreanMessagesTestCase {
    let target = Target(host: .orca(handle: "term_x"), agent: .claude, label: "x")

    func config(_ model: String, _ effort: String, keepDefaults: Bool = true, accept: Bool = false) -> SlashCommandConfig {
        SlashCommandConfig(keepDefaults: keepDefaults, acceptSwitchPrompt: accept,
                          slots: [Slot(claude: AgentPreset(model: model, effort: effort))])
    }

    func switcher(_ config: SlashCommandConfig, io: TerminalIO, settings: URL) -> Switcher {
        Switcher(config: config, claudeDefaults: ClaudeDefaults(url: settings),
                 codexModels: { CodexModels(models: []) }, makeIO: { _ in io }, sleep: { _ in })
    }

    func tempSettings(_ text: String = "{\n  \"model\": \"opus\"\n}") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("slashcommand-apply-\(UUID().uuidString).json")
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
        XCTAssertEqual(claude.confirmedBy, "s", "Must not confirm in a way that also saves to the default")
        XCTAssertEqual(claude.draft, "쓰던 글")
        XCTAssertEqual(result.summary, "Sonnet 5.5 · medium")
        XCTAssertNil(result.pendingRestore, "The default was not touched, so there is nothing to restore")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{\n  \"model\": \"opus\"\n}")
    }

    func testFindsARowFoldedAwayInALowWindow() throws {
        // Measured 2026-10-11 (tmux 90×14): the picker shows only the cursor row and the rest fold into `… +9 models`.
        // Before, it reported that row as missing and took the command route (`/model X` — changes the default and restores it).
        let settings = try tempSettings()
        let claude = FakeClaude()
        claude.settings = settings
        claude.windowRows = 1
        claude.model = "Haiku 4.5"
        _ = try switcher(config("opus", "medium"), io: claude, settings: settings).apply(slot: 1, to: target)
        XCTAssertEqual(claude.model, "Opus 5.5", "The top row picked in a tall window, not the lower row (Opus 5) with the same prefix")
        XCTAssertEqual(claude.effort, "medium")
        XCTAssertEqual(claude.confirmedBy, "s", "Confirmed with 'this session only' in the picker — not the command route")
        // A row below the current model, and starting from the bottom row (there is no marker that the top is folded).
        _ = try switcher(config("haiku", "high"), io: claude, settings: settings).apply(slot: 1, to: target)
        XCTAssertEqual(claude.model, "Haiku 4.5")
        claude.model = "Opus 5"
        _ = try switcher(config("fable", "high"), io: claude, settings: settings).apply(slot: 1, to: target)
        XCTAssertEqual(claude.model, "Fable 5.1")
        XCTAssertEqual(claude.confirmedBy, "s")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{\n  \"model\": \"opus\"\n}", "The defaults file was never written")
        XCTAssertFalse(claude.sent.contains { $0.hasPrefix("/model ") || $0.contains("/model sonnet") })
    }

    func testClosesAPickerWhoseHintRowIsCutOff() throws {
        // Measured 2026-10-12 (11-row tmux window): the hint line was cut so the picker was not recognized, and it ended saying it did not open, with the picker left open.
        let settings = try tempSettings()
        let claude = FakeClaude()
        claude.settings = settings
        claude.windowRows = 1
        claude.hintCutOff = true
        XCTAssertThrowsError(try switcher(config("opus", "medium"), io: claude, settings: settings).stepEffort(up: false, on: target)) { error in
            XCTAssertEqual((error as? SlashCommandError)?.message,
                           loc("Nothing was changed: the window is too low to show the whole model picker. Make it taller, then press again."))
        }
        XCTAssertTrue(Readiness.claudePromptVisible(claude.screen() ?? []), "Closed the picker and returned to the input box")
        XCTAssertEqual(claude.effort, "high", "Nothing changed")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{\n  \"model\": \"opus\"\n}")
    }

    func testEffortWrapsAroundToReachALowerLevel() throws {
        let claude = FakeClaude()
        claude.effort = "max"
        _ = try switcher(config("opus", "low"), io: claude, settings: tempSettings()).apply(slot: 1, to: target)
        XCTAssertEqual(claude.effort, "low")
        XCTAssertEqual(claude.model, "Opus 5.5")
    }

    /// Measured 2026-10-13 (claude 2.1.296): the effort line does not wrap at the end. In a session at `xhigh`, pressing the `high` preset pressed only → and stopped
    /// at `max`, ending with "could not match effort".
    func testReachesALowerLevelWhereTheEffortDoesNotWrap() throws {
        for (start, wanted) in [("xhigh", "high"), ("max", "low"), ("low", "max"), ("medium", "xhigh")] {
            let claude = FakeClaude()
            claude.effortWraps = false
            claude.effort = start
            _ = try switcher(config("opus", wanted), io: claude, settings: tempSettings()).apply(slot: 1, to: target)
            XCTAssertEqual(claude.effort, wanted, "\(start) → \(wanted)")
            XCTAssertEqual(claude.confirmedBy, "s")
            let arrows = claude.sent.filter { $0 == "\u{1B}[C" || $0 == "\u{1B}[D" }
            let order = Picker.claudeEffortOrder
            XCTAssertEqual(arrows.count, abs(order.firstIndex(of: start)! - order.firstIndex(of: wanted)!), "Only toward where it needs to go, exactly that many: \(arrows)")
        }
    }

    /// If the picker lacks that step: go to both ends, close the picker, and move on to the command route (`/model` · `/effort`) — do not press endlessly.
    func testALevelThePickerDoesNotOfferFallsBackToTheCommands() throws {
        for wraps in [true, false] {
            let claude = FakeClaude()
            claude.effortWraps = wraps
            claude.efforts = ["low", "medium", "high"]
            _ = try switcher(config("opus", "max"), io: claude, settings: tempSettings()).apply(slot: 1, to: target)
            XCTAssertEqual(claude.stage, .prompt, "Closes the picker and leaves (wraps=\(wraps))")
            XCTAssertEqual(claude.confirmedBy, "command", "Did not confirm in the picker (wraps=\(wraps))")
            let arrows = claude.sent.filter { $0 == "\u{1B}[C" || $0 == "\u{1B}[D" }
            XCTAssertLessThanOrEqual(arrows.count, 16, "Up to eight on one side: \(arrows.count)")
        }
    }

    /// In a short window, when effort reaches `max`, two description lines are added and push the hint line off the screen. Quitting in that state must also close the picker
    /// (measured 2026-10-13: in a 16-row window the picker stayed open and the following presses were rejected with "input box not visible").
    func testClosesAPickerWhoseHintRowWasPushedOutWhileSettingTheEffort() throws {
        let claude = FakeClaude()
        claude.effortWraps = false
        claude.maxNoteHidesHint = true
        claude.efforts = ["medium", "high", "xhigh", "max"]   // the picker has no low
        claude.effort = "xhigh"
        // It is not there even at the left end (medium), so try the right end (max) — the hint line disappears there and it gives up.
        _ = try switcher(config("opus", "low"), io: claude, settings: tempSettings()).apply(slot: 1, to: target)
        XCTAssertTrue(claude.sent.contains("\u{1B}[C"), "Tried up to the right end")
        XCTAssertEqual(claude.stage, .prompt, "Closes the picker and leaves even if the hint line is not visible")
        XCTAssertEqual(claude.confirmedBy, "command", "Moved on to the command route after closing")
    }

    func testFullModelIDPicksThatVersionNotTheNewest() throws {
        let claude = FakeClaude()
        _ = try switcher(config("claude-opus-5", "high"), io: claude, settings: tempSettings()).apply(slot: 1, to: target)
        XCTAssertEqual(claude.model, "Opus 5", "Not Opus 5.5")
    }

    func testModelWithoutEffortStillSwitches() throws {
        let claude = FakeClaude()
        let result = try switcher(config("haiku", "high"), io: claude, settings: tempSettings()).apply(slot: 1, to: target)
        XCTAssertEqual(claude.model, "Haiku 4.5")
        XCTAssertEqual(result.summary, "Haiku 4.5", "An effort that was not applied is not used in the notice")
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
            XCTAssertEqual(($0 as? SlashCommandError)?.awaitingUser, true)
            XCTAssertTrue("\($0)".contains("Sonnet 5.5"))
        }
        XCTAssertEqual(claude.stage, .confirm, "Leaves the confirmation window as is")
        XCTAssertEqual(claude.sent.last, "s", "Nothing was sent to the confirmation window")
        XCTAssertEqual(claude.model, "Opus 5.5")
    }

    func testFinishesAfterTheUserConfirmsThemselves() throws {
        let claude = FakeClaude()
        claude.asksBeforeSwitching = true
        claude.draft = "쓰던 글"
        var switcher = switcher(config("sonnet", "medium"), io: claude, settings: try tempSettings())
        var asked: [String] = []
        // The user who saw the notice presses Enter.
        switcher.onAwaitingUser = { model in asked.append(model); try? claude.type("\r") }
        let result = try switcher.apply(slot: 1, to: target)
        XCTAssertEqual(asked, ["Sonnet 5.5"])
        XCTAssertEqual(claude.model, "Sonnet 5.5")
        XCTAssertEqual(result.summary, "Sonnet 5.5 · medium", "Reports the result after the user's choice")
        XCTAssertEqual(claude.draft, "쓰던 글")
    }

    func testReportsThatNothingChangedWhenTheUserSaysNo() throws {
        let claude = FakeClaude()
        claude.asksBeforeSwitching = true
        var switcher = switcher(config("sonnet", "medium"), io: claude, settings: try tempSettings())
        switcher.onAwaitingUser = { _ in try? claude.type("2") }
        XCTAssertThrowsError(try switcher.apply(slot: 1, to: target)) {
            XCTAssertEqual(($0 as? SlashCommandError)?.nothingToDo, true, "\($0)")
        }
        XCTAssertEqual(claude.model, "Opus 5.5")
        XCTAssertEqual(claude.stage, .prompt, "Closes the picker that was returned to")
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
        // If the cursor is on No, it is not treated as that window.
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
        // A model unknown to the picker list but known to the `/model` command (imitates an old model pushed below the list).
        let hidden = "Opus 4.7"
        claude.rows.removeAll { $0 == hidden }
        let io = HidingRows(claude: claude, hidden: hidden)
        let result = try switcher(config("opus 4.7", "high"), io: io, settings: settings).apply(slot: 1, to: target)
        XCTAssertEqual(claude.model, hidden)
        XCTAssertEqual(claude.confirmedBy, "command")
        XCTAssertEqual(claude.draft, "쓰던 글")
        XCTAssertEqual(result.summary, "Opus 4.7 · high")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original, "The command changes the default, so it is restored")
        XCTAssertEqual(claude.sent.filter { $0 == "\u{1B}" }.count, 1, "The picker closes with a single Esc")
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
        // The notice line while working arrives truncated.
        XCTAssertEqual(summary(["Set model to Opus 5.5 and", "Set effort level to high (saved as your default for new sessions): Compre"]),
                       "Opus 5.5 · high")
        XCTAssertEqual(summary(["Set model to Opus 5.5 and saved as your default for new sessions"]), "Opus 5.5 · xhigh")
        XCTAssertEqual(summary(["Effort not supported for Haiku 4.5", "Set model to Haiku 4.5 for this session only"]), "Haiku 4.5")
        XCTAssertEqual(summary(["Set model to Opus 5.5 for this session only"]), "Opus 5.5 · xhigh", "If effort is unchanged claude does not mention it")
        XCTAssertEqual(summary(["Kept model as Opus 5.5"]), "Opus 5.5 · xhigh")
        XCTAssertEqual(summary(["Model changed to gpt-6.1-sol max for this session only"]), "gpt-6.1-sol · max")
        XCTAssertEqual(summary([]), "opus · xhigh", "Without confirmation text, the preset value")
    }
}

final class EffortStepTests: KoreanMessagesTestCase {
    let target = Target(host: .orca(handle: "term_x"), agent: .claude, label: "x")

    func switcher(io: TerminalIO, keepDefaults: Bool = true, accept: Bool = false) -> Switcher {
        Switcher(config: SlashCommandConfig(keepDefaults: keepDefaults, acceptSwitchPrompt: accept, slots: []),
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
        XCTAssertEqual(claude.model, "Fable 5.1", "Model unchanged")
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
        XCTAssertEqual(asked, ["xhigh"], "The user chooses in the 'Change effort level?' window")
        XCTAssertEqual(claude.effort, "xhigh")
        XCTAssertEqual(result.summary, "Opus 5.5 · xhigh")
    }

    func testClaudeEffortConfirmationIsAcceptedOnlyForTheLevelWeMovedTo() throws {
        let claude = FakeClaude()
        claude.asksBeforeEffortChange = true
        let accepting = Switcher(config: SlashCommandConfig(acceptSwitchPrompt: true, slots: []),
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
                XCTAssertEqual(($0 as? SlashCommandError)?.nothingToDo, true, "\($0)")
            }
            XCTAssertEqual(claude.effort, start, "Pressing at the end wraps to the other end — do not press")
            XCTAssertNil(claude.confirmedBy)
            XCTAssertEqual(claude.stage, .prompt, "Closes the picker and leaves")
        }
    }

    func testClaudeStopsWhereAModelHasFewerLevels() {
        let claude = FakeClaude()
        claude.efforts = ["low", "medium", "high"]   // This model has no xhigh or max
        claude.effort = "high"
        XCTAssertThrowsError(try switcher(io: claude).stepEffort(up: true, on: target)) {
            XCTAssertEqual(($0 as? SlashCommandError)?.nothingToDo, true)
        }
        XCTAssertEqual(claude.effort, "high")
        XCTAssertNil(claude.confirmedBy, "Must not confirm after moving over to low")
    }

    func testClaudeLeavesAModelThatIsNotInThePickerAlone() {
        let claude = FakeClaude()
        claude.model = "Custom Model"   // A model not in the list — the cursor is on another row
        XCTAssertThrowsError(try switcher(io: claude).stepEffort(up: true, on: target))
        XCTAssertNil(claude.confirmedBy, "Confirming here would change the model to the cursor row")
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
            XCTAssertEqual(($0 as? SlashCommandError)?.nothingToDo, true, "\($0)")
        }
        XCTAssertEqual(picker.stage, .composer, "At the end, closes the picker and leaves")
        seen = []
        for _ in 0..<5 {
            _ = try switcher(io: picker).stepEffort(up: false, on: codex)
            seen.append(picker.current)
        }
        XCTAssertEqual(seen, ["max", "extra high", "high", "medium", "low"])
        XCTAssertThrowsError(try switcher(io: picker).stepEffort(up: false, on: codex)) {
            XCTAssertEqual(($0 as? SlashCommandError)?.nothingToDo, true)
        }
        XCTAssertEqual(picker.current, "low")
    }

    func testCodexStopsAtTheLastRowOfAModelWithoutMoreReasoning() {
        let picker = FakePicker()
        picker.advanced = []
        picker.current = "extra high"
        XCTAssertThrowsError(try switcher(io: picker).stepEffort(up: true, on: codex)) {
            XCTAssertEqual(($0 as? SlashCommandError)?.nothingToDo, true)
        }
        XCTAssertNil(picker.confirmedBy)
    }

    func testCodexNeverConfirmsWithANumberOrEnter() throws {
        let picker = FakePicker()
        picker.current = "extra high"
        _ = try switcher(io: picker).stepEffort(up: true, on: codex)   // the Enter that enters More reasoning… is not a confirmation
        XCTAssertEqual(picker.current, "max")
        XCTAssertEqual(picker.confirmedBy, "s")
    }
}

final class LaggingTerminalTests: KoreanMessagesTestCase {
    let target = Target(host: .ghostty(terminalID: "T"), agent: .claude, label: "x")

    /// Puts claude on a terminal (Ghostty) whose screen follows 0.5 seconds late. Time is advanced by `sleep`.
    func setUp(_ claude: FakeClaude, settings: URL, accept: Bool = false) -> (Switcher, LaggingIO) {
        var clock = 0
        let io = LaggingIO(base: claude, lagMs: 500)
        io.now = { clock }
        let config = SlashCommandConfig(acceptSwitchPrompt: accept, slots: [Slot(claude: AgentPreset(model: "sonnet", effort: "medium"))])
        let switcher = Switcher(config: config, claudeDefaults: ClaudeDefaults(url: settings),
                                codexModels: { CodexModels(models: []) }, makeIO: { _ in io }, sleep: { clock += $0 })
        return (switcher, io)
    }

    func tempSettings() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("slashcommand-lag-\(UUID().uuidString).json")
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
        XCTAssertEqual(claude.confirmedBy, "command", "The picker takes 0.5 s per step, so it is not used")
        XCTAssertEqual(claude.sent, ["\u{13}/model sonnet\r", "\u{13}/effort medium\r"])
        XCTAssertEqual(claude.draft, "쓰던 글")
        XCTAssertEqual(result.summary, "Sonnet 5.5 · medium", "After finishing, reads claude's words from the new screen")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{\n  \"model\": \"opus\"\n}", "The default is restored")
    }

    func testAcceptsAResultThatDidNotTouchTheSettingsFile() throws {
        let settings = try tempSettings()
        let claude = FakeClaude()
        claude.settings = settings
        var clock = 0
        let io = LaggingIO(base: claude, lagMs: 500)
        io.now = { clock }
        let config = SlashCommandConfig(slots: [Slot(claude: AgentPreset(model: "fable", effort: "max"))])
        let switcher = Switcher(config: config, claudeDefaults: ClaudeDefaults(url: settings),
                                codexModels: { CodexModels(models: []) }, makeIO: { _ in io }, sleep: { clock += $0 })
        let result = try switcher.apply(slot: 1, to: target)
        XCTAssertEqual(claude.effort, "max")
        XCTAssertEqual(result.summary, "Fable 5.1 · max", "/effort max does not write the file — confirmed by the new result line on screen")
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
        XCTAssertEqual(claude.sent, ["\u{13}/model sonnet\r"], "If rejected, the next command is not sent")
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
        XCTAssertEqual(claude.effort, "medium", "After the user confirms, effort is matched as well")
        XCTAssertEqual(result.summary, "Sonnet 5.5 · medium")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{\n  \"model\": \"opus\"\n}", "The default written after confirmation is also restored")
    }

    func testStopsWhenTheUserDeclinesAndSendsNothingMore() throws {
        let settings = try tempSettings()
        let claude = FakeClaude()
        claude.settings = settings
        claude.asksBeforeSwitching = true
        var (switcher, _) = setUp(claude, settings: settings)
        switcher.onAwaitingUser = { _ in try? claude.type("2") }
        XCTAssertThrowsError(try switcher.apply(slot: 1, to: target)) {
            XCTAssertEqual(($0 as? SlashCommandError)?.nothingToDo, true, "\($0)")
        }
        XCTAssertEqual(claude.model, "Opus 5.5")
        XCTAssertEqual(claude.sent.filter { $0.contains("/effort") }, [], "Did not change the model, so effort alone is not changed")
    }

    /// Claim check from review: that settings file is also written by other claude sessions. Our command did not run, so
    /// it must not count as success just because someone else touched the file.
    func testAnotherSessionWritingTheSettingsFileIsNotOurSuccess() throws {
        let settings = try tempSettings()
        let claude = FakeClaude()
        claude.settings = settings
        claude.ignoresInput = true      // Our command is not accepted (for example, input went elsewhere)
        var clock = 0
        let io = LaggingIO(base: claude, lagMs: 500)
        io.now = { clock }
        var touches = 0
        let config = SlashCommandConfig(slots: [Slot(claude: AgentPreset(model: "sonnet", effort: "medium"))])
        let switcher = Switcher(config: config, claudeDefaults: ClaudeDefaults(url: settings),
                                codexModels: { CodexModels(models: []) }, makeIO: { _ in io },
                                sleep: { ms in
                                    clock += ms
                                    // Another session rewrites the same file (the content is that session's).
                                    touches += 1
                                    try? Data("{\n  \"model\": \"fable\"\n}".utf8).write(to: settings)
                                    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000_000 + Double(touches))],
                                                                           ofItemAtPath: settings.path)
                                })
        XCTAssertThrowsError(try switcher.apply(slot: 1, to: target), "Read a file written by someone else as our command's success")
        XCTAssertEqual(claude.model, "Opus 5.5")
    }

    func testRepeatingTheSameSwitchIsStillConfirmedByTheEchoedCommand() throws {
        let settings = try tempSettings()
        let claude = FakeClaude()
        claude.settings = settings
        let (switcher, _) = setUp(claude, settings: settings)
        // The same switch many times — the screen (last 6 lines) is full of identical lines, so the line count cannot tell a new result.
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
        _ = io.snapshot()               // A screen showing the input box is kept
        claude.stage = .picker          // Right after, the picker opened (the kept screen still shows the input box)
        XCTAssertThrowsError(try switcher.apply(slot: 1, to: target))
        XCTAssertEqual(claude.sent, [], "Trusting a stale screen and sending Enter to the picker would save that row as the default")
    }
}

/// Builds a model that is not in the picker list but can be chosen with the `/model` command.
final class HidingRows: TerminalIO {
    let claude: FakeClaude
    let hidden: String
    init(claude: FakeClaude, hidden: String) { self.claude = claude; self.hidden = hidden }

    func type(_ text: String) throws {
        // Makes the model known only when it arrives by command.
        if text.contains("/model \(hidden.lowercased())") { claude.rows.append(hidden) }
        try claude.type(text)
    }
    func press(_ key: Key) throws { try type(key.bytes) }
    func screen() -> [String]? { claude.screen() }
    func snapshot() -> ScreenSnapshot? { claude.snapshot() }
}

/// Claim check from review: when the conversation contains text that looks like a picker or input box.
/// The sample is a real claude 2.1.291 screen from 2026-10-06 — the reply contains picker-shaped text, and a real permission prompt is open below it.
final class SpoofedScreenTests: KoreanMessagesTestCase {
    struct Fixture: Decodable { let tail: [String] }

    func screen(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tail
    }

    func testTextThatLooksLikeAPickerIsNotAPicker() throws {
        let lines = try screen("claude-permission-fake-picker")
        XCTAssertTrue(lines.contains { $0.contains("Select model") }, "The sample must contain the fake picker text")
        XCTAssertFalse(Readiness.claudePromptVisible(lines), "A permission prompt is open")
        XCTAssertEqual(Picker.rows(lines), [], "Reading text in the conversation as a picker would see its rows and send arrows and s")
        XCTAssertFalse(Picker.isOpen(lines))
    }
}

final class AnchoredPickerTests: KoreanMessagesTestCase {
    struct Fixture: Decodable { let tail: [String] }

    func screen(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tail
    }

    /// Real screen: the conversation has fake picker text, and a real picker is open below it.
    func testReadsTheRealPickerAtTheBottomNotTheLookalikeAbove() throws {
        let open = try XCTUnwrap(Picker.open(try screen("claude-picker-below-fake-picker")))
        XCTAssertEqual(open.rows.count, 10, "2 rows for the fake, 10 for the real")
        XCTAssertEqual(open.rows.first(where: \.selected)?.label, "Sonnet 5.5", "The fake's cursor is on Opus 5.5")
        XCTAssertTrue(open.header.hasPrefix("Select model"))
        XCTAssertTrue(open.footer.contains("s to use this session only"))
    }

    /// Real screen: claude picker narrowed to 62 columns — row descriptions and the bottom hint line fold onto the next line.
    func testReadsAClaudePickerWhoseLinesWrap() throws {
        let open = try XCTUnwrap(Picker.open(try screen("claude-picker-narrow")))
        XCTAssertEqual(open.rows.map(\.number), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(open.rows.first(where: \.selected)?.label, "Sonnet 5.5")
        XCTAssertTrue(open.footer.contains("s to use this session only"), open.footer)
        XCTAssertEqual(Picker.claudeEffort(try screen("claude-picker-narrow")), "high")
    }

    /// Real screen: codex effort list narrowed to 58 columns.
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
        // Form of the real 62-column screen: earlier lines are above, and the last command's reply is folded onto the next line.
        let idle = ["❯ /model", "  ⎿  Kept model as Sonnet 5.5",
                    "❯ /model", "  ⎿  Set model to Fable 5.1 for this session only with max", "     effort",
                    "                    ◈ max · /effort", rule, "❯", rule, "  상태 줄"]
        XCTAssertEqual(ClaudeScreen.latestResult(idle, command: "/model", prefixes: prefixes),
                       "Set model to Fable 5.1 for this session only with max effort")
        // While working: notice line above the input box.
        let busy = ["❯ /model", "  ⎿  Kept model as Sonnet 5.5", "✳ Nucleating… (8s)",
                    "            Set model to Opus 5.5 for this session only with high effort", rule, "❯", rule]
        XCTAssertEqual(ClaudeScreen.latestResult(busy, command: "/model", prefixes: prefixes),
                       "Set model to Opus 5.5 for this session only with high effort")
        XCTAssertNil(ClaudeScreen.latestResult(["⏺ 대답", rule, "❯", rule], command: "/model", prefixes: prefixes))
    }

    func testPromptAndComposerMustBeAtTheBottom() {
        let rule = String(repeating: "─", count: 20)
        // An input-box-like shape remains above and something else is open below.
        let stale = [rule, "❯ ", rule] + (1...9).map { " 창의 \($0)번째 줄" }
        XCTAssertFalse(Readiness.claudePromptVisible(stale))
        XCTAssertTrue(Readiness.claudePromptVisible([rule, "❯ 첫 줄", "  둘째 줄", "  셋째 줄", rule, "  상태 줄", "  ⏵⏵ auto mode on"]), "Multi-line draft")
        // codex: the `› text I sent` from earlier conversation is not an input box.
        XCTAssertFalse(Readiness.codexComposerVisible(["› 아까 보낸 글", "• 대답", "  Would you like to run this?", "■ 번호 없는 창"]))
        XCTAssertTrue(Readiness.codexComposerVisible(["› 아까 보낸 글", "• 대답", "› ", "  GPT-6-Sol high · ~/x", "  ? for shortcuts"]))
        XCTAssertTrue(Readiness.codexComposerVisible(["› 첫 줄", "  둘째 줄", "  GPT-6-Sol high · ~/x"]), "Multi-line draft")
    }
}

final class ClaudePickerTests: KoreanMessagesTestCase {
    /// Exactly the 2026-10-06 claude 2.1.289 screen.
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

    func testKnowsWhenRowsAreFoldedAway() {
        XCTAssertTrue(Picker.hasHiddenRows(picker), "`↓ 10.` and `… +2 models`")
        let low = ["   Select model", "   Switch between Claude models. Your pick becomes the default for new sessions.",
                   "   ❯ 4.  Sonnet 5.5 ✔           Most efficient for simpler tasks", "      … +9 models",
                   "   ● High effort ←/→ to adjust", "   Enter to set as default · s to use this session only · Esc to cancel"]
        XCTAssertTrue(Picker.hasHiddenRows(low))
        // Bottom row: there is no separate marker that the top is folded — it is known because the number is not 1.
        var bottom = low
        bottom[2] = "   ❯ 13. Opus 4.6"
        bottom.remove(at: 3)
        XCTAssertTrue(Picker.hasHiddenRows(bottom))
        let whole = ["   Select model", "   ❯ 1.  Default (recommended)", "     2.  Opus 5.5 ✔", "   ● High effort ←/→ to adjust",
                     "   Enter to set as default · s to use this session only · Esc to cancel"]
        XCTAssertFalse(Picker.hasHiddenRows(whole))
        XCTAssertFalse(Picker.hasHiddenRows(["❯ ", "  … +9 models"]), "Not a picker")
    }

    func testReadsRowsCursorAndCurrentMark() {
        let rows = Picker.rows(picker)
        XCTAssertEqual(rows.map(\.label), ["Default (recommended)", "Opus 5.5", "Fable 5.1", "Sonnet 5.5", "Haiku 4.5", "Sonnet 5", "Opus 5", "Opus 4.7"])
        XCTAssertEqual(rows.map(\.number), [1, 2, 3, 4, 5, 6, 7, 10])
        XCTAssertEqual(rows.firstIndex(where: \.selected), 1)
        XCTAssertEqual(rows.firstIndex(where: \.current), 1)
    }

    func testFindsTheRowForAPresetModel() {
        let rows = Picker.rows(picker)
        XCTAssertEqual(Picker.index(of: ClaudeModels.rowLabel("opus"), in: rows), 1, "The alias is the top (newest) row")
        XCTAssertEqual(Picker.index(of: ClaudeModels.rowLabel("sonnet"), in: rows), 3, "The Sonnet 5.5 row, not the Default row")
        XCTAssertEqual(Picker.index(of: ClaudeModels.rowLabel("claude-opus-5"), in: rows), 6, "Opus 5, not Opus 5.5")
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

final class LaunchTests: KoreanMessagesTestCase {
    func testBuildsSessionOnlyFlags() {
        XCTAssertEqual(Launch.command(agent: .claude, preset: AgentPreset(model: "opus", effort: "high"), extra: ["-c"]),
                       ["claude", "--model", "opus", "--effort", "high", "-c"])
        XCTAssertEqual(Launch.command(agent: .codex, preset: AgentPreset(model: "gpt-6.1-sol", effort: "xhigh")),
                       ["codex", "-m", "gpt-6.1-sol", "-c", "model_reasoning_effort=\"xhigh\""])
    }
}

final class SlotTests: KoreanMessagesTestCase {
    func testNameIsOptionalInTheFile() throws {
        let config = try JSONDecoder().decode(SlashCommandConfig.self, from: Data(#"{"slots":[{"claude":{"model":"opus","effort":"high"}},{"name":"밤샘","codex":{"model":"gpt-x","effort":"max"}}]}"#.utf8))
        XCTAssertEqual(config.slots[0].name, "")
        XCTAssertTrue(config.effortKeys, "Items missing from an old file get the default")
        XCTAssertTrue(config.acceptSwitchPrompt, "The confirmation window is accepted by default (only when asking about a value we chose)")
        let off = try JSONDecoder().decode(SlashCommandConfig.self, from: Data(#"{"acceptSwitchPrompt":false,"slots":[]}"#.utf8))
        XCTAssertFalse(off.acceptSwitchPrompt)
        XCTAssertEqual(config.slots[0].listing, "claude opus · high")
        XCTAssertEqual(config.slots[1].listing, "codex gpt-x · max   — 밤샘")
        let saved = String(data: try JSONEncoder().encode(config.slots[0]), encoding: .utf8) ?? ""
        XCTAssertFalse(saved.contains("name"), "An empty name is not written to the file")
        XCTAssertEqual(try JSONDecoder().decode(Slot.self, from: JSONEncoder().encode(config.slots[1])), config.slots[1])
    }
}

final class AgentVersionTests: KoreanMessagesTestCase {
    func testParsesVersionOutputOfBothAgents() {
        XCTAssertEqual(AgentVersions.parse(versionOutput: "2.1.291 (Claude Code)\n"), "2.1.291")
        XCTAssertEqual(AgentVersions.parse(versionOutput: "codex-cli 0.160.1\n"), "0.160.1")
        XCTAssertNil(AgentVersions.parse(versionOutput: "command not found"), "Without three numeric parts, no version is invented")
        XCTAssertNil(AgentVersions.parse(versionOutput: "1.2 beta"))
        XCTAssertEqual(AgentVersions.parse(versionOutput: "2026.10.01-14929f9\n"), "2026.10.01-14929f9", "cursor-agent")
    }

    func testReadsVersionFromInstallPath() {
        XCTAssertEqual(AgentVersions.version(inCommandLine: "/Users/x/.local/share/claude/versions/2.1.289 --model opus"), "2.1.289")
        XCTAssertEqual(AgentVersions.version(inCommandLine: "/Users/x/.codex/packages/standalone/releases/0.160.0/bin/codex -m x"), "0.160.0")
        XCTAssertEqual(AgentVersions.version(inCommandLine: "/Users/x/.codex/packages/standalone/releases/0.160.1-aarch64-apple-darwin/bin/codex"), "0.160.1")
        XCTAssertNil(AgentVersions.version(inCommandLine: "/Users/x/.codex/packages/standalone/releases/latest/bin/codex"))
        // The form installed with Homebrew (measured 2026-10-11: cursor-cli is a cask, opencode a formula).
        XCTAssertEqual(AgentVersions.version(inCommandLine: "/opt/homebrew/Caskroom/cursor-cli/2026.10.01-e373342/dist-package/node"), "2026.10.01-e373342")
        XCTAssertEqual(AgentVersions.version(inCommandLine: "/opt/homebrew/Cellar/opencode/2.0.25/bin/opencode"), "2.0.25")
        XCTAssertNil(AgentVersions.version(inCommandLine: "/opt/homebrew/Cellar/node/26.8.2/bin/node /x/agent.js"), "The launcher's version is not read as the agent's version")
        XCTAssertNil(AgentVersions.version(inCommandLine: "/opt/homebrew/Cellar/node@22/22.1.0/bin/node /x/agent.js"))
        XCTAssertNil(AgentVersions.version(inCommandLine: "/opt/homebrew/bin/cursor-agent --use-system-ca"), "A path without a version")
        XCTAssertEqual(AgentVersions.version(inCommandLine: "/Users/x/.codex/packages/standalone/releases/0.160.0-alpha.6-aarch64-apple-darwin/bin/codex"), "0.160.0-alpha.6")
        let prerelease = AgentVersions.Report(agent: .codex, installed: "0.160.0", running: ["0.160.0-alpha.6"])
        XCTAssertEqual(prerelease.untested, ["0.160.0-alpha.6"], "A prerelease is not a confirmed stable version")
        XCTAssertNil(AgentVersions.version(inCommandLine: "/opt/homebrew/bin/codex -m x"), "If the path has no version, say unknown")
    }

    func testFlagsVersionsWeNeverSaw() {
        let seen = AgentVersions.Report(agent: .claude, installed: "2.1.289", running: ["2.1.283"])
        XCTAssertEqual(seen.untested, [])
        let newer = AgentVersions.Report(agent: .claude, installed: "2.1.999", running: ["2.1.289"])
        XCTAssertEqual(newer.untested, ["2.1.999"], "Positive control: an unverified version must be caught")
        XCTAssertTrue(newer.lines.contains { $0.contains("2.1.999") && $0.contains("확인 못 한 판") })
        let unknown = AgentVersions.Report(agent: .codex, installed: nil, running: [])
        XCTAssertEqual(unknown.untested, [], "Not being able to read the installed version differs from an unverified version")
        XCTAssertFalse(unknown.lines.contains { $0.contains("확인한 판입니다") }, "Without evidence, it does not say verified")
        XCTAssertTrue(unknown.lines.contains { $0.contains("판을 읽지 못한 것") })
        let hidden = AgentVersions.Report(agent: .claude, installed: "2.1.289", running: ["알 수 없음"])
        XCTAssertFalse(hidden.lines.contains { $0.contains("확인한 판입니다") }, "Even if the installed version is verified, without the running session's version it does not say verified")
        XCTAssertTrue(hidden.lines.contains { $0.contains("실행 중인 claude 일부") })
        let clean = AgentVersions.Report(agent: .claude, installed: "2.1.289", running: ["2.1.288"])
        XCTAssertTrue(clean.lines.contains { $0.contains("확인한 판입니다") }, "Positive control: if everything was read and verified, it says so")
    }
}

final class OrcaViewTests: KoreanMessagesTestCase {
    private func layout(_ worktree: String, _ titles: [String]) -> [String: Any] {
        ["worktreeId": worktree, "root": ["tabs": titles.enumerated().map { ["tabId": "\(worktree)-t\($0.offset)", "title": $0.element] as [String: Any] }]]
    }

    private func strip(_ titles: [String], active: Int, truncated: Set<Int> = []) -> OrcaView.Strip {
        OrcaView.Strip(tabs: titles.enumerated().map { .init(title: $0.element, truncated: truncated.contains($0.offset), active: $0.offset == active) })
    }

    // Tab strip from a Mac screen on 2026-10-07 (this workspace).
    private let initialTitles = ["이 repo 루트의 HANDOFF-2026-10-06-", "Terminal 2", "initial", "<local-command-caveat>The comm", "OpenCode", "grok", "Terminal 7", "Cursor Agent"]
    private let shownTitles = ["이 repo 루트의 HANDOFF 2026 10 06", "Terminal 2", "initial", "<local-command-caveat>The", "OpenCode", "grok", "Terminal 7", "Cursor Agent"]

    func testReadsTabButtonLabelAndActiveClass() {
        let active = OrcaView.tab(fromLabel: "Working 이 repo 루트의 HANDOFF 2026 10 06 Close tab 이 repo 루트의 HANDOFF 2026 10 06",
                                  classes: ["group", "bg-[color-mix(in_srgb,var(--foreground)_6%,var(--card))]", "text-foreground"])
        XCTAssertEqual(active, .init(title: "이 repo 루트의 HANDOFF 2026 10 06", truncated: false, active: true))
        let inactive = OrcaView.tab(fromLabel: "grok Close tab grok", classes: ["group", "bg-card", "text-muted-foreground", "hover:text-foreground"])
        XCTAssertEqual(inactive?.active, false, "hover:text-foreground is not an active marker")
        let truncated = OrcaView.tab(fromLabel: "Done <local-command-caveat>The command... Close tab <local-command-caveat>The command...", classes: [])
        XCTAssertEqual(truncated?.title, "<local-command-caveat>The command")
        XCTAssertEqual(truncated?.truncated, true)
        XCTAssertNil(OrcaView.tab(fromLabel: "Tasks", classes: ["text-foreground"]), "Not a tab button")
    }

    func testResolvesTheVisibleTabWhileTheDatabaseStillSaysTheOldOne() {
        let layouts = [layout("w-other", ["Terminal 2", "Terminal 3"]), layout("w-initial", initialTitles)]
        for index in 0..<initialTitles.count {
            let result = OrcaView.resolve(strip: strip(shownTitles, active: index, truncated: [3]), layouts: layouts)
            XCTAssertEqual(result, .tab(.init(worktreeID: "w-initial", tabID: "w-initial-t\(index)")), "Tab \(index)")
        }
    }

    func testNoMatchWhenTheStripHasTabsTheLayoutDoesNot() {
        // If non-terminal tabs such as file tabs are mixed in, the counts differ and it does not match (the caller falls back to the DB).
        let layouts = [layout("w-initial", initialTitles)]
        XCTAssertEqual(OrcaView.resolve(strip: strip(shownTitles + ["README.md"], active: 8), layouts: layouts), .noMatch)
        XCTAssertEqual(OrcaView.resolve(strip: strip(["a", "b"], active: 0), layouts: layouts), .noMatch)
    }

    func testIdenticalStripsInTwoWorkspacesAreAlwaysAmbiguous() {
        let layouts = [layout("w1", ["Terminal 2"]), layout("w2", ["Terminal 2"])]
        let one = strip(["Terminal 2"], active: 0)
        XCTAssertEqual(OrcaView.resolve(strip: one, layouts: layouts), .ambiguous(["w1", "w2"]))
        // Positive control: if even one tab title differs, it is determined.
        XCTAssertEqual(OrcaView.resolve(strip: one, layouts: [layout("w1", ["Terminal 2"]), layout("w2", ["Terminal 3"])]),
                       .tab(.init(worktreeID: "w1", tabID: "w1-t0")))
    }

    func testNeedsExactlyOneActiveTab() {
        let layouts = [layout("w", ["a", "b"])]
        let none = OrcaView.Strip(tabs: [.init(title: "a", truncated: false, active: false), .init(title: "b", truncated: false, active: false)])
        let both = OrcaView.Strip(tabs: [.init(title: "a", truncated: false, active: true), .init(title: "b", truncated: false, active: true)])
        XCTAssertEqual(OrcaView.resolve(strip: none, layouts: layouts), .noMatch)
        XCTAssertEqual(OrcaView.resolve(strip: both, layouts: layouts), .noMatch)
    }

    func testLongTitleCutWithoutEllipsisStillMatchesButShortOnesNeedToBeExact() {
        let layouts = [layout("w", ["이 repo 루트의 HANDOFF-2026-10-06-modelswitch.md 를 먼저 끝까지 읽고 이어서 진행해줘", "initial"])]
        let cut = OrcaView.Strip(tabs: [.init(title: "이 repo 루트의 HANDOFF 2026 10 06", truncated: false, active: true), .init(title: "initial", truncated: false, active: false)])
        XCTAssertEqual(OrcaView.resolve(strip: cut, layouts: layouts), .tab(.init(worktreeID: "w", tabID: "w-t0")))
        let shortCut = OrcaView.Strip(tabs: [.init(title: "이 repo 루트의 HANDOFF 2026 10 06", truncated: false, active: true), .init(title: "init", truncated: false, active: false)])
        XCTAssertEqual(OrcaView.resolve(strip: shortCut, layouts: layouts), .noMatch, "A short title does not accept a prefix match")
    }

    func testTruncatedTitleOnlyMatchesAsAPrefix() {
        let layouts = [layout("w", ["긴 제목입니다 정말로 길어서 잘렸어요"])]
        XCTAssertEqual(OrcaView.resolve(strip: strip(["긴 제목입니다"], active: 0, truncated: [0]), layouts: layouts), .tab(.init(worktreeID: "w", tabID: "w-t0")))
        XCTAssertEqual(OrcaView.resolve(strip: strip(["긴 제목입니다"], active: 0), layouts: layouts), .noMatch, "A title that is not truncated must match exactly")
    }
}

// MARK: - grok

/// Real grok 1.0.46 screen (2026-10-07) and samples of the model list and settings.
final class GrokScreenTests: KoreanMessagesTestCase {
    struct Fixture: Decodable { let tail: [String] }

    func screen(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tail
    }

    func testIdleBoxIsReadyAndHasTheLabel() throws {
        let lines = try screen("grok-idle")
        let box = try XCTUnwrap(GrokScreen.box(lines))
        XCTAssertEqual(box.input, "")
        XCTAssertEqual(box.label, "Grok 4.7 (xhigh)")
        XCTAssertTrue(GrokScreen.idle(lines))
        XCTAssertEqual(GrokScreen.draft(lines), "")
    }

    func testWorkingScreenIsNotIdleEvenThoughTheBoxLooksEmpty() throws {
        // Real screen: grok is working right after the question was sent. The input box looks empty and only the hint line differs, with `Ctrl+c:cancel`.
        let working = try screen("grok-working")
        XCTAssertEqual(GrokScreen.draft(working), "")
        XCTAssertFalse(GrokScreen.idle(working), "Typing /model while working goes into the queue or mixes with the work")
        XCTAssertTrue(GrokScreen.idle(try screen("grok-after-work")), "Positive control: idle after finishing")
    }

    func testDraftIsSeenAndBlocksSending() throws {
        let lines = try screen("grok-draft")
        XCTAssertEqual(GrokScreen.draft(lines), "abc draft")
        XCTAssertFalse(GrokScreen.idle(lines), "With draft text it would mix with the command")
    }

    func testOpenPickerAndLeftoverCommandAreNotIdle() throws {
        XCTAssertFalse(GrokScreen.idle(try screen("grok-picker")), "A picker is open")
        let after = try screen("grok-after-esc")
        XCTAssertEqual(GrokScreen.draft(after), "/model", "Text remains in the input box even after closing with Esc (measured)")
        XCTAssertFalse(GrokScreen.idle(after))
    }

    // 1.0.50 (2026-10-12): a just-opened session has only a channel tag where the hint line goes, and the permission mode is attached after the label.
    func testFirstScreenOfANewSessionIsReady() throws {
        let lines = try screen("grok-1050-welcome")
        let box = try XCTUnwrap(GrokScreen.box(lines))
        XCTAssertEqual(box.footer, "[stable]")
        XCTAssertEqual(box.label, "Grok 4.7 (high)", "The permission mode (· always-approve) is not part of the model label")
        XCTAssertTrue(GrokScreen.idle(lines))
        XCTAssertEqual(GrokScreen.draft(lines), "")
    }

    func testFirstScreenInALowWindow() throws {
        let lines = try screen("grok-1050-welcome-low")
        XCTAssertEqual(GrokScreen.box(lines)?.label, "Grok 4.7 (high)")
        XCTAssertTrue(GrokScreen.idle(lines))
    }

    func testLowWindowTellsWorkingByTheStatusRow() throws {
        // Window of 20 rows or fewer: the hint line is `Ctrl+x:shortcuts` both when idle and while working.
        let idle = try screen("grok-1050-low-idle")
        let working = try screen("grok-1050-low-working")
        XCTAssertEqual(GrokScreen.box(idle)?.footer, GrokScreen.box(working)?.footer)
        XCTAssertTrue(GrokScreen.idle(idle))
        XCTAssertTrue(GrokScreen.working(working))
        XCTAssertFalse(GrokScreen.idle(working), "Typing /model while working goes into the queue or mixes with the work")
        XCTAssertTrue(GrokScreen.working(try screen("grok-working")), "The 1.0.46 working screen also has the same status line")
        XCTAssertFalse(GrokScreen.working(try screen("grok-after-work")))
    }

    func testTallWindowHasABlankRowAboveTheHints() throws {
        let lines = try screen("grok-1050-welcome-tall")
        XCTAssertEqual(GrokScreen.box(lines)?.label, "Grok 4.7 (medium)")
        XCTAssertTrue(GrokScreen.idle(lines))
        let working = try screen("grok-1050-working")
        XCTAssertEqual(GrokScreen.box(working)?.label, "Grok 4.7 (medium)", "Positive control: the box is read")
        XCTAssertFalse(GrokScreen.idle(working), "Working (Ctrl+c:cancel)")
    }

    func testPermissionModeIsNotPartOfTheLabel() {
        for mode in ["plan", "auto-review", "always-approve"] {
            XCTAssertEqual(GrokScreen.label(inBorder: "╰──────────── Grok 4.7 (medium) · \(mode) ─╯"), "Grok 4.7 (medium)", mode)
        }
        XCTAssertEqual(GrokScreen.label(inBorder: "╰──────────── Grok Code · plan ─╯"), "Grok Code")
        XCTAssertEqual(GrokScreen.label(inBorder: "╰──────────── Grok 4.7 (xhigh) ─╯"), "Grok 4.7 (xhigh)")
    }

    func testOnlyAChannelTagCountsAsTheFirstScreenHint() {
        XCTAssertTrue(GrokScreen.isChannelTag("[stable]"))
        XCTAssertTrue(GrokScreen.isChannelTag("[alpha]"))
        XCTAssertTrue(GrokScreen.isChannelTag("Grok Build  1.0.50 [stable]"), "First screen of a short window")
        XCTAssertFalse(GrokScreen.isChannelTag("Grok Build is here [stable]"))
        XCTAssertFalse(GrokScreen.isChannelTag("[Opt out] [Opt in]"))
        XCTAssertFalse(GrokScreen.isChannelTag("Enter:send"))
    }

    func testClaudeAndCodexScreensAreNotGrok() throws {
        for name in ["claude-idle", "codex-idle", "claude-draft"] {
            XCTAssertFalse(GrokScreen.idle(try screen(name)), name)
            XCTAssertNil(GrokScreen.box(try screen(name)), name)
        }
    }

    func testParsesTheLabel() {
        XCTAssertEqual(GrokScreen.parse(label: "Grok 4.7 (xhigh)").name, "Grok 4.7")
        XCTAssertEqual(GrokScreen.parse(label: "Grok 4.7 (xhigh)").effort, "xhigh")
        XCTAssertNil(GrokScreen.parse(label: "Grok Code").effort)
    }

    func testOldUnknownModelLineIsCountedSoNewOnesCanBeTold() {
        let before = ["  Unknown model: grok-4.6", "  │ ❯", "  ╰──╯"]
        XCTAssertEqual(GrokScreen.errorLines(before), ["Unknown model: grok-4.6"])
        XCTAssertEqual(GrokScreen.errorLines(["hello"]), [])
    }
}

final class GrokModelsAndDefaultsTests: KoreanMessagesTestCase {
    func testParsesModelsAndOrdersEfforts() {
        let json = """
        {"models": {"grok-4.7": {"info": {"id": "grok-4.7", "name": "Grok 4.7", "supports_reasoning_effort": true,
          "reasoning_efforts": [{"value": "xhigh"}, {"value": "high"}, {"value": "medium"}, {"value": "low"}]}},
          "hidden": {"info": {"id": "x", "name": "X", "hidden": true}},
          "plain": {"info": {"id": "grok-code", "name": "Grok Code", "supports_reasoning_effort": false}}}}
        """
        let models = GrokModels.parse(Data(json.utf8))
        XCTAssertEqual(models.models.map(\.id), ["grok-4.7", "grok-code"], "Hidden models are left out")
        XCTAssertEqual(models.resolve("grok-4.7")?.efforts, ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(models.resolve("Grok 4.7")?.id, "grok-4.7", "Also found by the on-screen name")
        XCTAssertEqual(models.resolve("grok-code")?.efforts, [])
        XCTAssertNil(models.resolve("grok-9"))
    }

    private func original() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "grok-config-before", withExtension: "toml", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testRemovesTheAppendedModelsTableExactly() throws {
        // Measured 2026-10-07: grok appended "original file + blank line + [models] table".
        let before = try original()
        let after = before + "\n[models]\ndefault = \"grok-4.7\"\ndefault_reasoning_effort = \"xhigh\"\n"
        XCTAssertEqual(GrokDefaults.restoring(current: after, from: before), before, "Must match down to the bytes")
    }

    func testPutsBackPreviousValuesAndKeepsOtherKeys() {
        let before = "[ui]\nyolo = false\n\n[models]\ndefault = \"grok-4.6\"\ndefault_reasoning_effort = \"low\"\nallowed = 1\n"
        let after = "[ui]\nyolo = true\n\n[models]\nallowed = 1\ndefault = \"grok-4.7\"\ndefault_reasoning_effort = \"xhigh\"\n"
        let fixed = GrokDefaults.restoring(current: after, from: before)
        XCTAssertTrue(fixed.contains("default = \"grok-4.6\""))
        XCTAssertTrue(fixed.contains("default_reasoning_effort = \"low\""))
        XCTAssertTrue(fixed.contains("yolo = true"), "Other keys (written by other sessions) are not touched")
        XCTAssertFalse(fixed.contains("grok-4.7"))
    }

    func testNothingToDoWhenAlreadyOriginal() throws {
        let before = try original()
        XCTAssertEqual(GrokDefaults.restoring(current: before, from: before), before)
    }

    func testRestoreWritesTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grok-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try original()
        try (before + "\n[models]\ndefault = \"x\"\n").write(to: url, atomically: true, encoding: .utf8)
        let defaults = GrokDefaults(url: url)
        XCTAssertEqual(defaults.restore(to: before), .restored)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before)
        XCTAssertEqual(defaults.restore(to: before), .unchanged)
    }
}

/// Fakes the grok input box and `/model` command. The settings file also gets `[models]` appended as in reality.
final class FakeGrok: TerminalIO {
    var input = ""
    var label: String
    var busy = false
    var errors: [String] = []
    let known: [String: (name: String, efforts: [String])]
    let configURL: URL
    var typed: [String] = []
    var ignoreEnter = false
    /// Permission mode attached after the label (` · always-approve`). 1.0.50.
    var mode = ""

    init(label: String = "Grok 4.7 (high)", configURL: URL,
         known: [String: (name: String, efforts: [String])] = ["grok-4.7": ("Grok 4.7", ["low", "medium", "high", "xhigh"])]) {
        self.label = label
        self.configURL = configURL
        self.known = known
    }

    func type(_ text: String) throws { typed.append(text); input += text }
    func press(_ key: Key) throws {
        switch key {
        case .backspace: if !input.isEmpty { input.removeLast() }
        case .enter:
            if ignoreEnter { return }
            run()
        default: break
        }
    }

    private func run() {
        defer { input = "" }
        let words = input.split(separator: " ").map(String.init)
        guard words.count >= 2, words[0] == "/model" else { return }
        guard let model = known[words[1]] else { errors.append("  Unknown model: \(words[1])"); return }
        let effort = words.count > 2 ? words[2] : nil
        label = model.name + (effort.map { " (\($0))" } ?? "")
        var text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        text += "\n[models]\ndefault = \"\(words[1])\"\n" + (effort.map { "default_reasoning_effort = \"\($0)\"\n" } ?? "")
        try? text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    func screen() -> [String]? {
        var lines = ["  Read Terms and Privacy Policy."] + errors
        let width = 60
        lines.append("  ╭" + String(repeating: "─", count: width) + "╮")
        lines.append("  │ ❯ " + input + String(repeating: " ", count: max(0, width - 3 - input.count)) + "│")
        lines.append("  ╰" + String(repeating: "─", count: max(1, width - label.count - mode.count - 4)) + " \(label)\(mode) ─╯")
        lines.append(busy ? "  Esc:interrupt  │  Ctrl+x:shortcuts" : (input.isEmpty ? "  Shift+Tab:mode  │  Ctrl+x:shortcuts" : "  Enter:send  │  Shift+Tab:mode  │  Ctrl+x:shortcuts"))
        return lines
    }
}

final class GrokDriverTests: KoreanMessagesTestCase {
    private var url: URL!
    private var original = ""

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("grok-driver-\(UUID().uuidString).toml")
        original = "[ui]\nyolo = false\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    private func driver(_ io: FakeGrok, keepDefaults: Bool = true) -> GrokDriver {
        let models = GrokModels(models: [.init(id: "grok-4.7", name: "Grok 4.7", efforts: ["low", "medium", "high", "xhigh"]),
                                         .init(id: "grok-code", name: "Grok Code", efforts: [])])
        return GrokDriver(io: io, sleep: { _ in }, models: models, defaults: GrokDefaults(url: url), keepDefaults: keepDefaults)
    }

    func testSwitchesModelAndEffortAndPutsTheDefaultBack() throws {
        let io = FakeGrok(configURL: url)
        let outcome = try driver(io).apply(AgentPreset(model: "grok-4.7", effort: "xhigh"))
        XCTAssertEqual(io.typed, ["/model grok-4.7 xhigh"])
        XCTAssertEqual(outcome.confirmations, ["Using Grok 4.7 (xhigh)"])
        XCTAssertNil(outcome.warning)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original, "The new-session default must stay as is")
    }

    func testSwitchesInASessionThatShowsItsPermissionMode() throws {
        let io = FakeGrok(configURL: url)
        io.mode = " · always-approve"
        let outcome = try driver(io).apply(AgentPreset(model: "grok-4.7", effort: "xhigh"))
        XCTAssertEqual(outcome.confirmations, ["Using Grok 4.7 (xhigh)"])
        let stepped = try driver(io).stepEffort(up: false)
        XCTAssertEqual(io.typed.last, "/model grok-4.7 high")
        XCTAssertEqual(stepped.confirmations, ["Using Grok 4.7 (high)"])
    }

    func testLeavesTheDefaultSavedWhenKeepDefaultsIsOff() throws {
        let io = FakeGrok(configURL: url)
        _ = try driver(io, keepDefaults: false).apply(AgentPreset(model: "grok-4.7", effort: "low"))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("default = \"grok-4.7\""))
    }

    func testUnknownModelIsRefusedBeforeTypingAnything() throws {
        let io = FakeGrok(configURL: url)
        XCTAssertThrowsError(try driver(io).apply(AgentPreset(model: "grok-9", effort: "high")))
        XCTAssertEqual(io.typed, [], "A model not in the list is not sent")
    }

    func testUnsupportedEffortIsRefusedBeforeTypingAnything() {
        let io = FakeGrok(configURL: url)
        XCTAssertThrowsError(try driver(io).apply(AgentPreset(model: "grok-4.7", effort: "max")))
        XCTAssertEqual(io.typed, [])
    }

    func testModelWithoutEffortSendsNoEffortWord() throws {
        let io = FakeGrok(configURL: url, known: ["grok-code": ("Grok Code", [])])
        let outcome = try driver(io).apply(AgentPreset(model: "grok-code", effort: "high"))
        XCTAssertEqual(io.typed, ["/model grok-code"])
        XCTAssertEqual(outcome.confirmations, ["Using Grok Code"])
    }

    func testRefusesWhenADraftIsInTheBox() throws {
        let io = FakeGrok(configURL: url)
        io.input = "작성 중인 글"
        XCTAssertThrowsError(try driver(io).apply(AgentPreset(model: "grok-4.7", effort: "high")))
        XCTAssertEqual(io.typed, [])
        XCTAssertEqual(io.input, "작성 중인 글", "The draft text stays as is")
    }

    func testRefusesWhileBusy() {
        let io = FakeGrok(configURL: url)
        io.busy = true
        XCTAssertThrowsError(try driver(io).apply(AgentPreset(model: "grok-4.7", effort: "high")))
        XCTAssertEqual(io.typed, [])
    }

    func testServerUnknownModelClearsOurTextAndRestoresDefaults() throws {
        // The case where it is in the list (cache) but grok answers that it does not know it.
        let io = FakeGrok(configURL: url, known: [:])
        XCTAssertThrowsError(try driver(io).apply(AgentPreset(model: "grok-4.7", effort: "high"))) { error in
            XCTAssertTrue("\(error)".contains("Unknown model"), "\(error)")
        }
        XCTAssertEqual(io.input, "")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testIgnoredEnterLeavesNoTextBehind() {
        let io = FakeGrok(configURL: url)
        io.ignoreEnter = true
        XCTAssertThrowsError(try driver(io).apply(AgentPreset(model: "grok-4.7", effort: "xhigh")))
        XCTAssertEqual(io.input, "", "If there is no response, erases the text we wrote and stops")
    }

    func testStepsEffortUpAndDownAndStopsAtTheEnds() throws {
        let io = FakeGrok(label: "Grok 4.7 (high)", configURL: url)
        XCTAssertEqual(try driver(io).stepEffort(up: true).confirmations, ["Using Grok 4.7 (xhigh)"])
        XCTAssertThrowsError(try driver(io).stepEffort(up: true)) { XCTAssertTrue(($0 as? SlashCommandError)?.nothingToDo == true) }
        XCTAssertEqual(try driver(io).stepEffort(up: false).confirmations, ["Using Grok 4.7 (high)"])
        io.label = "Grok 4.7 (low)"
        XCTAssertThrowsError(try driver(io).stepEffort(up: false)) { XCTAssertTrue(($0 as? SlashCommandError)?.nothingToDo == true) }
        XCTAssertEqual(io.typed.count, 2, "At the last step nothing is sent")
    }

    func testSummaryUsesTheLabelGrokShowed() {
        let target = Target(host: .orca(handle: "h"), agent: .grok, label: "t")
        let result = SwitchResult(target: target, slotName: "", preset: AgentPreset(model: "grok-4.7", effort: "high"),
                                  warning: nil, confirmations: ["Using Grok 4.7 (xhigh)"], pendingRestore: nil)
        XCTAssertEqual(result.summary, "Grok 4.7 · xhigh")
    }

    func testSlotKeepsGrokPresetThroughTheFile() throws {
        let slot = Slot(claude: AgentPreset(model: "opus", effort: "high"), grok: AgentPreset(model: "grok-4.7", effort: "xhigh"))
        let decoded = try JSONDecoder().decode(Slot.self, from: JSONEncoder().encode(slot))
        XCTAssertEqual(decoded, slot)
        XCTAssertEqual(decoded.listing, "claude opus · high  /  grok grok-4.7 · xhigh")
        XCTAssertEqual(try JSONDecoder().decode(Slot.self, from: Data(#"{"claude":{"model":"a","effort":"b"},"future-agent":{"model":"x","effort":"y"}}"#.utf8)).claude?.model, "a",
                       "Unknown agent keys are ignored")
    }
}

// MARK: - cursor-agent

final class CursorScreenTests: KoreanMessagesTestCase {
    struct Fixture: Decodable { let tail: [String] }

    func screen(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tail
    }

    func testIdleAndDraft() throws {
        let idle = try screen("cursor-idle")
        XCTAssertTrue(CursorScreen.idle(idle))
        XCTAssertEqual(CursorScreen.draft(idle), "")
        XCTAssertEqual(CursorScreen.status(idle), "Grok 4.7 256K Medium")
        let draft = try screen("cursor-draft")
        XCTAssertEqual(CursorScreen.draft(draft), "abc")
        XCTAssertFalse(CursorScreen.idle(draft))
    }

    func testWorkingAndAfterWorkScreens() throws {
        // Real screen: while working a spinner (`⠰⠳ Working`) runs above the input line; after finishing the placeholder is "Add a follow-up" and usage is attached to the model line.
        let working = try screen("cursor-working")
        XCTAssertEqual(CursorScreen.draft(working), "")
        XCTAssertFalse(CursorScreen.idle(working), "Does not send /model while working")
        let after = try screen("cursor-after-work")
        XCTAssertTrue(CursorScreen.idle(after), "Idle after finishing — 'Add a follow-up' is not draft text")
        XCTAssertEqual(CursorScreen.status(after), "Grok 4.7 256K High", "Usage (· 7.1%) is not part of the model line")
    }

    /// Lines taken from the 2026-10-11 measurement (2026.10.01-e373342, session opened with `--yolo`).
    func testRunEverythingSessionScreens() {
        let path = "  ~/orca/workspaces/slash-command/initial-2 · yohangwak/real-device-fixes"
        let right = String(repeating: " ", count: 60)
        let idle = ["  Cursor Agent", "  v2026.10.01-e373342", "  → Plan, search, build anything", "  Grok 4.7 256K High Fast" + right + "Run Everything", path]
        XCTAssertTrue(CursorScreen.idle(idle))
        XCTAssertEqual(CursorScreen.status(idle), "Grok 4.7 256K High Fast", "The run-mode marker on the right is not part of the model line")
        let after = ["  ok", "  → Add a follow-up", "  Grok 4.7 256K Medium Fast · 6.9%" + right + "Run Everything", path]
        XCTAssertTrue(CursorScreen.idle(after))
        XCTAssertEqual(CursorScreen.status(after), "Grok 4.7 256K Medium Fast")
        // While working: a help line sits between the spinner and the input line — looking only at the line right above would look idle.
        let working = ["  Reply with exactly: ok. Do not use any tools.", " ⠀⠞ Working", "    Tip: Use subagents to parallelize work and preserve context.",
                       "  → Add a follow-up" + right + "ctrl+c to stop", "  Grok 4.7 256K Medium Fast" + right + "Run Everything", path]
        XCTAssertFalse(CursorScreen.idle(working), "Does not send /model while working")
        XCTAssertEqual(CursorScreen.draft(working), "", "The hint on the right is not draft text")
        // Even if the window is narrow and the right-hand hint is cut off, the spinner tells.
        var narrow = working
        narrow[3] = "  → Add a follow-up"
        XCTAssertFalse(CursorScreen.idle(narrow))
    }

    func testListRowsCursorAndFilter() throws {
        let list = try XCTUnwrap(CursorScreen.list(try screen("cursor-list")))
        XCTAssertEqual(list.filter, "")
        XCTAssertEqual(list.rows.first(where: \.cursor)?.name, "Grok 4.7")
        XCTAssertEqual(list.rows.first(where: \.cursor)?.params, "256K Medium")
        XCTAssertEqual(list.rows.map(\.name).prefix(3), ["Auto", "Grok 4.7", "Grok 4.6"])
        XCTAssertFalse(list.rows.contains { $0.name.contains("1-10") }, "The page marker is not a row")
        let filtered = try XCTUnwrap(CursorScreen.list(try screen("cursor-filtered")))
        XCTAssertEqual(filtered.filter, "opus")
        XCTAssertEqual(filtered.rows.first?.name, "Claude Opus 5.5")
        XCTAssertEqual(filtered.rows.last?.name, "Claude Opus 4.5")
        XCTAssertEqual(filtered.rows.last?.params, "", "A row without parameters")
    }

    func testEditorOptionsKeepFastOutOfTheEffortGroup() throws {
        let editor = try XCTUnwrap(CursorScreen.editor(try screen("cursor-editor")))
        XCTAssertEqual(editor.title, "Grok 4.7")
        let efforts = editor.options.filter { $0.section == "Effort" }.map(\.label)
        XCTAssertEqual(efforts, ["Low", "Medium", "High", "Extra High"], "Fast is not Effort (real incident: Fast got turned on)")
        XCTAssertEqual(editor.options.first(where: { $0.section == "Toggle" })?.label, "Fast")
        XCTAssertEqual(editor.options.first(where: { $0.chosen && $0.section == "Effort" })?.label, "Medium")
        let opus = try XCTUnwrap(CursorScreen.editor(try screen("cursor-editor-opus")))
        XCTAssertEqual(opus.title, "Claude Opus 5.5", "The Max mode text on the right is not put into the name")
    }

    func testNothingIsOpenOnOtherAgentsScreens() throws {
        for name in ["claude-idle", "codex-idle", "grok-idle", "grok-picker"] {
            XCTAssertFalse(CursorScreen.idle(try screen(name)), name)
            XCTAssertNil(CursorScreen.list(try screen(name)), name)
            XCTAssertNil(CursorScreen.editor(try screen(name)), name)
        }
        XCTAssertFalse(GrokScreen.idle(try screen("cursor-idle")))
    }

    func testStatusParsingAndEffortAliases() {
        XCTAssertEqual(CursorScreen.parse(status: "Grok 4.7 256K Extra High").name, "Grok 4.7")
        XCTAssertEqual(CursorScreen.parse(status: "Grok 4.7 256K Extra High").effort, "Extra High")
        XCTAssertEqual(CursorScreen.parse(status: "Grok 4.6 High").name, "Grok 4.6")
        XCTAssertNil(CursorScreen.parse(status: "Composer 2.5").effort)
        XCTAssertTrue(CursorScreen.effortMatches("xhigh", label: "Extra High"))
        XCTAssertTrue(CursorScreen.effortMatches("high", label: "High"))
        XCTAssertFalse(CursorScreen.effortMatches("high", label: "Extra High"))
        XCTAssertEqual(CursorScreen.key("claude-opus-5-5"), CursorScreen.key("Claude Opus 5.5"))
    }
}

final class CursorDefaultsTests: KoreanMessagesTestCase {
    private func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    func testRestoresOriginalBytesWhenOnlyTheModelKeysChanged() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(["version": 1, "model": ["modelId": "a"], "selectedModel": ["modelId": "a"], "modelSelectionHistory": ["a"], "modelParameters": ["a": []]], to: url)
        let before = try Data(contentsOf: url)
        try write(["version": 1, "model": ["modelId": "b"], "selectedModel": ["modelId": "b"], "modelSelectionHistory": ["b", "a"], "modelParameters": ["b": [1]]], to: url)
        XCTAssertEqual(CursorDefaults(url: url).restore(to: before), .restored)
        XCTAssertEqual(try Data(contentsOf: url), before, "Must match down to the bytes")
        XCTAssertEqual(CursorDefaults(url: url).restore(to: before), .unchanged)
    }

    func testKeepsOtherChangesMadeByAnotherSession() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(["version": 1, "model": ["modelId": "a"], "selectedModel": ["modelId": "a"], "modelSelectionHistory": ["a"], "modelParameters": [:], "hints": true], to: url)
        let before = try Data(contentsOf: url)
        try write(["version": 1, "model": ["modelId": "b"], "selectedModel": ["modelId": "b"], "modelSelectionHistory": ["b"], "modelParameters": ["b": []], "hints": false], to: url)
        XCTAssertEqual(CursorDefaults(url: url).restore(to: before), .restored)
        let now = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((now["model"] as? [String: String])?["modelId"], "a")
        XCTAssertEqual(now["hints"] as? Bool, false, "A value changed by another session is left as is")
    }
}

/// Fakes cursor-agent's `/model` list and parameter editing. The filter works only when typed one character at a time (a chunk is ignored), and Enter/Esc/Tab behave as measured.
final class FakeCursor: TerminalIO {
    struct Model {
        let name: String
        let contexts: [String]
        let efforts: [String]
        var context: String
        var effort: String?
        var fast = false
    }

    enum Mode: Equatable { case idle, list, editor }

    var models: [Model]
    var current: Int
    var mode = Mode.idle
    var input = ""
    var filter = ""
    var cursor = 0
    var editorCursor = 0
    var typed: [String] = []
    var presses: [Key] = []
    var busyFooter = false
    /// Session opened with `--yolo`: `Run Everything` is attached at the right end of the model line.
    var runEverything = false
    /// After the list opens, the cursor stays on the top line until this many reads, then moves to the current model (measured).
    var lateCursor = 0
    private var late = 0
    let configURL: URL

    init(configURL: URL) {
        self.configURL = configURL
        models = [Model(name: "Auto", contexts: [], efforts: [], context: "", effort: nil),
                  Model(name: "Grok 4.7", contexts: ["256K", "500K"], efforts: ["Low", "Medium", "High", "Extra High"], context: "256K", effort: "High"),
                  Model(name: "Claude Opus 5.5", contexts: ["300K", "1M"], efforts: ["Low", "Medium", "High", "Extra High", "Max"], context: "300K", effort: "Medium")]
        current = 1
    }

    private var visible: [Int] {
        models.indices.filter { filter.isEmpty || models[$0].name.lowercased().contains(filter.lowercased()) }
    }

    /// Line list of the edit screen: (kind, label).
    private func editorRows(_ m: Model) -> [(String, String)] {
        m.contexts.map { ("Context", $0) } + m.efforts.map { ("Effort", $0) } + [("Toggle", "Fast")]
    }

    func type(_ text: String) throws {
        typed.append(text)
        switch mode {
        case .idle: input += text
        case .list:
            guard text.count == 1 else { return }   // A chunk is treated as a paste and ignored
            filter += text
            cursor = 0
        case .editor: break
        }
    }

    func press(_ key: Key) throws {
        presses.append(key)
        switch (mode, key) {
        case (.idle, .enter):
            if input == "/model" {
                mode = .list
                filter = ""
                late = lateCursor
                cursor = late > 0 ? 0 : visible.firstIndex(of: current) ?? 0
            }
            input = ""
        case (.idle, .backspace): if !input.isEmpty { input.removeLast() }
        case (.list, .up): cursor = max(0, cursor - 1)
        case (.list, .down): cursor = min(visible.count - 1, cursor + 1)
        case (.list, .escape): mode = .idle; filter = ""
        case (.list, .backspace): if !filter.isEmpty { filter.removeLast(); cursor = 0 }
        case (.list, .tab):
            let index = visible[cursor]
            if !models[index].contexts.isEmpty { mode = .editor; editorCursor = 0 }
        case (.list, .enter):
            current = visible[cursor]
            mode = .idle
            filter = ""
            write()
        case (.editor, .up): editorCursor = max(0, editorCursor - 1)
        case (.editor, .down): editorCursor = min(editorRows(models[visible[cursor]]).count - 1, editorCursor + 1)
        case (.editor, .escape): mode = .list
        case (.editor, .enter):
            let index = visible[cursor]
            let row = editorRows(models[index])[editorCursor]
            switch row.0 {
            case "Context": models[index].context = row.1
            case "Effort": models[index].effort = row.1
            default: models[index].fast.toggle()
            }
        default: break
        }
    }

    private func write() {
        let m = models[current]
        let object: [String: Any] = ["version": 1, "model": ["modelId": m.name], "selectedModel": ["modelId": m.name],
                                     "modelSelectionHistory": [m.name], "modelParameters": [m.name: [m.effort ?? ""]], "hints": true]
        try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: configURL)
    }

    private var statusLine: String {
        let m = models[current]
        return "  " + [m.name, m.context, m.effort, m.fast ? "Fast" : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            + (runEverything ? String(repeating: " ", count: 40) + "Run Everything" : "")
    }

    func screen() -> [String]? {
        if mode == .list, late > 0 {
            late -= 1
            if late == 0, filter.isEmpty { cursor = visible.firstIndex(of: current) ?? 0 }
        }
        switch mode {
        case .idle:
            return ["", "  Cursor Agent", "", busyFooter ? "  ⬡ Generating…" : "  → " + (input.isEmpty ? "Plan, search, build anything" : input), "", "", statusLine,
                    "  ~/work/repo · main"].filter { !busyFooter || !$0.hasPrefix("  →") }
        case .list:
            var lines = ["  → Plan, search, build anything", " Available models", " Filter: \(filter)", ""]
            for (offset, index) in visible.enumerated() {
                let m = models[index]
                let params = [m.context, m.effort].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                lines.append((offset == cursor ? " →  " : "    ") + m.name + (params.isEmpty ? "" : "          " + params) + (offset == cursor && !m.contexts.isEmpty ? " (Tab to modify)" : ""))
            }
            return lines + ["", " Type to filter • Enter to select • Tab to edit"]
        case .editor:
            let m = models[visible[cursor]]
            var lines = [" \(m.name) — Edit Parameters       Max mode: OFF", ""]
            var section = ""
            for (offset, row) in editorRows(m).enumerated() {
                if row.0 != section {
                    if row.0 == "Toggle" { lines.append("") } else { lines.append("  \(row.0)") }
                    section = row.0
                }
                let on = row.0 == "Context" ? m.context == row.1 : row.0 == "Effort" ? m.effort == row.1 : m.fast
                let glyph = row.0 == "Toggle" ? (on ? "◉" : "◯") : (on ? "●" : "○")
                lines.append((offset == editorCursor ? "  → " : "    ") + glyph + " " + row.1 + (on && row.0 != "Toggle" ? " ✓" : ""))
            }
            return lines + ["", " ↑/↓ to navigate • Enter to select • Esc to go back"]
        }
    }
}

final class CursorDriverTests: KoreanMessagesTestCase {
    private var url: URL!
    private var original = Data()

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-driver-\(UUID().uuidString).json")
        let object: [String: Any] = ["version": 1, "model": ["modelId": "Grok 4.7"], "selectedModel": ["modelId": "Grok 4.7"],
                                     "modelSelectionHistory": ["Grok 4.7"], "modelParameters": ["Grok 4.7": ["High"]], "hints": true]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        original = try Data(contentsOf: url)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    private func driver(_ io: FakeCursor, keepDefaults: Bool = true) -> CursorDriver {
        CursorDriver(io: io, sleep: { _ in }, defaults: CursorDefaults(url: url), keepDefaults: keepDefaults)
    }

    func testSwitchesModelAndEffortThenRestoresTheDefault() throws {
        let io = FakeCursor(configURL: url)
        let outcome = try driver(io).apply(AgentPreset(model: "claude-opus-5-5", effort: "xhigh"))
        XCTAssertEqual(outcome.confirmations, ["Using Claude Opus 5.5 300K Extra High"])
        XCTAssertEqual(io.models[io.current].name, "Claude Opus 5.5")
        XCTAssertFalse(io.models[io.current].fast, "Fast is not touched")
        XCTAssertEqual(try Data(contentsOf: url), original, "The new-session default must stay as is")
        XCTAssertNil(outcome.warning)
    }

    func testFilterIsTypedOneCharacterAtATime() throws {
        let io = FakeCursor(configURL: url)
        _ = try driver(io).apply(AgentPreset(model: "Claude Opus 5.5", effort: "high"))
        let filterTyped = io.typed.filter { $0 != "/model" }
        XCTAssertTrue(filterTyped.allSatisfy { $0.count == 1 }, "Sent as one chunk, cursor treats it as a paste and ignores it: \(filterTyped)")
        XCTAssertFalse(filterTyped.isEmpty)
    }

    func testSkipsTheEditorWhenTheRowAlreadyShowsTheEffort() throws {
        let io = FakeCursor(configURL: url)
        _ = try driver(io).apply(AgentPreset(model: "Grok 4.7", effort: "high"))
        XCTAssertFalse(io.presses.contains(.tab), "Already High, so parameter editing is not opened")
    }

    func testUnknownModelClosesTheListAndTypesNothingElse() {
        let io = FakeCursor(configURL: url)
        XCTAssertThrowsError(try driver(io).apply(AgentPreset(model: "No Such Model", effort: "high")))
        XCTAssertEqual(io.mode, .idle, "Closes the list with Esc and returns")
        XCTAssertEqual(io.input, "")
        XCTAssertEqual(io.current, 1)
        XCTAssertEqual(try? Data(contentsOf: url), original)
    }

    func testUnsupportedEffortIsRefusedAndNothingIsSelected() {
        let io = FakeCursor(configURL: url)
        XCTAssertThrowsError(try driver(io).apply(AgentPreset(model: "Grok 4.7", effort: "max")))
        XCTAssertEqual(io.mode, .idle)
        XCTAssertEqual(io.current, 1)
        XCTAssertEqual(io.models[1].effort, "High")
    }

    func testRefusesWithADraftOrWhileBusy() {
        let draft = FakeCursor(configURL: url)
        draft.input = "쓰던 글"
        XCTAssertThrowsError(try driver(draft).apply(AgentPreset(model: "Grok 4.7", effort: "low")))
        XCTAssertEqual(draft.typed, [])
        let busy = FakeCursor(configURL: url)
        busy.busyFooter = true
        XCTAssertThrowsError(try driver(busy).apply(AgentPreset(model: "Grok 4.7", effort: "low")))
        XCTAssertEqual(busy.typed, [])
    }

    func testRunEverythingLabelIsNotPartOfTheModelLine() throws {
        // Measured 2026-10-11 (`cursor-agent --yolo`): the switch happened, but it also read `Run Everything` at the right of the model line and stopped, saying it had not changed.
        let io = FakeCursor(configURL: url)
        io.runEverything = true
        XCTAssertEqual(try driver(io).apply(AgentPreset(model: "Claude Opus 5.5", effort: "high")).confirmations, ["Using Claude Opus 5.5 300K High"])
        XCTAssertEqual(try driver(io).stepEffort(up: true).confirmations, ["Using Claude Opus 5.5 300K Extra High"])
        XCTAssertEqual(try Data(contentsOf: url), original, "The new-session default stays as is")
    }

    func testEffortStepWaitsUntilTheListCursorIsOnTheCurrentModel() throws {
        // Measured 2026-10-11: the instant the list opened the cursor was on the top line (Auto), and Tab pressed there stopped it with "Auto has no effort" (2 of 8 times).
        let io = FakeCursor(configURL: url)
        io.lateCursor = 5
        XCTAssertEqual(try driver(io).stepEffort(up: true).confirmations, ["Using Grok 4.7 256K Extra High"])
        XCTAssertEqual(io.current, 1)
        // If it never arrives at that model, Tab is not pressed on any row.
        let never = FakeCursor(configURL: url)
        never.lateCursor = 100_000
        XCTAssertThrowsError(try driver(never).stepEffort(up: true))
        XCTAssertFalse(never.presses.contains(.tab))
        XCTAssertEqual(never.mode, .idle)
        XCTAssertEqual(never.current, 1)
        XCTAssertEqual(never.models[1].effort, "High")
    }

    func testStepsEffortAndStopsAtTheEnds() throws {
        let io = FakeCursor(configURL: url)
        XCTAssertEqual(try driver(io).stepEffort(up: true).confirmations, ["Using Grok 4.7 256K Extra High"])
        XCTAssertThrowsError(try driver(io).stepEffort(up: true)) { XCTAssertTrue(($0 as? SlashCommandError)?.nothingToDo == true) }
        XCTAssertEqual(io.mode, .idle)
        XCTAssertFalse(io.models[1].fast, "At the last step Enter must not go to Fast")
        for _ in 0..<3 { _ = try driver(io).stepEffort(up: false) }
        XCTAssertEqual(io.models[1].effort, "Low")
        XCTAssertThrowsError(try driver(io).stepEffort(up: false)) { XCTAssertTrue(($0 as? SlashCommandError)?.nothingToDo == true) }
        XCTAssertFalse(io.models[1].fast)
    }

    func testKeepDefaultsOffLeavesTheSavedModel() throws {
        let io = FakeCursor(configURL: url)
        _ = try driver(io, keepDefaults: false).apply(AgentPreset(model: "Claude Opus 5.5", effort: "low"))
        XCTAssertNotEqual(try Data(contentsOf: url), original)
    }

    func testSummaryForCursorStatusLine() {
        let target = Target(host: .orca(handle: "h"), agent: .cursor, label: "t")
        let result = SwitchResult(target: target, slotName: "", preset: AgentPreset(model: "x", effort: "high"),
                                  warning: nil, confirmations: ["Using Grok 4.7 256K Extra High"], pendingRestore: nil)
        XCTAssertEqual(result.summary, "Grok 4.7 · Extra High")
    }
}

// MARK: - antigravity (agy)

final class AgyScreenTests: KoreanMessagesTestCase {
    struct Fixture: Decodable { let tail: [String] }

    func screen(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tail
    }

    func testIdleDraftAndWorking() throws {
        XCTAssertTrue(AgyScreen.idle(try screen("agy-idle")))
        XCTAssertTrue(AgyScreen.idle(try screen("agy-after-esc")))
        XCTAssertTrue(AgyScreen.idle(try screen("agy-after-work")), "Positive control: idle when the work is done")
        let draft = try screen("agy-draft")
        XCTAssertEqual(AgyScreen.draft(draft), "abc")
        XCTAssertFalse(AgyScreen.idle(draft))
        let working = try screen("agy-working")
        XCTAssertEqual(AgyScreen.draft(working), "", "The input line looks empty")
        XCTAssertFalse(AgyScreen.idle(working), "Not sent while working (spinner, esc to cancel)")
    }

    func testTypingASlashCommandShowsTheCommandListButTheDraftIsStillRead() throws {
        let typed = try screen("agy-typed-model")
        XCTAssertEqual(AgyScreen.draft(typed), "/model", "The input line is read even when the command list is shown")
        XCTAssertFalse(AgyScreen.idle(typed))
    }

    func testPickerRowsAndSlider() throws {
        let lines = try screen("agy-picker")
        let picker = try XCTUnwrap(AgyScreen.picker(lines))
        XCTAssertEqual(picker.rows.map(\.name).prefix(4), ["Gemini 3.8 Flash", "Gemini 3.7 Flash", "Gemini 3.6 Flash", "Gemini 3.1 Pro"])
        XCTAssertEqual(picker.rows.first(where: \.cursor)?.name, "Gemini 3.8 Flash")
        XCTAssertEqual(picker.rows.first(where: \.current)?.name, "Gemini 3.8 Flash")
        XCTAssertTrue(picker.rows.contains { $0.name == "GPT-OSS 120B (Medium)" })
        let slider = try XCTUnwrap(picker.slider)
        XCTAssertEqual(slider.labels, ["low", "medium", "high"])
        XCTAssertEqual(slider.selected, 2, "◉ is below high")
        XCTAssertFalse(AgyScreen.idle(lines), "A picker is open")
    }

    func testSliderStopsAreFilledOrHollowDependingOnTheSelection() throws {
        // Real screen after choosing the lowest level: each level is drawn as `◉` (selected) · `○` (above it) — looking at `●` alone as a dot would read one level.
        let slider = try XCTUnwrap(AgyScreen.picker(try screen("agy-picker-low"))?.slider)
        XCTAssertEqual(slider.labels, ["low", "medium", "high"])
        XCTAssertEqual(slider.selected, 0)
    }

    func testOtherAgentsAreNotAntigravity() throws {
        for name in ["claude-idle", "codex-idle", "grok-idle", "cursor-idle"] {
            XCTAssertFalse(AgyScreen.idle(try screen(name)), name)
            XCTAssertNil(AgyScreen.picker(try screen(name)), name)
        }
        XCTAssertFalse(GrokScreen.idle(try screen("agy-idle")))
        XCTAssertFalse(CursorScreen.idle(try screen("agy-idle")))
    }
}

final class AntigravityDefaultsTests: KoreanMessagesTestCase {
    func testRestoresOnlyTheModelKey() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        func write(_ object: [String: Any]) throws { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url) }
        try write(["model": "Gemini 3.8 Flash (High)", "theme": "dark"])
        let before = try Data(contentsOf: url)
        try write(["model": "Gemini 3.7 Flash (Medium)", "theme": "dark"])
        XCTAssertEqual(AntigravityDefaults(url: url).restore(to: before), .restored)
        XCTAssertEqual(try Data(contentsOf: url), before)
        try write(["model": "Gemini 3.7 Flash (Medium)", "theme": "light"])
        XCTAssertEqual(AntigravityDefaults(url: url).restore(to: before), .restored)
        let now = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(now["model"] as? String, "Gemini 3.8 Flash (High)")
        XCTAssertEqual(now["theme"] as? String, "light", "Other keys unchanged")
    }

    func testRemovesTheKeyWhenItWasAbsentBefore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: ["theme": "dark"], options: [.sortedKeys]).write(to: url)
        let before = try Data(contentsOf: url)
        try JSONSerialization.data(withJSONObject: ["theme": "dark", "model": "X"], options: [.sortedKeys]).write(to: url)
        XCTAssertEqual(AntigravityDefaults(url: url).restore(to: before), .restored)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
}

/// Fakes the agy input line and `/model` picker.
final class FakeAgy: TerminalIO {
    struct Model { let name: String; let efforts: [String]; var effort: Int }
    var models = [Model(name: "Gemini 3.8 Flash", efforts: ["low", "medium", "high"], effort: 2),
                  Model(name: "Gemini 3.7 Flash", efforts: ["medium", "high"], effort: 0),
                  Model(name: "GPT-OSS 120B (Medium)", efforts: [], effort: 0)]
    var current = 0
    var picker = false
    var cursor = 0
    var input = ""
    var busy = false
    var echoes: [String] = []     // the replies below `> /model`
    var typed: [String] = []
    var presses: [Key] = []
    let configURL: URL
    var wraps = false

    init(configURL: URL) { self.configURL = configURL }

    func type(_ text: String) throws { typed.append(text); if !picker { input += text } }

    func press(_ key: Key) throws {
        presses.append(key)
        if !picker {
            if key == .enter {
                if input == "/model" { picker = true; cursor = current; echoes.append("") }
                input = ""
            } else if key == .backspace, !input.isEmpty { input.removeLast() }
            return
        }
        switch key {
        case .up: cursor = max(0, cursor - 1)
        case .down: cursor = min(models.count - 1, cursor + 1)
        case .left, .right:
            let m = models[cursor]
            guard !m.efforts.isEmpty else { return }
            let step = key == .right ? 1 : -1
            let next = models[cursor].effort + step
            models[cursor].effort = wraps ? (next + m.efforts.count) % m.efforts.count : min(max(next, 0), m.efforts.count - 1)
        case .escape: picker = false; echoes[echoes.count - 1] = "Exited /model command"
        case .enter:
            current = cursor
            picker = false
            let m = models[current]
            echoes[echoes.count - 1] = "Model set to \(m.name)" + (m.efforts.isEmpty ? "" : " (\(m.efforts[m.effort].capitalized))")
            let object: [String: Any] = ["model": echoes.last!.replacingOccurrences(of: "Model set to ", with: ""), "theme": "dark"]
            try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: configURL)
        default: break
        }
    }

    func screen() -> [String]? {
        let rule = String(repeating: "─", count: 60)
        if picker {
            var lines = ["Switch Model", "", "  Search:", " " + String(repeating: "─", count: 20), ""]
            for (index, m) in models.enumerated() { lines.append((index == cursor ? "> " : "  ") + m.name + (index == current ? "      (current)" : "")) }
            lines.append("")
            let m = models[cursor]
            if !m.efforts.isEmpty {
                // Dots are spaced 14 columns apart per level, names are centered below the dot.
                var dots = Array("  Effort  ◂ ")
                var names = Array(String(repeating: " ", count: dots.count))
                for (i, e) in m.efforts.enumerated() {
                    dots += Array(i == m.effort ? "◉" : "●")
                    names += Array(e)
                    if i < m.efforts.count - 1 { dots += Array(String(repeating: "━", count: 14)); names += Array(String(repeating: " ", count: 14 - e.count + 0)) }
                }
                lines.append(String(dots) + " ▸")
                lines.append(String(names))
                // Align so the name is in the same column as the dot (dot position = name start column + 0).
            }
            lines += ["", "Keyboard: ↑/↓ Navigate  ←/→ Effort  enter Select  esc Go Back"]
            return lines
        }
        var lines = echoes.flatMap { ["> /model", "  ⎿  \($0)"] }
        if busy { lines += ["⣽  Working..."] }
        lines += [rule, ">" + (input.isEmpty ? "" : " " + input), rule, busy ? "esc to cancel" : "? for shortcuts        \(models[current].name)"]
        return lines
    }
}

final class AntigravityDriverTests: KoreanMessagesTestCase {
    private var url: URL!
    private var original = Data()

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("agy-driver-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["model": "Gemini 3.8 Flash (High)", "theme": "dark"], options: [.sortedKeys]).write(to: url)
        original = try Data(contentsOf: url)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    private func driver(_ io: FakeAgy, keepDefaults: Bool = true) -> AntigravityDriver {
        AntigravityDriver(io: io, sleep: { _ in }, defaults: AntigravityDefaults(url: url), keepDefaults: keepDefaults)
    }

    func testSwitchesModelAndEffortThenRestoresTheDefault() throws {
        let io = FakeAgy(configURL: url)
        let outcome = try driver(io).apply(AgentPreset(model: "Gemini 3.7 Flash", effort: "medium"))
        XCTAssertEqual(outcome.confirmations, ["Model set to Gemini 3.7 Flash (Medium)"])
        XCTAssertEqual(io.models[io.current].name, "Gemini 3.7 Flash")
        XCTAssertEqual(try Data(contentsOf: url), original, "The new-session default must stay as is")
    }

    func testMovesTheSliderBothWaysAndNeverWrapsAround() throws {
        let io = FakeAgy(configURL: url)
        io.wraps = true      // Even a slider that wraps from the end to the other side (like claude) is not pressed further at the end
        _ = try driver(io).apply(AgentPreset(model: "Gemini 3.8 Flash", effort: "low"))
        XCTAssertEqual(io.models[0].effort, 0)
        XCTAssertEqual(io.presses.filter { $0 == .left || $0 == .right }.count, 2)
    }

    func testUnknownModelAndEffortAreRefusedAndThePickerIsClosed() {
        let a = FakeAgy(configURL: url)
        XCTAssertThrowsError(try driver(a).apply(AgentPreset(model: "No Such", effort: "high"))) {
            XCTAssertEqual("\($0)", "antigravity 모델 목록에 'No Such'이(가) 없습니다. 가능한 값: Gemini 3.8 Flash, Gemini 3.7 Flash, GPT-OSS 120B (Medium)",
                           "The refusal names the models the picker offers, so the preset can be fixed without opening the picker")
        }
        XCTAssertFalse(a.picker)
        XCTAssertEqual(a.current, 0)
        let b = FakeAgy(configURL: url)
        XCTAssertThrowsError(try driver(b).apply(AgentPreset(model: "Gemini 3.7 Flash", effort: "low")))
        XCTAssertFalse(b.picker)
        XCTAssertEqual(try? Data(contentsOf: url), original)
    }

    func testModelWithoutEffortSliderJustSelects() throws {
        let io = FakeAgy(configURL: url)
        let outcome = try driver(io).apply(AgentPreset(model: "GPT-OSS 120B (Medium)", effort: "high"))
        XCTAssertEqual(outcome.confirmations, ["Model set to GPT-OSS 120B (Medium)"])
    }

    func testRefusesWithADraftOrWhileWorking() {
        let draft = FakeAgy(configURL: url)
        draft.input = "쓰던 글"
        XCTAssertThrowsError(try driver(draft).apply(AgentPreset(model: "Gemini 3.8 Flash", effort: "low")))
        XCTAssertEqual(draft.typed, [])
        let busy = FakeAgy(configURL: url)
        busy.busy = true
        XCTAssertThrowsError(try driver(busy).apply(AgentPreset(model: "Gemini 3.8 Flash", effort: "low")))
        XCTAssertEqual(busy.typed, [])
    }

    func testStepsEffortAndStopsAtTheEnds() throws {
        let io = FakeAgy(configURL: url)
        io.wraps = true
        XCTAssertThrowsError(try driver(io).stepEffort(up: true)) { XCTAssertTrue(($0 as? SlashCommandError)?.nothingToDo == true) }
        XCTAssertFalse(io.picker, "At the last step, closes the picker and changes nothing")
        XCTAssertEqual(io.models[0].effort, 2)
        XCTAssertEqual(try driver(io).stepEffort(up: false).confirmations, ["Model set to Gemini 3.8 Flash (Medium)"])
        XCTAssertEqual(try driver(io).stepEffort(up: false).confirmations, ["Model set to Gemini 3.8 Flash (Low)"])
        XCTAssertThrowsError(try driver(io).stepEffort(up: false)) { XCTAssertTrue(($0 as? SlashCommandError)?.nothingToDo == true) }
    }

    func testSummaryAndSlotForAntigravity() throws {
        let target = Target(host: .orca(handle: "h"), agent: .antigravity, label: "t")
        let result = SwitchResult(target: target, slotName: "", preset: AgentPreset(model: "x", effort: "high"),
                                  warning: nil, confirmations: ["Model set to Gemini 3.7 Flash (Medium)"], pendingRestore: nil)
        XCTAssertEqual(result.summary, "Gemini 3.7 Flash · Medium")
        XCTAssertEqual(AgentProcesses.agent(forCommandLine: "agy"), .antigravity)
        XCTAssertEqual(AgentProcesses.agent(forCommandLine: "/Users/x/.local/bin/cursor-agent --use-system-ca /x/index.js"), .cursor)
        XCTAssertEqual(AgentProcesses.agent(forCommandLine: "grok"), .grok)
        let slot = Slot(antigravity: AgentPreset(model: "Gemini 3.8 Flash", effort: "high"))
        XCTAssertEqual(try JSONDecoder().decode(Slot.self, from: JSONEncoder().encode(slot)), slot)
    }
}

// MARK: - opencode

final class OpenCodeScreenTests: KoreanMessagesTestCase {
    func testPlaceholderExampleVariesByVersion() {
        // The idle screen of 2.0.25 (measured 2026-10-11): the example inside the quotes differs from 1.18.35.
        let two = ["  ┃", "  ┃  Ask anything… \"Fix a TODO in the codebase\"", "  ┃", "  ┃  Build · Exo Free OpenCode Zen",
                   "  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀", "  …/initial-2:yohangwak/real-device-fixes   shift+tab agents  ctrl+p commands"]
        XCTAssertTrue(OpenCodeScreen.idle(two))
        XCTAssertEqual(OpenCodeScreen.draft(two), "")
        XCTAssertEqual(OpenCodeScreen.status(two)?.model, "Exo Free OpenCode Zen")
        XCTAssertNil(OpenCodeScreen.status(two)?.variant)
        XCTAssertTrue(OpenCodeScreen.isPlaceholder("Ask anything… \"Fix broken tests\""))
        XCTAssertFalse(OpenCodeScreen.isPlaceholder("Ask anything about the tests"), "Draft text")
    }

    struct Fixture: Decodable { let tail: [String] }

    func screen(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tail
    }

    // The model dialog of 2.0.25 (2026-10-12).
    func testFilteredRowsOfVersionTwo() throws {
        let similar = try XCTUnwrap(OpenCodeScreen.dialog(try screen("oc2-similar-names")))
        XCTAssertEqual(similar.search, "GLM-5.3 OpenCode Go")
        XCTAssertEqual(similar.rows.map(\.text), ["GLM-5.3-Flash OpenCode Go", "GLM-5.3 OpenCode Go"], "Similar names come first · the bottom hint line is not a row")
        let same = try XCTUnwrap(OpenCodeScreen.dialog(try screen("oc2-same-name")))
        XCTAssertEqual(same.rows.map(\.text), ["LongCat 2.5 Preview Free OpenCode Zen", "LongCat 2.5 Preview Free OpenCode Go"])
    }

    func testOneProviderDialogHasNoProviderColumn() throws {
        let none = try XCTUnwrap(OpenCodeScreen.dialog(try screen("oc2-one-provider-none")))
        XCTAssertEqual(none.search, "Big Pickle OpenCode Zen")
        XCTAssertEqual(none.rows, [], "`No results found` is not a row")
        let name = try XCTUnwrap(OpenCodeScreen.dialog(try screen("oc2-one-provider-name")))
        XCTAssertEqual(name.rows, [OpenCodeScreen.Row(text: "Big Pickle", current: true)], "The name without the value column (Free) and the hint line")
        XCTAssertEqual(OpenCodeScreen.status(try screen("oc2-one-provider-name"))?.model, "Big Pickle OpenCode Zen")
    }

    func testDialogFooters() {
        XCTAssertTrue(OpenCodeScreen.isDialogFooter("Connect provider ctrl+a"))
        XCTAssertTrue(OpenCodeScreen.isDialogFooter("Connect an integration ctrl+a  Favorite ctrl+f"))
        XCTAssertTrue(OpenCodeScreen.isDialogFooter("View all integrations ctrl+a"))
        XCTAssertFalse(OpenCodeScreen.isDialogFooter("Connect Pro OpenCode Go"))
    }

    func testIdleDraftAndWorking() throws {
        XCTAssertTrue(OpenCodeScreen.idle(try screen("oc-idle")), "First screen")
        XCTAssertTrue(OpenCodeScreen.idle(try screen("oc-after-work")), "After a conversation")
        XCTAssertTrue(OpenCodeScreen.idle(try screen("oc-session-idle")))
        XCTAssertEqual(OpenCodeScreen.draft(try screen("oc-idle")), "", "A placeholder is not draft text")
        let draft = try screen("oc-draft")
        XCTAssertEqual(OpenCodeScreen.draft(draft), "abc")
        XCTAssertFalse(OpenCodeScreen.idle(draft))
        let working = try screen("oc-working")
        XCTAssertEqual(OpenCodeScreen.draft(working), "")
        XCTAssertFalse(OpenCodeScreen.idle(working), "Not sent while working (esc interrupt)")
    }

    func testStatusLineHasModelAndVariantWithoutTheBranchOnTheRight() throws {
        let status = try XCTUnwrap(OpenCodeScreen.status(try screen("oc-idle")))
        XCTAssertEqual(status.model, "GLM-5.3-Flash OpenCode Go")
        XCTAssertEqual(status.variant, "high")
        let session = try XCTUnwrap(OpenCodeScreen.status(try screen("oc-session-idle")))
        XCTAssertEqual(session.variant, "high", "The branch name at the right end does not get mixed into the variant")
    }

    func testDialogsAreReadEvenWhenConversationTextOverlapsOnTheLeft() throws {
        let models = try XCTUnwrap(OpenCodeScreen.dialog(try screen("oc-models-filtered")))
        XCTAssertEqual(models.title, "Select model")
        XCTAssertEqual(models.search, "GLM-5.3")
        XCTAssertEqual(models.rows.first?.text, "GLM-5.3-Flash OpenCode Go", "The (Favorite) marker is stripped")
        XCTAssertEqual(models.rows.first?.current, true)
        XCTAssertEqual(models.rows.count, 6)
        let variants = try XCTUnwrap(OpenCodeScreen.dialog(try screen("oc-variants")))
        XCTAssertEqual(variants.rows.map(\.text), ["Default", "low", "high", "max"])
        XCTAssertEqual(variants.rows.firstIndex(where: \.current), 2)
        // In a conversation: line numbers and conversation text overlap to the left of the header and a margin line is mixed in (real screen).
        let session = try XCTUnwrap(OpenCodeScreen.dialog(try screen("oc-session-variants")))
        XCTAssertEqual(session.title, "Select variant")
        XCTAssertEqual(session.rows.map(\.text), ["Default", "low", "high", "max"])
        XCTAssertFalse(OpenCodeScreen.idle(try screen("oc-session-variants")), "A dialog is open")
    }

    func testOtherAgentsAreNotOpenCode() throws {
        for name in ["claude-idle", "codex-idle", "grok-idle", "cursor-idle", "agy-idle"] {
            XCTAssertFalse(OpenCodeScreen.idle(try screen(name)), name)
            XCTAssertNil(OpenCodeScreen.dialog(try screen(name)), name)
        }
        XCTAssertFalse(AgyScreen.idle(try screen("oc-idle")))
        XCTAssertFalse(GrokScreen.idle(try screen("oc-idle")))
    }
}

final class OpenCodeDefaultsTests: KoreanMessagesTestCase {
    func testRestoresRecentAndVariantOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        func write(_ object: [String: Any]) throws { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url) }
        try write(["recent": [["modelID": "a"]], "favorite": [["modelID": "a"]], "variant": ["x/a": "high"]])
        let before = try Data(contentsOf: url)
        try write(["recent": [["modelID": "b"], ["modelID": "a"]], "favorite": [["modelID": "a"], ["modelID": "c"]], "variant": ["x/a": "low"]])
        XCTAssertEqual(OpenCodeDefaults(url: url).restore(to: before), .restored)
        let now = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((now["recent"] as? [[String: String]])?.count, 1)
        XCTAssertEqual((now["variant"] as? [String: String])?["x/a"], "high")
        XCTAssertEqual((now["favorite"] as? [Any])?.count, 2, "Favorites were changed separately by the user, so they are left as is")
    }
}

/// Fakes the opencode input box and `/models`·`/variants` dialogs.
final class FakeOpenCode: TerminalIO {
    struct Model { let name: String; let provider: String; let variants: [String]; var variant: String? }
    var models = [Model(name: "GLM-5.3-Flash", provider: "OpenCode Go", variants: ["Default", "low", "high", "max"], variant: "high"),
                  Model(name: "DeepSeek V4.1 Flash", provider: "OpenCode Go", variants: ["Default", "low", "high"], variant: nil),
                  Model(name: "Big Pickle", provider: "OpenCode Zen", variants: [], variant: nil),
                  Model(name: "GLM-5.3", provider: "OpenCode Go", variants: ["Default", "low", "high"], variant: "high"),
                  Model(name: "Big Pickle", provider: "OpenCode Go", variants: [], variant: nil),
                  Model(name: "Exo Free", provider: "OpenCode Zen", variants: [], variant: nil)]
    var current = 0
    enum Mode: Equatable { case idle, models, variants }
    var mode = Mode.idle
    var input = ""
    var search = ""
    var busy = false
    var typed: [String] = []
    var presses: [Key] = []
    var focused = true
    /// A model for which Default was chosen directly. A model running as Default because it has no saved variant has no `●` in the dialog (measured).
    var explicitDefault: Set<Int> = []
    let configURL: URL
    /// Dialog cursor (which one among the filtered rows). It is not visible as text.
    var cursor = 0
    /// Fakes a dialog where ↓ does not respond — a row different from the counted number is chosen.
    var ignoresDown = false
    /// opencode 2 with a single provider: only that provider's models exist, it filters by name only, and rows have no provider column.
    var onlyProvider: String?
    /// A "No variants available" notice is showing (it remains for a few seconds — in the fake, until turned off).
    var toast = false

    init(configURL: URL) { self.configURL = configURL }

    /// As in reality, it matches if the characters are present in order (`GLM-5.3 OpenCode Go` also matches `GLM-5.3-Flash OpenCode Go`).
    private func matches(_ text: String) -> Bool {
        var rest = Substring(text.lowercased())
        for character in search.lowercased() where character != " " {
            guard let at = rest.firstIndex(of: character) else { return false }
            rest = rest[rest.index(after: at)...]
        }
        return true
    }

    private var visibleModels: [Int] {
        models.indices.filter { index in
            if let onlyProvider { return models[index].provider == onlyProvider && matches(models[index].name) }
            return matches("\(models[index].name) \(models[index].provider)")
        }
    }

    private var visibleVariants: [String] {
        models[current].variants.filter { matches($0) }
    }

    func type(_ text: String) throws {
        typed.append(text)
        switch mode {
        case .idle: if focused { input += text }
        case .models, .variants:
            // If delete bytes (0x7F) are mixed in, it deletes one character at a time as in reality.
            for character in text {
                if String(character) == Key.backspace.bytes { if !search.isEmpty { search.removeLast() } } else { search.append(character) }
            }
            cursor = 0
        }
    }

    func press(_ key: Key) throws {
        presses.append(key)
        switch (mode, key) {
        case (.idle, .enter):
            if input == "/models" { mode = .models; search = ""; cursor = 0 }
            else if input == "/variants" {
                // Model without a variant: a notice appears instead of a dialog and it returns to the input box (measured on 2.0.25).
                if models[current].variants.isEmpty { toast = true } else { mode = .variants; search = ""; cursor = 0 }
            }
            input = ""
        case (.idle, .backspace): if !input.isEmpty { input.removeLast() }
        case (_, .escape) where mode != .idle: mode = .idle
        case (_, .backspace): if !search.isEmpty { search.removeLast(); cursor = 0 }
        case (.models, .down): if !ignoresDown { cursor = min(cursor + 1, max(0, visibleModels.count - 1)) }
        case (.variants, .down): if !ignoresDown { cursor = min(cursor + 1, max(0, visibleVariants.count - 1)) }
        case (.models, .enter):
            guard visibleModels.indices.contains(cursor) else { return }
            current = visibleModels[cursor]
            mode = .idle
            // If there is no remembered variant and the model has variants, the dialog follows.
            if models[current].variant == nil, !models[current].variants.isEmpty { mode = .variants; search = ""; cursor = 0 }
            save()
        case (.variants, .enter):
            guard visibleVariants.indices.contains(cursor) else { return }
            let first = visibleVariants[cursor]
            models[current].variant = first == "Default" ? nil : first
            if first == "Default" { explicitDefault.insert(current) } else { explicitDefault.remove(current) }
            mode = .idle
            save()
        default: break
        }
    }

    private func save() {
        let m = models[current]
        let object: [String: Any] = ["recent": [["modelID": m.name]], "favorite": [["modelID": "GLM"]], "variant": [m.name: m.variant ?? "default"]]
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: configURL)
    }

    func screen() -> [String]? {
        let m = models[current]
        let box = ["  ┃", "  ┃  " + (input.isEmpty ? "Ask anything… \"Fix broken tests\"" : input), "  ┃",
                   "  ┃  Build · \(m.name) \(m.provider)" + (m.variant.map { " · \($0)" } ?? "") + "                  main",
                   "  ╹" + String(repeating: "▀", count: 60),
                   busy ? "   ⬝■■■■■■⬝  esc interrupt            tab agents  ctrl+p commands" : "                              tab agents  ctrl+p commands",
                   "  ~/work/repo:main"]
        func overlay(_ title: String, _ rows: [String], footer: String? = nil) -> [String] {
            var lines = ["    ✓ earlier output", "                      \(title)                       esc", "", "                      \(search.isEmpty ? "Search" : search)", ""]
            lines += (rows.isEmpty && footer != nil ? ["  No results found"] : rows).map { "                      " + $0 }
            if let footer { lines += ["", "                        " + footer] }
            lines += ["", "    ✓ more output"]
            return lines + box
        }
        let notice = toast ? ["                  ┃  No variants available                          x  ┃",
                              "                  ┃  The current model does not support any variants.  ┃"] : []
        switch mode {
        case .idle: return notice + ["    ✓ earlier output"] + box
        case .models:
            let single = onlyProvider != nil
            return overlay("Select model", visibleModels.map { (($0 == current ? "● " : "  ") + models[$0].name + (single ? "" : "           " + models[$0].provider)) },
                           footer: single ? "View all integrations ctrl+a" : "Connect an integration ctrl+a  Favorite ctrl+f")
        case .variants:
            let marked = models[current].variant ?? (explicitDefault.contains(current) ? "Default" : nil)
            return notice + overlay("Select variant", visibleVariants.map { (marked == $0 ? "● " : "  ") + $0 })
        }
    }
}

final class OpenCodeDriverTests: KoreanMessagesTestCase {
    private var url: URL!
    private var original = Data()

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("oc-driver-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["recent": [["modelID": "GLM-5.3-Flash"]], "favorite": [["modelID": "GLM"]], "variant": ["GLM-5.3-Flash": "high"]],
                                   options: [.sortedKeys]).write(to: url)
        original = try Data(contentsOf: url)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    private func driver(_ io: FakeOpenCode, keepDefaults: Bool = true) -> OpenCodeDriver {
        OpenCodeDriver(io: io, sleep: { _ in }, defaults: OpenCodeDefaults(url: url), keepDefaults: keepDefaults)
    }

    func testAModelWithoutVariantsIsSwitchedAndTheEffortIsReportedAsNotSet() throws {
        // Measured 2026-10-12 (Big Pickle): before, it changed the model and still reported failure, saying the Select variant dialog did not open.
        let io = FakeOpenCode(configURL: url)
        let outcome = try driver(io).apply(AgentPreset(model: "Big Pickle OpenCode Zen", effort: "high"))
        XCTAssertEqual(io.models[io.current].name, "Big Pickle")
        XCTAssertEqual(io.mode, .idle)
        XCTAssertEqual(outcome.confirmations, ["Using Big Pickle OpenCode Zen"])
        XCTAssertEqual(outcome.warning, loc("This OpenCode model has no variants, so the effort (%@) was not set.", "high"))
        XCTAssertEqual(try Data(contentsOf: url), original, "The defaults file stays as is")
    }

    func testEffortOnAModelWithoutVariantsSaysSoAndChangesNothing() throws {
        let io = FakeOpenCode(configURL: url)
        io.current = 2   // Big Pickle
        XCTAssertThrowsError(try driver(io).stepEffort(up: true)) { error in
            XCTAssertTrue((error as? SlashCommandError)?.nothingToDo == true)
            XCTAssertEqual("\(error)", loc("This OpenCode model has no effort levels (it has no variants)."))
        }
        XCTAssertEqual(io.mode, .idle)
        XCTAssertEqual(io.input, "", "No text left in the input box")
    }

    func testAnOldNoVariantsNoticeDoesNotHideARealVariantDialog() throws {
        // The notice stays for a few seconds. In the meantime, pressing effort on a model with variants sees the dialog, not the notice.
        let io = FakeOpenCode(configURL: url)
        io.toast = true
        _ = try driver(io).stepEffort(up: false)
        XCTAssertEqual(io.models[0].variant, "low")
        XCTAssertEqual(io.mode, .idle)
        // Pressing on a model without a variant while the notice remains: the dialog never opens → report that there is none.
        io.current = 2
        XCTAssertThrowsError(try driver(io).stepEffort(up: true)) { XCTAssertTrue(($0 as? SlashCommandError)?.nothingToDo == true) }
    }

    func testNoVariantsNoticeOnARealScreen() throws {
        struct Fixture: Decodable { let tail: [String] }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "oc2-no-variants", withExtension: "json", subdirectory: "Fixtures"))
        let real = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tail
        XCTAssertTrue(OpenCodeScreen.noVariants(real))
        XCTAssertTrue(OpenCodeScreen.idle(real), "Even with the notice showing, the input box is empty")
        XCTAssertFalse(OpenCodeScreen.noVariants(["  some reply says No variants available here", "  ┃  Ask anything"]), "The same text in the conversation")
    }

    func testSwitchesModelThenVariantAndRestoresTheDefault() throws {
        let io = FakeOpenCode(configURL: url)
        let outcome = try driver(io).apply(AgentPreset(model: "DeepSeek V4.1 Flash OpenCode Go", effort: "low"))
        XCTAssertEqual(outcome.confirmations, ["Using DeepSeek V4.1 Flash OpenCode Go · low"])
        XCTAssertEqual(io.models[io.current].name, "DeepSeek V4.1 Flash")
        XCTAssertEqual(try? Data(contentsOf: url), original, "The new-session default must stay as is")
    }

    func testOnlyVariantChangeSkipsTheModelDialog() throws {
        let io = FakeOpenCode(configURL: url)
        _ = try driver(io).apply(AgentPreset(model: "GLM-5.3-Flash OpenCode Go", effort: "max"))
        XCTAssertEqual(io.typed.first, "/variants", "If it is already that model, the model dialog is not opened")
        XCTAssertEqual(io.models[0].variant, "max")
    }

    func testRefusesAWrongTopRowAndClosesTheDialog() {
        let io = FakeOpenCode(configURL: url)
        XCTAssertThrowsError(try driver(io).apply(AgentPreset(model: "No Such Model", effort: "high")))
        XCTAssertEqual(io.mode, .idle)
        XCTAssertEqual(io.current, 0)
        XCTAssertEqual(io.input, "")
        XCTAssertEqual(try? Data(contentsOf: url), original)
    }

    func testPicksTheExactRowBelowASimilarName() throws {
        // Measured on 2.0.25: typing `GLM-5.3 OpenCode Go` puts `GLM-5.3-Flash` on top and `GLM-5.3` second.
        let io = FakeOpenCode(configURL: url)
        let outcome = try driver(io).apply(AgentPreset(model: "GLM-5.3 OpenCode Go", effort: "high"))
        XCTAssertEqual(outcome.confirmations, ["Using GLM-5.3 OpenCode Go · high"])
        XCTAssertEqual(io.current, 3)
        XCTAssertEqual(io.presses.filter { $0 == .down }.count, 1)
        XCTAssertEqual(try? Data(contentsOf: url), original)
    }

    func testSameNameUnderTwoProviders() throws {
        let io = FakeOpenCode(configURL: url)
        _ = try driver(io).apply(AgentPreset(model: "Big Pickle OpenCode Go", effort: ""))
        XCTAssertEqual(io.current, 4)
        _ = try driver(io).apply(AgentPreset(model: "Big Pickle OpenCode Zen", effort: ""))
        XCTAssertEqual(io.current, 2)
    }

    func testFailsWhenAnotherRowWasChosen() {
        // Rows are chosen by counting, so confirm the result with the model line — if ↓ does not respond, the top row gets chosen.
        let io = FakeOpenCode(configURL: url)
        io.ignoresDown = true
        io.models[0].variant = nil     // After choosing, the variant dialog appears, so the model line is confirmed only at the end
        XCTAssertThrowsError(try driver(io).apply(AgentPreset(model: "GLM-5.3 OpenCode Go", effort: "high"))) { error in
            XCTAssertEqual((error as? SlashCommandError)?.message, loc("The OpenCode model line did not change to '%@'.", "GLM-5.3 OpenCode Go"))
        }
        XCTAssertEqual(io.mode, .idle)
        XCTAssertEqual(try? Data(contentsOf: url), original)
    }

    func testOneProviderIsFilteredByNameOnly() throws {
        let io = FakeOpenCode(configURL: url)
        io.onlyProvider = "OpenCode Go"
        let outcome = try driver(io).apply(AgentPreset(model: "DeepSeek V4.1 Flash OpenCode Go", effort: "low"))
        XCTAssertEqual(outcome.confirmations, ["Using DeepSeek V4.1 Flash OpenCode Go · low"])
        _ = try driver(io).apply(AgentPreset(model: "GLM-5.3  OpenCode Go", effort: "high"))
        XCTAssertEqual(io.current, 3, "Even with two spaces between words · the row below the similar name")
        XCTAssertEqual(io.mode, .idle)
        XCTAssertEqual(try? Data(contentsOf: url), original)
    }

    func testOneProviderRefusesAModelOfAnotherProvider() {
        // A provider with the same name but fewer presets is not the only provider in that session.
        let io = FakeOpenCode(configURL: url)
        io.onlyProvider = "OpenCode Go"
        XCTAssertThrowsError(try driver(io).apply(AgentPreset(model: "Big Pickle OpenCode Zen", effort: "")))
        XCTAssertEqual(io.current, 0)
        XCTAssertEqual(io.mode, .idle)
        XCTAssertFalse(io.presses.dropFirst().contains(.enter), "Nothing is confirmed except the Enter that opened the dialog")
        XCTAssertThrowsError(try driver(io).apply(AgentPreset(model: "GLM OpenCode Go", effort: "")), "A preset with only part of the name")
        XCTAssertEqual(io.current, 0)
    }

    func testOneProviderDoesNotTakeModelNameWordsForTheProvider() {
        // PR #24 review: when the current model is `Exo Free OpenCode Zen`, the trailing `Free OpenCode Zen` of the nonexistent preset `Big Pickle Free OpenCode Zen` is
        // the same as the end of the current model line. Treating that as the provider would choose `Big Pickle`, change the session model, and only then fail.
        let io = FakeOpenCode(configURL: url)
        io.onlyProvider = "OpenCode Zen"
        io.current = 5
        XCTAssertThrowsError(try driver(io).apply(AgentPreset(model: "Big Pickle Free OpenCode Zen", effort: "")))
        XCTAssertEqual(io.current, 5, "The session's model must stay as is")
        XCTAssertEqual(io.mode, .idle)
        XCTAssertEqual(io.presses.filter { $0 == .enter }.count, 1, "Only the Enter that opened the dialog")
        // Positive control: in the same state, a model that exists is chosen.
        XCTAssertNoThrow(try driver(io).apply(AgentPreset(model: "Big Pickle OpenCode Zen", effort: "")))
        XCTAssertEqual(io.current, 2)
    }

    func testUnknownVariantClosesTheDialogAndRestores() {
        let io = FakeOpenCode(configURL: url)
        XCTAssertThrowsError(try driver(io).apply(AgentPreset(model: "DeepSeek V4.1 Flash OpenCode Go", effort: "max")))
        XCTAssertEqual(io.mode, .idle)
        XCTAssertEqual(try? Data(contentsOf: url), original)
    }

    func testClosesTheAutoOpenedVariantDialogWhenThePresetHasNoVariant() throws {
        let io = FakeOpenCode(configURL: url)
        _ = try driver(io).apply(AgentPreset(model: "DeepSeek V4.1 Flash OpenCode Go", effort: ""))
        XCTAssertEqual(io.mode, .idle)
    }

    func testRefusesWhenTypedTextDoesNotLand() {
        let io = FakeOpenCode(configURL: url)
        io.focused = false     // A state actually encountered: after the conversation ends the input box does not receive characters
        XCTAssertThrowsError(try driver(io).apply(AgentPreset(model: "DeepSeek V4.1 Flash OpenCode Go", effort: "low")))
        XCTAssertEqual(io.mode, .idle)
        XCTAssertFalse(io.presses.contains(.enter), "If no characters are visible, Enter is not sent")
    }

    func testRefusesWithADraftOrWhileWorking() {
        let draft = FakeOpenCode(configURL: url)
        draft.input = "쓰던 글"
        XCTAssertThrowsError(try driver(draft).apply(AgentPreset(model: "GLM-5.3-Flash OpenCode Go", effort: "low")))
        XCTAssertEqual(draft.typed, [])
        let busy = FakeOpenCode(configURL: url)
        busy.busy = true
        XCTAssertThrowsError(try driver(busy).apply(AgentPreset(model: "GLM-5.3-Flash OpenCode Go", effort: "low")))
        XCTAssertEqual(busy.typed, [])
    }

    func testStepsVariantUpAndDownAndStopsAtTheEnds() throws {
        let io = FakeOpenCode(configURL: url)
        XCTAssertEqual(try driver(io).stepEffort(up: true).confirmations, ["Using GLM-5.3-Flash OpenCode Go · max"])
        XCTAssertThrowsError(try driver(io).stepEffort(up: true)) { XCTAssertTrue(($0 as? SlashCommandError)?.nothingToDo == true) }
        XCTAssertEqual(io.mode, .idle)
        for _ in 0..<3 { _ = try driver(io).stepEffort(up: false) }
        XCTAssertNil(io.models[0].variant, "Default")
        XCTAssertThrowsError(try driver(io).stepEffort(up: false)) { XCTAssertTrue(($0 as? SlashCommandError)?.nothingToDo == true) }
    }

    func testSummaryAndDetection() {
        let target = Target(host: .orca(handle: "h"), agent: .opencode, label: "t")
        let result = SwitchResult(target: target, slotName: "", preset: AgentPreset(model: "x", effort: "high"),
                                  warning: nil, confirmations: ["Using GLM-5.3-Flash OpenCode Go · high"], pendingRestore: nil)
        XCTAssertEqual(result.summary, "GLM-5.3-Flash OpenCode Go · high")
        XCTAssertEqual(AgentProcesses.agent(forCommandLine: "opencode"), .opencode)
        XCTAssertEqual(try? JSONDecoder().decode(Slot.self, from: JSONEncoder().encode(Slot(opencode: AgentPreset(model: "m", effort: "e")))).opencode?.model, "m")
    }
}

// MARK: - From the PR #9 review

/// A terminal whose screen cannot be read after a few confirmations (Enter) have been sent — imitates a Ghostty that lost focus or a dropped connection.
final class GoesBlind: TerminalIO {
    let base: TerminalIO
    let afterEnters: Int
    private var enters = 0

    init(_ base: TerminalIO, afterEnters: Int) {
        self.base = base
        self.afterEnters = afterEnters
    }

    func type(_ text: String) throws { try base.type(text) }
    func press(_ key: Key) throws {
        try base.press(key)
        if key == .enter { enters += 1 }
    }
    func screen() -> [String]? { enters >= afterEnters ? nil : base.screen() }
}

/// Even if the screen cannot be read after confirming, the new-session default must return to its pre-switch value (the agent has already written the file).
final class DefaultsRestoredWhenTheScreenGoesBlindTests: KoreanMessagesTestCase {
    private func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("blind-\(UUID().uuidString)-\(name)")
    }

    func testGrok() throws {
        let url = temp("grok.toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try "[ui]\nyolo = false\n".write(to: url, atomically: true, encoding: .utf8)
        let fake = FakeGrok(configURL: url)
        let models = GrokModels(models: [.init(id: "grok-4.7", name: "Grok 4.7", efforts: ["low", "medium", "high", "xhigh"])])
        let driver = GrokDriver(io: GoesBlind(fake, afterEnters: 1), sleep: { _ in }, models: models, defaults: GrokDefaults(url: url), keepDefaults: true)
        XCTAssertThrowsError(try driver.apply(AgentPreset(model: "grok-4.7", effort: "xhigh")))
        XCTAssertEqual(fake.label, "Grok 4.7 (xhigh)", "Positive control: the agent really changed and wrote the file")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[ui]\nyolo = false\n")
    }

    func testCursor() throws {
        let url = temp("cursor.json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: ["version": 1, "model": ["modelId": "Grok 4.7"], "selectedModel": ["modelId": "Grok 4.7"],
                                                    "modelSelectionHistory": ["Grok 4.7"], "modelParameters": ["Grok 4.7": ["High"]], "hints": true],
                                   options: [.prettyPrinted, .sortedKeys]).write(to: url)
        let original = try Data(contentsOf: url)
        let fake = FakeCursor(configURL: url)
        let driver = CursorDriver(io: GoesBlind(fake, afterEnters: 2), sleep: { _ in }, defaults: CursorDefaults(url: url), keepDefaults: true)
        XCTAssertThrowsError(try driver.apply(AgentPreset(model: "Claude Opus 5.5", effort: "medium")))
        XCTAssertEqual(fake.models[fake.current].name, "Claude Opus 5.5", "Positive control")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testAntigravity() throws {
        let url = temp("agy.json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: ["model": "Gemini 3.8 Flash (High)", "theme": "dark"], options: [.sortedKeys]).write(to: url)
        let original = try Data(contentsOf: url)
        let fake = FakeAgy(configURL: url)
        let driver = AntigravityDriver(io: GoesBlind(fake, afterEnters: 2), sleep: { _ in }, defaults: AntigravityDefaults(url: url), keepDefaults: true)
        XCTAssertThrowsError(try driver.apply(AgentPreset(model: "Gemini 3.7 Flash", effort: "medium")))
        XCTAssertEqual(fake.current, 1, "Positive control")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testOpenCode() throws {
        let url = temp("oc.json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: ["recent": [["modelID": "GLM-5.3-Flash"]], "favorite": [["modelID": "GLM"]], "variant": ["GLM-5.3-Flash": "high"]],
                                   options: [.sortedKeys]).write(to: url)
        let original = try Data(contentsOf: url)
        let fake = FakeOpenCode(configURL: url)
        let driver = OpenCodeDriver(io: GoesBlind(fake, afterEnters: 2), sleep: { _ in }, defaults: OpenCodeDefaults(url: url), keepDefaults: true)
        XCTAssertThrowsError(try driver.apply(AgentPreset(model: "GLM-5.3-Flash OpenCode Go", effort: "max")))
        XCTAssertEqual(fake.models[0].variant, "max", "Positive control")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}

final class CursorEffortLabelTests: KoreanMessagesTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-label-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "model": ["modelId": "Grok 4.7"]], options: [.sortedKeys]).write(to: url)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    private func driver(_ io: FakeCursor) -> CursorDriver {
        CursorDriver(io: io, sleep: { _ in }, defaults: CursorDefaults(url: url), keepDefaults: true)
    }

    func testHighIsNotExtraHigh() throws {
        // Pressing preset high on a model that is currently Extra High must go down — it must not be left alone just because the word High is in it.
        let io = FakeCursor(configURL: url)
        io.models[1].effort = "Extra High"
        let outcome = try driver(io).apply(AgentPreset(model: "Grok 4.7", effort: "high"))
        XCTAssertEqual(io.models[1].effort, "High")
        XCTAssertEqual(outcome.confirmations, ["Using Grok 4.7 256K High"])
        XCTAssertTrue(io.presses.contains(.tab), "Opened parameter editing and matched")
        // The reverse direction too.
        _ = try driver(io).apply(AgentPreset(model: "Grok 4.7", effort: "xhigh"))
        XCTAssertEqual(io.models[1].effort, "Extra High")
    }

    func testStatusWithFastSuffixStillParses() {
        XCTAssertEqual(CursorScreen.parse(status: "Grok 4.7 256K Medium Fast").effort, "Medium")
        XCTAssertEqual(CursorScreen.parse(status: "Grok 4.7 256K Medium Fast").name, "Grok 4.7")
    }

    func testModelWithoutParametersIsSelectedWithoutAnEffort() throws {
        let io = FakeCursor(configURL: url)
        let outcome = try driver(io).apply(AgentPreset(model: "Auto", effort: "high"))
        XCTAssertEqual(io.models[io.current].name, "Auto")
        XCTAssertEqual(outcome.confirmations, ["Using Auto"])
        XCTAssertFalse(io.presses.contains(.tab), "Does not open editing on a row without parameters")
    }
}

final class LaunchSupportTests: KoreanMessagesTestCase {
    func testAgentsThatTakeAnIdNeverGetTheOnScreenName() {
        for agent in [Agent.cursor, .antigravity, .opencode] {
            XCTAssertNotNil(Launch.listing(agent: agent), agent.rawValue)
            let command = Launch.command(agent: agent, preset: AgentPreset(model: "GLM-5.3-Flash OpenCode Go", effort: "high"))
            XCTAssertFalse(command.contains("GLM-5.3-Flash OpenCode Go"), "The on-screen name is not passed to --model")
        }
        XCTAssertEqual(Launch.command(agent: .antigravity, preset: AgentPreset(model: "Gemini 3.8 Flash", effort: "high"), model: "gemini-3.8-flash-high", extra: ["-p"]),
                       ["agy", "--model", "gemini-3.8-flash-high", "-p"])
        XCTAssertEqual(Launch.command(agent: .opencode, preset: AgentPreset(model: "GLM-5.3-Flash OpenCode Go", effort: "Default"), model: "opencode-go/glm-5.3-flash"),
                       ["opencode", "--model", "opencode-go/glm-5.3-flash"])
    }

    /// Lines taken from the 2026-10-11 output of `cursor-agent models` (2026.10.01-e373342). The `Fast` lines end with zero-width characters.
    static let cursorListing = """
    Available models

    auto - Auto (default)
    gpt-5.3-codex-low - Codex 5.3 Low
    gpt-5.3-codex - Codex 5.3
    gpt-5.3-codex-high - Codex 5.3 High
    composer-2.5 - Composer 2.5
    composer-2.5-fast - Composer 2.5 Fast
    claude-opus-5-thinking-high - Claude Opus 5 1M Thinking
    claude-opus-5-low - Claude Opus 5 1M Low
    claude-opus-5-high - Claude Opus 5 1M
    claude-opus-5-thinking-xhigh - Claude Opus 5 1M Extra High Thinking
    claude-fable-5-thinking-high - Claude Fable 5 1M Thinking (NO ZDR)
    grok-4.7-medium - Grok 4.7  Medium
    grok-4.7-medium-fast - Grok 4.7  Medium Fast\u{200B}\u{200B}
    grok-4.7-high - Grok 4.7  High
    grok-4.7-high-fast - Grok 4.7  High Fast\u{200B}\u{200B}
    grok-4.7-xhigh - Grok 4.7  Extra High
    claude-opus-5-5-low - Claude Opus 5.5 1M Low
    claude-opus-5-5-medium - Claude Opus 5.5 1M
    claude-opus-5-5-medium-fast - Claude Opus 5.5 1M Fast
    claude-opus-5-5-high - Claude Opus 5.5 1M High
    claude-opus-5-5-xhigh - Claude Opus 5.5 1M Extra High
    gpt-5.5-none - GPT-5.5 1M None
    gpt-5.5-extra-high - GPT-5.5 1M Extra High
    claude-haiku-5-5-low - Claude Haiku 5.5 Low No Thinking
    claude-haiku-5-5-thinking-low - Claude Haiku 5.5 Low
    gemini-3.1-pro - Gemini 3.1 Pro

    Tip: use --model <id> (or /model <id> in interactive mode) to switch. Parameterized models also accept quoted overrides, e.g. --model 'claude-opus-4-8[context=1m,effort=high,fast=false]'.
    """

    func testCursorIdComesFromItsModelList() throws {
        func id(_ model: String, _ effort: String) throws -> String {
            try Launch.resolve(agent: .cursor, preset: AgentPreset(model: model, effort: effort), listing: Self.cursorListing).model
        }
        XCTAssertEqual(try id("Grok 4.7", "high"), "grok-4.7-high", "Fast lines are not chosen")
        XCTAssertEqual(try id("Grok 4.7", "xhigh"), "grok-4.7-xhigh", "Extra High is not High")
        XCTAssertEqual(try id("grok 4.7", "medium"), "grok-4.7-medium")
        // A line without a label is that model's default effort — it differs per model, so read it from the end of the id.
        XCTAssertEqual(try id("Claude Opus 5.5", "medium"), "claude-opus-5-5-medium")
        XCTAssertEqual(try id("Claude Opus 5.5", "high"), "claude-opus-5-5-high")
        XCTAssertEqual(try id("Claude Opus 5", "high"), "claude-opus-5-high", "The one without the Thinking marker comes first")
        XCTAssertEqual(try id("Claude Opus 5", "xhigh"), "claude-opus-5-thinking-xhigh", "If that effort exists only on the Thinking side, use that")
        XCTAssertEqual(try id("Claude Haiku 5.5", "low"), "claude-haiku-5-5-thinking-low", "'No Thinking' is also the non-default side")
        XCTAssertEqual(try id("Claude Fable 5", "high"), "claude-fable-5-thinking-high", "The tag (NO ZDR) is not part of the name")
        XCTAssertEqual(try id("GPT-5.5", "xhigh"), "gpt-5.5-extra-high")
        XCTAssertEqual(try id("GPT-5.5", "none"), "gpt-5.5-none")
        XCTAssertEqual(try id("Codex 5.3", "high"), "gpt-5.3-codex-high")
        // A model without effort only matches the model.
        XCTAssertEqual(try id("Auto", "high"), "auto")
        XCTAssertEqual(try id("Composer 2.5", "high"), "composer-2.5")
        XCTAssertEqual(try id("Gemini 3.1 Pro", "low"), "gemini-3.1-pro")
        XCTAssertThrowsError(try id("Grok 4.7", "max")) {
            XCTAssertEqual(($0 as? SlashCommandError)?.message, loc("Cursor '%@' has no effort '%@' (%@).", "Grok 4.7", "max", "Medium, High, Extra High"))
        }
        XCTAssertThrowsError(try id("Codex 5.3", "medium"), "A line with neither a label nor an id ending is not guessed to be medium")
        XCTAssertThrowsError(try id("Grok 9", "high")) {
            XCTAssertEqual(($0 as? SlashCommandError)?.message, loc("'%@' is not in the Cursor model list.", "Grok 9"))
        }
        XCTAssertEqual(Launch.command(agent: .cursor, preset: AgentPreset(model: "Grok 4.7", effort: "high"), model: "grok-4.7-high", extra: ["--yolo"]),
                       ["cursor-agent", "--model", "grok-4.7-high", "--yolo"])
        XCTAssertTrue(Launch.savesLaunchModelAsDefault(agent: .cursor))
        for agent in [Agent.claude, .codex, .grok, .antigravity, .opencode] { XCTAssertFalse(Launch.savesLaunchModelAsDefault(agent: agent), agent.rawValue) }
    }

    func testOpenCodeHelpTellsWhetherItTakesAModel() {
        // Help of 1.18.35.
        XCTAssertTrue(Launch.openCodeTakesModel(help: "Options:\n  -m, --model         model to use in the format of provider/model   [string]\n      --prompt        prompt to use"))
        // Help of 2.0.25: the launch options have no --model.
        let two = "FLAGS\n  --standalone            Run with a private server\n  --session, -s string    Session ID to continue\n  --prompt string         Prompt to use\n\nSUBCOMMANDS\n  models             List all available models\n  run                Run OpenCode with a message (--model provider/model#variant)"
        XCTAssertFalse(Launch.openCodeTakesModel(help: two))
        XCTAssertFalse(Launch.openCodeTakesModel(help: "FLAGS\n  --models-dir string"), "Not fooled by another option having the same prefix")
    }

    // MARK: Restoring the default after launch (cursor)

    private func launchFiles() -> (defaults: URL, record: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("launch-cursor-\(UUID().uuidString)")
        let files = (base.appendingPathExtension("json"), base.appendingPathExtension("record.json"))
        addTeardownBlock {
            for url in [files.0, files.1, URL(fileURLWithPath: files.1.path + ".lock")] { try? FileManager.default.removeItem(at: url) }
        }
        return files
    }

    /// The form cursor writes after opening with that id (measured 2026-10-11: `grok-4.7-high` → modelId `grok-4.7`).
    private func cursorWrites(_ modelID: String, to url: URL, aliases: [String] = []) throws {
        var object = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]) ?? ["version": 1]
        object["model"] = ["modelId": modelID, "displayModelId": aliases.first ?? modelID, "aliases": aliases]
        object["selectedModel"] = ["modelId": modelID]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    private func savedModel(_ url: URL) -> String? {
        (((try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any])?["model"] as? [String: Any])?["modelId"] as? String
    }

    #if os(macOS)
    func testLaunchPutsBackOnlyWhatItsOwnLaunchWrote() throws {
        let (url, record) = launchFiles()
        try JSONSerialization.data(withJSONObject: ["version": 1, "hints": true], options: [.prettyPrinted, .sortedKeys]).write(to: url)
        let ticket = try LaunchDefaults.begin(agent: .cursor, model: "claude-opus-5-5-high", defaults: url, record: record)
        var round = 0
        let restored = LaunchDefaults.keep(agent: .cursor, ticket: ticket, defaults: url, record: record, rounds: 30, sleep: { _ in
            round += 1
            // The agent writes twice right after opening (measured).
            if round == 2 || round == 4 { try? self.cursorWrites("claude-opus-5-5", to: url) }
        })
        XCTAssertEqual(restored, 2)
        XCTAssertNil(savedModel(url), "There was no model key before the launch")
        let left = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(left["hints"] as? Bool, true, "Other keys unchanged")
        XCTAssertLessThanOrEqual(round, 4 + 20, "After the first restore, watch for only 3 more seconds")
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path), "Deletes the record when finished")
    }
    #endif

    #if os(macOS)
    func testLaunchLeavesAnotherSessionsChangeAlone() throws {
        // Review (2026-10-11): during the one minute of watching, it must not revert a default that another session changed on purpose.
        let (url, record) = launchFiles()
        try JSONSerialization.data(withJSONObject: ["version": 1], options: [.sortedKeys]).write(to: url)
        try cursorWrites("grok-4.7", to: url)
        let ticket = try LaunchDefaults.begin(agent: .cursor, model: "claude-opus-5-5-high", defaults: url, record: record)
        var round = 0
        let restored = LaunchDefaults.keep(agent: .cursor, ticket: ticket, defaults: url, record: record, rounds: 12, sleep: { _ in
            round += 1
            if round == 2 { try? self.cursorWrites("gemini-3.7-flash", to: url) }   // a model chosen by another session
            if round == 5 { try? self.cursorWrites("claude-opus-5-5", to: url) }    // after that, the session we opened writes
        })
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(savedModel(url), "gemini-3.7-flash", "The value another session changed is the new baseline — only the opened model is restored")
    }
    #endif

    #if os(macOS)
    func testOverlappingLaunchesShareTheStateFromBeforeTheFirst() throws {
        // Review (2026-10-11): if opened again before the value written by the previous launch is restored, that momentary value is taken as the pre-launch one and the watchers fight each other.
        let (url, record) = launchFiles()
        try JSONSerialization.data(withJSONObject: ["version": 1], options: [.sortedKeys]).write(to: url)
        try cursorWrites("grok-4.7", to: url)
        let first = try LaunchDefaults.begin(agent: .cursor, model: "claude-opus-5-5-high", defaults: url, record: record)
        try cursorWrites("claude-opus-5-5", to: url)   // The first launch wrote and it has not been restored yet
        let second = try LaunchDefaults.begin(agent: .cursor, model: "gemini-3.7-flash-high", defaults: url, record: record)
        // Second watcher: the value the first launch wrote is also a live launch's model, so it is restored.
        var round = 0
        XCTAssertEqual(LaunchDefaults.keep(agent: .cursor, ticket: second, defaults: url, record: record, rounds: 6, sleep: { _ in
            round += 1
            if round == 3 { try? self.cursorWrites("gemini-3.7-flash", to: url) }
        }), 2)
        XCTAssertEqual(savedModel(url), "grok-4.7")
        // Even if the first watcher runs late, it sees the same baseline.
        try cursorWrites("gemini-3.7-flash", to: url)
        XCTAssertEqual(LaunchDefaults.keep(agent: .cursor, ticket: first, defaults: url, record: record, rounds: 3, sleep: { _ in }), 0,
                       "The second launch is finished — that model now belongs not to a live launch but is a value someone else changed")
        XCTAssertEqual(savedModel(url), "gemini-3.7-flash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }
    #endif

    #if os(macOS)
    func testLaunchWithNoSettingsFileBefore() throws {
        let (url, record) = launchFiles()
        let ticket = try LaunchDefaults.begin(agent: .cursor, model: "auto", defaults: url, record: record)
        var round = 0
        XCTAssertEqual(LaunchDefaults.keep(agent: .cursor, ticket: ticket, defaults: url, record: record, rounds: 4, sleep: { _ in
            round += 1
            if round == 1 { try? self.cursorWrites("default", to: url, aliases: ["auto"]) }
        }), 1)
        XCTAssertNil(savedModel(url), "Only the model key is removed from the file the agent created")
        // If the file cannot be read, stop before opening.
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try LaunchDefaults.begin(agent: .cursor, model: "auto", defaults: url, record: record))
        // A record with only finished launches is not used as a baseline (when the watcher died and the record remained).
        try JSONSerialization.data(withJSONObject: ["version": 1], options: [.sortedKeys]).write(to: url)
        try cursorWrites("grok-4.7", to: url)
        let old = Date(timeIntervalSinceNow: -600)
        _ = try LaunchDefaults.begin(agent: .cursor, model: "auto", defaults: url, record: record, now: old)
        try cursorWrites("gemini-3.7-flash", to: url)
        let fresh = try LaunchDefaults.begin(agent: .cursor, model: "claude-opus-5-5-high", defaults: url, record: record)
        try cursorWrites("claude-opus-5-5", to: url)
        XCTAssertEqual(LaunchDefaults.keep(agent: .cursor, ticket: fresh, defaults: url, record: record, rounds: 2, sleep: { _ in }), 1)
        XCTAssertEqual(savedModel(url), "gemini-3.7-flash", "Not the baseline (grok-4.7) of the launch 10 minutes ago")
    }
    #endif

    func testWhichSavedModelALaunchIdWrites() {
        // The eight pairs measured on 2026-10-11.
        let pairs = [("grok-4.7-high", "grok-4.7"), ("claude-opus-5-5-medium", "claude-opus-5-5"), ("composer-2.5", "composer-2.5"),
                     ("gpt-5.5-extra-high", "gpt-5.5"), ("claude-opus-5-thinking-high", "claude-opus-5"), ("cursor-grok-4.6-high", "grok-4.6"),
                     ("gemini-3.7-flash-high", "gemini-3.7-flash")]
        for (launch, saved) in pairs {
            XCTAssertTrue(LaunchDefaults.wrote(launch: launch, model: ["modelId": saved, "displayModelId": saved, "aliases": [String]()]), launch)
        }
        XCTAssertTrue(LaunchDefaults.wrote(launch: "auto", model: ["modelId": "default", "displayModelId": "auto", "aliases": ["auto"]]))
        XCTAssertFalse(LaunchDefaults.wrote(launch: "grok-4.7-high", model: ["modelId": "grok-4.6"]))
        // Another model with only the same prefix — both ways (review 2026-10-11: opened with 5.5 and took the 5 saved by someone else as what I wrote).
        XCTAssertFalse(LaunchDefaults.wrote(launch: "claude-opus-5-high", model: ["modelId": "claude-opus-5-5"]))
        XCTAssertFalse(LaunchDefaults.wrote(launch: "claude-opus-5-5-high", model: ["modelId": "claude-opus-5"]))
        XCTAssertFalse(LaunchDefaults.wrote(launch: "claude-opus-5-5-thinking-max-fast", model: ["modelId": "claude-opus-5"]))
        XCTAssertFalse(LaunchDefaults.wrote(launch: "gpt-5.4-mini-high", model: ["modelId": "gpt-5.4"]))
        XCTAssertTrue(LaunchDefaults.wrote(launch: "claude-4.6-sonnet-medium-thinking", model: ["modelId": "claude-4.6-sonnet"]))
        XCTAssertTrue(LaunchDefaults.wrote(launch: "claude-opus-5-5-thinking-max-fast", model: ["modelId": "claude-opus-5-5"]))
        XCTAssertFalse(LaunchDefaults.wrote(launch: "grok-4.7-high", model: [:]))
    }

    #if os(macOS)
    func testLaunchLeavesASimilarlyNamedModelSavedByAnotherSession() throws {
        let (url, record) = launchFiles()
        try JSONSerialization.data(withJSONObject: ["version": 1], options: [.sortedKeys]).write(to: url)
        try cursorWrites("grok-4.7", to: url)
        let ticket = try LaunchDefaults.begin(agent: .cursor, model: "claude-opus-5-5-high", defaults: url, record: record)
        var round = 0
        XCTAssertEqual(LaunchDefaults.keep(agent: .cursor, ticket: ticket, defaults: url, record: record, rounds: 6, sleep: { _ in
            round += 1
            if round == 2 { try? self.cursorWrites("claude-opus-5", to: url) }   // another session chose Opus 5
        }), 0)
        XCTAssertEqual(savedModel(url), "claude-opus-5", "The Opus 5 chosen by someone else stays — what we opened is Opus 5.5")
    }
    #endif

    #if os(macOS)
    func testRestoringAnotherLaunchDoesNotCutThisLaunchsWatchShort() throws {
        // Review (2026-10-11): B's watcher restored A's write and then shortened to 3 seconds because it had restored, and after 5 seconds nobody restored what B wrote.
        let (url, record) = launchFiles()
        try JSONSerialization.data(withJSONObject: ["version": 1], options: [.sortedKeys]).write(to: url)
        try cursorWrites("grok-4.7", to: url)
        _ = try LaunchDefaults.begin(agent: .cursor, model: "claude-opus-5-5-high", defaults: url, record: record)
        let second = try LaunchDefaults.begin(agent: .cursor, model: "gemini-3.7-flash-high", defaults: url, record: record)
        var round = 0
        let restored = LaunchDefaults.keep(agent: .cursor, ticket: second, defaults: url, record: record, rounds: 60, sleep: { _ in
            round += 1
            if round == 1 { try? self.cursorWrites("claude-opus-5-5", to: url) }      // A writes — B's watcher restores it
            if round == 35 { try? self.cursorWrites("gemini-3.7-flash", to: url) }    // 5 seconds later (past 3 seconds) B writes
        })
        XCTAssertEqual(restored, 2)
        XCTAssertEqual(savedModel(url), "grok-4.7", "What B wrote late was also restored")
        XCTAssertEqual(round, 35 + 20, "Shortens to 3 seconds only after restoring its own")
    }
    #endif

    /// Lines taken from the 2026-10-11 output of `agy models` (agy 1.3.3).
    static let agyModels = """
    Fetching available models...
    gemini-3.8-flash-high\tGemini 3.8 Flash (High)
    gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)
    gemini-3.8-flash-low\tGemini 3.8 Flash (Low)
    gemini-3.1-pro-high\tGemini 3.1 Pro (High)
    gemini-3.1-pro-low\tGemini 3.1 Pro (Low)
    claude-opus-5-5-high\tClaude Opus 5.5 (High)
    gpt-oss-120b-medium\tGPT-OSS 120B (Medium)
    """

    func testAntigravityNameAndEffortResolveToAnID() throws {
        let listing = LaunchSupportTests.agyModels
        XCTAssertEqual(try Launch.resolve(agent: .antigravity, preset: AgentPreset(model: "Gemini 3.8 Flash", effort: "medium"), listing: listing),
                       Launch.Resolved(model: "gemini-3.8-flash-medium", note: nil))
        XCTAssertEqual(try Launch.resolve(agent: .antigravity, preset: AgentPreset(model: "gemini-3.1-pro", effort: "low"), listing: listing).model,
                       "gemini-3.1-pro-low", "Case and symbols are ignored")
        XCTAssertThrowsError(try Launch.resolve(agent: .antigravity, preset: AgentPreset(model: "Gemini 3.1 Pro", effort: "medium"), listing: listing)) {
            XCTAssertEqual("\($0)", "antigravity 'Gemini 3.1 Pro'에는 effort 'medium'이(가) 없습니다(high, low).")
        }
        XCTAssertThrowsError(try Launch.resolve(agent: .antigravity, preset: AgentPreset(model: "Gemini 9", effort: "high"), listing: listing)) {
            XCTAssertEqual("\($0)", "antigravity 모델 목록에 'Gemini 9'이(가) 없습니다.")
        }
        XCTAssertThrowsError(try Launch.resolve(agent: .antigravity, preset: AgentPreset(model: "Gemini 3.8 Flash", effort: "high"),
                                                listing: "Error: Please sign in to view available models."), "If the list could not be obtained, it does not guess")
    }

    /// Shortened from the 2026-10-11 output of `opencode models --verbose` (opencode 1.18.35).
    static let opencodeModels = """
    opencode/glm-5.3-flash
    {
      "id": "glm-5.3-flash",
      "providerID": "opencode",
      "name": "GLM-5.3-Flash",
      "api": {
        "id": "glm-5.3-flash"
      },
      "variants": {}
    }
    opencode-go/glm-5.3
    {
      "id": "glm-5.3",
      "providerID": "opencode-go",
      "name": "GLM-5.3",
      "variants": {
        "low": {},
        "high": {}
      }
    }
    opencode-go/glm-5.3-flash
    {
      "id": "glm-5.3-flash",
      "providerID": "opencode-go",
      "name": "GLM-5.3-Flash",
      "variants": {
        "low": {},
        "high": {},
        "max": {}
      }
    }
    opencode-go/deepseek-v4.1-flash
    {
      "id": "deepseek-v4.1-flash",
      "providerID": "opencode-go",
      "name": "DeepSeek V4.1 Flash",
      "variants": {}
    }
    """

    /// Provider names shown on screen (from opencode's model cache on 2026-10-11: `opencode` shows as "OpenCode Zen").
    static let opencodeProviders = ["opencode": "OpenCode Zen", "opencode-go": "OpenCode Go", "google-vertex": "Vertex"]

    func testOpenCodeNameWithProviderResolvesToAnID() throws {
        let listing = LaunchSupportTests.opencodeModels
        let names = LaunchSupportTests.opencodeProviders
        let go = try Launch.resolve(agent: .opencode, preset: AgentPreset(model: "GLM-5.3-Flash OpenCode Go", effort: "high"), listing: listing, providerNames: names)
        XCTAssertEqual(go.model, "opencode-go/glm-5.3-flash", "Even if the same name exists in two providers, the one that matches the provider is chosen")
        let zen = try Launch.resolve(agent: .opencode, preset: AgentPreset(model: "GLM-5.3-Flash OpenCode Zen", effort: "high"), listing: listing, providerNames: names)
        XCTAssertEqual(zen.model, "opencode/glm-5.3-flash", "The provider is matched by the name on screen (OpenCode Zen), not the id (opencode)")
        XCTAssertEqual(try Launch.resolve(agent: .opencode, preset: AgentPreset(model: "DeepSeek V4.1 Flash", effort: "Default"), listing: listing, providerNames: names).model,
                       "opencode-go/deepseek-v4.1-flash", "If the provider is not given but the name is unique, it is accepted")
        XCTAssertThrowsError(try Launch.resolve(agent: .opencode, preset: AgentPreset(model: "GLM-5.3-Flash", effort: "Default"), listing: listing, providerNames: names),
                             "Written without a provider but the name is shared by two, so none is chosen")
        XCTAssertThrowsError(try Launch.resolve(agent: .opencode, preset: AgentPreset(model: "GLM-9 OpenCode Go", effort: "Default"), listing: listing, providerNames: names))
    }

    func testOpenCodeWithoutProviderNamesFallsBackToIDsAndNeverGuesses() throws {
        let listing = LaunchSupportTests.opencodeModels
        // Without the name table (cache unreadable), only providers whose id and name are the same resolve — "OpenCode Zen" does not match id `opencode`, so it is not chosen.
        XCTAssertEqual(try Launch.resolve(agent: .opencode, preset: AgentPreset(model: "GLM-5.3-Flash OpenCode Go", effort: "high"), listing: listing).model,
                       "opencode-go/glm-5.3-flash")
        XCTAssertThrowsError(try Launch.resolve(agent: .opencode, preset: AgentPreset(model: "GLM-5.3-Flash OpenCode Zen", effort: "high"), listing: listing))
        // A provider not in the name table (a user-added provider) is matched by id.
        let custom = "my-proxy/glm-5.3-flash\n{\n  \"id\": \"glm-5.3-flash\",\n  \"providerID\": \"my-proxy\",\n  \"name\": \"GLM-5.3-Flash\"\n}\n"
        XCTAssertEqual(try Launch.resolve(agent: .opencode, preset: AgentPreset(model: "GLM-5.3-Flash My Proxy", effort: "Default"),
                                          listing: listing + "\n" + custom, providerNames: LaunchSupportTests.opencodeProviders).model, "my-proxy/glm-5.3-flash")
    }

    func testOpenCodeAlwaysSaysTheVariantIsNotSet() throws {
        // Even when opened with `--model`, opencode reloads the variant that model last used — it reports this even if Default was wanted.
        for effort in ["Default", "high"] {
            let resolved = try Launch.resolve(agent: .opencode, preset: AgentPreset(model: "GLM-5.3-Flash OpenCode Go", effort: effort),
                                              listing: LaunchSupportTests.opencodeModels, providerNames: LaunchSupportTests.opencodeProviders)
            XCTAssertTrue(resolved.note?.contains("'\(effort)'") == true, effort)
        }
    }

    func testProviderNamesComeFromTheModelsCacheAndTheResolvedConfig() throws {
        let cache = Data(#"{"opencode": {"id": "opencode", "name": "OpenCode Zen", "models": {}}, "google-vertex": {"name": "Vertex"}, "broken": 3}"#.utf8)
        XCTAssertEqual(Launch.openCodeProviderNames(cache: cache), ["opencode": "OpenCode Zen", "google-vertex": "Vertex"])
        XCTAssertEqual(Launch.openCodeProviderNames(cache: Data("not json".utf8)), [:])
        XCTAssertEqual(Launch.openCodeProviderNames(cache: nil), [:])
        // The name of a user-added provider is in the settings, not in the cache. If the same id is in both, the settings win.
        let config = Data(#"{"model": "x/y", "provider": {"my-proxy": {"name": "Acme Gateway", "options": {"apiKey": "never-read"}}, "opencode": {"name": "Zen (work)"}}}"#.utf8)
        let names = Launch.openCodeProviderNames(cache: cache, config: config)
        XCTAssertEqual(names, ["opencode": "Zen (work)", "google-vertex": "Vertex", "my-proxy": "Acme Gateway"])

        // A user-added provider whose name is completely different from its id also resolves by its on-screen name.
        let custom = "my-proxy/glm-5.3-flash\n{\n  \"id\": \"glm-5.3-flash\",\n  \"providerID\": \"my-proxy\",\n  \"name\": \"GLM-5.3-Flash\"\n}\n"
        let listing = LaunchSupportTests.opencodeModels + "\n" + custom
        XCTAssertEqual(try Launch.resolve(agent: .opencode, preset: AgentPreset(model: "GLM-5.3-Flash Acme Gateway", effort: "Default"),
                                          listing: listing, providerNames: names).model, "my-proxy/glm-5.3-flash")
        XCTAssertEqual(try Launch.resolve(agent: .opencode, preset: AgentPreset(model: "GLM-5.3-Flash Zen (work)", effort: "Default"),
                                          listing: listing, providerNames: names).model, "opencode/glm-5.3-flash")
    }
}


// MARK: - From the PR #10 review

final class OpenCodeRealStateTests: KoreanMessagesTestCase {
    struct Fixture: Decodable { let tail: [String] }

    func screen(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tail
    }

    func testImplicitDefaultHasNoCurrentMarker() throws {
        // Real screen (2026-10-08): `/variants` of a model with no saved variant (DeepSeek V4 Pro) — no row has ●.
        for name in ["oc-variants-implicit", "oc-variants-auto"] {
            let dialog = try XCTUnwrap(OpenCodeScreen.dialog(try screen(name)), name)
            XCTAssertEqual(dialog.title, "Select variant")
            XCTAssertEqual(dialog.rows.map(\.text), ["Default", "high", "max"], name)
            XCTAssertNil(dialog.rows.firstIndex(where: \.current), name)
        }
        XCTAssertNil(try XCTUnwrap(OpenCodeScreen.status(try screen("oc-variants-implicit"))).variant, "The model line also has no variant")
    }

    func testStepsUpFromAnImplicitDefault() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oc-implicit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let io = FakeOpenCode(configURL: url)
        io.current = 1      // DeepSeek: no variant, and Default was never chosen
        let driver = OpenCodeDriver(io: io, sleep: { _ in }, defaults: OpenCodeDefaults(url: url), keepDefaults: false)
        XCTAssertEqual(try driver.stepEffort(up: true).confirmations, ["Using DeepSeek V4.1 Flash OpenCode Go · low"], "To the step after Default")
        io.models[1].variant = nil
        XCTAssertThrowsError(try driver.stepEffort(up: false)) { XCTAssertTrue(($0 as? SlashCommandError)?.nothingToDo == true, "Default is the lowest") }
    }

    func testPriceColumnIsNotPartOfTheModelIdentity() throws {
        XCTAssertEqual(OpenCodeScreen.normalizeRow("Big Pickle                    OpenCode Zen        Free"), "Big Pickle OpenCode Zen")
        XCTAssertEqual(OpenCodeScreen.normalizeRow("Muse Spark 1.3 Free OpenCode Zen                Free"), "Muse Spark 1.3 Free OpenCode Zen", "Free inside a name is kept")
        XCTAssertEqual(OpenCodeScreen.normalizeRow("GPT-6.1 Sol            OpenRouter      $1.25"), "GPT-6.1 Sol OpenRouter")
        XCTAssertEqual(OpenCodeScreen.normalizeRow("Free"), "Free", "If there is only one column, it is the name")
        // Real screen: the filtered free-model row (there is no value column at this width).
        let dialog = try XCTUnwrap(OpenCodeScreen.dialog(try screen("oc-models-free")))
        XCTAssertEqual(dialog.rows.first?.text, "Big Pickle OpenCode Zen")
    }

    func testStateHomeFollowsTheSessionsEnvironment() throws {
        let plain = (arguments: ["opencode"], environment: ["HOME=/Users/x", "ORCA_TERMINAL_HANDLE=term_a"])
        let custom = (arguments: ["opencode"], environment: ["HOME=/Users/x", "XDG_STATE_HOME=/data/state", "ORCA_TERMINAL_HANDLE=term_b"])
        let other = (arguments: ["claude"], environment: ["XDG_STATE_HOME=/elsewhere"])
        XCTAssertEqual(OpenCodeDefaults.stateHomes(processes: [plain, other], orcaHandle: nil), ["/Users/x/.local/state"], "Processes that are not opencode are not looked at")
        XCTAssertEqual(try OpenCodeDefaults.resolve(processes: [custom], orcaHandle: nil).url.path, "/data/state/opencode/model.json")
        // If the two differ, narrow by the Orca handle.
        XCTAssertEqual(try OpenCodeDefaults.resolve(processes: [plain, custom], orcaHandle: "term_b").url.path, "/data/state/opencode/model.json")
        XCTAssertEqual(try OpenCodeDefaults.resolve(processes: [plain, custom], orcaHandle: "term_a").url.path, "/Users/x/.local/state/opencode/model.json")
        // If it cannot be narrowed, it stops instead of claiming to have protected the wrong file.
        XCTAssertThrowsError(try OpenCodeDefaults.resolve(processes: [plain, custom], orcaHandle: nil))
        XCTAssertThrowsError(try OpenCodeDefaults.resolve(processes: [plain, custom], orcaHandle: "term_zzz"))
        // If that session's process cannot be found, it stops — without substituting a folder from our environment.
        XCTAssertThrowsError(try OpenCodeDefaults.resolve(processes: [], orcaHandle: nil, environment: ["XDG_STATE_HOME": "/env/state"]))
        XCTAssertThrowsError(try OpenCodeDefaults.resolve(processes: [other], orcaHandle: "term_a"))
        XCTAssertThrowsError(try OpenCodeDefaults.resolve(processes: [plain], orcaHandle: "term_other"), "Does not substitute a session from another terminal")
    }
}

/// Cases where the defaults file did not exist before the switch and where it could not be read.
final class AbsentOrUnreadableDefaultsTests: KoreanMessagesTestCase {
    private func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString)-\(name)")
    }

    func testAbsentFileGetsNoNewDefaultModel() throws {
        // opencode: a first-time user has no model.json. Switching makes opencode create it — it must be gone again afterward.
        let url = temp("oc.json")
        defer { try? FileManager.default.removeItem(at: url) }
        let io = FakeOpenCode(configURL: url)
        let driver = OpenCodeDriver(io: io, sleep: { _ in }, defaults: OpenCodeDefaults(url: url), keepDefaults: true)
        let outcome = try driver.apply(AgentPreset(model: "GLM-5.3-Flash OpenCode Go", effort: "max"))
        XCTAssertEqual(io.models[0].variant, "max", "Positive control: the switch happened")
        XCTAssertNil(outcome.warning)
        // When creating the file, opencode also writes another key (`favorite`) — it does not decide the new session's model, so it may stay.
        // The two keys that decide the new-session default must be absent.
        let left = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        XCTAssertNil(left["recent"], "A default model that did not exist must not appear")
        XCTAssertNil(left["variant"])
    }

    func testAbsentFileKeepsWhatAnotherSessionWrote() throws {
        let url = temp("generic.json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: ["recent": [["modelID": "x"]], "variant": ["x": "high"], "favorite": [["modelID": "y"]]], options: [.sortedKeys]).write(to: url)
        XCTAssertEqual(OpenCodeDefaults(url: url).restore(to: .absent), .restored)
        let now = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Array(now.keys), ["favorite"], "Remove only our keys and leave others'")
        XCTAssertEqual(OpenCodeDefaults(url: url).restore(to: .absent), .unchanged)
    }

    func testAbsentWorksForEveryAgentsFile() throws {
        let grok = temp("grok.toml")
        defer { try? FileManager.default.removeItem(at: grok) }
        try "\n[models]\ndefault = \"grok-4.7\"\ndefault_reasoning_effort = \"high\"\n".write(to: grok, atomically: true, encoding: .utf8)
        XCTAssertEqual(GrokDefaults(url: grok).restore(to: .absent), .restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: grok.path))

        let cursor = temp("cursor.json")
        defer { try? FileManager.default.removeItem(at: cursor) }
        try JSONSerialization.data(withJSONObject: ["model": ["modelId": "a"], "selectedModel": ["modelId": "a"], "modelSelectionHistory": ["a"], "modelParameters": [:]]).write(to: cursor)
        XCTAssertEqual(CursorDefaults(url: cursor).restore(to: .absent), .restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cursor.path))

        let agy = temp("agy.json")
        defer { try? FileManager.default.removeItem(at: agy) }
        try JSONSerialization.data(withJSONObject: ["model": "Gemini", "theme": "dark"]).write(to: agy)
        XCTAssertEqual(AntigravityDefaults(url: agy).restore(to: .absent), .restored)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(contentsOf: agy)) as? [String: String]), ["theme": "dark"])
    }

    func testUnreadableFileRefusesBeforeTypingAnything() throws {
        // A folder is a file that exists but cannot be read.
        let url = temp("unreadable")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(DefaultsFile.snapshot(temp("nothing")), .absent)
        guard case .unreadable = DefaultsFile.snapshot(url) else { return XCTFail("A folder must come out as unreadable") }

        let oc = FakeOpenCode(configURL: temp("unused"))
        XCTAssertThrowsError(try OpenCodeDriver(io: oc, sleep: { _ in }, defaults: OpenCodeDefaults(url: url), keepDefaults: true)
            .apply(AgentPreset(model: "GLM-5.3-Flash OpenCode Go", effort: "max")))
        XCTAssertEqual(oc.typed, [], "If the value to restore is unknown, nothing is sent")

        let grokFile = temp("unused.toml")
        let grok = FakeGrok(configURL: grokFile)
        let models = GrokModels(models: [.init(id: "grok-4.7", name: "Grok 4.7", efforts: ["low", "high", "xhigh"])])
        XCTAssertThrowsError(try GrokDriver(io: grok, sleep: { _ in }, models: models, defaults: GrokDefaults(url: url), keepDefaults: true)
            .apply(AgentPreset(model: "grok-4.7", effort: "xhigh")))
        XCTAssertEqual(grok.typed, [])

        // If keepDefaults is off, that file is never looked at, so it proceeds as is.
        _ = try OpenCodeDriver(io: oc, sleep: { _ in }, defaults: OpenCodeDefaults(url: url), keepDefaults: false)
            .apply(AgentPreset(model: "GLM-5.3-Flash OpenCode Go", effort: "max"))
        XCTAssertEqual(oc.models[0].variant, "max")
    }
}

/// Base for tests that check wording. It runs with the Korean translation table on — so the Korean sentences the tests below check have gone through
/// "the English sentence in code → the translation in `Resources/ko.lproj` → value insertion" (a missing translation or a mismatched placeholder shows up here).
class KoreanMessagesTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        L10n.use(language: "ko", directory: L10nTests.resources)
    }
}

final class L10nTests: XCTestCase {
    /// The repo's `Resources/` (translation files) and `Sources/`.
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let resources = root.appendingPathComponent("Resources")

    func testPicksTheFirstPreferredLanguageWeHave() {
        let have = ["ar", "de", "en", "es", "fr", "ja", "ko", "pt", "zh-Hans"]
        XCTAssertEqual(L10n.pick(from: have, preferences: ["en-KR", "ko-KR"]), "en")
        XCTAssertEqual(L10n.pick(from: have, preferences: ["ko-KR", "en-KR"]), "ko")
        XCTAssertEqual(L10n.pick(from: have, preferences: ["pt-BR"]), "pt")
        XCTAssertEqual(L10n.pick(from: have, preferences: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(L10n.pick(from: have, preferences: ["zh-CN"]), "zh-Hans", "Chinese without a script is picked by region")
        XCTAssertEqual(L10n.pick(from: have, preferences: ["zh-TW", "ja-JP"]), "ja", "Traditional is not substituted by Simplified")
        XCTAssertEqual(L10n.pick(from: have, preferences: ["it-IT"]), "en")
        XCTAssertEqual(L10n.pick(from: have, preferences: []), "en")
        XCTAssertEqual(L10n.pick(from: ["ko"], preferences: ["en-US", "ko-KR"]), "en", "English is a language it has even without a translation file")
    }

    func testFormatFillsSequentialAndNumberedPlaceholders() {
        XCTAssertEqual(L10n.format("%@ on %@", ["claude", "Ghostty"]), "claude on Ghostty")
        XCTAssertEqual(L10n.format("%2$@ 의 %1$@", ["claude", "Ghostty"]), "Ghostty 의 claude")
        XCTAssertEqual(L10n.format("%@ is 100%% sure", [3]), "3 is 100% sure")
        XCTAssertEqual(L10n.format("100% as written", []), "100% as written", "If there are no values, the sentence is left alone")
        XCTAssertEqual(L10n.format("%@ and %@", ["one"]), "one and %@", "If values are short, the placeholder remains")
        XCTAssertEqual(L10n.format("50% of %@", ["x"]), "50% of x", "A % that is not a placeholder is left as is")
    }

    /// The English sentences used as `loc("…")` in code.
    static func keysInCode() throws -> Set<String> {
        var keys: Set<String> = []
        let pattern = try NSRegularExpression(pattern: #"\bloc\(\s*"((?:[^"\\]|\\.)*)""#)
        let sources = root.appendingPathComponent("Sources")
        for case let url as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let raw = String(text[Range(match.range(at: 1), in: text)!])
                keys.insert(raw.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\"))
            }
        }
        return keys
    }

    /// Counts placeholders after normalizing to numbered: `%@ %@` and `%2$@ %1$@` are the same placeholders.
    static func placeholders(_ text: String) -> [Int] {
        var found: [Int] = []
        var next = 1
        var rest = Substring(text)
        while let percent = rest.firstIndex(of: "%") {
            rest = rest[rest.index(after: percent)...]
            if rest.first == "%" { rest = rest.dropFirst(); continue }
            if rest.first == "@" { found.append(next); next += 1; continue }
            let digits = rest.prefix(while: \.isNumber)
            if let position = Int(digits), rest.dropFirst(digits.count).hasPrefix("$@") { found.append(position) }
        }
        return found.sorted()
    }

    func testEveryLanguageTranslatesExactlyTheSentencesInCode() throws {
        let keys = try L10nTests.keysInCode()
        XCTAssertFalse(keys.isEmpty)
        let languages = L10n.available(in: L10nTests.resources)
        XCTAssertTrue(languages.contains("en") && languages.contains("ko"), "\(languages)")
        for language in languages where language != "en" {
            let table = L10n.table(in: L10nTests.resources, language: language)
            XCTAssertFalse(table.isEmpty, "\(language): could not read the translation file (maybe a syntax error)")
            let missing = keys.subtracting(table.keys).sorted()
            let extra = Set(table.keys).subtracting(keys).sorted()
            XCTAssertTrue(missing.isEmpty, "\(language): \(missing.count) sentences without a translation — \(missing.prefix(5))")
            XCTAssertTrue(extra.isEmpty, "\(language): \(extra.count) sentences not in code — \(extra.prefix(5))")
            for (key, value) in table where keys.contains(key) {
                XCTAssertEqual(L10nTests.placeholders(value), L10nTests.placeholders(key), "\(language): placeholders differ — \(key)")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language): empty translation — \(key)")
            }
        }
    }

    func testEnglishFileAddsNothing() {
        XCTAssertTrue(L10n.table(in: L10nTests.resources, language: "en").isEmpty, "English is based on the sentences in code — no translations in the en file")
    }

    func testCoreSentencesAreEnglishWithoutATable() {
        defer { L10n.use(language: "en", directory: nil) }
        L10n.use(language: "en", directory: nil)
        let switcher = Switcher(config: .starter, codexModels: { CodexModels(models: []) })
        XCTAssertThrowsError(try switcher.plan(slot: 9, agent: .claude)) { XCTAssertEqual("\($0)", "There is no preset 9 (there are 3).") }
        XCTAssertThrowsError(try switcher.plan(slot: 3, agent: .codex)) { XCTAssertEqual("\($0)", "Preset 3 has no Codex entry.") }
        L10n.use(language: "ko", directory: L10nTests.resources)
        XCTAssertThrowsError(try switcher.plan(slot: 9, agent: .claude)) { XCTAssertEqual("\($0)", "9번 프리셋이 없습니다(지금 3개).") }
    }

    func testTranslatedSentenceIsUsed() {
        defer { L10n.use(language: "en", directory: nil) }
        L10n.use(language: "ko", directory: L10nTests.resources)
        XCTAssertEqual(L10n.language, "ko")
        XCTAssertEqual(loc("Quit Slash Command"), "Slash Command 종료")
        XCTAssertEqual(loc("A sentence nobody translated"), "A sentence nobody translated")
        L10n.use(language: "en", directory: nil)
        XCTAssertEqual(loc("Quit Slash Command"), "Quit Slash Command")
    }
}
