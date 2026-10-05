import Foundation

/// codex 가 내려받아 둔 모델 목록(`~/.codex/models_cache.json`). `/model` 선택창의 행 순서가 여기서 나온다.
public struct CodexModels: Sendable {
    public struct Model: Decodable, Sendable, Equatable {
        public let slug: String
        public let displayName: String?
        public let visibility: String?
        public let priority: Int?
        public let efforts: [String]

        enum CodingKeys: String, CodingKey {
            case slug
            case displayName = "display_name"
            case visibility
            case priority
            case levels = "supported_reasoning_levels"
        }

        struct Level: Decodable { let effort: String }

        public init(slug: String, displayName: String? = nil, visibility: String? = "list",
                    priority: Int? = nil, efforts: [String]) {
            self.slug = slug
            self.displayName = displayName
            self.visibility = visibility
            self.priority = priority
            self.efforts = efforts
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            slug = try c.decode(String.self, forKey: .slug)
            displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
            priority = try c.decodeIfPresent(Int.self, forKey: .priority)
            efforts = (try c.decodeIfPresent([Level].self, forKey: .levels) ?? []).map(\.effort)
        }
    }

    private struct Cache: Decodable { let models: [Model] }

    /// 선택창에 보이는 순서(숨김 제외, priority 오름차순).
    public let listed: [Model]

    public init(models: [Model]) {
        listed = models.enumerated()
            .filter { $0.element.visibility == "list" }
            .sorted { lhs, rhs in
                let l = lhs.element.priority ?? Int.max
                let r = rhs.element.priority ?? Int.max
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
    }

    public static func load(from url: URL = CodexModels.defaultURL) throws -> CodexModels {
        do {
            let data = try Data(contentsOf: url)
            return CodexModels(models: try JSONDecoder().decode(Cache.self, from: data).models)
        } catch {
            throw ModelSwitchError("codex 모델 목록을 읽지 못했습니다: \(url.path) — \(error.localizedDescription)")
        }
    }

    /// 선택창에서 누를 (모델 번호, effort 행 번호). 둘 다 1부터.
    public func position(of preset: AgentPreset) throws -> (modelIndex: Int, effortRow: Int) {
        guard let offset = listed.firstIndex(where: { $0.slug == preset.model }) else {
            let known = listed.map(\.slug).joined(separator: ", ")
            throw ModelSwitchError("codex 모델 '\(preset.model)' 이 선택창 목록에 없습니다. 가능한 값: \(known)")
        }
        let modelIndex = offset + 1
        guard modelIndex <= 9 else {
            throw ModelSwitchError("codex 모델 '\(preset.model)' 은 선택창 \(modelIndex)번째라 숫자 키로 고를 수 없습니다.")
        }
        let efforts = listed[offset].efforts
        guard let effortOffset = efforts.firstIndex(of: preset.effort) else {
            throw ModelSwitchError("codex 모델 '\(preset.model)' 은 effort '\(preset.effort)' 를 지원하지 않습니다. 가능한 값: \(efforts.joined(separator: ", "))")
        }
        // 선택창은 앞의 4단계를 1~4행에, 나머지를 5행(More reasoning…) 하위에 둔다.
        guard efforts.count > 4 else {
            throw ModelSwitchError("codex 모델 '\(preset.model)' 은 effort 목록에 기준 행이 없어 아직 지원하지 않습니다.")
        }
        guard effortOffset < 4 else {
            throw ModelSwitchError("codex effort '\(preset.effort)' (More reasoning 하위)는 아직 지원하지 않습니다. low·medium·high·xhigh 중에서 골라 주세요.")
        }
        return (modelIndex, effortOffset + 1)
    }
}
