import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Interprets Orca's structured chat options and prepares option changes.
public enum OrcaChatOptions {
    public struct Effort: Equatable, Sendable {
        public let value: String
        public let label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    public struct Model: Equatable, Sendable {
        public let id: String
        public let label: String
        public let efforts: [Effort]

        public init(id: String, label: String, efforts: [Effort]) {
            self.id = id
            self.label = label
            self.efforts = efforts
        }
    }

    public struct Options: Equatable, Sendable {
        public let models: [Model]
        public let current: [String: String]
        public let acceptedSources: [String: String]

        public var currentModel: String? { current["model"] }
        public var currentEffort: String? { current["effort"] }

        public func holds(key: String, value: String) -> Bool {
            current[key] == value && acceptedSources[key] == "saved"
        }

        /// Model IDs take precedence over display labels.
        public func model(for wanted: String) -> Match {
            let name = OrcaView.normalized(wanted)
            let ids = models.filter { OrcaView.normalized($0.id) == name }
            if let match = ids.first {
                return ids.count == 1 ? .found(match) : .ambiguous
            }
            let labels = models.filter { OrcaView.normalized($0.label) == name }
            guard let match = labels.first else { return .missing }
            return labels.count == 1 ? .found(match) : .ambiguous
        }
    }

    public enum Match: Equatable, Sendable {
        case found(Model), missing, ambiguous
    }

    /// Reads the result of agentSession.options.
    public static func parse(_ result: [String: Any]) -> Options? {
        guard let listed = result["models"] as? [[String: Any]],
              let current = result["current"] as? [String: Any] else { return nil }
        var models: [Model] = []
        for model in listed {
            guard let id = model["id"] as? String, !id.isEmpty else { return nil }
            let label = model["label"] as? String ?? ""
            var efforts: [Effort] = []
            if let rawEfforts = model["efforts"], !(rawEfforts is NSNull) {
                guard let listedEfforts = rawEfforts as? [[String: Any]] else { return nil }
                for effort in listedEfforts {
                    guard let value = effort["value"] as? String, !value.isEmpty,
                          let label = effort["label"] as? String, !label.isEmpty else { return nil }
                    efforts.append(Effort(value: value, label: label))
                }
            }
            models.append(Model(id: id, label: label.isEmpty ? id : label, efforts: efforts))
        }
        var selected: [String: String] = [:]
        for key in ["model", "effort"] {
            guard let value = current[key] else { continue }
            guard let text = value as? String else { return nil }
            if !text.isEmpty { selected[key] = text }
        }
        guard let sources = (current["acceptedInputSources"] ?? [:]) as? [String: Any] else { return nil }
        return Options(models: models, current: selected, acceptedSources: sources.compactMapValues { $0 as? String })
    }

    /// Effort values take precedence over display labels.
    public static func effort(_ wanted: String, in model: Model) -> String? {
        let name = OrcaView.normalized(wanted)
        let values = model.efforts.filter { OrcaView.normalized($0.value) == name }
        if !values.isEmpty { return values.count == 1 ? values.first?.value : nil }
        let labels = model.efforts.filter { OrcaView.normalized($0.label) == name }
        return labels.count == 1 ? labels.first?.value : nil
    }

    /// Steps through the reported efforts from lower to higher, without wrapping.
    public static func neighbor(of current: String, up: Bool, in model: Model) -> String? {
        guard let index = model.efforts.firstIndex(where: { $0.value == current }) else { return nil }
        let next = index + (up ? 1 : -1)
        return model.efforts.indices.contains(next) ? model.efforts[next].value : nil
    }

    public static func operationID(now: Date, entropy: UUID) -> String {
        let milliseconds = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        let hex = entropy.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return String(format: "%013lld", milliseconds) + "-" + hex
    }

    public static func accepted(_ setOptionResult: [String: Any]) -> Bool {
        setOptionResult["ok"] as? Bool == true
    }

    /// Hashes the canonical JSON for agentSession.setOption. An empty result means hashing is unavailable.
    public static func fingerprint(sessionID: String, key: String, value: String) -> String {
        #if canImport(CryptoKit)
        let json = """
        {"fields":{"key":\(quoted(key)),"value":\(quoted(value))},"method":"agentSession.setOption","sessionId":\(quoted(sessionID))}
        """
        return SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }

    /// Builds the parameters for agentSession.setOption.
    public static func setOptionParams(sessionID: String, key: String, value: String, operationID: String) -> [String: Any] {
        let envelope: [String: Any] = [
            "sessionId": sessionID,
            "clientOperationId": operationID,
            "expectedRuntimeFence": NSNull(),
            "payloadFingerprint": fingerprint(sessionID: sessionID, key: key, value: value),
        ]
        return ["envelope": envelope, "key": key, "value": value]
    }

    #if canImport(CryptoKit)
    /// Quotes a string with the same escaping as JavaScript's JSON.stringify.
    private static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\u{08}": result += "\\b"
            case "\u{0c}": result += "\\f"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{00}"..."\u{1f}": result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }
    #endif
}
