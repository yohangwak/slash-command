import Foundation

public enum Agent: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case grok
    case cursor
    case antigravity
    case opencode

    /// Name of the installed executable (used when calling `--version`).
    public var executable: String {
        switch self {
        case .cursor: return "cursor-agent"
        case .antigravity: return "agy"
        default: return rawValue
        }
    }

    /// Name shown to people (a product name, so not translated). The file's keys and the command line use `rawValue`.
    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        case .antigravity: return "Antigravity"
        case .opencode: return "OpenCode"
        }
    }

    /// An agent driven by a dedicated driver that watches the screen, rather than by a list of steps (`Step`).
    public var usesDriver: Bool { self != .claude && self != .codex }
}

/// A JSON value this version does not know. It is read from a key a later version wrote in the preset file and held so it can be handed back on save
/// (previously, saving from the settings window dropped unknown keys).
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    /// An unsigned integer that does not fit in `Int64` (a `UInt64` value) — reading it as a floating-point number would change the value (PR #28 review).
    case unsigned(UInt64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int64.self) { self = .integer(value) }
        else if let value = try? c.decode(UInt64.self) { self = .unsigned(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .integer(let value): try c.encode(value)
        case .unsigned(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

/// A JSON key whose name is decided at run time.
struct DynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init(_ name: String) { self.stringValue = name }
    init?(intValue: Int) { nil }

    /// The values of the keys at that position that are not in `known`.
    static func unknown(in decoder: Decoder, known: Set<String>) throws -> [String: JSONValue] {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        var extra: [String: JSONValue] = [:]
        for key in c.allKeys where !known.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
        return extra
    }

    static func write(_ extra: [String: JSONValue], to encoder: Encoder, known: Set<String>) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        for (name, value) in extra where !known.contains(name) { try c.encode(value, forKey: DynamicKey(name)) }
    }
}

public struct AgentPreset: Codable, Equatable, Sendable {
    public var model: String
    public var effort: String
    /// Keys this version does not know (written back exactly as read).
    public var extra: [String: JSONValue] = [:]

    public init(model: String, effort: String) {
        self.model = model
        self.effort = effort
    }

    private static let known: Set<String> = ["model", "effort"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        model = try c.decode(String.self, forKey: DynamicKey("model"))
        effort = try c.decode(String.self, forKey: DynamicKey("effort"))
        extra = try DynamicKey.unknown(in: decoder, known: AgentPreset.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(model, forKey: DynamicKey("model"))
        try c.encode(effort, forKey: DynamicKey("effort"))
        try DynamicKey.write(extra, to: encoder, known: AgentPreset.known)
    }
}

public struct Slot: Codable, Equatable, Sendable {
    /// A name used only when you want to attach one. When empty, the entry is called by its model and effort.
    public var name: String
    /// Per-agent settings. An agent that is absent does nothing for that number.
    public var presets: [Agent: AgentPreset]
    /// Keys this version does not know (agents of a later version, etc. — written back exactly as read).
    public var extra: [String: JSONValue] = [:]

    public var claude: AgentPreset? {
        get { presets[.claude] }
        set { presets[.claude] = newValue }
    }
    public var codex: AgentPreset? {
        get { presets[.codex] }
        set { presets[.codex] = newValue }
    }
    public var grok: AgentPreset? {
        get { presets[.grok] }
        set { presets[.grok] = newValue }
    }
    public var cursor: AgentPreset? {
        get { presets[.cursor] }
        set { presets[.cursor] = newValue }
    }
    public var antigravity: AgentPreset? {
        get { presets[.antigravity] }
        set { presets[.antigravity] = newValue }
    }
    public var opencode: AgentPreset? {
        get { presets[.opencode] }
        set { presets[.opencode] = newValue }
    }

    public init(name: String = "", claude: AgentPreset? = nil, codex: AgentPreset? = nil, grok: AgentPreset? = nil, cursor: AgentPreset? = nil, antigravity: AgentPreset? = nil, opencode: AgentPreset? = nil) {
        self.name = name
        self.presets = [:]
        self.claude = claude
        self.codex = codex
        self.grok = grok
        self.cursor = cursor
        self.antigravity = antigravity
        self.opencode = opencode
    }

    /// The keys in the file are `name` and the agent names (`claude`, `codex`, `grok` …). Unknown keys are not written but are held and written back as they were
    /// (so reading a file written by a later version and saving keeps that version's values).
    private static let known = Set(["name"] + Agent.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        name = try c.decodeIfPresent(String.self, forKey: DynamicKey("name")) ?? ""
        presets = [:]
        for agent in Agent.allCases {
            if let preset = try c.decodeIfPresent(AgentPreset.self, forKey: DynamicKey(agent.rawValue)) {
                presets[agent] = preset
            }
        }
        extra = try DynamicKey.unknown(in: decoder, known: Slot.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        if !name.isEmpty { try c.encode(name, forKey: DynamicKey("name")) }
        for agent in Agent.allCases {
            try c.encodeIfPresent(presets[agent], forKey: DynamicKey(agent.rawValue))
        }
        try DynamicKey.write(extra, to: encoder, known: Slot.known)
    }

    public func preset(for agent: Agent) -> AgentPreset? { presets[agent] }

    /// Agents that have settings (in a fixed order).
    public var agents: [Agent] { Agent.allCases.filter { presets[$0] != nil } }

    /// A short one-liner: lists only up to `limit` agents and shows the rest as a count — `Claude Code opus · high, Codex gpt-6-astra · high +4`.
    public func summary(limit: Int = 2) -> String {
        let listed = agents.prefix(limit).compactMap { agent in presets[agent].map { "\(agent.displayName) \($0.model) · \($0.effort)" } }
        guard !listed.isEmpty else { return loc("No agents set") }
        let more = agents.count - listed.count
        return listed.joined(separator: ", ") + (more > 0 ? " +\(more)" : "")
    }

    /// The one-liner to show in the menu. If the front session's agent is known, it shows only "what pressing it now will do" (`opus · high`).
    /// nil if that agent has no setting — that number does nothing right now. If the agent is unknown, the name or a short summary.
    public func menuTitle(for agent: Agent?) -> String? {
        guard let agent else { return name.isEmpty ? summary() : name }
        guard let preset = presets[agent] else { return nil }
        let value = "\(preset.model) · \(preset.effort)"
        return name.isEmpty ? value : "\(name) — \(value)"
    }

    /// The one-liner to show in the list: `claude opus · high  /  codex gpt-6-astra · high`, with the name appended if there is one.
    public var listing: String {
        let parts = Agent.allCases.compactMap { agent in presets[agent].map { "\(agent.rawValue) \($0.model) · \($0.effort)" } }
        let body = parts.isEmpty ? loc("(no agents set)") : parts.joined(separator: "  /  ")
        return name.isEmpty ? body : "\(body)   — \(name)"
    }
}

public struct SlashCommandConfig: Codable, Equatable, Sendable {
    public var version: Int
    /// After a switch, restores the "new session default" to its value before the switch (claude's /model and /effort also save the default).
    public var keepDefaults: Bool
    /// When you change the model or effort in a conversation that has just answered, claude shows a confirmation dialog ("Switch model?" and "Change effort level?"
    /// — a notice that the conversation history will be reread). When true (default), that dialog is accepted with Enter only if it asks about "the value we chose" and the cursor is on Yes
    /// — pressing the hotkey is already that answer (decided 2026-10-06). When false, the dialog is left as is and the user chooses.
    public var acceptSwitchPrompt: Bool
    /// The modifier keys plus `=` (up) and `-` (down) change only the effort by one step and leave the model alone.
    public var effortKeys: Bool
    /// The modifier keys pressed together with the number keys. From `shift`, `option`, `control`, `command`.
    public var modifiers: [String]
    /// Names in the file that are not modifier keys, dropped when decoding. Not written to the file.
    public private(set) var ignoredModifiers: [String] = []
    /// The file's modifiers could not be used (no control, option or command) and were replaced. Not written to the file.
    public private(set) var modifiersWereReplaced = false
    public var slots: [Slot]
    /// Keys this version does not know (written back exactly as read).
    public var extra: [String: JSONValue] = [:]

    public static let defaultModifiers = ["option", "shift"]
    public static let knownModifiers = ["control", "option", "shift", "command"]

    public init(version: Int = 1, keepDefaults: Bool = true, acceptSwitchPrompt: Bool = true, effortKeys: Bool = true,
                modifiers: [String] = SlashCommandConfig.defaultModifiers, slots: [Slot]) {
        self.version = version
        self.keepDefaults = keepDefaults
        self.acceptSwitchPrompt = acceptSwitchPrompt
        self.effortKeys = effortKeys
        self.modifiers = modifiers
        self.slots = slots
    }

    /// The modifier keys as symbols in the Mac order (⌃⌥⇧⌘).
    public var modifierSymbols: String {
        let symbols = ["control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘"]
        return SlashCommandConfig.knownModifiers.filter(modifiers.contains).compactMap { symbols[$0] }.joined()
    }

    public var modifierWarning: String? { modifierWarning(using: modifierSymbols) }

    /// The warning about the file's modifiers, naming the keys actually used as `used` (Mac symbols here, `Alt+Shift` on Windows).
    public func modifierWarning(using used: String) -> String? {
        if !ignoredModifiers.isEmpty {
            return loc("The modifier keys in the presets file were not recognized (%@), so %@ is used. Use control, option, shift or command.", ignoredModifiers.joined(separator: ", "), used)
        }
        guard modifiersWereReplaced else { return nil }
        return loc("The modifier keys in the presets file cannot be used on their own, so %@ is used. Include control, option or command.", used)
    }

    /// What the warning remembers about the file is not part of the settings: a draft built from these values is equal to the loaded file.
    public static func == (a: SlashCommandConfig, b: SlashCommandConfig) -> Bool {
        a.version == b.version && a.keepDefaults == b.keepDefaults && a.acceptSwitchPrompt == b.acceptSwitchPrompt
            && a.effortKeys == b.effortKeys && a.modifiers == b.modifiers && a.slots == b.slots && a.extra == b.extra
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        keepDefaults = try c.decodeIfPresent(Bool.self, forKey: .keepDefaults) ?? true
        acceptSwitchPrompt = try c.decodeIfPresent(Bool.self, forKey: .acceptSwitchPrompt) ?? true
        effortKeys = try c.decodeIfPresent(Bool.self, forKey: .effortKeys) ?? true
        let wanted = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? SlashCommandConfig.defaultModifiers
        modifiers = SlashCommandConfig.knownModifiers.filter(wanted.contains)
        // Grabbing bare digits without a modifier would make it impossible to type digits in the terminal. The same goes for Shift alone (`!`, `@`, `#` could not be typed).
        if !SlashCommandConfig.modifiersAreUsable(modifiers) {
            modifiers = SlashCommandConfig.defaultModifiers
            modifiersWereReplaced = true
        }
        ignoredModifiers = wanted.filter { !SlashCommandConfig.knownModifiers.contains($0) }
        slots = try c.decode([Slot].self, forKey: .slots)
        extra = try DynamicKey.unknown(in: decoder, known: SlashCommandConfig.known)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, keepDefaults, acceptSwitchPrompt, effortKeys, modifiers, slots
    }

    private static let known = Set(CodingKeys.allCases.map(\.rawValue))

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(keepDefaults, forKey: .keepDefaults)
        try c.encode(acceptSwitchPrompt, forKey: .acceptSwitchPrompt)
        try c.encode(effortKeys, forKey: .effortKeys)
        try c.encode(modifiers, forKey: .modifiers)
        try c.encode(slots, forKey: .slots)
        try DynamicKey.write(extra, to: encoder, known: SlashCommandConfig.known)
    }

    public static let maxSlots = 9

    /// Whether it is a usable hotkey combination: at least one of Control, Option, Command is required.
    /// Grabbing the number keys without one (no modifier, or Shift only) would make it impossible to type those characters in the terminal.
    public static func modifiersAreUsable(_ modifiers: [String]) -> Bool {
        modifiers.contains { ["control", "option", "command"].contains($0) }
    }

    public static let starter = SlashCommandConfig(slots: [
        Slot(claude: AgentPreset(model: "opus", effort: "high"),
             codex: AgentPreset(model: "gpt-6-astra", effort: "high")),
        Slot(claude: AgentPreset(model: "sonnet", effort: "high"),
             codex: AgentPreset(model: "gpt-6.1-sol", effort: "high")),
        Slot(claude: AgentPreset(model: "fable", effort: "high"),
             codex: nil),
    ])
}

public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL = ConfigStore.defaultURL) {
        self.url = url
    }

    /// By default `~/.config/slashcommand/presets.json`. `SLASHCOMMAND_CONFIG` can point to a different file.
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["SLASHCOMMAND_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/slashcommand/presets.json")
    }

    /// Config locations from before the renames (Gear -> ModelSwitch -> Slash Command), nearest name first.
    static var legacyURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".config/modelswitch/presets.json", ".config/gear/presets.json"].map(home.appendingPathComponent)
    }

    /// Only when the new location has no file, copies the first one that exists among the old locations, once. The old file is left as is.
    static func adoptLegacy(into url: URL, from candidates: [URL]) throws {
        guard !FileManager.default.fileExists(atPath: url.path),
              let legacy = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: legacy, to: url)
    }

    /// If the file does not exist, creates the starter presets, saves them and returns them.
    public func load() throws -> SlashCommandConfig {
        if url == ConfigStore.defaultURL {
            try ConfigStore.adoptLegacy(into: url, from: ConfigStore.legacyURLs)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            try save(.starter)
            return .starter
        }
        let data = try Data(contentsOf: url)
        do {
            let config = try JSONDecoder().decode(SlashCommandConfig.self, from: data)
            guard config.slots.count <= SlashCommandConfig.maxSlots else {
                throw SlashCommandError(loc("At most %@ presets are allowed (there are %@): %@", SlashCommandConfig.maxSlots, config.slots.count, url.path))
            }
            return config
        } catch let error as SlashCommandError {
            throw error
        } catch {
            throw SlashCommandError(loc("Could not read the presets file: %@ — %@", url.path, error.localizedDescription))
        }
    }

    public func save(_ config: SlashCommandConfig) throws {
        guard config.slots.count <= SlashCommandConfig.maxSlots else {
            throw SlashCommandError(loc("At most %@ presets are allowed (there are %@): %@", SlashCommandConfig.maxSlots, config.slots.count, url.path))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(config)
        data.append(0x0A)
        // If the preset file is a link (tools that manage config files in one place), write to the file the link points to —
        // writing in place of the link would turn the link into a regular file because of the "replace with a new file" step.
        try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
    }
}

public struct SlashCommandError: Error, CustomStringConvertible, Equatable {
    public let message: String
    /// A failure confirmed after closing the picker and returning to the input box — nothing changed, so it is fine to try again another way.
    public var cleanlyAborted = false
    /// Not a failure but a state waiting for the user's confirmation (claude's "Switch model?" dialog is showing).
    public var awaitingUser = false
    /// Not a failure; there was nothing to change (already at the highest level, etc.).
    public var nothingToDo = false
    /// Not sent because the Accessibility permission is missing — the app opens the settings screen where it can be turned on.
    public var needsAccessibility = false
    /// Not sent because the Automation permission is off — the app opens the settings screen where it can be turned on.
    public var needsAutomation = false

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
