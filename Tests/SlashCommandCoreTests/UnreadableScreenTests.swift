import Foundation
import XCTest
@testable import SlashCommandCore

/// A Grok terminal that shows a half-typed command in the input box, then cannot be read once a key has been pressed.
private final class GrokThatGoesBlind: TerminalIO {
    var input = ""
    var blind = false
    var backspaces = 0

    func type(_ text: String) throws { input = String(text.prefix(4)) }
    func press(_ key: Key) throws {
        if key == .backspace { backspaces += 1; blind = true }
    }
    func screen() -> [String]? {
        if blind { return nil }
        return [
            "  ╭" + String(repeating: "─", count: 40) + "╮",
            "  │ ❯ " + input + String(repeating: " ", count: 40 - 3 - input.count) + "│",
            "  ╰" + String(repeating: "─", count: 20) + " Grok 4.7 (high) ─╯",
            input.isEmpty ? "  Shift+Tab:mode  │  Ctrl+x:shortcuts" : "  Enter:send  │  Shift+Tab:mode  │  Ctrl+x:shortcuts",
        ]
    }
}

final class UnreadableScreenTests: KoreanMessagesTestCase {
    func testClosePickerStopsWithoutAnyKeyWhenTheScreenCannotBeRead() {
        let io = FakeIO()
        io.screens = nil
        XCTAssertThrowsError(try Runner(io: io, sleep: { _ in }).run([.closePicker, .text("\u{19}\u{7F}")])) {
            XCTAssertEqual(($0 as? SlashCommandError)?.message, loc("Stopped: could not read the terminal screen."))
        }
        XCTAssertEqual(io.sent, [], "No key (Esc, the draft restore text) is sent to a screen that cannot be read")
    }

    func testSliderNeedsExactlyOneSelectedDot() {
        func screen(_ track: String) -> [String] {
            ["  Effort  ◂        \(track)        ▸",
             "                  low          medium          high"]
        }
        XCTAssertNil(AgyScreen.slider(screen("●──────────────●──────────────●")), "No ◉: the selected step is unknown")
        XCTAssertNil(AgyScreen.slider(screen("◉──────────────◉──────────────●")), "Two ◉: the selected step is ambiguous")
        let one = AgyScreen.slider(screen("●──────────────◉──────────────○"))
        XCTAssertEqual(one?.selected, 1)
        XCTAssertEqual(one?.labels, ["low", "medium", "high"])
    }

    func testGrokPressesBackspaceOnlyOnceWhenTheScreenGoesUnreadable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grok-blind-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let io = GrokThatGoesBlind()
        let models = GrokModels(models: [.init(id: "grok-4.7", name: "Grok 4.7", efforts: ["low", "medium", "high", "xhigh"])])
        let driver = GrokDriver(io: io, sleep: { _ in }, models: models, defaults: GrokDefaults(url: url), keepDefaults: false)
        // The command never shows in the input box (only "/mod" does), so it is erased; after the first Backspace the screen cannot be read.
        XCTAssertThrowsError(try driver.apply(AgentPreset(model: "grok-4.7", effort: "xhigh")))
        XCTAssertEqual(io.backspaces, 1, "Once the screen cannot be read, no more Backspace is pressed")
    }
}
