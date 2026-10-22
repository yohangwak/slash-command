import XCTest
@testable import SlashCommandCore

final class TmuxCopyModeTests: KoreanMessagesTestCase {
    private let socket = "sc-copymode-test"
    private var executable: String?

    override func tearDown() {
        if let executable { _ = Proc.run(executable, ["-L", socket, "kill-server"]) }
        super.tearDown()
    }

    func testWriteChecksPaneModeInTheSameCommand() {
        XCTAssertTrue(TmuxIO.sendArguments(pane: "%5", bytes: "x").contains("#{pane_in_mode}"))
    }

    func testCopyModeRefusesKeysAndCancelAllowsThem() throws {
        guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("tmux is not installed in the supported test locations")
        }
        executable = tmux
        func run(_ args: [String]) -> ProcResult { Proc.run(tmux, ["-L", socket] + args) }
        XCTAssertTrue(run(["-f", "/dev/null", "new-session", "-d", "-s", socket, "-x", "80", "-y", "10", "cat"]).ok)
        let pane = "\(socket):0.0"
        XCTAssertTrue(run(["copy-mode", "-t", pane]).ok)
        XCTAssertEqual(run(["display-message", "-p", "-t", pane, "#{pane_in_mode}"]).out.trimmingCharacters(in: .whitespacesAndNewlines), "1")
        let io = TmuxIO(tmux: tmux, socket: socket, pane: pane)
        XCTAssertThrowsError(try io.type("x")) { error in
            XCTAssertEqual((error as? SlashCommandError)?.message, loc("Not sent: this tmux pane is in copy mode, so the keys would not reach the agent. Press q to leave it, then press again."))
        }
        XCTAssertTrue(run(["send-keys", "-t", pane, "-X", "cancel"]).ok)
        XCTAssertNoThrow(try io.type("x"))
        // The existing synchronize-panes guard must still run in the nested command.
        XCTAssertTrue(run(["set-window-option", "-t", pane, "synchronize-panes", "on"]).ok)
        XCTAssertThrowsError(try io.type("y")) { error in
            XCTAssertEqual((error as? SlashCommandError)?.message, loc("Not sent: tmux `synchronize-panes` is on in this window, so the keys would go to its other panes too. Turn it off, then press again."))
        }
    }
}
