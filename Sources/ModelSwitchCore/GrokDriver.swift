import Foundation

// grok(xAI 의 Grok Build CLI, 1.0.46)로 모델·effort 를 바꾼다.
//
// 2026-10-07 집 맥 실측(요한님의 시험 터미널):
// - `/model <모델> [창] [effort]` 한 줄이 이 세션의 모델과 effort 를 바꾸고, 입력 상자 아래 테두리의 이름표가
//   `Grok 4.7 (xhigh)` 로 바뀐다. 없는 모델이면 «Unknown model: …» 한 줄이 뜬다.
// - 🔴 `/model` 명령도 선택창(`/model` 만 쳐서 여는 3단계: 모델 → 창 크기 → effort)도 «새 세션 기본값»을
//   `~/.grok/config.toml` 의 `[models] default · default_reasoning_effort` 로 저장한다. 「이 세션만」 확정이 없다.
//   그래서 claude 의 명령 방식처럼 «전환 뒤 그 두 키만 전환 전 값으로 되돌린다»(다른 키·다른 세션의 쓰기는 건드리지 않는다).
// - 입력 상자에 쓰던 글이 있으면 명령과 섞이므로 비어 있을 때만 보낸다.

/// 화면에서 grok 입력 상자를 읽는다. 맨 아래 줄부터 읽는다 — 대화 내용에 비슷한 글이 있어도 보지 않는다.
public enum GrokScreen {
    public struct Box: Equatable, Sendable {
        /// `│ ❯ ` 뒤의 글(여러 줄이면 이어 붙인다). 비어 있으면 "".
        public let input: String
        /// 아래 테두리의 이름표(`Grok 4.7 (xhigh)`). 없으면 nil.
        public let label: String?
        public let footer: String
    }

    static let placeholders: Set<String> = ["Build anything"]

    /// 화면 맨 아래의 입력 상자: 마지막 줄은 안내 줄, 그 위는 아래 테두리(`╰…╯`), 그 위는 `│` 로 시작하는 입력 줄들, 그 위는 위 테두리(`╭`).
    public static func box(_ screen: [String]) -> Box? {
        var lines = screen.map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count >= 3, let footer = lines.last, footer.contains("Ctrl+x:shortcuts") else { return nil }
        let bottom = lines[lines.count - 2]
        guard bottom.hasPrefix("╰"), bottom.hasSuffix("╯") else { return nil }
        var rows: [String] = []
        var index = lines.count - 3
        while index >= 0, lines[index].hasPrefix("│") {
            rows.insert(lines[index], at: 0)
            index -= 1
        }
        guard index >= 0, lines[index].hasPrefix("╭"), !rows.isEmpty else { return nil }
        var text = ""
        for (offset, row) in rows.enumerated() {
            var body = row
            if body.hasPrefix("│") { body.removeFirst() }
            if body.hasSuffix("│") { body.removeLast() }
            body = body.trimmingCharacters(in: .whitespaces)
            if offset == 0 {
                guard body.hasPrefix("❯") else { return nil }
                body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            text += (text.isEmpty ? "" : "\n") + body
        }
        return Box(input: text, label: label(inBorder: bottom), footer: footer)
    }

    /// `╰───── Grok 4.7 (xhigh) ─╯` 에서 이름표.
    static func label(inBorder border: String) -> String? {
        var inner = border
        inner.removeFirst()
        inner.removeLast()
        let parts = inner.split(separator: "─", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.last { !$0.isEmpty }
    }

    /// 입력 상자가 «비어 있고» 아무것도 열려 있지 않은 대기 상태. 안내 줄이 알려진 두 가지(입력 칸 / 대화 칸에 포커스)일 때만 인정한다 —
    /// 작업 중에는 안내 줄에 `Ctrl+c:cancel` 이 붙고(2026-10-07 실측: 입력 상자는 그대로 비어 보인다), 선택창·명령 목록·글을 쓰는 중에는
    /// `Enter:send …` 가 붙는다. 처음 보는 안내 줄이면 대기가 아니다.
    public static func idle(_ screen: [String]) -> Bool {
        guard let box = box(screen) else { return false }
        let footer = box.footer.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        let known = footer == "Shift+Tab:mode │ Ctrl+x:shortcuts" || (footer.hasPrefix("Space:prompt") && !footer.contains("cancel"))
        return known && (box.input.isEmpty || placeholders.contains(box.input))
    }

    /// 입력 상자의 글(자리 표시 문구는 빈 글로 본다). 상자를 못 읽으면 nil.
    public static func draft(_ screen: [String]) -> String? {
        guard let box = box(screen) else { return nil }
        return placeholders.contains(box.input) ? "" : box.input
    }

    /// 이름표 `Grok 4.7 (xhigh)` → (이름, effort). effort 가 없는 모델이면 effort 는 nil.
    public static func parse(label: String) -> (name: String, effort: String?) {
        guard label.hasSuffix(")"), let open = label.lastIndex(of: "(") else { return (label, nil) }
        let effort = String(label[label.index(after: open)..<label.index(before: label.endIndex)])
        let name = String(label[..<open]).trimmingCharacters(in: .whitespaces)
        return (name, effort)
    }

    /// 마지막 몇 줄에 있는 grok 의 «모른다» 류 답 줄들. 예전 시도의 줄이 화면에 남아 있을 수 있으므로 부른 쪽이 «전·후 비교» 로 새 줄만 본다.
    public static func errorLines(_ screen: [String], bottom: Int = 14) -> [String] {
        let tail = screen.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(bottom)
        return tail.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("Unknown model") || $0.hasPrefix("Invalid ") || $0.contains("not available") }
    }
}

/// `~/.grok/models_cache.json` — grok 이 서버에서 받아 둔 모델 목록.
public struct GrokModels: Sendable {
    public struct Model: Equatable, Sendable {
        public let id: String
        public let name: String
        /// 지원하는 effort(낮은 단계부터). 비어 있으면 effort 가 없는 모델.
        public let efforts: [String]
    }

