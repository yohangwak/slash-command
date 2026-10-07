import Foundation

public enum Agent: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case grok
    case cursor
}

public struct AgentPreset: Codable, Equatable, Sendable {
    public var model: String
    public var effort: String

    public init(model: String, effort: String) {
        self.model = model
        self.effort = effort
    }
}

public struct Slot: Codable, Equatable, Sendable {
    /// 붙이고 싶을 때만 쓰는 이름. 비어 있으면 모델·effort 로 부른다.
    public var name: String
    /// 에이전트마다의 설정. 없는 에이전트는 그 번호에서 아무것도 하지 않는다.
    public var presets: [Agent: AgentPreset]

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

    public init(name: String = "", claude: AgentPreset? = nil, codex: AgentPreset? = nil, grok: AgentPreset? = nil, cursor: AgentPreset? = nil) {
        self.name = name
        self.presets = [:]
        self.claude = claude
        self.codex = codex
        self.grok = grok
        self.cursor = cursor
    }

    /// 파일의 키는 `name` 과 에이전트 이름(`claude`·`codex`·`grok`…)이다. 모르는 키는 무시한다(나중 판이 쓴 파일을 읽을 수 있게).
    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        name = try c.decodeIfPresent(String.self, forKey: Key(stringValue: "name")) ?? ""
        presets = [:]
        for agent in Agent.allCases {
            if let preset = try c.decodeIfPresent(AgentPreset.self, forKey: Key(stringValue: agent.rawValue)) {
                presets[agent] = preset
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        if !name.isEmpty { try c.encode(name, forKey: Key(stringValue: "name")) }
        for agent in Agent.allCases {
            try c.encodeIfPresent(presets[agent], forKey: Key(stringValue: agent.rawValue))
        }
    }

    public func preset(for agent: Agent) -> AgentPreset? { presets[agent] }

    /// 목록에 보여 줄 한 줄: `claude opus · high  /  codex gpt-6-astra · high`, 이름이 있으면 뒤에 붙인다.
    public var listing: String {
        let parts = Agent.allCases.compactMap { agent in presets[agent].map { "\(agent.rawValue) \($0.model) · \($0.effort)" } }
        let body = parts.isEmpty ? "(설정 없음)" : parts.joined(separator: "  /  ")
        return name.isEmpty ? body : "\(body)   — \(name)"
    }
}

public struct ModelSwitchConfig: Codable, Equatable, Sendable {
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

    public static let defaultModifiers = ["option", "shift"]
    public static let knownModifiers = ["control", "option", "shift", "command"]

    public init(version: Int = 1, keepDefaults: Bool = true, acceptSwitchPrompt: Bool = true, effortKeys: Bool = true,
                modifiers: [String] = ModelSwitchConfig.defaultModifiers, slots: [Slot]) {
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
        return ModelSwitchConfig.knownModifiers.filter(modifiers.contains).compactMap { symbols[$0] }.joined()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        keepDefaults = try c.decodeIfPresent(Bool.self, forKey: .keepDefaults) ?? true
        acceptSwitchPrompt = try c.decodeIfPresent(Bool.self, forKey: .acceptSwitchPrompt) ?? true
        effortKeys = try c.decodeIfPresent(Bool.self, forKey: .effortKeys) ?? true
        let wanted = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? ModelSwitchConfig.defaultModifiers
        modifiers = ModelSwitchConfig.knownModifiers.filter(wanted.contains)
        // 조합 키 없이 숫자만 잡으면 터미널에 숫자를 칠 수 없게 된다.
        if modifiers.isEmpty { modifiers = ModelSwitchConfig.defaultModifiers }
        slots = try c.decode([Slot].self, forKey: .slots)
    }

    public static let maxSlots = 9

    public static let starter = ModelSwitchConfig(slots: [
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

    /// 기본은 `~/.config/modelswitch/presets.json`. `MODELSWITCH_CONFIG` 로 다른 파일을 가리킬 수 있다.
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["MODELSWITCH_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/modelswitch/presets.json")
    }

    /// 개명(Gear → ModelSwitch) 전 설정 위치. 새 위치에 파일이 없을 때만 한 번 복사해 온다.
    static var legacyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/gear/presets.json")
    }

    /// 파일이 없으면 시작 프리셋을 만들어 저장하고 돌려준다.
    public func load() throws -> ModelSwitchConfig {
        if !FileManager.default.fileExists(atPath: url.path), url == ConfigStore.defaultURL,
           FileManager.default.fileExists(atPath: ConfigStore.legacyURL.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: ConfigStore.legacyURL, to: url)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            try save(.starter)
            return .starter
        }
        let data = try Data(contentsOf: url)
        do {
            let config = try JSONDecoder().decode(ModelSwitchConfig.self, from: data)
            guard config.slots.count <= ModelSwitchConfig.maxSlots else {
                throw ModelSwitchError("프리셋은 \(ModelSwitchConfig.maxSlots)개까지입니다(지금 \(config.slots.count)개): \(url.path)")
            }
            return config
        } catch let error as ModelSwitchError {
            throw error
        } catch {
            throw ModelSwitchError("프리셋 파일을 읽지 못했습니다: \(url.path) — \(error.localizedDescription)")
        }
    }

    public func save(_ config: ModelSwitchConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(config)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}

public struct ModelSwitchError: Error, CustomStringConvertible, Equatable {
    public let message: String
    /// 선택창을 닫고 입력창으로 돌아온 것까지 확인한 실패 — 아무것도 바뀌지 않았으므로 다른 방법으로 다시 해도 된다.
    public var cleanlyAborted = false
    /// 실패가 아니라 사용자의 확인을 기다리는 상태(claude 의 「Switch model?」 창이 떠 있다).
    public var awaitingUser = false
    /// 실패가 아니라 바꿀 것이 없었다(이미 가장 높은 단계 등).
    public var nothingToDo = false

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
