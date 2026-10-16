import Foundation

/// Puts text and keys into one terminal and, where possible, reads its screen.
public protocol TerminalIO {
    func type(_ text: String) throws
    func press(_ key: Key) throws
    /// The lines of the screen right now. nil for a terminal whose screen cannot be read.
    func screen() -> [String]?
    /// Specific reason a read stopped, when known. Never contains screen text.
    var lastFailure: String? { get }
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
    var lastFailure: String? { nil }
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
        #if os(Windows)
        self.orca = orca ?? (try? Proc.locate("orca", extra: Detector.orcaExtraDirectories))
        #else
        self.orca = orca
        #endif
        self.handle = handle
    }

    static var runtimeWorkingDirectory: String {
        #if os(Windows)
        return FileManager.default.temporaryDirectory.path
        #else
        return "/"
        #endif
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
                              env: OrcaIO.cleanEnv, cwd: OrcaIO.runtimeWorkingDirectory, timeout: 15)
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
        #if os(Windows)
        let response = OrcaRuntime.call("terminal.read", ["terminal": handle, "screen": true])
        if case .failure(.failed) = response { return nil }
        #else
        let response = OrcaRuntime.call("terminal.read", ["terminal": handle, "screen": true])
        #endif
        if case .success(let result) = response {
            terminal = result["terminal"] as? [String: Any]
        } else if let orca {
            let result = Proc.run(orca, ["terminal", "read", "--terminal", handle, "--screen", "--json"],
                                  env: OrcaIO.cleanEnv, cwd: OrcaIO.runtimeWorkingDirectory, timeout: 10)
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
