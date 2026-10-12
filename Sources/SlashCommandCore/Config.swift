import Foundation

public enum Agent: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case grok
    case cursor
    case antigravity
    case opencode

    /// 설치된 실행 파일 이름(`--version` 을 부를 때).
    public var executable: String {
        switch self {
        case .cursor: return "cursor-agent"
        case .antigravity: return "agy"
        default: return rawValue
        }
    }

    /// 사람에게 보여 주는 이름(제품 이름이라 번역하지 않는다). 파일의 키와 명령줄은 `rawValue` 를 쓴다.
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

    /// 단계 목록(`Step`)이 아니라 전용 드라이버가 화면을 보며 진행하는 에이전트.
    public var usesDriver: Bool { self != .claude && self != .codex }
}

/// 이 판이 모르는 JSON 값. 나중 판이 프리셋 파일에 쓴 키를 읽었다가, 저장할 때 그대로 돌려주려고 든다
/// (전에는 설정 창에서 저장하면 모르는 키가 사라졌다).
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    /// `Int64` 에 안 들어가는 부호 없는 정수(`UInt64` 값) — 실수로 받으면 값이 달라진다(PR #28 리뷰).
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

/// 이름을 실행 중에 정하는 JSON 키.
struct DynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init(_ name: String) { self.stringValue = name }
    init?(intValue: Int) { nil }

    /// 그 자리의 키 가운데 `known` 에 없는 것들의 값.
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
    /// 이 판이 모르는 키(읽은 그대로 다시 쓴다).
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
    /// 붙이고 싶을 때만 쓰는 이름. 비어 있으면 모델·effort 로 부른다.
    public var name: String
    /// 에이전트마다의 설정. 없는 에이전트는 그 번호에서 아무것도 하지 않는다.
    public var presets: [Agent: AgentPreset]
    /// 이 판이 모르는 키(나중 판의 에이전트 등 — 읽은 그대로 다시 쓴다).
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

    /// 파일의 키는 `name` 과 에이전트 이름(`claude`·`codex`·`grok`…)이다. 모르는 키는 쓰지는 않지만 들고 있다가 그대로 다시 쓴다
    /// (나중 판이 쓴 파일을 읽고, 저장해도 그 판의 값이 남게).
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

    /// 설정이 있는 에이전트들(정해진 순서).
    public var agents: [Agent] { Agent.allCases.filter { presets[$0] != nil } }

    /// 짧은 한 줄: 에이전트 `limit` 개까지만 적고 나머지는 수로 — `Claude Code opus · high, Codex gpt-6-astra · high +4`.
    public func summary(limit: Int = 2) -> String {
        let listed = agents.prefix(limit).compactMap { agent in presets[agent].map { "\(agent.displayName) \($0.model) · \($0.effort)" } }
        guard !listed.isEmpty else { return loc("No agents set") }
        let more = agents.count - listed.count
        return listed.joined(separator: ", ") + (more > 0 ? " +\(more)" : "")
    }

    /// 메뉴에 보여 줄 한 줄. 맨 앞 세션의 에이전트를 알면 «지금 누르면 무엇이 되는가» 만 적는다(`opus · high`).
    /// 그 에이전트의 설정이 없으면 nil — 그 번호는 지금 아무것도 하지 않는다. 에이전트를 모르면 이름이나 짧은 요약이다.
    public func menuTitle(for agent: Agent?) -> String? {
        guard let agent else { return name.isEmpty ? summary() : name }
        guard let preset = presets[agent] else { return nil }
        let value = "\(preset.model) · \(preset.effort)"
        return name.isEmpty ? value : "\(name) — \(value)"
    }

    /// 목록에 보여 줄 한 줄: `claude opus · high  /  codex gpt-6-astra · high`, 이름이 있으면 뒤에 붙인다.
    public var listing: String {
        let parts = Agent.allCases.compactMap { agent in presets[agent].map { "\(agent.rawValue) \($0.model) · \($0.effort)" } }
        let body = parts.isEmpty ? loc("(no agents set)") : parts.joined(separator: "  /  ")
        return name.isEmpty ? body : "\(body)   — \(name)"
    }
}

