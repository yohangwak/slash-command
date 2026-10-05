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

    /// effort 값이 선택창에 표시되는 이름.
    static let effortLabels = ["none": "None", "minimal": "Minimal", "low": "Low", "medium": "Medium",
                               "high": "High", "xhigh": "Extra high", "max": "Max", "ultra": "Ultra"]

    public struct Selection: Equatable, Sendable {
        /// 모델 목록에서 누를 숫자(1부터).
        public let modelIndex: Int
        /// effort 목록 머리말에 나오는 모델 이름.
        public let displayName: String?
        /// effort 목록에서 찾을 행 이름.
        public let effortLabel: String
    }

    /// 지금 모델(선택창에 보이는 이름)과 effort 에서 한 단계 위·아래 프리셋. 이미 끝이면 그렇게 알린다.
    public func neighbour(displayName: String, effort: String, up: Bool) throws -> AgentPreset {
        guard let model = listed.first(where: { $0.displayName == displayName }) else {
            throw ModelSwitchError("codex 모델 '\(displayName)' 을 모델 목록에서 찾지 못했습니다.")
        }
        guard let index = model.efforts.firstIndex(of: effort) else {
            throw ModelSwitchError("codex 의 지금 effort '\(effort)' 를 모델 목록에서 찾지 못했습니다.")
        }
        let next = index + (up ? 1 : -1)
        guard model.efforts.indices.contains(next) else {
            var error = ModelSwitchError("이미 가장 \(up ? "높은" : "낮은") 단계(\(effort))입니다.")
            error.nothingToDo = true
            throw error
        }
        return AgentPreset(model: model.slug, effort: model.efforts[next])
    }

    /// 선택창에서 고를 모델 번호와 effort 행 이름.
    public func selection(of preset: AgentPreset) throws -> Selection {
        guard let offset = listed.firstIndex(where: { $0.slug == preset.model }) else {
            let known = listed.map(\.slug).joined(separator: ", ")
            throw ModelSwitchError("codex 모델 '\(preset.model)' 이 선택창 목록에 없습니다. 가능한 값: \(known)")
        }
        let modelIndex = offset + 1
        guard modelIndex <= 9 else {
            throw ModelSwitchError("codex 모델 '\(preset.model)' 은 선택창 \(modelIndex)번째라 숫자 키로 고를 수 없습니다.")
        }
        let efforts = listed[offset].efforts
        guard efforts.contains(preset.effort) else {
            throw ModelSwitchError("codex 모델 '\(preset.model)' 은 effort '\(preset.effort)' 를 지원하지 않습니다. 가능한 값: \(efforts.joined(separator: ", "))")
        }
        let label = CodexModels.effortLabels[preset.effort] ?? preset.effort.prefix(1).uppercased() + preset.effort.dropFirst()
        return Selection(modelIndex: modelIndex, displayName: listed[offset].displayName, effortLabel: label)
    }
}
