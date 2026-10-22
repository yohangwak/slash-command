import XCTest
@testable import SlashCommandCore

/// A fresh codex session lists commands under "To get started" (`/model - choose what model …`). With blank lines dropped,
/// that help text is among the last lines above the input box, so it must not count as the slash-command popup
/// (measured 2026-10-22, codex 0.162.1: Enter went out before the popup and the picker never opened).
final class CodexWelcomeBannerTests: KoreanMessagesTestCase {
    private let banner = [
        "  To get started, describe a task or try one of these commands:",
        "  /init - create an AGENTS.md file with instructions for Codex",
        "  /status - show current session configuration",
        "  /permissions - choose what Codex is allowed to do",
        "  /model - choose what model and reasoning effort to use",
        "  /review - review any changes and find issues",
    ]
    private let needle = "choose what model and reasoning effort"

    func testWelcomeBannerIsNotThePopup() {
        let io = FakeIO()
        io.screens = [banner + Array(repeating: "", count: 20) + ["› /model", "", "  GPT-6.1-Sol high · ~/Repos", ""]]
        XCTAssertThrowsError(try Runner(io: io, sleep: { _ in }).run([
            .expect(needle: needle, bottom: 5, timeoutMs: 200, abort: [], failure: "no popup"), .key(.enter),
        ]))
        XCTAssertFalse(io.sent.contains("\r"), "Enter must wait for the real popup")
    }

    func testPopupBelowTheBannerCounts() {
        let io = FakeIO()
        io.screens = [banner + Array(repeating: "", count: 18) + ["› /model  choose what model and reasoning effort to use", "", "› /model", "", "  GPT-6.1-Sol high · ~/Repos"]]
        XCTAssertNoThrow(try Runner(io: io, sleep: { _ in }).run([
            .expect(needle: needle, bottom: 5, timeoutMs: 200, abort: [], failure: "no popup"),
        ]))
    }

    func testNarrowPopupThatWrapsStillCounts() {
        let io = FakeIO()
        io.screens = [["› /model  choose what model and", "          reasoning effort to use", "", "› /model", "", "  GPT-6-Astra high · ~/Repos"]]
        XCTAssertNoThrow(try Runner(io: io, sleep: { _ in }).run([
            .expect(needle: needle, bottom: 5, timeoutMs: 200, abort: [], failure: "no popup"),
        ]))
    }
}
