import XCTest
@testable import SlashCommandCore

final class CommandLineCheckTests: XCTestCase {
    func testRejectsMissingOptionValuesBeforeTargetDetection() {
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--orca"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--orca", "--agent", "claude"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--orca", ""]))
    }

    func testRejectsUnknownOptionsAndAgents() {
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--ghosty", "x"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--tmux", "%1", "--agent", "claud"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--orca h1 --agent claude"]))
    }

    func testLinesMustBeAPositiveInteger() {
        for value in ["-1", "0", "no", "1.5", "999999999999999999999999999"] {
            XCTAssertNotNil(CommandLineCheck.problem(in: ["doctor", "--screen", "--lines", value]), value)
        }
        XCTAssertNil(CommandLineCheck.problem(in: ["doctor", "--screen", "--lines", "20"]))
    }

    func testAcceptsExplicitTargetAndTrace() {
        XCTAssertNil(CommandLineCheck.problem(in: ["apply", "2", "--orca", "h1", "--agent", "claude", "--trace"]))
        XCTAssertNil(CommandLineCheck.problem(in: ["apply", "2", "--bundle", "com.example.Terminal", "--orca", "h1"]))
    }

    func testAcceptsPositionalArgumentsAndHelp() {
        for args in [[String](), ["list"], ["--help"], ["plan", "2", "codex"], ["effort", "up"], ["run", "2", "claude", "--dry-run"]] {
            XCTAssertNil(CommandLineCheck.problem(in: args), "\(args)")
        }
    }

    func testEveryValueOptionRequiresItsOwnValue() {
        let values = ["--orca": "h1", "--ghostty": "id", "--bundle": "com.example.Terminal",
                      "--app": "windowsterminal", "--console": "42", "--agent": "claude",
                      "--tmux": "%1", "--tmux-socket": "socket", "--kitty": "1",
                      "--kitty-socket": "unix:/tmp/socket", "--wezterm": "1", "--wezterm-socket": "socket",
                      "--iterm": "id", "--dump": "/tmp/screen.json", "--lines": "20", "--seconds": "1"]
        for (option, value) in values {
            XCTAssertNil(CommandLineCheck.problem(in: ["doctor", option, value]), option)
            XCTAssertNotNil(CommandLineCheck.problem(in: ["doctor", option]), option)
            XCTAssertNotNil(CommandLineCheck.problem(in: ["doctor", option, "--screen"]), option)
        }
    }

    func testValidatesEveryOccurrenceOfAnOption() {
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--orca", "h1", "--orca"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--agent", "claude", "--agent", "claud"]))
    }

    func testInternalCommandsAreNotChecked() {
        for command in ["__console-bridge", "follow", "keep-defaults"] {
            XCTAssertNil(CommandLineCheck.problem(in: [command, "--internal-option"]))
        }
    }

    func testRunValidatesItsAgentAndPreservesForwardedArguments() {
        XCTAssertNil(CommandLineCheck.problem(in: ["run", "2", "claude", "--dry-run", "--resume"]))
        XCTAssertNil(CommandLineCheck.problem(in: ["run", "2", "claude", "--resume"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["run", "2", "claud"]))
    }

    func testRejectsStrayOrEmptyPositionalArguments() {
        // A target whose option was lost, or an empty shell variable, must not fall back to the frontmost session.
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "sctest:0.0"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", ""]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["effort", "up", "x"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["doctor", "x"]))
        XCTAssertNil(CommandLineCheck.problem(in: ["apply", "2"]))
        XCTAssertNil(CommandLineCheck.problem(in: ["effort", "down", "--trace"]))
        XCTAssertNil(CommandLineCheck.problem(in: ["plan", "2", "claude"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["plan", "2", "claude", "x"]))
    }
}
