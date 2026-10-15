import Foundation

/// claude's `/model` and `/effort` change not only this session but also the "new session defaults" (`~/.claude/settings.json`).
/// The content before the switch is captured and, after the switch, only the defaults are put back. Sessions already open do not re-read the file, so they are unaffected.
public struct ClaudeDefaults: Sendable {
    public let url: URL

    public init(url: URL = ClaudeDefaults.defaultURL) {
        self.url = url.resolvingSymlinksInPath()
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    public enum Outcome: Equatable, Sendable {
        case unchanged
        case restored
        case failed(String)
    }

    /// The file's modification time (microseconds). claude rewrites this file on every `/model` and `/effort` even if the value is the same (measured on 2.1.289).
    public func stamp() -> Int64? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        return Int64(date.timeIntervalSince1970 * 1_000_000)
    }

    public func snapshot() -> Data? {
        try? Data(contentsOf: url)
    }

    public func restore(to original: Data) -> Outcome {
        guard let current = try? Data(contentsOf: url) else {
            return .failed(loc("Could not read the settings file"))
        }
        switch ClaudeDefaults.restoredContents(original: original, current: current) {
        case .unchanged:
            return .unchanged
        case .failed(let reason):
            return .failed(reason)
        case .write(let data):
            do {
                let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                try data.write(to: url, options: .atomic)
                if let permissions {
                    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
                }
                return .restored
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Pure logic

    enum Decision: Equatable {
        case unchanged
        case write(Data)
        case failed(String)
    }

    /// Builds the file content with only the default keys (model · effortLevel · modelSettings.*.effortLevel) restored.
    static func restoredContents(original: Data, current: Data) -> Decision {
        guard let before = object(original), let after = object(current) else {
            return .failed(loc("The settings file is not a JSON object"))
        }
        if tracked(before) == tracked(after) { return .unchanged }
        // If nothing but the default keys changed, put back the original bytes unchanged (preserves formatting and key order).
        if stripped(before).isEqual(stripped(after)) { return .write(original) }

        // Other settings changed in the meantime too: fix only the default lines in the current file.
        guard var text = String(data: current, encoding: .utf8) else {
            return .failed(loc("The settings file is not UTF-8"))
        }
        let old = tracked(before)
        for (key, value) in tracked(after) where old[key] != value {
            guard let wanted = old[key] else {
                return .failed(loc("A default (%@) that was not there before the switch appeared, so it could not be put back automatically", key))
            }
            guard let patched = replacingValue(in: text, key: key, with: wanted) else {
                return .failed(loc("Could not find where the default (%@) is", key))
            }
            text = patched
        }
        let data = Data(text.utf8)
        guard let result = object(data), tracked(result) == old, stripped(result).isEqual(stripped(after)) else {
            return .failed(loc("The corrected defaults did not come out as expected, so they were not written"))
        }
        return .write(data)
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The default keys and values. Keys are "model" · "effortLevel" · "modelSettings.<model>.effortLevel".
    static func tracked(_ json: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        if let model = json["model"] as? String { out["model"] = model }
        if let effort = json["effortLevel"] as? String { out["effortLevel"] = effort }
        if let settings = json["modelSettings"] as? [String: Any] {
            for (id, value) in settings {
                if let effort = (value as? [String: Any])?["effortLevel"] as? String {
                    out["modelSettings.\(id).effortLevel"] = effort
                }
            }
        }
        return out
    }

    static func stripped(_ json: [String: Any]) -> NSDictionary {
        var copy = json
        copy["model"] = nil
        copy["effortLevel"] = nil
        if var settings = copy["modelSettings"] as? [String: Any] {
            for (id, value) in settings {
                guard var entry = value as? [String: Any] else { continue }
                entry["effortLevel"] = nil
                settings[id] = entry.isEmpty ? nil : entry
            }
            copy["modelSettings"] = settings.isEmpty ? nil : settings
        }
        return copy as NSDictionary
    }

    /// In the 2-space-indented JSON claude writes, changes only the string value of that key. Edits only when there is exactly one match.
    static func replacingValue(in text: String, key: String, with value: String) -> String? {
        let pattern: String
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 {
            pattern = "(?m)^(  \"\(NSRegularExpression.escapedPattern(for: key))\": \")[^\"]*(\")"
        } else if parts.count >= 3, parts.first == "modelSettings", parts.last == "effortLevel" {
            let id = parts[1..<(parts.count - 1)].joined(separator: ".")
            pattern = "(\"\(NSRegularExpression.escapedPattern(for: id))\": \\{\\s*\"effortLevel\": \")[^\"]*(\")"
        } else {
            return nil
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard regex.numberOfMatches(in: text, range: range) == 1 else { return nil }
        let template = "$1" + NSRegularExpression.escapedTemplate(for: value) + "$2"
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
