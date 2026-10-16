import Foundation

/// After `run` opens an agent that "cannot pick a model with launch options" (opencode 2), continues the switch in that terminal.
/// It runs in a separately started process. The screen is being written by the just-opened agent, so there is nowhere to print the result; one line goes to the log file instead.
public enum Follow {
    /// The process `run` opened: pid and start time. `run` turns itself into the agent (`exec`), so that pid is the agent.
    public struct Launched: Equatable, Sendable {
        public let pid: Int32
        public let started: UInt64

        public init(pid: Int32, started: UInt64) {
            self.pid = pid
            self.started = started
        }

        /// This process right now (it will turn into the agent).
        public static func current() -> Launched? {
            #if os(macOS)
            let pid = getpid()
            return ProcessTable.startTime(of: pid).map { Launched(pid: pid, started: $0) }
            #else
            return nil
            #endif
        }

        public var argument: String { "\(pid):\(started)" }

        public init?(argument: String) {
            let parts = argument.split(separator: ":")
            guard parts.count == 2, let pid = Int32(parts[0]), let started = UInt64(parts[1]) else { return nil }
            self.init(pid: pid, started: started)
        }

        #if os(macOS)
        /// Whether that process is still alive (not a different process with the same pid), is that agent, and is the foreground job of its own terminal.
        /// False if the launch failed or the user quit. Even if another session appears in the same terminal, nothing is written to it (PR #29 review).
        func isRunning(_ agent: Agent, entries: [ProcessTable.Entry], startTime: (Int32) -> UInt64?) -> Bool {
            guard startTime(pid) == started, let entry = entries.first(where: { $0.pid == pid }) else { return false }
            return entry.isForeground && AgentProcesses.agent(forCommandLine: entry.arguments.joined(separator: " ")) == agent
        }
        #endif
    }

    /// Waits until the input box is seen "twice in a row" (does not start from one frame of a screen that is just being drawn). If it does not appear in time, nothing is sent.
    /// `alive` is whether the opened process is still that session; it is checked on every wait and again just before applying.
    public static func run(timeoutMs: Int = 30_000, pollMs: Int = 250, sleep: (Int) -> Void = {
                               #if os(macOS)
                               usleep(UInt32($0) * 1000)
                               #else
                               Thread.sleep(forTimeInterval: Double($0) / 1000)
                               #endif
                           },
                           alive: () -> Bool = { true }, ready: () -> Bool, apply: () throws -> String) -> String {
        let gone = "not applied — the session this was opened for is no longer running in that terminal"
        var waited = 0
        var seen = 0
        // Right after starting it may not have done `exec` yet: for the first few tries, "not that agent yet" is not treated as finished.
        var everAlive = false
        while waited <= timeoutMs {
            let running = alive()
            if running { everAlive = true } else if everAlive || waited >= 5000 { return gone }
            seen = running && ready() ? seen + 1 : 0
            if seen >= 2 {
                guard alive() else { return gone }
                do {
                    return "applied — \(try apply())"
                } catch {
                    return "not applied — \(error)"
                }
            }
            sleep(pollMs)
            waited += pollMs
        }
        return "not applied — the input box did not appear within \(timeoutMs / 1000)s"
    }

    public static func run(slot: Int, target: Target, launched: Launched, config: SlashCommandConfig) -> String {
        #if os(macOS)
        guard let io = try? Switcher.terminalIO(for: target) else { return "not applied — the terminal cannot be reached" }
        return run(alive: { launched.isRunning(target.agent, entries: ProcessTable.snapshot().entries, startTime: ProcessTable.startTime(of:)) },
                   ready: { io.screen().map { Readiness.inputVisible(agent: target.agent, screen: $0) } ?? false },
                   apply: {
                       let result = try Switcher(config: config).apply(slot: slot, to: target)
                       // The log file is the only place the result remains: do not drop the warnings (effort could not be set, default could not be restored).
                       return result.summary + (result.warning.map { " ⚠️ \($0)" } ?? "")
                   })
        #else
        return "not applied — \(SlashCommandError(loc("This is not supported on this operating system yet.")))"
        #endif
    }

    /// One line in the same log file as the app (`~/Library/Logs/SlashCommand/slashcommand.log`).
    public static func log(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SlashCommand/slashcommand.log")
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let line = Data("\(formatter.string(from: Date())) \(message)\n".utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}
