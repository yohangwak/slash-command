import Foundation

// cursor-agent(2026.10.01)로 모델·effort 를 바꾼다.
//
// 2026-10-07 실측(따로 연 시험 터미널):
// - `/model` 이 «Available models» 목록을 연다(`→` 가 커서, 맨 처음 커서는 지금 모델). 글자를 «한 글자씩» 치면 «Filter:» 로
//   걸러진다 — 여러 글자를 한 덩이로 보내면 붙여넣기로 보고 무시한다.
// - Tab 은 그 행의 «Edit Parameters»(Context · Effort · Fast 라디오)를 열고, Enter 는 그 줄을 고르며(✓), Esc 는 목록으로 돌아간다.
//   목록의 Enter 가 그 행을 확정한다. 입력 상자 아래 «<모델> <컨텍스트> <Effort>» 줄이 바뀐다.
// - 🔴 확정은 «새 세션 기본값»을 `~/.cursor/cli-config.json` 의 `model`·`selectedModel`·`modelSelectionHistory`·`modelParameters`(모델마다 마지막으로 고른 매개변수) 로 저장한다.
//   「이 세션만」이 없으므로 전환 뒤 그 네 키만 전환 전 값으로 되돌린다. 되돌려도 돌고 있는 세션은 모델을 유지한다(실측).

public enum CursorScreen {
    public struct Row: Equatable, Sendable {
        public let name: String
        public let params: String
        public let cursor: Bool
    }

    public struct Option: Equatable, Sendable {
        public let section: String
        public let label: String
        public let chosen: Bool
        public let cursor: Bool
    }

