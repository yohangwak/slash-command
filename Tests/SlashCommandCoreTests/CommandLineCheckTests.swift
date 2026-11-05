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
        XCTAssertNil(CommandLineCheck.problem(in: ["apply", "2", "--bundle", "com.example.Terminal"]))
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
                      "--iterm": "id", "--dump": "/tmp/screen.json", "--lines": "20"]
        for (option, value) in values {
            XCTAssertNil(CommandLineCheck.problem(in: ["doctor", option, value]), option)
            XCTAssertNotNil(CommandLineCheck.problem(in: ["doctor", option]), option)
            XCTAssertNotNil(CommandLineCheck.problem(in: ["doctor", option, "--screen"]), option)
        }
        XCTAssertNil(CommandLineCheck.problem(in: ["probe-orca", "--seconds", "1"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["probe-orca", "--seconds"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["probe-orca", "--seconds", "--screen"]))
    }

    func testRejectsTheSameOptionGivenTwice() {
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--orca", "h1", "--orca"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--agent", "claude", "--agent", "claud"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--agent", "claude", "--agent", "claude"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--trace", "--trace"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["doctor", "--screen", "--screen"]))
    }

    func testRejectsOptionsTheCommandDoesNotRead() {
        // `apply` reads only `--trace`, so `--dry-run` would be ignored and the keys would be sent anyway.
        XCTAssertEqual(CommandLineCheck.problem(in: ["apply", "2", "--dry-run"]), "--dry-run is not used by apply.")
        XCTAssertNotNil(CommandLineCheck.problem(in: ["effort", "up", "--screen"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["doctor", "--seconds", "1"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["list", "--trace"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["path", "--trace"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["plan", "2", "claude", "--trace"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["where", "--trace"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--detach"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--launched", "1:2"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["probe-orca", "--orca", "h1"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--lines", "5"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["where", "--screen"]))
    }

    func testRejectsMoreThanOneTargetHost() {
        XCTAssertNotNil(CommandLineCheck.problem(in: ["apply", "2", "--orca", "h1", "--tmux", "%1", "--agent", "claude"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["where", "--bundle", "com.example.Terminal", "--orca", "h1"]))
        XCTAssertNotNil(CommandLineCheck.problem(in: ["doctor", "--ghostty", "id", "--iterm", "id"]))
        XCTAssertEqual(CommandLineCheck.problem(in: ["apply", "2", "--orca", "h1", "--tmux", "%1"]),
                       "use only one target option (--orca --tmux).")
        // The agent and the sockets belong to the host and do not count as a second target.
        XCTAssertNil(CommandLineCheck.problem(in: ["apply", "2", "--tmux", "%1", "--tmux-socket", "s", "--agent", "claude", "--trace"]))
        XCTAssertNil(CommandLineCheck.problem(in: ["doctor", "--screen", "--lines", "40"]))
    }

    func testSecondsMustBeAPositiveFiniteNumber() {
        for value in ["inf", "nan", "0", "-1", "no"] {
            XCTAssertEqual(CommandLineCheck.problem(in: ["probe-orca", "--seconds", value]), "--seconds needs a positive number.", value)
        }
        XCTAssertNil(CommandLineCheck.problem(in: ["probe-orca", "--seconds", "5"]))
        XCTAssertNil(CommandLineCheck.problem(in: ["probe-orca", "--seconds", "0.5"]))
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
