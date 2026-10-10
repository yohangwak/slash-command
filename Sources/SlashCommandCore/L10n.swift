import Foundation

/// 화면에 보이는 문구의 번역.
///
/// 영어가 기준이다 — 코드에 쓴 영어 문장이 곧 키이고, 번역은 앱 묶음의 `<언어>.lproj/Localizable.strings` 에 있다
/// (repo 의 `Resources/`, `scripts/build-app.sh` 가 묶음에 넣는다). 언어는 시스템의 언어 순서에서 우리가 가진 첫 언어를 쓴다.
/// 번역이 없는 문장은 영어 그대로 나온다. 에이전트 화면의 문구(`Select model` 등)는 번역 대상이 아니다 — 그 도구들의 화면이다.
public enum L10n {
    private static let lock = NSLock()
    private static var loaded: (language: String, table: [String: String])?

    /// 지금 쓰는 언어(`en`·`ko`·`zh-Hans` …).
    public static var language: String { current().language }

    /// 번역 파일들이 있는 폴더. 앱 묶음 안에서 실행 중이면 그 `Contents/Resources` 다.
    /// `~/.local/bin/slashcommand` 처럼 링크로 불려도 실제 실행 파일의 자리에서 찾는다.
    /// `SLASHCOMMAND_L10N_DIR` 로 다른 폴더를 가리킬 수 있다(개발·시험용).
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

    /// 그 폴더에 있는 언어들(`ko.lproj` → `ko`).
    public static func available(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(6)) }.sorted()
    }

    /// 사용자의 언어 순서에서 우리가 가진 첫 언어. `pt-BR` 은 `pt-BR` → `pt`, `zh-Hans-CN` 은 `zh-Hans-CN` → `zh-Hans` → `zh` 순으로 찾는다.
    /// 하나도 맞지 않으면 영어다. 문자가 다른 언어(`zh-Hant` 와 `zh-Hans`)는 서로 대신하지 않는다.
    public static func pick(from available: [String], preferences: [String]) -> String {
        // 영어는 코드에 있으므로 번역 파일이 없어도 늘 가진 언어다.
        let lowered = Dictionary((available + ["en"]).map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for preference in preferences {
            var parts = preference.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            // 문자를 적지 않은 중국어는 지역으로 문자를 가린다(대만·홍콩·마카오는 번체).
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

    /// `Localizable.strings` 한 벌을 읽는다. 없거나 읽지 못하면 빈 표(영어 그대로).
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

    /// 시험에서 언어를 고정한다. `directory` 가 nil 이면 영어(번역 없음).
    public static func use(language: String, directory: URL?) {
        lock.lock()
        defer { lock.unlock() }
        loaded = (language, directory.map { table(in: $0, language: language) } ?? [:])
    }

    /// 번역한 문장에 값을 넣는다. 자리표는 `%@`(차례대로)와 `%1$@`(번호로)만 쓴다 — 값은 `"\(값)"` 과 같은 글이 된다.
    /// 값이 없으면 문장을 그대로 돌려준다(그때는 `%` 를 겹쳐 쓰지 않는다).
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

/// 화면에 보일 문장. 영어 문장이 키다. 값은 문장의 `%@` 자리에 차례대로 들어간다(번역에서는 `%1$@` 처럼 번호로 순서를 바꿀 수 있다).
public func loc(_ key: String, _ arguments: Any...) -> String {
    L10n.text(key, arguments)
}