    static func trimmed(_ screen: [String]) -> [String] {
        var lines = screen.map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    // MARK: 대기 상태

    /// 맨 아래: 경로 줄(`~/… · 브랜치`), 그 위 모델 줄(`Grok 4.7 256K Medium`), 그 위(빈 줄 몇 개 건너) 입력 줄(`→ …`).
    /// 대화가 시작되면 모델 줄 끝에 컨텍스트 사용량(`· 7.1%`)이 붙고(2026-10-07 실측) 입력 줄의 자리 표시 문구가 바뀐다.
    static func bottom(_ screen: [String]) -> (input: String, status: String, path: String, busy: Bool)? {
        let lines = trimmed(screen)
        guard lines.count >= 3, let path = lines.last, path.contains(" · "), path.hasPrefix("~") || path.hasPrefix("/") else { return nil }
        var index = lines.count - 2
        while index >= 0, lines[index].isEmpty { index -= 1 }
        guard index >= 1 else { return nil }
        // 오른쪽에 붙는 실행 방식 표시(`Run Everything` — `--yolo` 로 연 세션)는 두 칸 이상 떨어져 있다 — 모델 줄은 그 앞까지만(2026-10-11 실측).
        var status = (lines[index].components(separatedBy: "  ").first ?? lines[index]).trimmingCharacters(in: .whitespaces)
        if let usage = status.range(of: #" · \d+(\.\d+)?%$"#, options: .regularExpression) { status = String(status[..<usage.lowerBound]) }
        index -= 1
        while index >= 0, lines[index].isEmpty { index -= 1 }
        guard index >= 0, lines[index].hasPrefix("→") else { return nil }
        // 오른쪽에 붙는 힌트(`ctrl+c to stop`)는 두 칸 이상 떨어져 있다 — 입력 글은 그 앞까지만.
        let input = (String(lines[index].dropFirst()).trimmingCharacters(in: .whitespaces).components(separatedBy: "  ").first ?? "").trimmingCharacters(in: .whitespaces)
        // 작업 중이면 입력 줄 오른쪽에 `ctrl+c to stop` 이 붙고, 그 위에 점자 스피너가 돈다(`⠰⠳ Working`) — 입력 상자는 그대로 비어 보인다.
        // 스피너와 입력 줄 사이에 도움말 한 줄(`Tip: …`)이 끼기도 한다(2026-10-11 실측: 바로 윗줄만 봐서 작업 중인데 전환했다) — 몇 줄 위까지 본다.
        var busy = lines[index].hasSuffix("ctrl+c to stop")
        var above = index - 1
        var looked = 0
        while !busy, above >= 0, looked < 3 {
            if !lines[above].isEmpty {
                busy = lines[above].unicodeScalars.first.map { (0x2800...0x28FF).contains($0.value) } ?? false
                looked += 1
            }
            above -= 1
        }
        return (input, status, path, busy)
    }

    static let placeholders: Set<String> = ["Plan, search, build anything", "Add a follow-up"]

    public static func idle(_ screen: [String]) -> Bool {
        guard let bottom = bottom(screen), !bottom.busy else { return false }
        return bottom.input.isEmpty || placeholders.contains(bottom.input)
    }

    public static func draft(_ screen: [String]) -> String? {
        guard let bottom = bottom(screen) else { return nil }
        return placeholders.contains(bottom.input) ? "" : bottom.input
    }

    /// 입력 상자 아래 모델 줄(`Grok 4.7 256K Medium`).
    public static func status(_ screen: [String]) -> String? { bottom(screen)?.status }

    // MARK: 목록

    /// 목록이 «열려 있는» 상태의 행들. 맨 아랫줄이 목록 안내(`Type to filter …`)일 때만 인정한다.
    public static func list(_ screen: [String]) -> (filter: String, rows: [Row])? {
        let lines = trimmed(screen)
        guard let footer = lines.last, footer.hasPrefix("Type to filter") else { return nil }
        guard let filterIndex = lines.lastIndex(where: { $0.hasPrefix("Filter:") }) else { return nil }
        let filter = String(lines[filterIndex].dropFirst("Filter:".count)).trimmingCharacters(in: .whitespaces)
        var rows: [Row] = []
        for line in lines[(filterIndex + 1)..<(lines.count - 1)] {
            guard !line.isEmpty else { continue }
            // `1-10 of 42` 같은 쪽 표시는 행이 아니다.
            if line.range(of: #"^\d+-\d+ of \d+$"#, options: .regularExpression) != nil { continue }
            var text = line
            var cursor = false
            if text.hasPrefix("→") { cursor = true; text = String(text.dropFirst()) }
            text = text.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("(Tab to modify)") { text = String(text.dropLast("(Tab to modify)".count)).trimmingCharacters(in: .whitespaces) }
            guard !text.isEmpty else { continue }
            let parts = text.components(separatedBy: "  ").filter { !$0.isEmpty }
            let name = parts.first?.trimmingCharacters(in: .whitespaces) ?? text
            let params = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            rows.append(Row(name: name, params: params, cursor: cursor))
        }
        return (filter, rows)
    }

    // MARK: 매개변수 편집

    public static func editor(_ screen: [String]) -> (title: String, options: [Option])? {
        let lines = trimmed(screen)
        guard let footer = lines.last, footer.contains("to go back"), footer.contains("to navigate"),
              let titleIndex = lines.lastIndex(where: { $0.contains("— Edit Parameters") }),
              let cut = lines[titleIndex].range(of: "— Edit Parameters") else { return nil }
        // Claude 모델은 같은 줄 오른쪽에 `Max mode: OFF` 가 붙는다(실측) — 이름은 «— Edit Parameters» 앞까지.
        let title = String(lines[titleIndex][..<cut.lowerBound]).trimmingCharacters(in: .whitespaces)
        var section = ""
        var options: [Option] = []
        // 빈 줄은 묶음의 끝이다 — 그 뒤의 `◯ Fast` 는 Effort 묶음에 속하지 않는다(2026-10-07 실측: 그걸 Effort 로 읽고 Enter 를 눌러 Fast 가 켜졌다).
        for line in lines[(titleIndex + 1)..<(lines.count - 1)] {
            if line.isEmpty { section = ""; continue }
            var text = line
            var cursor = false
            if text.hasPrefix("→") { cursor = true; text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if let first = text.first, "●○◯◉".contains(first) {
                var label = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
                let chosen = label.hasSuffix("✓") || first == "◉"
                if label.hasSuffix("✓") { label = String(label.dropLast()).trimmingCharacters(in: .whitespaces) }
                // `◯`(꺼짐)·`◉`(켜짐)은 켜고 끄는 스위치(Fast)다 — 라디오 묶음이 아니다.
                options.append(Option(section: (first == "◯" || first == "◉") ? "Toggle" : section, label: label, chosen: chosen, cursor: cursor))
            } else {
                section = text
            }
        }
        return (title, options)
    }

    /// 모델 줄(`Grok 4.7 256K Medium`)에서 (이름, effort 라벨). 컨텍스트 토큰(`256K`)은 버린다.
    public static func parse(status: String) -> (name: String, effort: String?) {
        var words = status.split(separator: " ").map(String.init)
        // `Fast` 스위치가 켜져 있으면 맨 끝에 붙는다(`Grok 4.7 256K Medium Fast`).
        if words.count > 1, words.last == "Fast" { words.removeLast() }
        var effort: String?
        for label in ["Extra High", "High", "Medium", "Low", "Max"] {
            let parts = label.split(separator: " ").map(String.init)
            if words.count > parts.count, Array(words.suffix(parts.count)) == parts {
                effort = label
                words.removeLast(parts.count)
                break
            }
        }
        if let last = words.last, last.range(of: #"^\d+[KkMm]$"#, options: .regularExpression) != nil { words.removeLast() }
        return (words.joined(separator: " "), effort)
    }

    // MARK: 비교

    /// 이름 비교용: 소문자에 글자·숫자만(`claude-opus-5-5` 와 `Claude Opus 5.5` 를 같게 본다).
    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// 프리셋의 effort 값(`xhigh`)이 화면 라벨(`Extra High`)과 같은가.
    static func effortMatches(_ value: String, label: String) -> Bool {
        let aliases: [String: [String]] = ["low": ["low"], "medium": ["medium"], "high": ["high"],
                                           "xhigh": ["xhigh", "extrahigh"], "max": ["max", "maximum"], "none": ["none", "off"]]
        let wanted = aliases[value.lowercased()] ?? [key(value)]
        return wanted.contains(key(label))
    }
}

/// `~/.cursor/cli-config.json` 에서 «기본 모델» 네 키만 다룬다.
public struct CursorDefaults: Sendable {
    public let url: URL

    public init(url: URL = CursorDefaults.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/cli-config.json")
    }

    static let keys = ["model", "selectedModel", "modelSelectionHistory", "modelParameters"]

    public func snapshot() -> DefaultsSnapshot { DefaultsFile.snapshot(url) }

    public enum Outcome: Equatable, Sendable {
        case unchanged
        case restored
        case failed(String)
    }

    /// 모델 관련 키만 전환 전 값으로 되돌린다(`DefaultsFile.restoreJSON`). 전환 전에 파일이 없었으면 그 키들을 없애고, 남는 것이 없으면 파일도 없앤다.
    public func restore(to snapshot: DefaultsSnapshot) -> Outcome {
        switch DefaultsFile.restoreJSON(url: url, keys: CursorDefaults.keys, to: snapshot, pretty: true, name: "cursor") {
        case .unchanged: return .unchanged
        case .restored: return .restored
        case .failed(let reason): return .failed(reason)
        }
    }

    public func restore(to before: Data) -> Outcome { restore(to: .content(before)) }
}

public struct CursorDriver {
    public let io: TerminalIO
    public let sleep: (Int) -> Void
    public let defaults: CursorDefaults
    public let keepDefaults: Bool

    public init(io: TerminalIO, sleep: @escaping (Int) -> Void, defaults: CursorDefaults = CursorDefaults(), keepDefaults: Bool) {
        self.io = io
        self.sleep = sleep
        self.defaults = defaults
        self.keepDefaults = keepDefaults
    }

    public struct Outcome: Sendable {
        public let confirmations: [String]
        public let warning: String?
    }

    // MARK: 화면 기다리기·키 보내기

    private func poll(timeoutMs: Int, _ condition: ([String]) -> Bool) throws -> [String]? {
        let started = DispatchTime.now()
        var simulated = 0
        while true {
            guard let screen = io.freshSnapshot() else { throw SlashCommandError(loc("Stopped: could not read the Cursor terminal screen.")) }
            if condition(screen.lines) { return screen.lines }
            let real = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            if max(real, simulated) >= timeoutMs { return nil }
            sleep(Runner.pollMs)
            simulated += Runner.pollMs
        }
    }

    /// 한 글자씩 친다 — 한 덩이는 붙여넣기로 보고 무시한다(실측).
    private func typeSlowly(_ text: String) throws {
        for character in text {
            try io.type(String(character))
            sleep(25)
        }
    }

    /// 열려 있는 것을 Esc 로 닫아 입력창까지 돌아간다(최대 3번). 입력창에 남은 글은 `leftover` 가 우리 것일 때만 지운다.
    private func back(toIdleClearing leftover: String? = nil) {
        for _ in 0..<3 {
            guard let lines = io.freshSnapshot()?.lines else { return }
            if CursorScreen.idle(lines) || CursorScreen.list(lines) != nil || CursorScreen.editor(lines) != nil {
                if CursorScreen.idle(lines) { break }
                try? io.press(.escape)
                sleep(80)
            } else {
                break
            }
        }
        guard let leftover, let lines = io.freshSnapshot()?.lines, let now = CursorScreen.draft(lines), !now.isEmpty,
              leftover.hasPrefix(now) else { return }
        for _ in 0..<(now.count + 1) { try? io.press(.backspace) }
    }

    // MARK: 전환

    public func apply(_ preset: AgentPreset) throws -> Outcome { try guarded { try applyUnguarded(preset) } }

    /// 모델은 그대로 두고 effort 만 한 단계 올리거나 내린다.
    public func stepEffort(up: Bool) throws -> Outcome { try guarded { try stepEffortUnguarded(up: up) } }

    /// 어느 단계에서 던져졌든 — 확정한 뒤 화면을 읽지 못한 경우까지 — 새 세션 기본값을 전환 전 값으로 되돌리고 나서 실패를 알린다.
    /// (각 단계의 실패 처리도 되돌리지만, 화면 읽기 실패는 그 처리를 거치지 않고 곧바로 던져진다.)
    private func guarded(_ body: () throws -> Outcome) throws -> Outcome {
        let before = keepDefaults ? defaults.snapshot() : nil
        // 전환 전 값을 읽지 못했으면 되돌릴 수 없다 — 아무것도 보내기 전에 멈춘다. (파일이 «없던» 것은 괜찮다: 끝나고 다시 없앤다.)
        try DefaultsFile.refuseIfUnreadable(before, name: "cursor")
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

    private func applyUnguarded(_ preset: AgentPreset) throws -> Outcome {
        try start()
        let before = keepDefaults ? defaults.snapshot() : nil
        func fail(_ message: String, leftover: String? = nil) -> SlashCommandError {
            back(toIdleClearing: leftover)
            if let before { sleep(250); _ = defaults.restore(to: before) }
            return SlashCommandError(message)
        }

        // 걸러내기는 화면에 보이는 글의 «부분 문자열» 일치다(실측: `claude opus 5.5` 는 되고 `claude opus 5 5` 는 안 된다).
        // 쓴 그대로 먼저 해 보고, 안 맞으면 숫자 앞까지의 낱말(`claude opus`)로 넓힌 뒤 이름 비교로 고른다.
        var filters = [preset.model]
        let words = preset.model.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        let leading = words.prefix { $0.rangeOfCharacter(from: .decimalDigits) == nil }.joined(separator: " ")
        if !leading.isEmpty, leading != preset.model { filters.append(leading) }
        let rows = try openList(filters: filters, wanted: preset.model, failure: fail)
        guard let target = rows.first(where: { CursorScreen.key($0.name) == CursorScreen.key(preset.model) }) else {
            throw fail(loc("'%@' is not in the Cursor model list.", preset.model))
        }
        try moveCursor(to: target.name, failure: fail)

        // 행에 매개변수가 없으면(`Claude Opus 4.5`·`Auto`) 맞출 effort 가 없다 — 그대로 확정한다.
        // 있으면 «라벨 전체» 로 비교한다: `300K Extra High` 의 낱말 `High` 가 프리셋 `high` 와 같다고 보면 안 된다.
        var expected: String?
        if !target.params.isEmpty {
            let shown = CursorScreen.parse(status: target.name + " " + target.params).effort
            if let shown, CursorScreen.effortMatches(preset.effort, label: shown) {
                expected = shown
            } else {
                expected = try setEffort(preset.effort, for: target.name, failure: fail)
            }
        }
        return try confirm(name: target.name, effortLabel: expected, before: before, failure: fail)
    }

    /// 모델은 그대로 두고 effort 만 한 단계 올리거나 내린다. 목록을 열면 커서가 지금 모델에 놓인다.
    private func stepEffortUnguarded(up: Bool) throws -> Outcome {
        try start()
        // 지금 모델은 목록을 열기 «전» 모델 줄에서 읽어 둔다 — 목록의 커서와 맞춰 볼 기준이다.
        let shown = CursorScreen.status(io.freshSnapshot()?.lines ?? []).map { CursorScreen.parse(status: $0).name } ?? ""
        let before = keepDefaults ? defaults.snapshot() : nil
        func fail(_ message: String, leftover: String? = nil) -> SlashCommandError {
            back(toIdleClearing: leftover)
            if let before { sleep(250); _ = defaults.restore(to: before) }
            return SlashCommandError(message)
        }
        _ = try openList(filters: [], wanted: nil, failure: fail)
        // 목록이 막 열린 순간에는 커서가 맨 윗줄(`Auto`)에 있다가 지금 모델로 옮겨 가기도 한다(2026-10-11 실측: 8번에 2번,
        // `Auto` 에서 Tab 을 눌러 «effort 가 없다» 로 멈췄다). 커서가 모델 줄의 그 모델에 놓인 것을 보고 나서만 Tab 을 누른다.
        guard !shown.isEmpty,
              let settled = try poll(timeoutMs: 2000, { CursorScreen.list($0)?.rows.first(where: \.cursor).map { CursorScreen.key($0.name) } == CursorScreen.key(shown) }),
              let current = CursorScreen.list(settled)?.rows.first(where: \.cursor) else {
            throw fail(loc("Could not read the cursor position in the Cursor list."))
        }
        try io.press(.tab)
        guard let editor = try poll(timeoutMs: 2000, { CursorScreen.editor($0)?.title.lowercased() == current.name.lowercased() }),
              let options = CursorScreen.editor(editor)?.options.filter({ $0.section == "Effort" }), !options.isEmpty else {
            throw fail(loc("Cursor '%@' has no effort to change.", current.name))
        }
        guard let at = options.firstIndex(where: \.chosen) else { throw fail(loc("Nothing was changed: Cursor does not show the current effort.")) }
        let next = at + (up ? 1 : -1)
        guard options.indices.contains(next) else {
            var error = fail(up ? loc("Already at the highest level (%@).", options[at].label) : loc("Already at the lowest level (%@).", options[at].label))
            error.nothingToDo = true
            throw error
        }
        let label = options[next].label
        try pick(optionLabel: label, section: "Effort", failure: fail)
        return try confirm(name: current.name, effortLabel: label, before: before, failure: fail)
    }

    // MARK: 단계

    private func start() throws {
        guard let first = io.freshSnapshot() else { throw SlashCommandError(loc("Not switched: could not read the Cursor terminal screen.")) }
        guard CursorScreen.idle(first.lines) else {
            if let draft = CursorScreen.draft(first.lines), !draft.isEmpty {
                throw SlashCommandError(loc("Not switched: there is text in the Cursor input box. Send or clear it, then press again."))
            }
            throw SlashCommandError(loc("Not switched: the Cursor input box is not visible. If a picker or a confirmation is showing, or it is working, deal with that first."))
        }
    }

    /// `/model` 목록을 연다. `filters` 가 있으면 차례로 쳐서 `wanted` 와 이름이 같은 행이 보이는 첫 것을 쓴다(없으면 마지막 결과).
    private func openList(filters: [String], wanted: String?, failure: (String, String?) -> SlashCommandError) throws -> [CursorScreen.Row] {
        try io.type("/model")
        guard (try poll(timeoutMs: 1500) { CursorScreen.draft($0) == "/model" }) != nil else {
            throw failure(loc("Nothing was sent: the command did not appear in the Cursor input box."), "/model")
        }
        try io.press(.enter)
        guard (try poll(timeoutMs: 3000) { CursorScreen.list($0) != nil }) != nil else {
            throw failure(loc("The Cursor model list did not open."), "/model")
        }
        var rows = CursorScreen.list(io.freshSnapshot()?.lines ?? [])?.rows ?? []
        var typed = ""
        for filter in filters where !filter.isEmpty {
            // 앞의 걸러내기를 지운다(글자 수만큼 Backspace).
            for _ in 0..<typed.count { try io.press(.backspace); sleep(10) }
            if !typed.isEmpty {
                guard (try poll(timeoutMs: 1500) { CursorScreen.list($0)?.filter.isEmpty == true }) != nil else {
                    throw failure(loc("Could not clear the filter in the Cursor model list."), nil)
                }
            }
            try typeSlowly(filter)
            typed = filter
            let expected = filter.lowercased()
            guard let lines = try poll(timeoutMs: 3500, { CursorScreen.list($0)?.filter.lowercased() == expected }),
                  let list = CursorScreen.list(lines) else {
                throw failure(loc("The Cursor model list was not filtered to '%@'.", filter), nil)
            }
            rows = list.rows
            if let wanted, rows.contains(where: { CursorScreen.key($0.name) == CursorScreen.key(wanted) }) { break }
        }
        return rows
    }

    /// 커서를 이름이 `name` 인 행으로 옮긴다. 옮긴 뒤 다시 읽어 확인한다.
    private func moveCursor(to name: String, failure: (String, String?) -> SlashCommandError) throws {
        for _ in 0..<12 {
            guard let list = CursorScreen.list(io.freshSnapshot()?.lines ?? []) else { throw failure(loc("The Cursor model list closed."), nil) }
            guard let from = list.rows.firstIndex(where: \.cursor), let to = list.rows.firstIndex(where: { $0.name == name }) else {
                throw failure(loc("Could not find the '%@' row in the Cursor model list.", name), nil)
            }
            if from == to { return }
            try io.press(to > from ? .down : .up)
            sleep(40)
        }
        throw failure(loc("Could not move the cursor to the '%@' row in the Cursor model list.", name), nil)
    }

    /// 매개변수 편집에서 effort 를 맞추고 목록으로 돌아온다. 고른 라벨을 돌려주고, Effort 묶음이 없는 모델이면 nil.
    private func setEffort(_ effort: String, for name: String, failure: (String, String?) -> SlashCommandError) throws -> String? {
        try io.press(.tab)
        guard let lines = try poll(timeoutMs: 2000, { CursorScreen.editor($0)?.title.lowercased() == name.lowercased() }),
              let options = CursorScreen.editor(lines)?.options else {
            throw failure(loc("The parameter editor for Cursor '%@' did not open.", name), nil)
        }
        let efforts = options.filter { $0.section == "Effort" }
        if efforts.isEmpty {
            // effort 가 없는 모델 — 목록으로 돌아가 그대로 확정한다.
            try io.press(.escape)
            guard (try poll(timeoutMs: 2000) { CursorScreen.list($0) != nil }) != nil else {
                throw failure(loc("Cursor did not return from the parameter editor to the list."), nil)
            }
            return nil
        }
        guard let option = efforts.first(where: { CursorScreen.effortMatches(effort, label: $0.label) }) else {
            throw failure(loc("Cursor '%@' has no effort '%@' (%@).", name, effort, efforts.map(\.label).joined(separator: ", ")), nil)
        }
        if !option.chosen { try pick(optionLabel: option.label, section: "Effort", failure: failure) }
        try io.press(.escape)
        guard (try poll(timeoutMs: 2000) { CursorScreen.list($0) != nil }) != nil else {
            throw failure(loc("Cursor did not return from the parameter editor to the list."), nil)
        }
        return option.label
    }

    /// 편집 화면에서 `section` 의 `optionLabel` 줄에 커서를 두고 Enter 로 고른 뒤 ✓ 를 확인한다.
    private func pick(optionLabel: String, section: String, failure: (String, String?) -> SlashCommandError) throws {
        for _ in 0..<14 {
            guard let options = CursorScreen.editor(io.freshSnapshot()?.lines ?? [])?.options else {
                throw failure(loc("The Cursor parameter editor closed."), nil)
            }
            guard let to = options.firstIndex(where: { $0.section == section && $0.label == optionLabel }),
                  let from = options.firstIndex(where: \.cursor) else {
                throw failure(loc("Could not find the '%@' line in the Cursor parameters.", optionLabel), nil)
            }
            if from == to {
                try io.press(.enter)
                if (try poll(timeoutMs: 1500) { CursorScreen.editor($0)?.options.contains { $0.section == section && $0.label == optionLabel && $0.chosen } == true }) != nil { return }
                throw failure(loc("Cursor did not apply the '%@' choice.", optionLabel), nil)
            }
            try io.press(to > from ? .down : .up)
            sleep(40)
        }
        throw failure(loc("Could not move the cursor to the '%@' line in the Cursor parameters.", optionLabel), nil)
    }

    /// `effortLabel` 이 nil 이면 effort 가 없는 모델이다 — 모델 이름만 확인한다.
    private func confirm(name: String, effortLabel: String?, before: DefaultsSnapshot?, failure: (String, String?) -> SlashCommandError) throws -> Outcome {
        // 목록(편집에서 돌아온 경우 포함)에서 커서가 그 모델 행에 있을 때만 Enter 로 확정한다.
        if CursorScreen.editor(io.freshSnapshot()?.lines ?? []) != nil {
            try io.press(.escape)
            guard (try poll(timeoutMs: 2000) { CursorScreen.list($0) != nil }) != nil else { throw failure(loc("Could not get back to the Cursor list."), nil) }
        }
        guard let list = CursorScreen.list(io.freshSnapshot()?.lines ?? []), list.rows.first(where: \.cursor)?.name == name else {
            throw failure(loc("Not confirmed: the cursor in the Cursor list is not on the '%@' row.", name), nil)
        }
        try io.press(.enter)
        func landed(_ lines: [String]) -> Bool {
            guard CursorScreen.idle(lines), let status = CursorScreen.status(lines) else { return false }
            guard status.lowercased().hasPrefix(name.lowercased()) else { return false }
            guard let effortLabel else { return true }
            // 모델 줄의 effort 도 «라벨 전체» 로 비교한다(`Extra High` 는 `High` 가 아니다).
            if let shown = CursorScreen.parse(status: status).effort { return CursorScreen.key(shown) == CursorScreen.key(effortLabel) }
            return CursorScreen.key(status).hasSuffix(CursorScreen.key(effortLabel))
        }
        guard let lines = try poll(timeoutMs: 4000, landed), let status = CursorScreen.status(lines) else {
            throw failure(loc("Stopped: the Cursor model line did not change to '%@%@'.", name, effortLabel.map { " · " + $0 } ?? ""), nil)
        }
        var warning: String?
        if let before {
            if case .failed(let reason) = defaults.restore(to: before) { warning = loc("Could not put back the default for new sessions: %@", reason) }
            sleep(250)
            if case .failed(let reason) = defaults.restore(to: before) { warning = loc("Could not put back the default for new sessions: %@", reason) }
        }
        return Outcome(confirmations: ["Using \(status)"], warning: warning)
    }
}
