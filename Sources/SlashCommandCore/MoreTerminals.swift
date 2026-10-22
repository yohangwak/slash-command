import Foundation

// Connections that write to and read from tmux · kitty · WezTerm. All three were measured on 2026-10-07 on a test Mac (tmux 3.7c · kitty 0.49.2 · WezTerm 20240203):
// whether bytes arrive unchanged (without bracketed-paste wrapping), how fast the screen can be read, and what happens when writing to a target that does not exist.

/// tmux: puts bytes in as hex with `send-keys -H` and reads the screen with `capture-pane -p`.
/// Measured: write 7 ms, 13-40 ms until the written text shows on screen, writing to a missing pane fails (exit code 1).
public struct TmuxIO: TerminalIO {
    public let tmux: String
    public let socket: String?
    public let pane: String

    private func run(_ arguments: [String]) -> ProcResult {
        Proc.run(tmux, TmuxFront.arguments(socket: socket) + arguments, timeout: 5)
    }

    static let synchronizedMark = "SLASHCOMMAND-PANES-SYNCHRONIZED"
    static let inModeMark = "SLASHCOMMAND-PANE-IN-MODE"

    /// The target name to put inside a tmux command string (a session name can contain blanks and quotes).
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The tmux arguments that put bytes into that pane. 🔴 If that window has `synchronize-panes` on, `send-keys -t <pane>` also puts the same text into "the other panes"
    /// even though a target is given (measured 2026-10-12, PR #25 review). Check and write are combined in one tmux command (`if-shell -F`); if it is on, nothing is written and a marker is printed.
    static func sendArguments(pane: String, bytes: String) -> [String] {
        let hex = Array(bytes.utf8).map { String(format: "%02x", $0) }.joined(separator: " ")
        let send = "send-keys -t \(quoted(pane)) -H \(hex)"
        let synchronizedCheck = "if-shell -F -t \(quoted(pane)) '#{pane_synchronized}' \(quoted("display-message -p \(synchronizedMark)")) \(quoted(send))"
        return ["if-shell", "-F", "-t", pane, "#{pane_in_mode}",
                "display-message -p \(inModeMark)", synchronizedCheck]
    }

    private func write(_ bytes: String) throws {
        let result = run(TmuxIO.sendArguments(pane: pane, bytes: bytes))
        guard result.ok else {
            throw SlashCommandError(loc("Could not type into tmux: %@", result.err.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if result.out.contains(TmuxIO.inModeMark) {
            throw SlashCommandError(loc("Not sent: this tmux pane is in copy mode, so the keys would not reach the agent. Press q to leave it, then press again."))
        }
        if result.out.contains(TmuxIO.synchronizedMark) {
            throw SlashCommandError(loc("Not sent: tmux `synchronize-panes` is on in this window, so the keys would go to its other panes too. Turn it off, then press again."))
        }
    }

    public func type(_ text: String) throws { try write(text) }
    public func press(_ key: Key) throws { try write(key.bytes) }

    public func screen() -> [String]? {
        let result = run(["capture-pane", "-p", "-t", pane])
        return result.ok ? result.out.components(separatedBy: "\n") : nil
    }
}

/// kitty: remote control (`kitty @ send-text` · `get-text`). The user must have turned on remote control in the kitty settings.
/// Measured: write 26 ms, about 50 ms until it shows on screen. 🔴 `send-text` to a missing window still returns success (exit code 0),
/// so first check that the window "exists" before writing.
public struct KittyIO: TerminalIO {
    public let kitty: String
    public let socket: String
    public let window: String

    private func run(_ arguments: [String]) -> ProcResult {
        Proc.run(kitty, ["@", "--to", socket] + arguments, timeout: 5)
    }

    private var exists: Bool {
        let result = run(["ls", "--match", "id:\(window)"])
        guard result.ok, let json = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [[String: Any]] else { return false }
        return !json.isEmpty
    }

    private func write(_ bytes: String) throws {
        guard exists else { throw SlashCommandError(loc("Could not find kitty window %@.", window)) }
        let result = run(["send-text", "--match", "id:\(window)", "--", bytes])
        guard result.ok else {
            throw SlashCommandError(loc("Could not type into kitty: %@", result.err.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    public func type(_ text: String) throws { try write(text) }
    public func press(_ key: Key) throws { try write(key.bytes) }

    public func screen() -> [String]? {
        let result = run(["get-text", "--match", "id:\(window)"])
        guard result.ok, !result.out.isEmpty || exists else { return nil }
        return result.out.components(separatedBy: "\n")
    }
}

/// WezTerm: `wezterm cli send-text --no-paste` · `get-text`.
/// Measured: write 15 ms, about 23 ms until it shows on screen, a missing pane fails. 🔴 Without `--no-paste` the text goes in wrapped in paste markers.
public struct WezTermIO: TerminalIO {
    public let wezterm: String
    /// The mux socket of that GUI. Writes and reads go to the same GUI that was used to find the target.
    public var socket: String?
    public let pane: String

    private func run(_ arguments: [String]) -> ProcResult {
        #if os(Windows)
        return Proc.run(wezterm, ["cli", "--no-auto-start"] + arguments, env: WezTermFront.environment(socket: socket), timeout: 5)
        #else
        Proc.run(wezterm, ["cli"] + arguments, env: WezTermFront.environment(socket: socket), timeout: 5)
        #endif
    }

    private func write(_ bytes: String) throws {
        let result = run(["send-text", "--pane-id", pane, "--no-paste", "--", bytes])
        guard result.ok else {
            throw SlashCommandError(loc("Could not type into WezTerm: %@", result.err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(120)))
        }
    }

    public func type(_ text: String) throws { try write(text) }
    public func press(_ key: Key) throws { try write(key.bytes) }

    public func screen() -> [String]? {
        let result = run(["get-text", "--pane-id", pane])
        return result.ok ? result.out.components(separatedBy: "\n") : nil
    }
}
