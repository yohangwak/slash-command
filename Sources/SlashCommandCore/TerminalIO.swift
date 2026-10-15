import Carbon
import Foundation

/// Puts text and keys into one terminal and, where possible, reads its screen.
public protocol TerminalIO {
    func type(_ text: String) throws
    func press(_ key: Key) throws
    /// The lines of the screen right now. nil for a terminal whose screen cannot be read.
    func screen() -> [String]?
    /// The text being written in the input box. nil if unknown.
    func draft() -> String?
    /// The screen and the draft in one call. A terminal that provides them separately (Orca) gives both in one call.
    func snapshot() -> ScreenSnapshot?
    /// The most the screen read can lag behind the real one (ms). 0 means the screen at the moment of reading.
    var screenLagMs: Int { get }
    /// A screen that is not stale. A terminal that can be stale waits and reads until fresh content is guaranteed.
    func freshSnapshot() -> ScreenSnapshot?
}

public struct ScreenSnapshot: Sendable {
    public let lines: [String]
    /// The text being written in the input box. nil if the terminal does not provide it separately.
    public let draft: String?
}

public extension TerminalIO {
    func draft() -> String? { nil }

    func snapshot() -> ScreenSnapshot? {
        screen().map { ScreenSnapshot(lines: $0, draft: draft()) }
    }

    var screenLagMs: Int { 0 }

    func freshSnapshot() -> ScreenSnapshot? { snapshot() }
}

// MARK: - Orca

public struct OrcaIO: TerminalIO {
    /// Location of the `orca` command. Used only when the app cannot be talked to directly.
    public let orca: String?
    public let handle: String

    public init(orca: String?, handle: String) {
        self.orca = orca
        self.handle = handle
    }

    /// Removes the ORCA_* environment variables so that, even when run inside an Orca terminal, only the specified handle is targeted rather than "that terminal".
    static var cleanEnv: [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ORCA_") }
    }

    /// Puts the bytes in as they are. Enter is also sent as `\r` inside the text.
    private func send(_ text: String) throws {
        let params: [String: Any] = ["terminal": handle, "text": text, "enter": false, "interrupt": false,
                                     "client": ["id": "slashcommand", "type": "desktop"]]
        switch OrcaRuntime.call("terminal.send", params) {
        case .success(let result):
            guard (result["send"] as? [String: Any])?["accepted"] as? Bool == true else {
                throw SlashCommandError(loc("The Orca terminal did not take the input."))
            }
            return
        case .failure(.failed(let message)):
            // It may already have gone in — do not send it again by another route.
            throw SlashCommandError(loc("Could not type into the Orca terminal: %@", message))
        case .failure(.unavailable):
            break
        }
        guard let orca else { throw SlashCommandError(loc("Could not connect to the Orca app, and the orca command was not found either.")) }
        let result = Proc.run(orca, ["terminal", "send", "--terminal", handle, "--text", text, "--json"],
                              env: OrcaIO.cleanEnv, cwd: "/", timeout: 15)
        guard result.ok else {
            throw SlashCommandError(loc("Could not type into the Orca terminal: %@", Self.errorSummary(result)))
        }
    }

    public func type(_ text: String) throws {
        try send(text)
    }

    public func press(_ key: Key) throws {
        try send(key.bytes)
    }

    private func readScreen() -> [String: Any]? {
        var terminal: [String: Any]?
        if case .success(let result) = OrcaRuntime.call("terminal.read", ["terminal": handle, "screen": true]) {
            terminal = result["terminal"] as? [String: Any]
        } else if let orca {
            let result = Proc.run(orca, ["terminal", "read", "--terminal", handle, "--screen", "--json"],
                                  env: OrcaIO.cleanEnv, cwd: "/", timeout: 10)
            if result.ok, let json = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any] {
                terminal = (json["result"] as? [String: Any])?["terminal"] as? [String: Any]
            }
        }
        // "screen-unavailable" is accumulated output, not the screen, so it is not used for the judgment.
        guard let terminal, terminal["source"] as? String == "screen" else { return nil }
        return terminal
    }

    public func screen() -> [String]? {
        readScreen()?["tail"] as? [String]
    }

    public func snapshot() -> ScreenSnapshot? {
        guard let terminal = readScreen(), let lines = terminal["tail"] as? [String] else { return nil }
        return ScreenSnapshot(lines: lines, draft: Self.draft(in: terminal))
    }

    /// Orca separates the input box text from the screen lines and gives it as `draft`. If the input box is empty, the entry itself is absent (measured 2026-10-06).
    public func draft() -> String? {
        readScreen().map(Self.draft(in:))
    }

    static func draft(in terminal: [String: Any]) -> String {
        terminal["draft"] as? String ?? ""
    }

    static func errorSummary(_ result: ProcResult) -> String {
        if result.timedOut { return loc("timed out") }
        if let json = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["code"] as? String) ?? loc("unknown error")
        }
        let text = result.err.isEmpty ? result.out : result.err
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }
}

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

/// Imitates a terminal whose screen follows late: for `lagMs` after the last read, it returns the screen from that time unchanged (Ghostty's behavior).
/// For tests — `SLASHCOMMAND_SCREEN_LAG_MS` lets an Orca session exercise the Ghostty path too.
public final class LaggingIO: TerminalIO {
    let base: TerminalIO
    let lagMs: Int
    private var cached: ScreenSnapshot?
    private var fetchedAt: DispatchTime?
    /// Used when a test drives time directly. With nil, the real time.
    var now: (() -> Int)?
    private var fetchedAtMs = 0

    public init(base: TerminalIO, lagMs: Int) {
        self.base = base
        self.lagMs = lagMs
    }

    private func ageMs() -> Int? {
        if let now { return cached == nil ? nil : now() - fetchedAtMs }
        return fetchedAt.map { Int((DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000) }
    }

    public func type(_ text: String) throws { try base.type(text) }
    public func press(_ key: Key) throws { try base.press(key) }
    public var screenLagMs: Int { lagMs }

    public func snapshot() -> ScreenSnapshot? {
        if let age = ageMs(), age < lagMs, let cached { return cached }
        cached = base.snapshot()
        fetchedAt = .now()
        fetchedAtMs = now?() ?? 0
        return cached
    }

    public func screen() -> [String]? { snapshot()?.lines }

    public func freshSnapshot() -> ScreenSnapshot? {
        if now == nil, let age = ageMs(), age < lagMs { Thread.sleep(forTimeInterval: Double(lagMs - age) / 1000) }
        cached = nil
        return snapshot()
    }
}
