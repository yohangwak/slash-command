import Foundation

/// 에이전트(claude·codex)의 판을 알아내고, 우리가 화면 문구를 «실제로 본» 판인지 대조한다.
///
/// 전환은 에이전트가 그리는 문구(`Select model` · `Set model to` 등)에 기댄다. 판이 바뀌어 문구가 달라지면 화면을 못 알아봐서
/// 아무것도 보내지 않고 멈춘다(안전한 쪽) — 그래도 «왜 안 되는지» 를 `doctor` 가 먼저 말해 줄 수 있어야 한다.
public enum AgentVersions {
    /// 선택창 문구·키 동작을 실제 세션에서 확인한 판(docs/PLAN-generalization.md 「화면 문구에 기댄다」 · README 실측 표).
    /// 목록에 없다고 동작하지 않는다는 뜻은 아니다 — 확인하지 못했다는 뜻이다.
    /// 실행 중인 프로세스에서 판을 읽지 못했을 때의 표시.
    static let unknown = "알 수 없음"

    public static let tested: [Agent: Set<String>] = [
        .claude: ["2.1.283", "2.1.288", "2.1.289", "2.1.291"],
        .codex: ["0.156.0", "0.160.0", "0.160.1"],
    ]

    public struct Report: Equatable, Sendable {
        public let agent: Agent
        /// 설치된 실행 파일이 말하는 판. 못 알아냈으면 nil.
        public let installed: String?
        /// 지금 터미널에서 도는 같은 종류 프로세스들의 판(오래된 세션은 업데이트 전 판일 수 있다).
        public let running: [String]

        public var untested: [String] {
            let known = AgentVersions.tested[agent] ?? []
            return Array(Set(([installed].compactMap { $0 }) + running.filter { $0 != AgentVersions.unknown }).subtracting(known)).sorted()
        }

        /// 판을 읽지 못한 항목 — 「확인한 판」이라고 말할 근거가 없다.
        public var unreadable: [String] {
            var result: [String] = []
            if installed == nil { result.append("설치된 \(agent.rawValue)") }
            if running.contains(AgentVersions.unknown) { result.append("실행 중인 \(agent.rawValue) 일부") }
            return result
        }

        public var lines: [String] {
            var result: [String] = []
            result.append("\(agent.rawValue) 판     설치 \(installed ?? AgentVersions.unknown) · 실행 중 \(running.isEmpty ? "없음" : running.joined(separator: ", "))")
            if !unreadable.isEmpty {
                result.append("⚠️           판을 읽지 못한 것: \(unreadable.joined(separator: ", ")) — 확인한 판인지 알 수 없습니다")
            }
            if untested.isEmpty {
                if unreadable.isEmpty { result.append("             확인한 판입니다") }
            } else {
                let known = (AgentVersions.tested[agent] ?? []).sorted().joined(separator: ", ")
                result.append("⚠️           확인 못 한 판: \(untested.joined(separator: ", ")) (확인한 판: \(known)) — 화면 문구가 달라졌으면 전환하지 않고 멈춥니다")
            }
            return result
        }
    }

    public static func report(for agent: Agent) -> Report {
        Report(agent: agent, installed: installed(agent), running: running(agent))
    }

    // MARK: - 설치된 판

    public static func installed(_ agent: Agent) -> String? {
        guard let exe = Proc.locate(agent.rawValue) else { return nil }
        let result = Proc.run(exe, ["--version"], timeout: 5)
        guard result.ok else { return nil }
        return parse(versionOutput: result.out)
    }

    /// `2.1.291 (Claude Code)` · `codex-cli 0.160.1` 처럼 숫자.숫자.숫자 꼴의 첫 토큰.
    static func parse(versionOutput: String) -> String? {
        for token in versionOutput.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let text = token.trimmingCharacters(in: CharacterSet(charactersIn: "v()"))
            if isVersion(text) { return text }
        }
        return nil
    }

    static func isVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    // MARK: - 실행 중인 판

    public static func running(_ agent: Agent) -> [String] {
        let table = ProcessTable.snapshot()
        let found: [(commandLine: String, executable: String)]
        if !table.entries.isEmpty {
            found = table.entries.map { ($0.arguments.joined(separator: " "), $0.executable) }
        } else {
            let ps = Proc.run("/bin/ps", ["-axo", "tty=,args="], timeout: 5)
            found = ps.ok ? ps.out.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                return fields.count == 2 && fields[0] != "??" ? (String(fields[1]), "") : nil
            } : []
        }
        // 에이전트인데 판을 못 읽은 프로세스는 «알 수 없음» 으로 센다 — 「없음」으로 보이면 안 된다.
        let versions = found.compactMap { entry -> String? in
            guard AgentProcesses.agent(forCommandLine: entry.commandLine) == agent else { return nil }
            return version(inCommandLine: entry.commandLine) ?? version(inCommandLine: entry.executable) ?? unknown
        }
        return Array(Set(versions)).sorted()
    }

    /// 실행 파일 경로에 판이 들어 있는 설치 꼴: claude `…/claude/versions/2.1.289` · codex `…/releases/0.160.0/bin/codex`.
    static func version(inCommandLine commandLine: String) -> String? {
        guard let first = commandLine.split(separator: " ").first else { return nil }
        let components = first.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() where component == "versions" || component == "releases" {
            // codex 의 설치 폴더는 `0.160.1-aarch64-apple-darwin` 처럼 플랫폼이 붙기도 한다.
            guard index + 1 < components.count,
                  let head = components[index + 1].split(separator: "-", maxSplits: 1).first.map(String.init),
                  isVersion(head) else { continue }
            return head
        }
        return nil
    }
}