    public let models: [Model]

    static let rank = ["minimal", "low", "medium", "high", "xhigh", "max"]

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/models_cache.json")
    }

    public static func load(from url: URL = GrokModels.defaultURL) -> GrokModels {
        guard let data = try? Data(contentsOf: url) else { return GrokModels(models: []) }
        return parse(data)
    }

    static func parse(_ data: Data) -> GrokModels {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let table = root["models"] as? [String: Any] else { return GrokModels(models: []) }
        var found: [Model] = []
        for (_, value) in table {
            guard let info = (value as? [String: Any])?["info"] as? [String: Any],
                  let id = info["id"] as? String, info["hidden"] as? Bool != true else { continue }
            let name = info["name"] as? String ?? id
            let supports = info["supports_reasoning_effort"] as? Bool ?? false
            let listed = (info["reasoning_efforts"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }
            let efforts = supports ? listed.sorted { (rank.firstIndex(of: $0) ?? 99) < (rank.firstIndex(of: $1) ?? 99) } : []
            found.append(Model(id: id, name: name, efforts: efforts))
        }
        return GrokModels(models: found.sorted { $0.id < $1.id })
    }

    /// 프리셋의 모델 칸(id 나 화면 이름)에 맞는 모델. 목록이 비어 있으면 nil(모르는 것과 없는 것은 다르다).
    public func resolve(_ text: String) -> Model? {
        let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        return models.first { $0.id.lowercased() == wanted || $0.name.lowercased() == wanted }
    }

    public func model(named name: String) -> Model? {
        models.first { $0.name.lowercased() == name.lowercased() }
    }
}

/// `~/.grok/config.toml` 의 `[models]` 에서 `default` · `default_reasoning_effort` 두 키만 다룬다.
public struct GrokDefaults: Sendable {
    public let url: URL

    public init(url: URL = GrokDefaults.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/config.toml")
    }

    static let keys = ["default", "default_reasoning_effort"]

