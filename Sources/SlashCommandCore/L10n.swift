import Foundation

/// Translation of the text shown on screen.
///
/// English is the baseline: the English sentence written in the code is the key, and translations are in the app bundle's `<language>.lproj/Localizable.strings`
/// (`Resources/` in the repo; `scripts/build-app.sh` puts them in the bundle). The language is the first one we have in the system's language order.
/// A sentence with no translation comes out in English. Text on the agents' screens (`Select model` and so on) is not translated: it is those tools' screens.
public enum L10n {
    private static let lock = NSLock()
    private static var loaded: (language: String, table: [String: String])?

    /// The language in use (`en`, `ko`, `zh-Hans` …).
    public static var language: String { current().language }

    /// The folder holding the translation files. When running inside the app bundle, its `Contents/Resources`.
    /// Even when called through a link such as `~/.local/bin/slashcommand`, it looks next to the real executable.
    /// `SLASHCOMMAND_L10N_DIR` can point at another folder (for development and tests).
    public static var directory: URL? {
        if let override = ProcessInfo.processInfo.environment["SLASHCOMMAND_L10N_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents" else { return nil }
        return contents.appendingPathComponent("Resources")
    }

    /// The languages in that folder (`ko.lproj` → `ko`).
    public static func available(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(6)) }.sorted()
    }

    /// The first language we have in the user's language order. `pt-BR` is looked up as `pt-BR` → `pt`, `zh-Hans-CN` as `zh-Hans-CN` → `zh-Hans` → `zh`.
    /// English if none match. Languages with a different script (`zh-Hant` and `zh-Hans`) do not stand in for each other.
    public static func pick(from available: [String], preferences: [String]) -> String {
        // English is in the code, so it is always an available language even without a translation file.
        let lowered = Dictionary((available + ["en"]).map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for preference in preferences {
            var parts = preference.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            // Chinese with no script given picks the script by region (Taiwan, Hong Kong and Macau are Traditional).
            if parts.first?.lowercased() == "zh", !parts.contains(where: { ["hans", "hant"].contains($0.lowercased()) }) {
                let traditional = parts.dropFirst().contains { ["tw", "hk", "mo"].contains($0.lowercased()) }
                parts.insert(traditional ? "Hant" : "Hans", at: 1)
            }
            let isChinese = parts.first?.lowercased() == "zh"
            while !parts.isEmpty {
                if let match = lowered[parts.joined(separator: "-").lowercased()] { return match }
                parts.removeLast()
                if isChinese, parts.count < 2 { break }
            }
        }
        return "en"
    }

    /// Reads one `Localizable.strings`. If it is missing or unreadable, an empty table (English as is).
    public static func table(in directory: URL, language: String) -> [String: String] {
        let url = directory.appendingPathComponent("\(language).lproj/Localizable.strings")
        return (NSDictionary(contentsOf: url) as? [String: String]) ?? [:]
    }

    private static func current() -> (language: String, table: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        var found: (language: String, table: [String: String]) = ("en", [:])
        if let directory {
            var preferences = Locale.preferredLanguages
            if let forced = ProcessInfo.processInfo.environment["SLASHCOMMAND_LANG"], !forced.isEmpty { preferences = [forced] }
            let language = pick(from: available(in: directory), preferences: preferences)
            found = (language, language == "en" ? [:] : table(in: directory, language: language))
        }
        loaded = found
        return found
    }

    /// Pins the language in tests. If `directory` is nil, English (no translation).
    public static func use(language: String, directory: URL?) {
        lock.lock()
        defer { lock.unlock() }
        loaded = (language, directory.map { table(in: $0, language: language) } ?? [:])
    }

    /// Fills values into a translated sentence. Only `%@` (in order) and `%1$@` (by number) are used as placeholders; the value becomes the same text as `"\(value)"`.
    /// If there are no values, the sentence is returned as is (then `%` is not doubled).
    public static func format(_ template: String, _ arguments: [Any]) -> String {
        guard !arguments.isEmpty else { return template }
        var out = ""
        var next = 0
        var rest = Substring(template)
        while let percent = rest.firstIndex(of: "%") {
            out += rest[..<percent]
            rest = rest[rest.index(after: percent)...]
            if rest.first == "%" {
                out += "%"
                rest = rest.dropFirst()
            } else if rest.first == "@" {
                out += next < arguments.count ? "\(arguments[next])" : "%@"
                next += 1
                rest = rest.dropFirst()
            } else {
                let digits = rest.prefix(while: \.isNumber)
                let after = rest.dropFirst(digits.count)
                if let position = Int(digits), after.hasPrefix("$@") {
                    out += (1...arguments.count).contains(position) ? "\(arguments[position - 1])" : "%\(digits)$@"
                    rest = after.dropFirst(2)
                } else {
                    out += "%"
                }
            }
        }
        return out + rest
    }

    static func text(_ key: String, _ arguments: [Any]) -> String {
        format(current().table[key] ?? key, arguments)
    }
}

/// A sentence to be shown on screen. The English sentence is the key. Values fill the sentence's `%@` slots in order (a translation can reorder them by number, like `%1$@`).
public func loc(_ key: String, _ arguments: Any...) -> String {
    L10n.text(key, arguments)
}
