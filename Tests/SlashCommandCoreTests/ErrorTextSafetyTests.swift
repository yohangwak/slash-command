import XCTest
@testable import SlashCommandCore

final class ErrorTextSafetyTests: KoreanMessagesTestCase {
    func testTimeoutDoesNotQuoteUnrelatedToolOutput() throws {
        let io = FakeIO()
        let rule = String(repeating: "─", count: 30)
        let prompt = [rule, "❯", rule, "  ⏵⏵ auto mode on"]
        io.screens = [prompt]
        io.onType = { _ in
            // A tool result elsewhere in the conversation is not our /model reply.
            io.screens = [["⏺ Tool output", "  ⎿  SECRET-TOOL-OUTPUT-123", "❯ /model sonnet"] + prompt]
        }
        let runner = Runner(io: io, sleep: { _ in }, initial: ScreenSnapshot(lines: prompt, draft: nil))

        XCTAssertThrowsError(try runner.run(Plans.claude(AgentPreset(model: "sonnet", effort: "medium")))) {
            guard let error = $0 as? SlashCommandError else { return XCTFail("Unexpected error type") }
            XCTAssertFalse(error.message.contains("SECRET-TOOL-OUTPUT-123"))
            XCTAssertEqual(error.message, loc("Claude Code did not respond to /model %@.", "sonnet"))
        }
    }

    // MARK: the log file never gets screen or window-title text

    func testAntigravityModelListIsInTheMessageButNotInTheLog() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agy-logtext-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["model": "Gemini 3.8 Flash (High)"], options: [.sortedKeys]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let io = FakeAgy(configURL: url)
        let driver = AntigravityDriver(io: io, sleep: { _ in }, defaults: AntigravityDefaults(url: url), keepDefaults: true)

        XCTAssertThrowsError(try driver.apply(AgentPreset(model: "No Such", effort: "high"))) {
            guard let error = $0 as? SlashCommandError else { return XCTFail("Unexpected error type") }
            XCTAssertTrue(error.message.contains("Gemini 3.8 Flash"), "The notification keeps the picker rows")
            XCTAssertFalse(error.logDescription.contains("Gemini 3.8 Flash"))
            XCTAssertTrue(error.logDescription.contains("‹screen text›"))
            XCTAssertTrue(error.logDescription.contains("No Such"), "The preset's own value is not screen text")
            XCTAssertEqual(SlashCommandError.logText(error), error.logDescription)
        }
    }

    func testReplyBelowTheCommandIsInTheMessageButNotInTheLog() {
        let error = Runner.refused("Model 'x' not found SECRET-REPLY-1")
        XCTAssertTrue(error.message.contains("SECRET-REPLY-1"))
        XCTAssertFalse(error.logDescription.contains("SECRET-REPLY-1"))
        XCTAssertFalse(SlashCommandError.logText(error).contains("SECRET-REPLY-1"))
    }

    // MARK: the log file never gets what an external command printed

    func testCommandOutputIsInTheMessageButNotInTheLog() {
        let error = SlashCommandError("Could not type into tmux: SECRET-PANE-TITLE (no such pane)").quotingOutput(["SECRET-PANE-TITLE (no such pane)"])
        XCTAssertTrue(error.message.contains("SECRET-PANE-TITLE"))
        XCTAssertFalse(error.logDescription.contains("SECRET-PANE-TITLE"))
        XCTAssertTrue(error.logDescription.contains("‹command output›"))
        XCTAssertEqual(error.logDescription, "Could not type into tmux: ‹command output›")
        XCTAssertEqual(error, SlashCommandError("Could not type into tmux: SECRET-PANE-TITLE (no such pane)"), "Quoted output does not change equality")
    }

    #if !os(Windows)
    /// A fake external command that prints a window title on stderr and fails — what tmux or wezterm can do.
    private func failingScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-terminal-\(UUID().uuidString).sh")
        try "#!/bin/sh\necho 'SECRET-PANE-TITLE' >&2\nexit 1\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testTmuxFailureOutputIsInTheMessageButNotInTheLog() throws {
        let script = try failingScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let io = TmuxIO(tmux: script.path, socket: nil, pane: "%1")
        XCTAssertThrowsError(try io.type("x")) {
            guard let error = $0 as? SlashCommandError else { return XCTFail("Unexpected error type") }
            XCTAssertTrue(error.message.contains("SECRET-PANE-TITLE"))
            XCTAssertFalse(error.logDescription.contains("SECRET-PANE-TITLE"))
            XCTAssertTrue(error.logDescription.contains("‹command output›"))
        }
    }

    func testWezTermFailureOutputIsInTheMessageButNotInTheLog() throws {
        let script = try failingScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let io = WezTermIO(wezterm: script.path, socket: nil, pane: "1")
        XCTAssertThrowsError(try io.type("x")) {
            guard let error = $0 as? SlashCommandError else { return XCTFail("Unexpected error type") }
            XCTAssertTrue(error.message.contains("SECRET-PANE-TITLE"))
            XCTAssertFalse(error.logDescription.contains("SECRET-PANE-TITLE"))
            XCTAssertTrue(error.logDescription.contains("‹command output›"))
        }
    }
    #endif

    func testLogDescriptionMasksLongestFirstAndSkipsOneCharacterValues() {
        let error = SlashCommandError("a: tab-title-1 / tab-title-1-extra / x").quoting(["tab-title-1", "tab-title-1-extra", "x"])
        XCTAssertEqual(error.logDescription, "a: ‹screen text› / ‹screen text› / x")
        XCTAssertEqual(error.message, "a: tab-title-1 / tab-title-1-extra / x")
        XCTAssertEqual(error.description, error.message, "The command line and notifications keep the original text")
    }

    func testQuotedValuesDoNotChangeEquality() {
        XCTAssertEqual(SlashCommandError("same"), SlashCommandError("same").quoting(["same-1"]))
    }

    func testLogTextOfAnotherErrorIsItsDescription() {
        struct Other: Error, CustomStringConvertible { var description: String { "other-description" } }
        XCTAssertEqual(SlashCommandError.logText(Other()), "\(Other())")
        XCTAssertEqual(SlashCommandError.logText(Other()), "other-description")
    }

    func testLocalizedDescriptionIsTheMessage() {
        XCTAssertEqual((SlashCommandError("abc") as Error).localizedDescription, "abc")
    }
}
