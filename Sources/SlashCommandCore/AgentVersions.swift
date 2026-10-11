import Foundation

/// 에이전트(claude·codex)의 판을 알아내고, 우리가 화면 문구를 «실제로 본» 판인지 대조한다.
///
/// 전환은 에이전트가 그리는 문구(`Select model` · `Set model to` 등)에 기댄다. 판이 바뀌어 문구가 달라지면 화면을 못 알아봐서
/// 아무것도 보내지 않고 멈춘다(안전한 쪽) — 그래도 «왜 안 되는지» 를 `doctor` 가 먼저 말해 줄 수 있어야 한다.
public enum AgentVersions {
    /// 선택창 문구·키 동작을 실제 세션에서 확인한 판(docs/PLAN-generalization.md 「화면 문구에 기댄다」 · README 실측 표).
    /// 목록에 없다고 동작하지 않는다는 뜻은 아니다 — 확인하지 못했다는 뜻이다.
    /// 실행 중인 프로세스에서 판을 읽지 못했을 때의 표시.
    static var unknown: String { loc("unknown") }

    public static let tested: [Agent: Set<String>] = [
        .claude: ["2.1.283", "2.1.288", "2.1.289", "2.1.291", "2.1.292", "2.1.296"],
        .codex: ["0.156.0", "0.160.0", "0.160.1", "0.162.0"],
        .grok: ["1.0.46", "1.0.50"],
        .cursor: ["2026.10.01-14929f9", "2026.10.01-e373342"],
        .antigravity: ["1.3.1", "1.3.3"],
        .opencode: ["1.18.35"],
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
            if installed == nil { result.append(loc("installed %@", agent.rawValue)) }
            if running.contains(AgentVersions.unknown) { result.append(loc("some running %@", agent.rawValue)) }
            return result
        }

        public var lines: [String] {
            var result: [String] = []
            let runningText = running.isEmpty ? loc("none") : running.joined(separator: ", ")
            result.append(loc("%@ version  installed %@ · running %@", agent.rawValue, installed ?? AgentVersions.unknown, runningText))
            if !unreadable.isEmpty {
                result.append(loc("⚠️           version not readable for: %@ — cannot tell whether it is a verified version", unreadable.joined(separator: ", ")))
            }
            if untested.isEmpty {
                if unreadable.isEmpty { result.append(loc("             verified version")) }
            } else {
                let known = (AgentVersions.tested[agent] ?? []).sorted().joined(separator: ", ")
                result.append(loc("⚠️           unverified version: %@ (verified: %@) — if the wording on screen has changed, switching stops instead of guessing", untested.joined(separator: ", "), known))
            }
            return result
        }
    }

    public static func report(for agent: Agent) -> Report {
        Report(agent: agent, installed: installed(agent), running: running(agent))
    }

    // MARK: - 설치된 판

    public static func installed(_ agent: Agent) -> String? {
        guard let exe = Proc.locate(agent.executable) else { return nil }
        let result = Proc.run(exe, ["--version"], timeout: 5)
        guard result.ok else { return nil }
        return parse(versionOutput: result.out)
    }

    /// `2.1.291 (Claude Code)` · `codex-cli 0.160.1` 처럼 숫자.숫자.숫자 꼴의 첫 토큰.
    static func parse(versionOutput: String) -> String? {
        for token in versionOutput.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let text = token.trimmingCharacters(in: CharacterSet(charactersIn: "v()"))
            if isVersion(text) { return text }
            // `2026.10.01-14929f9`(cursor-agent)처럼 뒤에 빌드 표시가 붙은 판.
            if text.first?.isNumber == true, let tagged = release(from: text) { return tagged }
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
            // 플랫폼만 떼고, 시험판 표시(`0.160.0-alpha.6`)는 남긴다 — 확인한 안정판으로 오인하면 안 된다.
            guard index + 1 < components.count, let found = release(from: components[index + 1]) else { continue }
            return found
        }
        // Homebrew 로 깐 꼴: `…/Caskroom/cursor-cli/2026.10.01-e373342/…` · `…/Cellar/opencode/2.0.25/…` — 이름 다음 칸이 판이다.
        // 에이전트를 돌리는 실행기(`…/Cellar/node/26.8.2/bin/node`)의 판은 에이전트의 판이 아니다.
        for (index, component) in components.enumerated() where component == "Caskroom" || component == "Cellar" {
            guard index + 2 < components.count, let found = release(from: components[index + 2]) else { continue }
            let package = components[index + 1].split(separator: "@").first.map(String.init) ?? ""
            if ["node", "bun", "deno", "python", "ruby"].contains(package) { continue }
            return found
        }
        return nil
    }

    /// 폴더 이름에서 판을 뽑는다: `0.160.1` · `0.160.1-aarch64-apple-darwin` → `0.160.1`, `0.160.0-alpha.6-aarch64-apple-darwin` → `0.160.0-alpha.6`.
    static func release(from folder: String) -> String? {
        var name = folder
        for platform in ["-aarch64-", "-x86_64-"] {
            if let range = name.range(of: platform) { name = String(name[..<range.lowerBound]) }
        }
        let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
        guard let head = parts.first, isVersion(head) else { return nil }
        if parts.count == 2, parts[1].isEmpty || !parts[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) { return nil }
        return name
    }
}
