import XCTest
@testable import SlashCommandCore

/// A terminal whose screen can be out of date (like Ghostty): plays the given screens in order, the last one repeats.
private final class LaggyIO: TerminalIO {
    var sent: [String] = []
    var screens: [[String]]
    private var reads = 0

    init(screens: [[String]]) { self.screens = screens }

    var screenLagMs: Int { 500 }
    func type(_ text: String) throws { sent.append(text) }
    func press(_ key: Key) throws { sent.append(key.bytes) }
    func screen() -> [String]? {
        defer { reads += 1 }
        return screens[min(reads, screens.count - 1)]
    }
}

final class SwitchPromptAnchorTests: XCTestCase {
    private let dialog = [
        "   Switch model?",
        "   Your next response will be slower and use more tokens",
        "   ❯ 1. Yes, switch to Sonnet 5.5",
        "     2. No, go back",
    ]
    private let inputBox = ["────────", "❯", "────────", "  ⏵⏵ auto mode on"]
    private let pickerBottom = [
        "   Select model",
        "   Switch between Claude models. Your pick becomes the default for new sessions.",
        "   ❯ 1.  Sonnet 5.5 ✔             description",
        "     2.  Opus 5.5                 description",
        "   ● High effort ←/→ to adjust",
        "   Enter to set as default · s to use this session only · Esc to cancel",
    ]

    func testDialogShapedTextInTheMiddleOfTheConversationIsNotRead() {
        let conversation = dialog + ["   and then the agent went on to talk about something else"] + inputBox
        XCTAssertNil(ClaudeScreen.switchPrompt(conversation))
    }

    func testDialogShapedTextAbovePickerIsNotRead() {
        XCTAssertNil(ClaudeScreen.switchPrompt(dialog + pickerBottom))
    }

    func testDialogAtTheBottomIsRead() {
        XCTAssertEqual(ClaudeScreen.switchPrompt(["earlier output"] + dialog), "Sonnet 5.5")
    }

    func testLongerDescriptionStillCountsAsTheDialog() {
        let lines = ["   Switch model?",
                     "   Your next response will be slower and use more tokens",
                     "   This conversation is cached for the current model. Switching to Sonnet 5.5",
                     "   means the whole conversation is read again.",
                     "   The new model may take longer to answer the first time.",
                     "   Nothing else changes.",
                     "   ❯ 1. Yes, switch to Sonnet 5.5",
                     "     2. No, go back"]
        XCTAssertEqual(ClaudeScreen.switchPrompt(lines), "Sonnet 5.5")
    }

    func testEffortDialogAtTheBottomIsRead() {
        let lines = ["   Change effort level?", "   Your next response will be slower and use more tokens",
                     "   ❯ 1. Yes, switch to high", "     2. No, go back"]
        XCTAssertEqual(ClaudeScreen.switchPrompt(lines), "high")
    }

    func testHeaderTooFarAboveTheYesRowIsNotRead() {
        let filler = (0..<9).map { "   line \($0)" }
        XCTAssertNil(ClaudeScreen.switchPrompt(["   Switch model?"] + filler + ["   ❯ 1. Yes, switch to Sonnet 5.5", "     2. No, go back"]))
    }

    func testEnterIsNotPressedWhenTheFreshScreenNoLongerShowsTheDialog() throws {
        // The last screen read was the dialog, but the real screen has moved on to the input box.
        let io = LaggyIO(screens: [dialog, inputBox])
        _ = try? Runner(io: io, sleep: { _ in }).run([
            .expectInput(agent: .claude, acceptSwitchTo: ["sonnet"], timeoutMs: 200, abort: [], failure: "f"),
        ])
        XCTAssertEqual(io.sent, [])
    }

    func testEnterIsPressedWhenTheFreshScreenStillShowsTheDialog() throws {
        let io = LaggyIO(screens: [dialog, dialog, inputBox])
        _ = try? Runner(io: io, sleep: { _ in }).run([
            .expectInput(agent: .claude, acceptSwitchTo: ["sonnet"], timeoutMs: 200, abort: [], failure: "f"),
        ])
        XCTAssertEqual(io.sent, ["\r"])
    }
}
