import Foundation

// Antigravity CLI(`agy` 1.3.1)로 모델·effort 를 바꾼다.
//
// 2026-10-07 집 맥 실측(요한님의 시험 터미널):
// - `/model` 이 «Switch Model» 선택창을 연다: `>` 가 커서, 지금 모델에 `(current)`, 아래에 `Effort ◂ ●━●━◉ ▸` 슬라이더(←/→)와
//   그 밑의 단계 이름(`low medium high`, 모델마다 다르다). Enter 가 확정, Esc 는 «Exited /model command» 로 닫는다.
// - 확정하면 `> /model` 아래에 `⎿  Model set to Gemini 3.7 Flash (Medium)` 이 남는다.
// - 🔴 확정은 «새 세션 기본값»을 `~/.gemini/antigravity-cli/settings.json` 의 `model` 키로 저장한다(「이 세션만」 없음).
//   그래서 전환 뒤 그 키만 전환 전 값으로 되돌린다.
// - 작업 중에는 입력줄 위에 스피너(`⣻  Generating...`)가 돈다. 입력줄(`>`)은 그대로 비어 보인다.

public enum AgyScreen {
    public struct Row: Equatable, Sendable {
        public let name: String
        public let current: Bool
        public let cursor: Bool
    }

    public struct Slider: Equatable, Sendable {
        public let labels: [String]
        public let selected: Int
    }

