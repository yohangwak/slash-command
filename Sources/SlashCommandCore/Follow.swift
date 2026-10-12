import Foundation

/// `run` 이 «여는 옵션으로 모델을 못 고르는» 에이전트(opencode 2)를 연 뒤, 그 터미널에서 전환을 이어서 돌린다.
/// 따로 띄운 프로세스에서 돈다 — 화면은 방금 연 에이전트가 쓰고 있어 결과를 찍을 곳이 없으므로 기록 파일에 한 줄 남긴다.
public enum Follow {
    /// `run` 이 연 프로세스: pid 와 시작 시각. `run` 은 자기 자신을 에이전트로 바꾸므로(`exec`) 그 pid 가 곧 에이전트다.
    public struct Launched: Equatable, Sendable {
        public let pid: Int32
        public let started: UInt64

        public init(pid: Int32, started: UInt64) {
            self.pid = pid
            self.started = started
        }

        /// 지금 이 프로세스(곧 에이전트로 바뀐다).
        public static func current() -> Launched? {
            let pid = getpid()
            return ProcessTable.startTime(of: pid).map { Launched(pid: pid, started: $0) }
        }

        public var argument: String { "\(pid):\(started)" }

        public init?(argument: String) {
            let parts = argument.split(separator: ":")
            guard parts.count == 2, let pid = Int32(parts[0]), let started = UInt64(parts[1]) else { return nil }
            self.init(pid: pid, started: started)
        }

        /// 그 프로세스가 아직 살아 있고(같은 pid 의 다른 프로세스가 아니다), 그 에이전트이고, 자기 터미널의 앞 작업인가.
        /// 열기가 실패했거나 사용자가 끝냈으면 거짓 — 같은 터미널에 다른 세션이 떠도 그 세션에 쓰지 않는다(PR #29 리뷰).
        func isRunning(_ agent: Agent, entries: [ProcessTable.Entry], startTime: (Int32) -> UInt64?) -> Bool {
            guard startTime(pid) == started, let entry = entries.first(where: { $0.pid == pid }) else { return false }
            return entry.isForeground && AgentProcesses.agent(forCommandLine: entry.arguments.joined(separator: " ")) == agent
        }
    }

    /// 입력창이 «연달아 두 번» 보일 때까지 기다린다(막 그려지는 화면의 한 장면으로 시작하지 않는다). 시간 안에 안 뜨면 아무것도 보내지 않는다.
    /// `alive` 는 연 프로세스가 아직 그 세션인가 — 기다리는 동안 매번, 그리고 적용 직전에 다시 본다.
    public static func run(timeoutMs: Int = 30_000, pollMs: Int = 250, sleep: (Int) -> Void = { usleep(UInt32($0) * 1000) },
                           alive: () -> Bool = { true }, ready: () -> Bool, apply: () throws -> String) -> String {
        let gone = "not applied — the session this was opened for is no longer running in that terminal"
        var waited = 0
        var seen = 0
        // 막 띄운 직후에는 아직 `exec` 전일 수 있다 — 처음 몇 번은 «아직 그 에이전트가 아님» 을 끝난 것으로 보지 않는다.
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
        guard let io = try? Switcher.terminalIO(for: target) else { return "not applied — the terminal cannot be reached" }
        return run(alive: { launched.isRunning(target.agent, entries: ProcessTable.snapshot().entries, startTime: ProcessTable.startTime(of:)) },
                   ready: { io.screen().map { Readiness.inputVisible(agent: target.agent, screen: $0) } ?? false },
                   apply: {
                       let result = try Switcher(config: config).apply(slot: slot, to: target)
                       // 결과가 남는 곳은 기록 파일뿐이다 — 경고(effort 를 정하지 못함 · 기본값을 되돌리지 못함)를 빼지 않는다.
                       return result.summary + (result.warning.map { " ⚠️ \($0)" } ?? "")
                   })
    }

    /// 앱과 같은 기록 파일(`~/Library/Logs/SlashCommand/slashcommand.log`)에 한 줄.
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
