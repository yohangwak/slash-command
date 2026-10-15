import Foundation

/// The model list codex has downloaded (`~/.codex/models_cache.json`). The row order of the `/model` picker comes from here.
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

    /// The order shown in the picker (hidden ones excluded, priority ascending).
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
            throw SlashCommandError(loc("Could not read the Codex model list: %@ — %@", url.path, error.localizedDescription))
        }
    }

    /// The name under which an effort value is shown in the picker.
    static let effortLabels = ["none": "None", "minimal": "Minimal", "low": "Low", "medium": "Medium",
                               "high": "High", "xhigh": "Extra high", "max": "Max", "ultra": "Ultra"]

    public struct Selection: Equatable, Sendable {
        /// The number to press in the model list (from 1).
        public let modelIndex: Int
        /// The model name shown in the header of the effort list.
        public let displayName: String?
        /// The row name to look for in the effort list.
        public let effortLabel: String
    }

    /// The model number and effort row name to pick in the picker.
    public func selection(of preset: AgentPreset) throws -> Selection {
        guard let offset = listed.firstIndex(where: { $0.slug == preset.model }) else {
            let known = listed.map(\.slug).joined(separator: ", ")
            throw SlashCommandError(loc("Codex model '%@' is not in the picker list. Available: %@", preset.model, known))
        }
        let modelIndex = offset + 1
        guard modelIndex <= 9 else {
            throw SlashCommandError(loc("Codex model '%@' is number %@ in the picker, so it cannot be chosen with a number key.", preset.model, modelIndex))
        }
        let efforts = listed[offset].efforts
        guard efforts.contains(preset.effort) else {
            throw SlashCommandError(loc("Codex model '%@' does not support effort '%@'. Available: %@", preset.model, preset.effort, efforts.joined(separator: ", ")))
        }
        let label = CodexModels.effortLabels[preset.effort] ?? preset.effort.prefix(1).uppercased() + preset.effort.dropFirst()
        return Selection(modelIndex: modelIndex, displayName: listed[offset].displayName, effortLabel: label)
    }
}
