import Foundation

/// claude 의 `/model`·`/effort` 는 이 세션뿐 아니라 「새 세션 기본값」(`~/.claude/settings.json`)까지 바꾼다.
/// 전환 전 내용을 잡아 뒀다가 전환 뒤에 기본값만 되돌린다. 열려 있는 세션은 파일을 다시 읽지 않아 영향이 없다.
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

    public func snapshot() -> Data? {
        try? Data(contentsOf: url)
    }

    public func restore(to original: Data) -> Outcome {
        guard let current = try? Data(contentsOf: url) else {
            return .failed("설정 파일을 읽지 못했습니다")
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

    // MARK: - 순수 로직

    enum Decision: Equatable {
        case unchanged
        case write(Data)
        case failed(String)
    }

    /// 기본값 키(model · effortLevel · modelSettings.*.effortLevel)만 원래대로 돌린 파일 내용을 만든다.
    static func restoredContents(original: Data, current: Data) -> Decision {
        guard let before = object(original), let after = object(current) else {
            return .failed("설정 파일이 JSON 객체가 아닙니다")
        }
        if tracked(before) == tracked(after) { return .unchanged }
        // 기본값 키 말고는 달라진 게 없으면 원래 바이트를 그대로 되돌린다(서식·키 순서 보존).
        if stripped(before).isEqual(stripped(after)) { return .write(original) }

        // 그 사이 다른 설정도 바뀌었다 — 지금 파일에서 기본값 줄만 고친다.
        guard var text = String(data: current, encoding: .utf8) else {
            return .failed("설정 파일이 UTF-8 이 아닙니다")
        }
        let old = tracked(before)
        for (key, value) in tracked(after) where old[key] != value {
            guard let wanted = old[key] else {
                return .failed("전환 전에 없던 기본값 항목(\(key))이 생겨 자동으로 되돌리지 못했습니다")
            }
            guard let patched = replacingValue(in: text, key: key, with: wanted) else {
                return .failed("기본값 항목(\(key))의 위치를 찾지 못했습니다")
            }
            text = patched
        }
        let data = Data(text.utf8)
        guard let result = object(data), tracked(result) == old, stripped(result).isEqual(stripped(after)) else {
            return .failed("기본값을 고친 결과가 예상과 달라 쓰지 않았습니다")
        }
        return .write(data)
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 기본값 키와 값. 키는 "model" · "effortLevel" · "modelSettings.<모델>.effortLevel".
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

    /// claude 가 쓰는 2칸 들여쓰기 JSON 에서 해당 키의 문자열 값만 바꾼다. 정확히 한 군데일 때만 고친다.
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