public struct SlashCommandConfig: Codable, Equatable, Sendable {
    public var version: Int
    /// 전환 뒤 「새 세션 기본값」을 전환 전 값으로 되돌린다(claude 의 /model·/effort 는 기본값까지 저장한다).
    public var keepDefaults: Bool
    /// claude 는 방금 응답한 대화에서 모델이나 effort 를 바꾸면 확인 창을 띄운다(「Switch model?」·「Change effort level?」
    /// — 대화 기록을 다시 읽는다는 안내). 참(기본)이면 그 창이 «우리가 고른 그 값»을 묻고 커서가 Yes 에 있을 때만
    /// Enter 로 받아들인다 — 단축키를 누른 것이 이미 그 답이다(2026-10-06 요한님 결정). 거짓이면 창을 그대로 두고 사용자가 고르게 한다.
    public var acceptSwitchPrompt: Bool
    /// 조합 키 + `=`(올림) · `-`(내림) 으로 모델은 그대로 두고 effort 만 한 단계 바꾼다.
    public var effortKeys: Bool
    /// 번호 키와 함께 누를 조합 키. `shift`·`option`·`control`·`command` 중에서.
    public var modifiers: [String]
    public var slots: [Slot]
    /// 이 판이 모르는 키(읽은 그대로 다시 쓴다).
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

    /// 조합 키를 맥 표기 순서(⌃⌥⇧⌘)의 기호로.
    public var modifierSymbols: String {
        let symbols = ["control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘"]
        return SlashCommandConfig.knownModifiers.filter(modifiers.contains).compactMap { symbols[$0] }.joined()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        keepDefaults = try c.decodeIfPresent(Bool.self, forKey: .keepDefaults) ?? true
        acceptSwitchPrompt = try c.decodeIfPresent(Bool.self, forKey: .acceptSwitchPrompt) ?? true
        effortKeys = try c.decodeIfPresent(Bool.self, forKey: .effortKeys) ?? true
        let wanted = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? SlashCommandConfig.defaultModifiers
        modifiers = SlashCommandConfig.knownModifiers.filter(wanted.contains)
        // 조합 키 없이 숫자만 잡으면 터미널에 숫자를 칠 수 없게 된다. Shift 뿐이어도 같다(`!`·`@`·`#` 을 칠 수 없다).
        if !SlashCommandConfig.modifiersAreUsable(modifiers) { modifiers = SlashCommandConfig.defaultModifiers }
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

    /// 단축키로 쓸 수 있는 조합인가: Control·Option·Command 가운데 하나는 있어야 한다.
    /// 그것 없이 숫자 키를 잡으면(조합 키가 없거나 Shift 뿐이면) 터미널에서 그 글자들을 칠 수 없게 된다.
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

    /// 기본은 `~/.config/slashcommand/presets.json`. `SLASHCOMMAND_CONFIG` 로 다른 파일을 가리킬 수 있다.
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["SLASHCOMMAND_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/slashcommand/presets.json")
    }

    /// 개명(Gear → ModelSwitch → Slash Command) 전 설정 위치들, 가까운 이름부터.
    static var legacyURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".config/modelswitch/presets.json", ".config/gear/presets.json"].map(home.appendingPathComponent)
    }

    /// 새 위치에 파일이 없을 때만, 옛 위치 가운데 처음으로 있는 것을 한 번 복사해 온다. 옛 파일은 그대로 둔다.
    static func adoptLegacy(into url: URL, from candidates: [URL]) throws {
        guard !FileManager.default.fileExists(atPath: url.path),
              let legacy = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: legacy, to: url)
    }

    /// 파일이 없으면 시작 프리셋을 만들어 저장하고 돌려준다.
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
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(config)
        data.append(0x0A)
        // 프리셋 파일이 링크면(설정 파일을 한곳에서 관리하는 도구들) 링크가 가리키는 파일에 쓴다 —
        // 링크 자리에 그대로 쓰면 「새 파일로 바꿔치기」 때문에 링크가 보통 파일로 바뀐다.
        try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
    }
}

public struct SlashCommandError: Error, CustomStringConvertible, Equatable {
    public let message: String
    /// 선택창을 닫고 입력창으로 돌아온 것까지 확인한 실패 — 아무것도 바뀌지 않았으므로 다른 방법으로 다시 해도 된다.
    public var cleanlyAborted = false
    /// 실패가 아니라 사용자의 확인을 기다리는 상태(claude 의 「Switch model?」 창이 떠 있다).
    public var awaitingUser = false
    /// 실패가 아니라 바꿀 것이 없었다(이미 가장 높은 단계 등).
    public var nothingToDo = false
    /// 손쉬운 사용 권한이 없어 보내지 않았다 — 앱은 그 권한을 켜는 설정 화면을 열어 준다.
    public var needsAccessibility = false
    /// 자동화 권한이 꺼져 있어 보내지 않았다 — 앱은 그 권한을 켜는 설정 화면을 열어 준다.
    public var needsAutomation = false

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
