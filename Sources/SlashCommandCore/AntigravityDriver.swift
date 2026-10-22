import Foundation

// Switches the model and effort with the Antigravity CLI (`agy` 1.3.1).
//
// Measured 2026-10-07 (in a separately opened test terminal):
// - `/model` opens a "Switch Model" picker: `>` is the cursor, `(current)` marks the current model, below it an `Effort ◂ ●━●━◉ ▸` slider (left/right arrows) and
//   under that the step names (`low medium high`, different per model). Enter confirms; Esc closes it with "Exited /model command".
// - Once confirmed, `⎿  Model set to Gemini 3.7 Flash (Medium)` is left under `> /model`.
// - RED: confirming saves the "new session default" in the `model` key of `~/.gemini/antigravity-cli/settings.json` (there is no "this session only").
//   So after the switch only that key is restored to its pre-switch value.
// - While working, a spinner (`⣻  Generating...`) runs above the input line. The input line (`>`) still looks empty.

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

    // MARK: Input line

    /// The bottom area: `────`, `> input`, `────`, the hint line (`? for shortcuts … <model> · <effort>`).
    /// Typing text that starts with `/` attaches a command list below (`> /model  Set a model…`, `↑/↓ Navigate · enter Select · tab Complete`) and
    /// the hint line changes to `esc to cancel`. While working the hint line is also `esc to cancel`, but there is no command list and a spinner (`⣽  Working...`) runs above
    /// (measured 2026-10-07). Either way the input line is read as it is.
    static func bottom(_ screen: [String]) -> (input: String, footer: String, popup: Bool, busy: Bool)? {
        let lines = trimmed(screen).filter { !$0.isEmpty }
        // Input box = horizontal rule, `>` line, horizontal rule. Finds the last one within the bottom eight lines (the `>` line of the command list has no rule below it).
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

    // MARK: Picker

    /// The picker is "open" when: the bottom line is the `Keyboard: …` hint and there is a `Switch Model` header above.
    /// The model rows are below the divider (`────`) and above the `Effort` line; the slider line and the name line under it are read by column position.
    public static func picker(_ screen: [String]) -> (rows: [Row], slider: Slider?)? {
        let lines = trimmed(screen)
        // The hint line (`Keyboard: …`) is near the bottom (below it one or two lines of input-line state remain — measured).
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

    /// Aligns the dots of the slider line (`Effort ◂ ●━━●━━◉ ▸`) with the names in the line below it by column position. The selected step is `◉`.
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

    // MARK: Result lines

    /// The `⎿  Model set to …` answers under `> /model` (oldest first).
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

/// The `model` key of `~/.gemini/antigravity-cli/settings.json`.
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

    /// Restores only the model-related keys to their pre-switch values (`DefaultsFile.restoreJSON`). If the file did not exist before the switch, those keys are removed, and if nothing is left the file is removed too.
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
            guard let screen = io.freshSnapshot() else { throw SlashCommandError(io.lastFailure ?? loc("Stopped: could not read the Antigravity terminal screen.")) }
            if condition(screen.lines) { return screen.lines }
            let real = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            if max(real, simulated) >= timeoutMs { return nil }
            sleep(Runner.pollMs)
            simulated += Runner.pollMs
        }
    }

    /// If the picker is open, closes it with Esc, and if the text we typed remains in the input line, clears it.
    private func back(clearing leftover: String? = nil) {
        guard io.lastFailure == nil else { return }
        for _ in 0..<2 {
            guard let lines = io.freshSnapshot()?.lines, AntigravityDriverHelper.pickerOpen(lines) else { break }
            try? io.press(.escape)
            _ = try? poll(timeoutMs: 1000) { !AntigravityDriverHelper.pickerOpen($0) }
        }
        guard let leftover, let lines = io.freshSnapshot()?.lines, let now = AgyScreen.draft(lines), !now.isEmpty, leftover.hasPrefix(now) else { return }
        for _ in 0..<(now.count + 1) { try? io.press(.backspace) }
    }

    public func apply(_ preset: AgentPreset) throws -> Outcome { try guarded { try applyUnguarded(preset) } }

    /// Raises or lowers only the effort by one step, leaving the model as is.
    public func stepEffort(up: Bool) throws -> Outcome { try guarded { try stepEffortUnguarded(up: up) } }

    /// Whichever step it was thrown from — including when the screen could not be read after confirming — it restores the new-session default to its pre-switch value and then reports the failure.
    /// (Each step's failure handling also restores, but a screen read failure is thrown directly without going through that handling.)
    private func guarded(_ body: () throws -> Outcome) throws -> Outcome {
        let before = keepDefaults ? defaults.snapshot() : nil
        // If the pre-switch value could not be read, it cannot be restored — stop before sending anything. (A file that "did not exist" is fine: it is removed again at the end.)
        try DefaultsFile.refuseIfUnreadable(before, name: "antigravity")
        do {
            return try body()
        } catch {
            if let before {
                sleep(250)
                _ = defaults.restore(to: before)
            }
            if let reason = io.lastFailure { throw SlashCommandError(reason) }
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
        guard let picker = AgyScreen.picker(io.freshSnapshot()?.lines ?? []) else { throw fail(loc("Could not read the Antigravity picker.")) }
        guard let target = picker.rows.first(where: { AgyScreen.key($0.name) == AgyScreen.key(preset.model) }) else {
            throw fail(loc("'%@' is not in the Antigravity model list.", preset.model))
        }
        try moveCursor(to: target.name, failure: fail)
        guard let fresh = io.freshSnapshot(), let movedPicker = AgyScreen.picker(fresh.lines) else {
            throw fail(loc("Could not read the Antigravity picker."))
        }
        if let slider = movedPicker.slider {
            guard let wanted = slider.labels.firstIndex(where: { AgyScreen.key($0) == AgyScreen.key(preset.effort) || (preset.effort == "xhigh" && AgyScreen.key($0) == "extrahigh") }) else {
                throw fail(loc("Antigravity '%@' has no effort '%@' (%@).", target.name, preset.effort, slider.labels.joined(separator: ", ")))
            }
            try moveEffort(to: wanted, failure: fail)
        }
        return try confirm(name: target.name, before: before, failure: fail)
    }

    /// Raises or lowers only the effort by one step, leaving the model as is. The picker's initial cursor and slider are the current model and effort.
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
            throw fail(loc("Nothing was changed: the Antigravity picker's cursor is not on the current model."))
        }
        guard let slider = picker.slider else { throw fail(loc("Antigravity '%@' has no effort to change.", current.name)) }
        let next = slider.selected + (up ? 1 : -1)
        guard slider.labels.indices.contains(next) else {
            var error = fail(up ? loc("Already at the highest level (%@).", slider.labels[slider.selected]) : loc("Already at the lowest level (%@).", slider.labels[slider.selected]))
            error.nothingToDo = true
            if let reason = io.lastFailure { throw SlashCommandError(reason) }
            throw error
        }
        try moveEffort(to: next, failure: fail)
        return try confirm(name: current.name, before: before, failure: fail)
    }

    // MARK: Steps

    private func start() throws {
        guard let first = io.freshSnapshot() else { throw SlashCommandError(io.lastFailure ?? loc("Not switched: could not read the Antigravity terminal screen.")) }
        guard AgyScreen.idle(first.lines) else {
            if let draft = AgyScreen.draft(first.lines), !draft.isEmpty {
                throw SlashCommandError(loc("Not switched: there is text in the Antigravity input box. Send or clear it, then press again."))
            }
            throw SlashCommandError(loc("Not switched: the Antigravity input box is not visible, or it is working."))
        }
    }

    private func openPicker(failure: (String, String?) -> SlashCommandError) throws {
        try io.type("/model")
        guard (try poll(timeoutMs: 1500) { AgyScreen.draft($0) == "/model" }) != nil else {
            throw failure(loc("Nothing was sent: the command did not appear in the Antigravity input box."), "/model")
        }
        try io.press(.enter)
        guard (try poll(timeoutMs: 3000) { AgyScreen.picker($0) != nil }) != nil else {
            throw failure(loc("The Antigravity model picker did not open."), "/model")
        }
    }

    private func moveCursor(to name: String, failure: (String, String?) -> SlashCommandError) throws {
        for _ in 0..<14 {
            guard let picker = AgyScreen.picker(io.freshSnapshot()?.lines ?? []) else { throw failure(loc("The Antigravity picker closed."), nil) }
            guard let from = picker.rows.firstIndex(where: \.cursor), let to = picker.rows.firstIndex(where: { $0.name == name }) else {
                throw failure(loc("Could not find the '%@' row in the Antigravity picker.", name), nil)
            }
            if from == to { return }
            try io.press(to > from ? .down : .up)
            sleep(40)
        }
        throw failure(loc("Could not move the cursor to the '%@' row in the Antigravity picker.", name), nil)
    }

    /// Sets the slider to the `target`-th step. Re-reads after each press to confirm — it does not press further at the end.
    private func moveEffort(to target: Int, failure: (String, String?) -> SlashCommandError) throws {
        for _ in 0..<8 {
            guard let slider = AgyScreen.picker(io.freshSnapshot()?.lines ?? [])?.slider else { throw failure(loc("Could not read the Antigravity effort slider."), nil) }
            if slider.selected == target { return }
            try io.press(target > slider.selected ? .right : .left)
            _ = try poll(timeoutMs: 800) { AgyScreen.picker($0)?.slider?.selected != slider.selected }
        }
        throw failure(loc("Could not set the Antigravity effort slider."), nil)
    }

    private func confirm(name: String, before: DefaultsSnapshot?, failure: (String, String?) -> SlashCommandError) throws -> Outcome {
        guard let fresh = io.freshSnapshot(), let picker = AgyScreen.picker(fresh.lines) else {
            throw failure(loc("Could not read the Antigravity picker."), nil)
        }
        guard let cursor = picker.rows.first(where: \.cursor), cursor.name == name else {   // the same test `moveCursor` uses
            throw failure(loc("Could not move the cursor to the '%@' row in the Antigravity picker.", name), nil)
        }
        let repliesBefore = AgyScreen.replies(fresh.lines)
        try io.press(.enter)
        guard let lines = try poll(timeoutMs: 4000, { lines in
            guard AgyScreen.idle(lines) else { return false }
            let replies = AgyScreen.replies(lines)
            guard let last = replies.last, last.hasPrefix("Model set to ") else { return false }
            return replies.count > repliesBefore.count || last != repliesBefore.last
        }), let reply = AgyScreen.replies(lines).last else {
            throw failure(loc("Stopped: Antigravity did not respond to the model switch."), nil)
        }
        guard AgyScreen.key(reply).hasPrefix(AgyScreen.key("Model set to " + name)) else {
            throw failure(loc("Antigravity says it switched to a different model: %@", reply), nil)
        }
        var warning: String?
        if let before {
            if case .failed(let reason) = defaults.restore(to: before) { warning = loc("Could not put back the default for new sessions: %@", reason) }
            sleep(250)
            if case .failed(let reason) = defaults.restore(to: before) { warning = loc("Could not put back the default for new sessions: %@", reason) }
        }
        return Outcome(confirmations: [reply], warning: warning)
    }
}

enum AntigravityDriverHelper {
    static func pickerOpen(_ lines: [String]) -> Bool { AgyScreen.picker(lines) != nil }
}
