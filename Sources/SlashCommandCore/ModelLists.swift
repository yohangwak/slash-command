import Foundation

/// The model menu of Settings for agents that keep no model list on disk (Cursor Agent, Antigravity).
/// Only when the person presses Refresh Model Lists, the app runs that agent's own command (`cursor-agent models`, `agy models`) — the same one
/// `slashcommand run` uses — and keeps the names it printed. That command asks the agent's service, signed in as the person; the app opens no connection
/// and sends nothing of its own. No prompt is sent and no model is run.
public enum ModelLists {
    /// The agents whose list can be refreshed, in menu order.
    public static let agents: [Agent] = [.cursor, .antigravity]

    /// The names in the order the command printed them, each once (effort and Fast variants of one model are one name).
    public static func names(agent: Agent, listing: String) -> [String] {
        let all: [String]
        switch agent {
        case .cursor: all = Launch.cursorRows(listing: listing).map(\.name)
        case .antigravity: all = Launch.antigravityRows(listing: listing).map(\.name)
        default: return []
        }
        var seen: Set<String> = []
        return all.filter { !$0.isEmpty && seen.insert(Launch.key($0)).inserted }
    }

    public enum Outcome: Equatable, Sendable {
        case names([String])
        case notInstalled
        case failed(String)
    }

    /// Runs each agent's list command. `locate` finds the executable, `run` runs it (both replaceable in tests).
    public static func ask(_ agents: [Agent] = ModelLists.agents,
                           locate: (String) -> String? = { Proc.locate($0) },
                           run: (String, [String]) -> ProcResult = { Proc.run($0, $1, timeout: 30) }) -> [Agent: Outcome] {
        var outcomes: [Agent: Outcome] = [:]
        for agent in agents {
            guard let command = Launch.listing(agent: agent), let exe = locate(command[0]) else {
                outcomes[agent] = .notInstalled
                continue
            }
            let result = run(exe, Array(command.dropFirst()))
            if result.timedOut {
                outcomes[agent] = .failed(loc("timed out"))
                continue
            }
            let found = result.ok ? names(agent: agent, listing: result.out) : []
            if found.isEmpty {
                // The reason is the first line the command printed (it may say to sign in), cut short. It is never logged.
                let first = (result.err + "\n" + result.out).split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                outcomes[agent] = .failed(String((first.map(String.init) ?? loc("no models listed")).prefix(120)))
            } else {
                outcomes[agent] = .names(found)
            }
        }
        return outcomes
    }

    /// Next to the presets file: `~/.config/slashcommand/model-lists.json`. If the presets file itself has that name
    /// (`SLASHCOMMAND_CONFIG`), `<presets file>.model-lists.json`, so the two never share a path.
    public static var defaultURL: URL { url(besides: ConfigStore.defaultURL) }

    static func url(besides presets: URL) -> URL {
        let url = presets.deletingLastPathComponent().appendingPathComponent("model-lists.json")
        // Compared without case: the usual Mac volume treats `Model-Lists.json` and `model-lists.json` as one file.
        let same = url.standardizedFileURL.path.lowercased() == presets.standardizedFileURL.path.lowercased()
        return same ? presets.appendingPathExtension("model-lists.json") : url
    }

    /// `kind` marks the file as ours: a presets file (or any other JSON) never reads as a model list, so it is never written over.
    struct File: Codable {
        static let marker = "slashcommand-model-lists"
        var kind = File.marker
        var version = 1
        var lists: [String: [String]]
        static func read(_ data: Data) -> File? {
            guard let file = try? JSONDecoder().decode(File.self, from: data), file.kind == marker else { return nil }
            return file
        }
    }

    /// The saved lists. Empty if there is no file or it cannot be read; the built-in lists are used then.
    public static func load(from url: URL = ModelLists.defaultURL) -> [Agent: [String]] {
        guard let data = try? Data(contentsOf: url), let file = File.read(data) else { return [:] }
        var lists: [Agent: [String]] = [:]
        for (key, names) in file.lists {
            if let agent = Agent(rawValue: key), agents.contains(agent), !names.isEmpty { lists[agent] = names }
        }
        return lists
    }

    /// Saves the lists that were read; an agent whose command failed keeps the list it had.
    @discardableResult
    public static func save(_ outcomes: [Agent: Outcome], to url: URL = ModelLists.defaultURL) throws -> [Agent: [String]] {
        // A file at that path that is not a model list (or cannot be read) is someone else's; it is left alone. Only a missing file is created.
        var lists: [Agent: [String]] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard File.read(data) != nil else { throw SlashCommandError(loc("%@ is not a model list file; it was left as it is.", url.path)) }
            lists = load(from: url)
        }
        for (agent, outcome) in outcomes { if case .names(let names) = outcome { lists[agent] = names } }
        let file = File(lists: Dictionary(uniqueKeysWithValues: lists.map { ($0.key.rawValue, $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url, options: .atomic)
        return lists
    }
}