    static func trimmed(_ screen: [String]) -> [String] {
        var lines = screen.map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    static func isRule(_ line: String) -> Bool { line.count >= 8 && line.allSatisfy { $0 == "─" } }

    static func isSpinner(_ line: String) -> Bool {
        line.unicodeScalars.first.map { (0x2800...0x28FF).contains($0.value) } ?? false
    }

    // MARK: 입력줄

    /// 맨 아래 영역: `────` · `> 입력` · `────` · 안내 줄(`? for shortcuts … <모델> · <effort>`).
    /// `/` 로 시작하는 글을 치면 아래에 명령 목록(`> /model  Set a model…`, `↑/↓ Navigate · enter Select · tab Complete`)이 붙고
    /// 안내 줄이 `esc to cancel` 로 바뀐다. 작업 중에도 안내 줄이 `esc to cancel` 이지만 명령 목록이 없고 위에 스피너(`⣽  Working...`)가 돈다
    /// (2026-10-07 실측). 어느 쪽이든 입력줄은 그대로 읽는다.
    static func bottom(_ screen: [String]) -> (input: String, footer: String, popup: Bool, busy: Bool)? {
        let lines = trimmed(screen).filter { !$0.isEmpty }
        // 입력 상자 = 가로줄 · `>` 줄 · 가로줄. 맨 아래 여덟 줄 안에서 마지막 것을 찾는다(명령 목록의 `>` 줄은 아래에 가로줄이 없다).
        guard let index = lines.indices.reversed().prefix(8).first(where: {
            lines[$0].hasPrefix(">") && $0 >= 1 && $0 + 1 < lines.count && isRule(lines[$0 - 1]) && isRule(lines[$0 + 1])
        }) else { return nil }
        let after = Array(lines[(index + 2)...])
        let popup = after.contains { $0.hasPrefix("↑/↓ Navigate") }
        let footer = popup ? "" : (after.last ?? "")
        let input = String(lines[index].dropFirst()).trimmingCharacters(in: .whitespaces)
        let above = index >= 2 ? lines[index - 2] : ""
        let busy = isSpinner(above) || above.contains("Working") || above.contains("Generating") || footer.hasPrefix("esc to cancel")
        return (input, footer, popup, busy)
    }

    public static func idle(_ screen: [String]) -> Bool {
        guard let bottom = bottom(screen) else { return false }
        return !bottom.busy && !bottom.popup && bottom.input.isEmpty && bottom.footer.hasPrefix("? for shortcuts")
    }

    public static func draft(_ screen: [String]) -> String? { bottom(screen)?.input }

    // MARK: 선택창

    /// 선택창이 «열려 있는» 상태: 맨 아랫줄이 `Keyboard: …` 안내이고 위에 `Switch Model` 머리말이 있다.
    /// 모델 행은 구분선(`────`) 아래 `Effort` 줄 위에 있고, 슬라이더 줄과 그 아래 이름 줄은 칸 위치(열)로 읽는다.
    public static func picker(_ screen: [String]) -> (rows: [Row], slider: Slider?)? {
        let lines = trimmed(screen)
        // 안내 줄(`Keyboard: …`)은 맨 아래 가까이에 있다(그 아래에는 입력줄 상태가 한두 줄 남는다 — 실측).
        guard let footerIndex = lines.lastIndex(where: { $0.hasPrefix("Keyboard:") && $0.contains("enter Select") }),
              footerIndex >= lines.count - 4,
              let header = lines[..<footerIndex].lastIndex(of: "Switch Model"),
              let rule = lines[(header + 1)..<footerIndex].firstIndex(where: { isRule($0) }) else { return nil }
        let effort = lines[(rule + 1)..<footerIndex].firstIndex { $0.hasPrefix("Effort") && $0.contains("◂") }
        var rows: [Row] = []
        for line in lines[(rule + 1)..<(effort ?? footerIndex)] where !line.isEmpty {
            var text = line
            let cursor = text.hasPrefix(">")
            if cursor { text = String(text.dropFirst()) }
            text = text.trimmingCharacters(in: .whitespaces)
            var current = false
            if let range = text.range(of: "(current)") {
                current = true
                text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            if !text.isEmpty { rows.append(Row(name: text, current: current, cursor: cursor)) }
        }
        return (rows, effort.flatMap { _ in slider(screen) })
    }

    /// 슬라이더 줄(`Effort ◂ ●━━●━━◉ ▸`)의 점들과 그 아래 줄의 이름들을 열 위치로 맞춘다. 선택된 단계는 `◉`.
    static func slider(_ screen: [String]) -> Slider? {
        guard let at = screen.lastIndex(where: { $0.contains("Effort") && $0.contains("◂") }), at + 1 < screen.count else { return nil }
        let dots = Array(screen[at]).enumerated().filter { "●◉○".contains($0.element) }
        guard !dots.isEmpty else { return nil }
        let chars = Array(screen[at + 1])
        var names: [(text: String, center: Double)] = []
        var start: Int?
        for (offset, character) in (chars + [" "]).enumerated() {
            if character != " ", start == nil { start = offset }
            if character == " ", let from = start {
                names.append((String(chars[from..<offset]), Double(from + offset - 1) / 2))
                start = nil
            }
        }
        guard !names.isEmpty else { return nil }
        var labels: [String] = []
        var selected = 0
        for (position, dot) in dots.enumerated() {
            guard let nearest = names.min(by: { abs($0.center - Double(dot.offset)) < abs($1.center - Double(dot.offset)) }) else { return nil }
            labels.append(nearest.text)
            if dot.element == "◉" { selected = position }
        }
        return Slider(labels: labels, selected: selected)
    }

    // MARK: 결과 줄

    /// `> /model` 아래의 `⎿  Model set to …` 답들(오래된 것부터).
    public static func replies(_ screen: [String]) -> [String] {
        let lines = trimmed(screen)
        var found: [String] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("> /model") && index + 1 < lines.count {
            let next = lines[index + 1]
            if next.hasPrefix("⎿") { found.append(String(next.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        }
        return found
    }

    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

/// `~/.gemini/antigravity-cli/settings.json` 의 `model` 키.
public struct AntigravityDefaults: Sendable {
    public let url: URL

    public init(url: URL = AntigravityDefaults.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli/settings.json")
    }

    public func snapshot() -> DefaultsSnapshot { DefaultsFile.snapshot(url) }

    public enum Outcome: Equatable, Sendable {
        case unchanged
        case restored
        case failed(String)
    }

    /// 모델 관련 키만 전환 전 값으로 되돌린다(`DefaultsFile.restoreJSON`). 전환 전에 파일이 없었으면 그 키들을 없애고, 남는 것이 없으면 파일도 없앤다.
    public func restore(to snapshot: DefaultsSnapshot) -> Outcome {
        switch DefaultsFile.restoreJSON(url: url, keys: ["model"], to: snapshot, pretty: true, name: "antigravity") {
        case .unchanged: return .unchanged
        case .restored: return .restored
        case .failed(let reason): return .failed(reason)
        }
    }

    public func restore(to before: Data) -> Outcome { restore(to: .content(before)) }
}

public struct AntigravityDriver {
    public let io: TerminalIO
    public let sleep: (Int) -> Void
    public let defaults: AntigravityDefaults
    public let keepDefaults: Bool

    public init(io: TerminalIO, sleep: @escaping (Int) -> Void, defaults: AntigravityDefaults = AntigravityDefaults(), keepDefaults: Bool) {
        self.io = io
        self.sleep = sleep
        self.defaults = defaults
        self.keepDefaults = keepDefaults
    }

    public struct Outcome: Sendable {
        public let confirmations: [String]
        public let warning: String?
    }

    private func poll(timeoutMs: Int, _ condition: ([String]) -> Bool) throws -> [String]? {
        let started = DispatchTime.now()
        var simulated = 0
        while true {
            guard let screen = io.freshSnapshot() else { throw SlashCommandError("antigravity 터미널 화면을 읽지 못해 중단했습니다.") }
            if condition(screen.lines) { return screen.lines }
            let real = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            if max(real, simulated) >= timeoutMs { return nil }
            sleep(Runner.pollMs)
            simulated += Runner.pollMs
        }
    }

    /// 선택창이 열려 있으면 Esc 로 닫고, 입력줄에 우리가 쓴 글이 남아 있으면 지운다.
    private func back(clearing leftover: String? = nil) {
        for _ in 0..<2 {
            guard let lines = io.freshSnapshot()?.lines, AntigravityDriverHelper.pickerOpen(lines) else { break }
            try? io.press(.escape)
            _ = try? poll(timeoutMs: 1000) { !AntigravityDriverHelper.pickerOpen($0) }
        }
        guard let leftover, let lines = io.freshSnapshot()?.lines, let now = AgyScreen.draft(lines), !now.isEmpty, leftover.hasPrefix(now) else { return }
        for _ in 0..<(now.count + 1) { try? io.press(.backspace) }
    }

    public func apply(_ preset: AgentPreset) throws -> Outcome { try guarded { try applyUnguarded(preset) } }

    /// 모델은 그대로 두고 effort 만 한 단계 올리거나 내린다.
    public func stepEffort(up: Bool) throws -> Outcome { try guarded { try stepEffortUnguarded(up: up) } }

    /// 어느 단계에서 던져졌든 — 확정한 뒤 화면을 읽지 못한 경우까지 — 새 세션 기본값을 전환 전 값으로 되돌리고 나서 실패를 알린다.
    /// (각 단계의 실패 처리도 되돌리지만, 화면 읽기 실패는 그 처리를 거치지 않고 곧바로 던져진다.)
    private func guarded(_ body: () throws -> Outcome) throws -> Outcome {
        let before = keepDefaults ? defaults.snapshot() : nil
        // 전환 전 값을 읽지 못했으면 되돌릴 수 없다 — 아무것도 보내기 전에 멈춘다. (파일이 «없던» 것은 괜찮다: 끝나고 다시 없앤다.)
        try DefaultsFile.refuseIfUnreadable(before, name: "antigravity")
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
            back(clearing: leftover)
            if let before { sleep(250); _ = defaults.restore(to: before) }
            return SlashCommandError(message)
        }
        try openPicker(failure: fail)
        guard var picker = AgyScreen.picker(io.freshSnapshot()?.lines ?? []) else { throw fail("antigravity 선택창을 읽지 못했습니다.") }
        guard let target = picker.rows.first(where: { AgyScreen.key($0.name) == AgyScreen.key(preset.model) }) else {
            throw fail("antigravity 모델 목록에 '\(preset.model)' 이 없습니다.")
        }
        try moveCursor(to: target.name, failure: fail)
        picker = AgyScreen.picker(io.freshSnapshot()?.lines ?? []) ?? picker
        if let slider = picker.slider {
            guard let wanted = slider.labels.firstIndex(where: { AgyScreen.key($0) == AgyScreen.key(preset.effort) || (preset.effort == "xhigh" && AgyScreen.key($0) == "extrahigh") }) else {
                throw fail("antigravity '\(target.name)' 에는 effort '\(preset.effort)' 가 없습니다(\(slider.labels.joined(separator: ", "))).")
            }
            try moveEffort(to: wanted, failure: fail)
        }
        return try confirm(name: target.name, before: before, failure: fail)
    }

    /// 모델은 그대로 두고 effort 만 한 단계 올리거나 내린다. 선택창의 첫 커서·슬라이더가 지금 모델과 effort 다.
    private func stepEffortUnguarded(up: Bool) throws -> Outcome {
        try start()
        let before = keepDefaults ? defaults.snapshot() : nil
        func fail(_ message: String, leftover: String? = nil) -> SlashCommandError {
            back(clearing: leftover)
            if let before { sleep(250); _ = defaults.restore(to: before) }
            return SlashCommandError(message)
        }
        try openPicker(failure: fail)
        guard let picker = AgyScreen.picker(io.freshSnapshot()?.lines ?? []),
              let current = picker.rows.first(where: \.current), picker.rows.first(where: \.cursor)?.name == current.name else {
            throw fail("antigravity 선택창의 커서가 지금 모델에 있지 않아 바꾸지 않았습니다.")
        }
        guard let slider = picker.slider else { throw fail("antigravity '\(current.name)' 에는 바꿀 effort 가 없습니다.") }
        let next = slider.selected + (up ? 1 : -1)
        guard slider.labels.indices.contains(next) else {
            var error = fail("이미 \(up ? "가장 높은" : "가장 낮은") 단계(\(slider.labels[slider.selected]))입니다.")
            error.nothingToDo = true
            throw error
        }
        try moveEffort(to: next, failure: fail)
        return try confirm(name: current.name, before: before, failure: fail)
    }

    // MARK: 단계

    private func start() throws {
        guard let first = io.freshSnapshot() else { throw SlashCommandError("antigravity 터미널 화면을 읽지 못해 전환하지 않았습니다.") }
        guard AgyScreen.idle(first.lines) else {
            if let draft = AgyScreen.draft(first.lines), !draft.isEmpty {
                throw SlashCommandError("antigravity 입력창에 쓰던 글이 있어 전환하지 않았습니다. 먼저 보내거나 지운 뒤 다시 눌러 주세요.")
            }
            throw SlashCommandError("antigravity 입력창이 보이지 않거나 작업 중이라 전환하지 않았습니다.")
        }
    }

    private func openPicker(failure: (String, String?) -> SlashCommandError) throws {
        try io.type("/model")
        guard (try poll(timeoutMs: 1500) { AgyScreen.draft($0) == "/model" }) != nil else {
            throw failure("antigravity 입력창에 명령이 나타나지 않아 보내지 않았습니다.", "/model")
        }
        try io.press(.enter)
        guard (try poll(timeoutMs: 3000) { AgyScreen.picker($0) != nil }) != nil else {
            throw failure("antigravity 모델 선택창이 열리지 않았습니다.", "/model")
        }
    }

    private func moveCursor(to name: String, failure: (String, String?) -> SlashCommandError) throws {
        for _ in 0..<14 {
            guard let picker = AgyScreen.picker(io.freshSnapshot()?.lines ?? []) else { throw failure("antigravity 선택창이 닫혔습니다.", nil) }
            guard let from = picker.rows.firstIndex(where: \.cursor), let to = picker.rows.firstIndex(where: { $0.name == name }) else {
                throw failure("antigravity 선택창에서 '\(name)' 행을 찾지 못했습니다.", nil)
            }
            if from == to { return }
            try io.press(to > from ? .down : .up)
            sleep(40)
        }
        throw failure("antigravity 선택창에서 '\(name)' 행으로 커서를 옮기지 못했습니다.", nil)
    }

    /// 슬라이더를 `target` 번째 단계에 맞춘다. 한 번 누를 때마다 다시 읽어 확인한다 — 끝에서 더 누르지 않는다.
    private func moveEffort(to target: Int, failure: (String, String?) -> SlashCommandError) throws {
        for _ in 0..<8 {
            guard let slider = AgyScreen.picker(io.freshSnapshot()?.lines ?? [])?.slider else { throw failure("antigravity effort 슬라이더를 읽지 못했습니다.", nil) }
            if slider.selected == target { return }
            try io.press(target > slider.selected ? .right : .left)
            _ = try poll(timeoutMs: 800) { AgyScreen.picker($0)?.slider?.selected != slider.selected }
        }
        throw failure("antigravity effort 슬라이더를 맞추지 못했습니다.", nil)
    }

    private func confirm(name: String, before: DefaultsSnapshot?, failure: (String, String?) -> SlashCommandError) throws -> Outcome {
        let repliesBefore = AgyScreen.replies(io.freshSnapshot()?.lines ?? [])
        try io.press(.enter)
        guard let lines = try poll(timeoutMs: 4000, { lines in
            guard AgyScreen.idle(lines) else { return false }
            let replies = AgyScreen.replies(lines)
            guard let last = replies.last, last.hasPrefix("Model set to ") else { return false }
            return replies.count > repliesBefore.count || last != repliesBefore.last
        }), let reply = AgyScreen.replies(lines).last else {
            throw failure("antigravity 가 모델 전환에 응답하지 않아 멈췄습니다.", nil)
        }
        guard AgyScreen.key(reply).hasPrefix(AgyScreen.key("Model set to " + name)) else {
            throw failure("antigravity 가 다른 모델로 바꿨다고 답했습니다: \(reply)", nil)
        }
        var warning: String?
        if let before {
            if case .failed(let reason) = defaults.restore(to: before) { warning = "새 세션 기본값을 되돌리지 못했습니다: \(reason)" }
            sleep(250)
            if case .failed(let reason) = defaults.restore(to: before) { warning = "새 세션 기본값을 되돌리지 못했습니다: \(reason)" }
        }
        return Outcome(confirmations: [reply], warning: warning)
    }
}

enum AntigravityDriverHelper {
    static func pickerOpen(_ lines: [String]) -> Bool { AgyScreen.picker(lines) != nil }
}
