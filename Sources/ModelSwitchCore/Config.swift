import Foundation

public enum Agent: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
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
    public var name: String
    public var claude: AgentPreset?
    public var codex: AgentPreset?

    public init(name: String, claude: AgentPreset? = nil, codex: AgentPreset? = nil) {
        self.name = name
        self.claude = claude
        self.codex = codex
    }

    public func preset(for agent: Agent) -> AgentPreset? {
        switch agent {
        case .claude: return claude
        case .codex: return codex
        }
    }
}

public struct ModelSwitchConfig: Codable, Equatable, Sendable {
    public var version: Int
    /// 전환 뒤 「새 세션 기본값」을 전환 전 값으로 되돌린다(claude 의 /model·/effort 는 기본값까지 저장한다).
    public var keepDefaults: Bool
    /// 번호 키와 함께 누를 조합 키. `shift`·`option`·`control`·`command` 중에서.
    public var modifiers: [String]
    public var slots: [Slot]

    public static let defaultModifiers = ["option", "shift"]
    public static let knownModifiers = ["control", "option", "shift", "command"]

    public init(version: Int = 1, keepDefaults: Bool = true,
                modifiers: [String] = ModelSwitchConfig.defaultModifiers, slots: [Slot]) {
        self.version = version
        self.keepDefaults = keepDefaults
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
        let wanted = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? ModelSwitchConfig.defaultModifiers
        modifiers = ModelSwitchConfig.knownModifiers.filter(wanted.contains)
        // 조합 키 없이 숫자만 잡으면 터미널에 숫자를 칠 수 없게 된다.
        if modifiers.isEmpty { modifiers = ModelSwitchConfig.defaultModifiers }
        slots = try c.decode([Slot].self, forKey: .slots)
    }

    public static let maxSlots = 9

    public static let starter = ModelSwitchConfig(slots: [
        Slot(name: "기본",
             claude: AgentPreset(model: "opus", effort: "high"),
             codex: AgentPreset(model: "gpt-6-astra", effort: "high")),
        Slot(name: "가볍게",
             claude: AgentPreset(model: "sonnet", effort: "high"),
             codex: AgentPreset(model: "gpt-6.1-sol", effort: "high")),
        Slot(name: "최고",
             claude: AgentPreset(model: "fable", effort: "high"),
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

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