    public func snapshot() -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public enum Outcome: Equatable, Sendable {
        case unchanged
        case restored
        case failed(String)
    }

    /// 지금 파일에서 두 키만 `before` 의 값으로 되돌린다. 나머지(다른 키·다른 세션이 쓴 것)는 그대로 둔다.
    public func restore(to before: String) -> Outcome {
        guard let current = snapshot() else { return .failed("grok 설정 파일을 읽지 못했습니다") }
        let fixed = GrokDefaults.restoring(current: current, from: before)
        if fixed == current { return .unchanged }
        do {
            try fixed.write(to: url, atomically: true, encoding: .utf8)
            return .restored
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: 텍스트 처리 (TOML 전체를 해석하지 않고 `[models]` 표의 두 줄만 다룬다)

    private static func section(_ lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[models]" }) else { return nil }
        var end = lines.count
        for index in (start + 1)..<lines.count where lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            end = index
            break
        }
        return start..<end
    }

    private static func isKey(_ line: String, _ key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(key) else { return false }
        return trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }

    static func restoring(current: String, from before: String) -> String {
        var lines = current.components(separatedBy: "\n")
        let beforeLines = before.components(separatedBy: "\n")
        let beforeSection = section(beforeLines)
        guard let range = section(lines) else { return current }
        var kept: [String] = []
        for index in range.dropFirst() where !keys.contains(where: { isKey(lines[index], $0) }) { kept.append(lines[index]) }
        var restored: [String] = []
        if let beforeSection {
            for key in keys {
                if let line = beforeLines[beforeSection].dropFirst().first(where: { isKey($0, key) }) { restored.append(line) }
            }
        }
        // 표 끝의 빈 줄은 키 뒤가 아니라 표 뒤에 둔다.
        var trailing: [String] = []
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            trailing.insert(kept.removeLast(), at: 0)
        }
        let body = kept + restored
        var replacement = [lines[range.lowerBound]] + body
        if body.isEmpty && beforeSection == nil {
            // 원래 `[models]` 표가 없었고 지금 비었다 — 표 머리와 그 앞의 빈 줄 하나를 함께 없앤다.
            replacement = []
            if range.lowerBound > 0, lines[range.lowerBound - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.remove(at: range.lowerBound - 1)
                let shifted = (range.lowerBound - 1)..<(range.upperBound - 1)
                lines.replaceSubrange(shifted, with: trailing)
                return lines.joined(separator: "\n")
            }
        }
        lines.replaceSubrange(range, with: replacement + trailing)
        return lines.joined(separator: "\n")
    }
}

/// grok 의 `/model` 명령으로 이 세션의 모델·effort 를 바꾼다.
public struct GrokDriver {
    public let io: TerminalIO
    public let sleep: (Int) -> Void
    public let models: GrokModels
    public let defaults: GrokDefaults
    public let keepDefaults: Bool

    public init(io: TerminalIO, sleep: @escaping (Int) -> Void, models: GrokModels = GrokModels.load(),
                defaults: GrokDefaults = GrokDefaults(), keepDefaults: Bool) {
        self.io = io
        self.sleep = sleep
        self.models = models
        self.defaults = defaults
        self.keepDefaults = keepDefaults
    }

    public struct Outcome: Sendable {
        public let confirmations: [String]
        public let warning: String?
    }

    // MARK: 화면 기다리기

    private func poll(timeoutMs: Int, _ condition: ([String]) -> Bool) throws -> [String]? {
        let started = DispatchTime.now()
        var simulated = 0
        while true {
            guard let screen = io.freshSnapshot() else { throw ModelSwitchError("grok 터미널 화면을 읽지 못해 중단했습니다.") }
            if condition(screen.lines) { return screen.lines }
            let real = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            if max(real, simulated) >= timeoutMs { return nil }
            sleep(Runner.pollMs)
            simulated += Runner.pollMs
        }
    }

