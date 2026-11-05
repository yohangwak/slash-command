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
