#if os(macOS)
import Carbon
import Foundation

// MARK: - Ghostty

/// Ghostty writes bytes straight to the pty with AppleScript's `perform action "text:…"`, and reads the screen through accessibility (AX).
/// (`input text` is wrapped as a paste and does not act as the number/letter keys of a picker, and `send key` does not know the names of arrows and digits.)
public struct GhosttyIO: TerminalIO {
    public let terminalID: String

    public init(terminalID: String) {
        self.terminalID = terminalID
    }

    /// Runs AppleScript inside this process. Launching `osascript` costs 0.2-0.3 s each time (measured 2026-10-06).
    /// The result is returned in the same form `osascript` printed (booleans as "true" and "false").
    static func osascript(_ script: String) -> ProcResult {
        let bounded = timeLimited(script)
        // NSAppleScript is meant to be used only on the main thread.
        if Thread.isMainThread { return runAppleScript(bounded) }
        return DispatchQueue.main.sync { runAppleScript(bounded) }
    }

    /// Seconds to wait for Ghostty's answer. Without a limit AppleScript waits up to 2 minutes — if Ghostty does not respond,
    /// the main thread would stall and the menu, notifications and hotkeys would all stop. The usual answer takes tens of ms.
    static let replySeconds = 5

    /// Wraps the whole script in `with timeout`. The last value, `return` and `error` come out as they did before wrapping (confirmed 2026-10-11).
    static func timeLimited(_ script: String) -> String {
        "with timeout of \(replySeconds) seconds\n\(script)\nend timeout"
    }

    private static func runAppleScript(_ source: String) -> ProcResult {
        guard let script = NSAppleScript(source: source) else {
            return Proc.run("/usr/bin/osascript", ["-e", source], timeout: 10)
        }
        var error: NSDictionary?
        let value = script.executeAndReturnError(&error)
        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String) ?? loc("AppleScript error")
            let number = (error[NSAppleScript.errorNumber] as? Int).map { " (\($0))" } ?? ""
            return ProcResult(status: 1, out: "", err: message + number, timedOut: false)
        }
        let out: String
        switch value.descriptorType {
        case typeTrue: out = "true"
        case typeFalse: out = "false"
        case typeBoolean: out = value.booleanValue ? "true" : "false"
        default: out = value.stringValue ?? ""
        }
        return ProcResult(status: 0, out: out, err: "", timedOut: false)
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Ghostty's `text:` action decodes Zig string escapes. Only control characters and backslash are escaped; everything else is left as is.
    static func actionEscaped(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar == "\\" {
                out += "\\\\"
            } else if scalar.value < 0x20 || scalar.value == 0x7F {
                out += String(format: "\\x%02x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private func write(_ bytes: String) throws {
        let action = "text:" + GhosttyIO.actionEscaped(bytes)
        // The screen is read from "the focused terminal". The place we write to must be that same terminal,
        // so we write only when the target is still the focused terminal of the frontmost window.
        let gone = loc("The target terminal is no longer in front")
        let script = """
        tell application "Ghostty"
            set t to focused terminal of selected tab of front window
            if (id of t) is not \(GhosttyIO.quoted(terminalID)) then error \(GhosttyIO.quoted(gone))
            perform action \(GhosttyIO.quoted(action)) on t
        end tell
        """
        let result = GhosttyIO.osascript(script)
        guard result.ok, result.out.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            let detail = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = detail.isEmpty ? loc("The target terminal is no longer in the front window") : detail
            throw SlashCommandError(loc("Could not type into Ghostty: %@", reason))
        }
    }

    public func type(_ text: String) throws {
        try write(text)
    }

    public func press(_ key: Key) throws {
        try write(key.bytes)
    }

    /// Ghostty gives back the same on-screen text via accessibility for 0.5 s after it last gave it out
    /// (measured 2026-10-06: text changed right after a read shows up only 507 ms later, and after a 0.7 s pause it shows immediately).
    public var screenLagMs: Int { GhosttyScreen.cacheMs }

    /// The screen read through accessibility is that of "the focused terminal in Ghostty". Checks that it is the target terminal.
    /// (2026-10-06: when the user moved to their own window behind the test window, the screen of that non-target window was read.)
    func targetIsFocused() -> Bool {
        let script = """
        tell application "Ghostty"
            if (count of windows) is 0 then return ""
            return id of focused terminal of selected tab of front window
        end tell
        """
        let result = GhosttyIO.osascript(script)
        return result.ok && result.out.trimmingCharacters(in: .whitespacesAndNewlines) == terminalID
    }

    public func screen() -> [String]? {
        guard targetIsFocused() else { return nil }
        // Reading can fail briefly while the screen is being drawn. Read a few more times so that single failure does not make us give up in the middle of a switch.
        for attempt in 0..<5 {
            if let lines = GhosttyScreen.lines() { return lines }
            guard GhosttyScreen.trusted() else { return nil }
            if attempt < 4 { Thread.sleep(forTimeInterval: 0.08) }
        }
        return nil
    }

    /// If less than 0.5 s has passed since the last read (or it is unknown), waits that long and then reads — that way it is the current screen.
    public func freshSnapshot() -> ScreenSnapshot? {
        GhosttyScreen.waitUntilFresh()
        return snapshot()
    }
}

#endif
