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
}