    /// 우리가 쓴 글이 입력 상자에 남아 있으면 지운다(다른 글은 건드리지 않는다).
    private func clear(_ text: String) {
        guard let lines = io.freshSnapshot()?.lines, let now = GrokScreen.draft(lines), !now.isEmpty, text.hasPrefix(now) || now.hasPrefix(text) else { return }
        for _ in 0..<(now.count + 2) {
            try? io.press(.backspace)
            if let lines = io.freshSnapshot()?.lines, GrokScreen.draft(lines)?.isEmpty == true { return }
        }
    }

    // MARK: 전환

    public func apply(_ preset: AgentPreset) throws -> Outcome { try guarded { try applyUnguarded(preset) } }

    /// 모델은 그대로 두고 effort 만 한 단계 올리거나 내린다.
    public func stepEffort(up: Bool) throws -> Outcome { try guarded { try stepEffortUnguarded(up: up) } }

    /// 어느 단계에서 던져졌든 — 확정한 뒤 화면을 읽지 못한 경우까지 — 새 세션 기본값을 전환 전 값으로 되돌리고 나서 실패를 알린다.
    /// (각 단계의 실패 처리도 되돌리지만, 화면 읽기 실패는 그 처리를 거치지 않고 곧바로 던져진다.)
    private func guarded(_ body: () throws -> Outcome) throws -> Outcome {
        let before = keepDefaults ? defaults.snapshot() : nil
        do {
            return try body()
        } catch {
            if let before {
                sleep(250)
                _ = defaults.restore(to: before)
            }
            throw error
        }
    }

    /// 입력 상자가 비어 있는 대기 상태에서만 시작한다. 실패하면 우리가 쓴 글만 지우고 멈춘다.
    private func applyUnguarded(_ preset: AgentPreset) throws -> Outcome {
        guard let first = io.freshSnapshot() else { throw ModelSwitchError("grok 터미널 화면을 읽지 못해 전환하지 않았습니다.") }
        guard GrokScreen.box(first.lines) != nil else {
            throw ModelSwitchError("grok 입력창이 보이지 않아 전환하지 않았습니다. 선택창이나 확인 창이 떠 있으면 먼저 처리해 주세요.")
        }
        if let draft = GrokScreen.draft(first.lines), !draft.isEmpty {
            throw ModelSwitchError("grok 입력창에 쓰던 글이 있어 전환하지 않았습니다. 먼저 보내거나 지운 뒤 다시 눌러 주세요.")
        }
        guard GrokScreen.idle(first.lines) else {
            throw ModelSwitchError("grok 가 작업 중이거나 선택창·명령 목록이 떠 있어 전환하지 않았습니다.")
        }

        // 프리셋의 모델을 목록에서 찾는다. 목록이 없으면(캐시 없음) 쓴 그대로 보낸다.
        let known = models.resolve(preset.model)
        if !models.models.isEmpty, known == nil {
            throw ModelSwitchError("grok 모델 목록에 '\(preset.model)' 이 없습니다.")
        }
        let id = known?.id ?? preset.model
        var effort: String? = preset.effort
        if let known {
            if known.efforts.isEmpty { effort = nil }
            else if !known.efforts.contains(preset.effort) {
                throw ModelSwitchError("grok \(known.name) 은 effort '\(preset.effort)' 를 지원하지 않습니다(\(known.efforts.joined(separator: ", "))).")
            }
        }
        let command = "/model \(id)" + (effort.map { " \($0)" } ?? "")
        let expected = known.map { $0.name + (effort.map { " (\($0))" } ?? "") }
        return try run(command: command, expectedLabel: expected, effort: effort, first: first.lines)
    }

