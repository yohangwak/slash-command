import Foundation

// Switch model and effort with cursor-agent (2026.10.01).
//
// Measured 2026-10-07 (in a separately opened test terminal):
// - `/model` opens the «Available models» list (`→` is the cursor; the cursor starts on the current model). Typing «one character at a time» filters it with «Filter:»;
//   several characters sent as one chunk are treated as a paste and ignored.
// - Tab opens that row's «Edit Parameters» (Context · Effort · Fast radios), Enter picks that line (✓), and Esc returns to the list.
//   Enter in the list confirms that row. The «<model> <context> <Effort>» line below the input box changes.
// - 🔴 Confirming saves the «new-session default» in `~/.cursor/cli-config.json` as `model`, `selectedModel`, `modelSelectionHistory` and `modelParameters` (the parameters last chosen for each model).
//   There is no "this session only", so after switching only those four keys are put back to their values from before. A running session keeps its model even after the restore (measured).

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

    // MARK: idle state

    /// Bottom: the path line (`~/… · branch`), above it the model line (`Grok 4.7 256K Medium`), and above that (skipping a few blank lines) the input line (`→ …`).
    /// Once a conversation starts, context usage (`· 7.1%`) is appended to the end of the model line (measured 2026-10-07) and the placeholder text of the input line changes.
    static func bottom(_ screen: [String]) -> (input: String, status: String, path: String, busy: Bool)? {
        let lines = trimmed(screen)
        guard lines.count >= 3, let path = lines.last, path.contains(" · "), path.hasPrefix("~") || path.hasPrefix("/") else { return nil }
        var index = lines.count - 2
        while index >= 0, lines[index].isEmpty { index -= 1 }
        guard index >= 1 else { return nil }
        // A run-mode label on the right (`Run Everything`, a session opened with `--yolo`) is two or more columns away; the model line is taken only up to it (measured 2026-10-11).
        var status = (lines[index].components(separatedBy: "  ").first ?? lines[index]).trimmingCharacters(in: .whitespaces)
        if let usage = status.range(of: #" · \d+(\.\d+)?%$"#, options: .regularExpression) { status = String(status[..<usage.lowerBound]) }
        index -= 1
        while index >= 0, lines[index].isEmpty { index -= 1 }
        guard index >= 0, lines[index].hasPrefix("→") else { return nil }
        // A hint on the right (`ctrl+c to stop`) is two or more columns away; the input text is taken only up to it.
        let input = (String(lines[index].dropFirst()).trimmingCharacters(in: .whitespaces).components(separatedBy: "  ").first ?? "").trimmingCharacters(in: .whitespaces)
        // While working, `ctrl+c to stop` is attached to the right of the input line and a braille spinner runs above it (`⠰⠳ Working`); the input box itself still looks empty.
        // A tip line (`Tip: …`) can sit between the spinner and the input line (measured 2026-10-11: looking only at the line directly above, we switched while it was working), so look a few lines up.
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

    /// The model line below the input box (`Grok 4.7 256K Medium`).
    public static func status(_ screen: [String]) -> String? { bottom(screen)?.status }

    // MARK: list

    /// The rows of the list while it is «open». Accepted only when the bottom line is the list hint (`Type to filter …`).
    public static func list(_ screen: [String]) -> (filter: String, rows: [Row])? {
        let lines = trimmed(screen)
        guard let footer = lines.last, footer.hasPrefix("Type to filter") else { return nil }
        guard let filterIndex = lines.lastIndex(where: { $0.hasPrefix("Filter:") }) else { return nil }
        let filter = String(lines[filterIndex].dropFirst("Filter:".count)).trimmingCharacters(in: .whitespaces)
        var rows: [Row] = []
        for line in lines[(filterIndex + 1)..<(lines.count - 1)] {
            guard !line.isEmpty else { continue }
            // A page indicator like `1-10 of 42` is not a row.
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

    // MARK: parameter editing

    public static func editor(_ screen: [String]) -> (title: String, options: [Option])? {
        let lines = trimmed(screen)
        guard let footer = lines.last, footer.contains("to go back"), footer.contains("to navigate"),
              let titleIndex = lines.lastIndex(where: { $0.contains("— Edit Parameters") }),
              let cut = lines[titleIndex].range(of: "— Edit Parameters") else { return nil }
        // Claude models have `Max mode: OFF` on the right of the same line (measured); the name is taken only up to «— Edit Parameters».
        let title = String(lines[titleIndex][..<cut.lowerBound]).trimmingCharacters(in: .whitespaces)
        var section = ""
        var options: [Option] = []
        // A blank line ends a group; a `◯ Fast` after it does not belong to the Effort group (measured 2026-10-07: it was read as Effort, Enter was pressed and Fast got turned on).
        for line in lines[(titleIndex + 1)..<(lines.count - 1)] {
            if line.isEmpty { section = ""; continue }
            var text = line
            var cursor = false
            if text.hasPrefix("→") { cursor = true; text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if let first = text.first, "●○◯◉".contains(first) {
                var label = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
                let chosen = label.hasSuffix("✓") || first == "◉"
                if label.hasSuffix("✓") { label = String(label.dropLast()).trimmingCharacters(in: .whitespaces) }
                // `◯` (off) and `◉` (on) are on/off switches (Fast), not a radio group.
                options.append(Option(section: (first == "◯" || first == "◉") ? "Toggle" : section, label: label, chosen: chosen, cursor: cursor))
            } else {
                section = text
            }
        }
        return (title, options)
    }

    /// (name, effort label) from the model line (`Grok 4.7 256K Medium`). The context token (`256K`) is dropped.
    public static func parse(status: String) -> (name: String, effort: String?) {
        var words = status.split(separator: " ").map(String.init)
        // If the `Fast` switch is on, it is appended at the very end (`Grok 4.7 256K Medium Fast`).
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

    // MARK: comparison

    /// For comparing names: lowercase, letters and digits only (`claude-opus-5-5` and `Claude Opus 5.5` count as the same).
    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Whether the preset's effort value (`xhigh`) equals the screen label (`Extra High`).
    static func effortMatches(_ value: String, label: String) -> Bool {
        let aliases: [String: [String]] = ["low": ["low"], "medium": ["medium"], "high": ["high"],
                                           "xhigh": ["xhigh", "extrahigh"], "max": ["max", "maximum"], "none": ["none", "off"]]
        let wanted = aliases[value.lowercased()] ?? [key(value)]
        return wanted.contains(key(label))
    }
}

/// Handles only the four «default model» keys in `~/.cursor/cli-config.json`.
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

    /// Puts only the model-related keys back to their pre-switch values (`DefaultsFile.restoreJSON`). If the file did not exist before the switch, those keys are removed, and if nothing is left the file is removed too.
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

    // MARK: waiting for the screen and sending keys

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

    /// Types one character at a time; a single chunk is treated as a paste and ignored (measured).
    private func typeSlowly(_ text: String) throws {
        for character in text {
            try io.type(String(character))
            sleep(25)
        }
    }

    /// Closes whatever is open with Esc and returns to the input box (at most 3 times). Text left in the input box is erased only if `leftover` is ours.
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

    // MARK: switching

    public func apply(_ preset: AgentPreset) throws -> Outcome { try guarded { try applyUnguarded(preset) } }

    /// Leaves the model alone and moves only effort up or down by one step.
    public func stepEffort(up: Bool) throws -> Outcome { try guarded { try stepEffortUnguarded(up: up) } }

    /// Whichever step it was thrown from, even when the screen could not be read after confirming, restores the new-session default to its pre-switch value and then reports the failure.
    /// (Each step's own failure handling also restores it, but a failure to read the screen is thrown directly without going through that.)
    private func guarded(_ body: () throws -> Outcome) throws -> Outcome {
        let before = keepDefaults ? defaults.snapshot() : nil
        // If the pre-switch value could not be read it cannot be restored, so stop before sending anything. (A file that «did not exist» is fine: it is removed again afterwards.)
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

        // Filtering matches a «substring» of the text shown on screen (measured: `claude opus 5.5` works, `claude opus 5 5` does not).
        // Try it as written first; if that does not match, widen to the words before the first digit (`claude opus`) and then pick by name comparison.
        var filters = [preset.model]
        let words = preset.model.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        let leading = words.prefix { $0.rangeOfCharacter(from: .decimalDigits) == nil }.joined(separator: " ")
        if !leading.isEmpty, leading != preset.model { filters.append(leading) }
        let rows = try openList(filters: filters, wanted: preset.model, failure: fail)
        guard let target = rows.first(where: { CursorScreen.key($0.name) == CursorScreen.key(preset.model) }) else {
            throw fail(loc("'%@' is not in the Cursor model list.", preset.model))
        }
        try moveCursor(to: target.name, failure: fail)

        // If the row has no parameters (`Claude Opus 4.5`, `Auto`) there is no effort to set, so confirm as is.
        // If it has, compare by the «whole label»: the word `High` in `300K Extra High` must not be taken as equal to the preset `high`.
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

    /// Leaves the model alone and moves only effort up or down by one step. Opening the list puts the cursor on the current model.
    private func stepEffortUnguarded(up: Bool) throws -> Outcome {
        try start()
        // Read the current model from the model line «before» opening the list; it is the reference to check the list's cursor against.
        let shown = CursorScreen.status(io.freshSnapshot()?.lines ?? []).map { CursorScreen.parse(status: $0).name } ?? ""
        let before = keepDefaults ? defaults.snapshot() : nil
        func fail(_ message: String, leftover: String? = nil) -> SlashCommandError {
            back(toIdleClearing: leftover)
            if let before { sleep(250); _ = defaults.restore(to: before) }
            return SlashCommandError(message)
        }
        _ = try openList(filters: [], wanted: nil, failure: fail)
        // Right after the list opens, the cursor may be on the top line (`Auto`) and then move to the current model (measured 2026-10-11: 2 of 8 times,
        // Tab was pressed on `Auto` and it stopped with "no effort"). Press Tab only after seeing the cursor on the current model's row.
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

    // MARK: steps

    private func start() throws {
        guard let first = io.freshSnapshot() else { throw SlashCommandError(loc("Not switched: could not read the Cursor terminal screen.")) }
        guard CursorScreen.idle(first.lines) else {
            if let draft = CursorScreen.draft(first.lines), !draft.isEmpty {
                throw SlashCommandError(loc("Not switched: there is text in the Cursor input box. Send or clear it, then press again."))
            }
            throw SlashCommandError(loc("Not switched: the Cursor input box is not visible. If a picker or a confirmation is showing, or it is working, deal with that first."))
        }
    }

    /// Opens the `/model` list. If `filters` is given, types them in turn and uses the first one that shows a row with the same name as `wanted` (otherwise the last result).
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
            // Erase the previous filter (Backspace as many times as its length).
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

    /// Moves the cursor to the row named `name`. Reads again after moving to confirm.
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

    /// Sets effort in parameter editing and returns to the list. Returns the label chosen, or nil for a model with no Effort group.
    private func setEffort(_ effort: String, for name: String, failure: (String, String?) -> SlashCommandError) throws -> String? {
        try io.press(.tab)
        guard let lines = try poll(timeoutMs: 2000, { CursorScreen.editor($0)?.title.lowercased() == name.lowercased() }),
              let options = CursorScreen.editor(lines)?.options else {
            throw failure(loc("The parameter editor for Cursor '%@' did not open.", name), nil)
        }
        let efforts = options.filter { $0.section == "Effort" }
        if efforts.isEmpty {
            // A model with no effort: return to the list and confirm as is.
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

    /// In the editor, puts the cursor on the `optionLabel` line of `section`, picks it with Enter, then confirms the ✓.
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

    /// If `effortLabel` is nil the model has no effort: only the model name is checked.
    private func confirm(name: String, effortLabel: String?, before: DefaultsSnapshot?, failure: (String, String?) -> SlashCommandError) throws -> Outcome {
        // Confirm with Enter only when the cursor is on that model's row in the list (including when returning from the editor).
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
            // The effort on the model line is also compared by the «whole label» (`Extra High` is not `High`).
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
