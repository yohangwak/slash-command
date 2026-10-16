import Foundation

/// Works out the version of an agent (claude, codex) and checks whether it is a version whose on-screen text we have "actually seen".
///
/// Switching relies on the text the agent draws (`Select model`, `Set model to`, and so on). If a version changes that text, the screen is not recognized and
/// nothing is sent; it stops (the safe side). Even so, `doctor` should be able to say "why it does not work" first.
public enum AgentVersions {
    /// Versions whose picker text and key behavior were checked in a real session (the table in docs/agents.md).
    /// Not being in the list does not mean it does not work; it means it was not checked.
    /// What is shown when the version could not be read from the running process.
    static var unknown: String { loc("unknown") }

    public static let tested: [Agent: Set<String>] = [
        .claude: ["2.1.283", "2.1.288", "2.1.289", "2.1.291", "2.1.292", "2.1.296"],
        .codex: ["0.156.0", "0.160.0", "0.160.1", "0.162.0"],
        .grok: ["1.0.46", "1.0.50"],
        .cursor: ["2026.10.01-14929f9", "2026.10.01-e373342"],
        .antigravity: ["1.3.1", "1.3.3"],
        .opencode: ["1.18.35", "2.0.25"],
    ]

    public struct Report: Equatable, Sendable {
        public let agent: Agent
        /// The version the installed executable reports. nil if it could not be determined.
        public let installed: String?
        /// Versions of processes of the same kind now running in terminals (an old session may be a pre-update version).
        public let running: [String]

        public var untested: [String] {
            let known = AgentVersions.tested[agent] ?? []
            return Array(Set(([installed].compactMap { $0 }) + running.filter { $0 != AgentVersions.unknown }).subtracting(known)).sorted()
        }

        /// An item whose version could not be read: there is no basis to call it a "checked version".
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

    // MARK: - Installed version

    public static func installed(_ agent: Agent) -> String? {
        guard let exe = Proc.locate(agent.executable) else { return nil }
        let result = Proc.run(exe, ["--version"], timeout: 5)
        guard result.ok else { return nil }
        return parse(versionOutput: result.out)
    }

    /// The first token shaped like number.number.number, as in `2.1.291 (Claude Code)` · `codex-cli 0.160.1`.
    static func parse(versionOutput: String) -> String? {
        for token in versionOutput.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let text = token.trimmingCharacters(in: CharacterSet(charactersIn: "v()"))
            if isVersion(text) { return text }
            // A version with a build suffix after it, like `2026.10.01-14929f9` (cursor-agent).
            if text.first?.isNumber == true, let tagged = release(from: text) { return tagged }
        }
        return nil
    }

    static func isVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    // MARK: - Running version

    public static func running(_ agent: Agent) -> [String] {
        #if os(macOS)
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
        // A process that is an agent but whose version could not be read counts as "unknown"; it must not look like "none".
        let versions = found.compactMap { entry -> String? in
            guard AgentProcesses.agent(forCommandLine: entry.commandLine) == agent else { return nil }
            return version(inCommandLine: entry.commandLine) ?? version(inCommandLine: entry.executable) ?? unknown
        }
        return Array(Set(versions)).sorted()
        #else
        return [unknown]
        #endif
    }

    /// Install layouts whose executable path contains the version: claude `…/claude/versions/2.1.289` · codex `…/releases/0.160.0/bin/codex`.
    static func version(inCommandLine commandLine: String) -> String? {
        guard let first = commandLine.split(separator: " ").first else { return nil }
        let components = first.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() where component == "versions" || component == "releases" {
            // codex's install folder can also carry a platform, like `0.160.1-aarch64-apple-darwin`.
            // Strip only the platform and keep the prerelease marker (`0.160.0-alpha.6`): it must not be mistaken for a checked stable version.
            guard index + 1 < components.count, let found = release(from: components[index + 1]) else { continue }
            return found
        }
        // Layout installed with Homebrew: `…/Caskroom/cursor-cli/2026.10.01-e373342/…` · `…/Cellar/opencode/2.0.25/…`. The segment after the name is the version.
        // The version of a runtime that runs the agent (`…/Cellar/node/26.8.2/bin/node`) is not the agent's version.
        for (index, component) in components.enumerated() where component == "Caskroom" || component == "Cellar" {
            guard index + 2 < components.count, let found = release(from: components[index + 2]) else { continue }
            let package = components[index + 1].split(separator: "@").first.map(String.init) ?? ""
            if ["node", "bun", "deno", "python", "ruby"].contains(package) { continue }
            return found
        }
        return nil
    }

    /// Extracts the version from a folder name: `0.160.1` · `0.160.1-aarch64-apple-darwin` → `0.160.1`, `0.160.0-alpha.6-aarch64-apple-darwin` → `0.160.0-alpha.6`.
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
