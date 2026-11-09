import Foundation

/// The project pages that Settings, the menu and the Windows tray open in the browser.
///
/// The app makes no network connection itself: it hands an address to the system and the browser opens it. GitHub receives the
/// address, values included, when the page opens; the issue is posted only when the person submits the form. The only values put into an address are version numbers: this app's, the system's and
/// the agents'. Never text read from a screen, the log, a path, a preset or a window title.
public enum ProjectLinks {
    public static let repository = URL(string: "https://github.com/yohangwak/slash-command")!
    public static var discussions: URL { repository.appendingPathComponent("discussions") }
    public static var releases: URL { repository.appendingPathComponent("releases") }

    /// This app's version, built into the program. A test keeps it equal to `scripts/Info.plist`, the bundle's version.
    /// (Not read from `Bundle.main`: in a test or a bare command line build that is some other program's bundle, or none.)
    public static var appVersion: String { WindowsAppModel.version }

    /// `macOS 15.4.1` · `Windows 10.0.26100`.
    public static var systemDescription: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(Windows)
        let name = "Windows"
        #else
        let name = "macOS"
        #endif
        return "\(name) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// A new bug report (`.github/ISSUE_TEMPLATE/bug_report.yml`) with that form's `version`, `macos` and `agent` fields filled in.
    /// GitHub fills issue form fields from query parameters named after their `id`. An empty value leaves its field empty.
    public static func bugReport(appVersion: String, system: String, agents: String) -> URL {
        let fields = [("template", "bug_report.yml"), ("version", appVersion), ("macos", system), ("agent", agents)]
        let query = fields.filter { !$0.1.isEmpty }.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        return URL(string: repository.absoluteString + "/issues/new?" + query)!
    }

    /// `Claude Code 2.1.319 · Codex 0.162.0`: the agents with a version, in the app's order of agents.
    public static func agentSummary(_ versions: [Agent: String]) -> String {
        Agent.allCases.compactMap { agent in versions[agent].map { "\(agent.displayName) \($0)" } }.joined(separator: " · ")
    }

    /// Asks every agent's executable for `--version` at the same time (each gives up after 5 seconds) and keeps those that answered.
    /// It starts processes, so call it off the main thread.
    public static func installedAgentVersions() -> [Agent: String] {
        let agents = Agent.allCases
        let found = Found(count: agents.count)
        DispatchQueue.concurrentPerform(iterations: agents.count) { index in
            found.set(index, AgentVersions.installed(agents[index]))
        }
        var versions: [Agent: String] = [:]
        for (index, agent) in agents.enumerated() {
            if let version = found.value(index) { versions[agent] = version }
        }
        return versions
    }

    /// Percent-encodes everything except the unreserved characters, so `+`, `&`, `=` and `#` in a value cannot change the query.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String?]
        init(count: Int) { values = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ value: String?) { lock.lock(); values[index] = value; lock.unlock() }
        func value(_ index: Int) -> String? { lock.lock(); defer { lock.unlock() }; return values[index] }
    }
}
