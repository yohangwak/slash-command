import Foundation

/// `run` 이 «여는 옵션으로 모델을 못 고르는» 에이전트(opencode 2)를 연 뒤, 그 터미널에서 전환을 이어서 돌린다.
/// 따로 띄운 프로세스에서 돈다 — 화면은 방금 연 에이전트가 쓰고 있어 결과를 찍을 곳이 없으므로 기록 파일에 한 줄 남긴다.
public enum Follow {
    /// 입력창이 «연달아 두 번» 보일 때까지 기다린다(막 그려지는 화면의 한 장면으로 시작하지 않는다). 시간 안에 안 뜨면 아무것도 보내지 않는다.
    public static func run(timeoutMs: Int = 30_000, pollMs: Int = 250, sleep: (Int) -> Void = { usleep(UInt32($0) * 1000) },
                           ready: () -> Bool, apply: () throws -> String) -> String {
        var waited = 0
        var seen = 0
        while waited <= timeoutMs {
            seen = ready() ? seen + 1 : 0
            if seen >= 2 {
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

    public static func run(slot: Int, target: Target, config: SlashCommandConfig) -> String {
        guard let io = try? Switcher.terminalIO(for: target) else { return "not applied — the terminal cannot be reached" }
        return run(ready: { io.screen().map { Readiness.inputVisible(agent: target.agent, screen: $0) } ?? false },
                   apply: { try Switcher(config: config).apply(slot: slot, to: target).summary })
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