    /// 모델은 그대로 두고 effort 만 한 단계 올리거나 내린다. 지금 값은 입력 상자 테두리의 이름표로 안다.
    private func stepEffortUnguarded(up: Bool) throws -> Outcome {
        guard let first = io.freshSnapshot(), let box = GrokScreen.box(first.lines) else {
            throw ModelSwitchError("grok 입력창이 보이지 않아 바꾸지 않았습니다.")
        }
        if let draft = GrokScreen.draft(first.lines), !draft.isEmpty {
            throw ModelSwitchError("grok 입력창에 쓰던 글이 있어 바꾸지 않았습니다. 먼저 보내거나 지운 뒤 다시 눌러 주세요.")
        }
        guard GrokScreen.idle(first.lines), let label = box.label else {
            throw ModelSwitchError("grok 가 작업 중이거나 선택창·명령 목록이 떠 있어 바꾸지 않았습니다.")
        }
        let (name, current) = GrokScreen.parse(label: label)
        guard let model = models.model(named: name), !model.efforts.isEmpty, let current, let at = model.efforts.firstIndex(of: current) else {
            throw ModelSwitchError("지금 grok 모델(\(label))의 effort 단계를 알 수 없어 바꾸지 않았습니다.")
        }
        let next = at + (up ? 1 : -1)
        guard model.efforts.indices.contains(next) else {
            var error = ModelSwitchError("이미 \(up ? "가장 높은" : "가장 낮은") 단계(\(current))입니다.")
            error.nothingToDo = true
            throw error
        }
        return try run(command: "/model \(model.id) \(model.efforts[next])", expectedLabel: "\(model.name) (\(model.efforts[next]))", effort: model.efforts[next], first: first.lines)
    }

    private func run(command: String, expectedLabel: String?, effort: String?, first: [String]) throws -> Outcome {
        let before = keepDefaults ? defaults.snapshot() : nil
        func finish(_ error: ModelSwitchError) -> ModelSwitchError {
            if let before { sleep(250); _ = defaults.restore(to: before) }
            return error
        }

        try io.type(command)
        // 쓴 글이 입력 상자에 «보임»을 확인한 뒤에만 Enter 를 보낸다.
        guard (try poll(timeoutMs: 1500) { GrokScreen.draft($0) == command }) != nil else {
            clear(command)
            throw finish(ModelSwitchError("grok 입력창에 명령이 나타나지 않아 보내지 않았습니다."))
        }
        try io.press(.enter)

        func matches(_ label: String?) -> Bool {
            guard let label else { return false }
            if let expectedLabel { return label.lowercased() == expectedLabel.lowercased() }
            guard let effort else { return true }
            return label.lowercased().hasSuffix("(\(effort.lowercased()))")
        }
        // 성공: 이름표가 목표 값이 되고 입력 상자가 비었다. 실패: grok 가 «모른다» 고 새로 답했다(예전 시도의 줄은 세지 않는다).
        let errorsBefore = GrokScreen.errorLines(first)
        var failure: String?
        let landed = try poll(timeoutMs: 4000) { lines in
            let errors = GrokScreen.errorLines(lines)
            if errors.count > errorsBefore.count || (errors.last != errorsBefore.last && !errors.isEmpty) { failure = errors.last; return true }
            guard let box = GrokScreen.box(lines) else { return false }
            return matches(box.label) && GrokScreen.draft(lines)?.isEmpty == true
        }
        if let failure {
            clear(command)
            throw finish(ModelSwitchError("grok 가 '\(command)' 를 받아들이지 않았습니다: \(failure)"))
        }
        guard let landed, let label = GrokScreen.box(landed)?.label else {
            clear(command)
            throw finish(ModelSwitchError("grok 가 '\(command)' 에 응답하지 않아 멈췄습니다."))
        }

        var warning: String?
        if let before {
            // 파일은 이미 써졌다. 바로 되돌리고, 늦게 오는 쓰기에 대비해 한 번 더 본다.
            if case .failed(let reason) = defaults.restore(to: before) { warning = "새 세션 기본값을 되돌리지 못했습니다: \(reason)" }
            sleep(250)
            if case .failed(let reason) = defaults.restore(to: before) { warning = "새 세션 기본값을 되돌리지 못했습니다: \(reason)" }
        }
        return Outcome(confirmations: ["Using \(label)"], warning: warning)
    }
}
