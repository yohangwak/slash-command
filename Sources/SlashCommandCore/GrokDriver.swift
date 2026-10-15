import Foundation

// Switches model and effort with grok (xAI's Grok Build CLI, 1.0.46 and 1.0.50).
//
// Measured 2026-10-07 (in a separately opened test terminal):
// - A single line `/model <model> [window] [effort]` changes this session's model and effort, and the label on the bottom border of the input box
//   changes to `Grok 4.7 (xhigh)`. For a nonexistent model, a line «Unknown model: …» appears.
// - 🔴 Both the `/model` command and the picker (opened by typing only `/model`: 3 steps, model → window size → effort) save the «new session default»
//   to `[models] default · default_reasoning_effort` in `~/.grok/config.toml`. There is no "this session only" confirmation.
//   So, like claude's command mode, «after switching, restore only those two keys to their pre-switch values» (other keys and writes by other sessions are left alone).
// - If there is text being written in the input box it would mix with the command, so send only when it is empty.
//
// Measured 2026-10-12 on a test Mac (1.0.50, in a separately opened test session):
// - A just-opened session (first screen) has only the release channel marker `[stable]` in the hint line's place (`Grok Build  1.0.50 [stable]` when the window is short).
//   After doing anything, it becomes the old hint line.
// - When the permission mode is not the default it follows the label: `Grok 4.7 (high) · always-approve`, `· plan`, `· auto-review`.
// - If the window is taller than 20 lines there is one blank line between the bottom border and the hint line. At 20 lines or fewer the hint line is always just `Ctrl+x:shortcuts`.

/// Reads the grok input box from the screen. Reads from the bottom line up — similar text in the conversation is ignored.
public enum GrokScreen {
    public struct Box: Equatable, Sendable {
        /// The text after `│ ❯ ` (joined if multiple lines). "" if empty.
        public let input: String
        /// The model part from the label on the bottom border (`Grok 4.7 (xhigh)`). nil if none.
        public let label: String?
        public let footer: String
    }

    static let placeholders: Set<String> = ["Build anything"]

    /// The hint-line slot of a just-opened session: one release channel marker (`[stable]`); in a short window the version precedes it (`Grok Build  1.0.50 [stable]`).
    static func isChannelTag(_ footer: String) -> Bool {
        footer.range(of: "^(Grok Build +[0-9][^ ]* +)?\\[[a-z0-9-]+\\]$", options: .regularExpression) != nil
    }

    /// The input box at the very bottom of the screen: the last line is the hint line, above it the bottom border (`╰…╯`), above that the input lines starting with `│`, above that the top border (`╭`).
    public static func box(_ screen: [String]) -> Box? {
        var lines = screen.map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count >= 3, let footer = lines.last, footer.contains("Ctrl+x:shortcuts") || isChannelTag(footer) else { return nil }
        lines.removeLast()
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count >= 2, let bottom = lines.last, bottom.hasPrefix("╰"), bottom.hasSuffix("╯") else { return nil }
        var rows: [String] = []
        var index = lines.count - 2
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

    /// The label from `╰───── Grok 4.7 (xhigh) ─╯`. The trailing permission mode (` · always-approve`) is stripped.
    static func label(inBorder border: String) -> String? {
        var inner = border
        inner.removeFirst()
        inner.removeLast()
        let parts = inner.split(separator: "─", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let whole = parts.last(where: { !$0.isEmpty }) else { return nil }
        let model = whole.components(separatedBy: " · ")[0].trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? nil : model
    }

    /// While working there is a status line above the input box: `⠹ Waiting for response… 1.4s   1.4s ⇣38.7k [stop]` (starts with a spinner and ends with `[stop]`).
    public static func working(_ screen: [String]) -> Bool {
        screen.contains { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let first = text.unicodeScalars.first, (0x2800...0x28FF).contains(first.value) else { return false }
            return text.hasSuffix("[stop]")
        }
    }

    /// The idle state where the input box is «empty» and nothing is open. Accepted only when the hint line is a known form (input field / conversation focused / release channel marker of a just-opened session /
    /// the short hint line of a short window) — while working `Ctrl+c:cancel` is added to the hint line (measured 2026-10-07: the input box still looks empty),
    /// and with a picker, command list, or text being written `Enter:send …` is added. A hint line never seen before is not idle.
    /// When the window is 20 lines or fewer the hint line is always just `Ctrl+x:shortcuts` (measured on 1.0.50: even while working, even with a picker open), so working is screened out by the status line —
    /// a picker or text being written is caught because the input box has text.
    public static func idle(_ screen: [String]) -> Bool {
        guard let box = box(screen), !working(screen) else { return false }
        let footer = box.footer.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        let known = footer == "Shift+Tab:mode │ Ctrl+x:shortcuts" || footer == "Ctrl+x:shortcuts"
            || (footer.hasPrefix("Space:prompt") && !footer.contains("cancel")) || isChannelTag(footer)
        return known && (box.input.isEmpty || placeholders.contains(box.input))
    }

    /// The text of the input box (placeholder text counts as empty). nil if the box cannot be read.
    public static func draft(_ screen: [String]) -> String? {
        guard let box = box(screen) else { return nil }
        return placeholders.contains(box.input) ? "" : box.input
    }

    /// Label `Grok 4.7 (xhigh)` → (name, effort). effort is nil for a model without effort.
    public static func parse(label: String) -> (name: String, effort: String?) {
        guard label.hasSuffix(")"), let open = label.lastIndex(of: "(") else { return (label, nil) }
        let effort = String(label[label.index(after: open)..<label.index(before: label.endIndex)])
        let name = String(label[..<open]).trimmingCharacters(in: .whitespaces)
        return (name, effort)
    }

    /// Lines in the last few lines where grok answers in the «unknown» vein. Lines from earlier attempts may remain on screen, so the caller compares «before and after» and looks only at new lines.
    public static func errorLines(_ screen: [String], bottom: Int = 14) -> [String] {
        let tail = screen.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(bottom)
        return tail.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("Unknown model") || $0.hasPrefix("Invalid ") || $0.contains("not available") }
    }
}

/// `~/.grok/models_cache.json` — the model list grok has fetched from the server.
public struct GrokModels: Sendable {
    public struct Model: Equatable, Sendable {
        public let id: String
        public let name: String
        /// Supported efforts (from the lowest level). Empty for a model without effort.
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

    /// The model matching the preset's model field (an id or screen name). nil if the list is empty (not knowing differs from not having).
    public func resolve(_ text: String) -> Model? {
        let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        return models.first { $0.id.lowercased() == wanted || $0.name.lowercased() == wanted }
    }

    public func model(named name: String) -> Model? {
        models.first { $0.name.lowercased() == name.lowercased() }
    }
}

/// Handles only the two keys `default` and `default_reasoning_effort` in `[models]` of `~/.grok/config.toml`.
public struct GrokDefaults: Sendable {
    public let url: URL

    public init(url: URL = GrokDefaults.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/config.toml")
    }

    static let keys = ["default", "default_reasoning_effort"]

    public func snapshot() -> DefaultsSnapshot { DefaultsFile.snapshot(url) }

    public enum Outcome: Equatable, Sendable {
        case unchanged
        case restored
        case failed(String)
    }

    /// Restores only the two keys in the current file to their pre-switch values. Everything else (other keys, what other sessions wrote) is left alone.
    /// If the file did not exist before the switch, it removes the two keys, and removes the file too if nothing is left.
    public func restore(to snapshot: DefaultsSnapshot) -> Outcome {
        let before: String
        var wasAbsent = false
        switch snapshot {
        case .unreadable(let reason): return .failed(loc("Could not read the Grok settings file before switching: %@", reason))
        case .absent: before = ""; wasAbsent = true
        case .content(let data):
            guard let text = String(data: data, encoding: .utf8) else { return .failed(loc("The Grok settings file as it was before switching is not UTF-8")) }
            before = text
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if wasAbsent { return .unchanged }
            do { try before.write(to: url, atomically: true, encoding: .utf8); return .restored } catch { return .failed(error.localizedDescription) }
        }
        guard let current = (try? Data(contentsOf: url)).flatMap({ String(data: $0, encoding: .utf8) }) else {
            return .failed(loc("Could not read the Grok settings file"))
        }
        let fixed = GrokDefaults.restoring(current: current, from: before)
        if fixed == current { return .unchanged }
        do {
            if wasAbsent, fixed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try FileManager.default.removeItem(at: url)
            } else {
                try fixed.write(to: url, atomically: true, encoding: .utf8)
            }
            return .restored
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func restore(to before: String) -> Outcome { restore(to: .content(Data(before.utf8))) }

    // MARK: Text handling (does not parse all of TOML; handles only the two lines of the `[models]` table)

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
        // A blank line at the end of the table goes after the table, not after the key.
        var trailing: [String] = []
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            trailing.insert(kept.removeLast(), at: 0)
        }
        let body = kept + restored
        var replacement = [lines[range.lowerBound]] + body
        if body.isEmpty && beforeSection == nil {
            // The `[models]` table did not originally exist and is now empty — remove the table header together with one blank line before it.
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

/// Changes this session's model and effort with grok's `/model` command.
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

    // MARK: Waiting for the screen

    private func poll(timeoutMs: Int, _ condition: ([String]) -> Bool) throws -> [String]? {
        let started = DispatchTime.now()
        var simulated = 0
        while true {
            guard let screen = io.freshSnapshot() else { throw SlashCommandError(loc("Stopped: could not read the Grok terminal screen.")) }
            if condition(screen.lines) { return screen.lines }
            let real = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            if max(real, simulated) >= timeoutMs { return nil }
            sleep(Runner.pollMs)
            simulated += Runner.pollMs
        }
    }

    /// If the text we wrote remains in the input box, erase it (other text is left alone).
    private func clear(_ text: String) {
        guard let lines = io.freshSnapshot()?.lines, let now = GrokScreen.draft(lines), !now.isEmpty, text.hasPrefix(now) || now.hasPrefix(text) else { return }
        for _ in 0..<(now.count + 2) {
            try? io.press(.backspace)
            if let lines = io.freshSnapshot()?.lines, GrokScreen.draft(lines)?.isEmpty == true { return }
        }
    }

    // MARK: Switching

    public func apply(_ preset: AgentPreset) throws -> Outcome { try guarded { try applyUnguarded(preset) } }

    /// Leaves the model alone and raises or lowers only the effort by one step.
    public func stepEffort(up: Bool) throws -> Outcome { try guarded { try stepEffortUnguarded(up: up) } }

    /// At whatever step it was thrown — including when the screen could not be read after confirming — restore the new-session default to its pre-switch value, then report the failure.
    /// (Each step's failure handling also restores, but a screen-read failure is thrown straight away without going through that handling.)
    private func guarded(_ body: () throws -> Outcome) throws -> Outcome {
        let before = keepDefaults ? defaults.snapshot() : nil
        // If the pre-switch values could not be read, it cannot restore — stop before sending anything. (A file that "did not exist" is fine: it is removed again at the end.)
        try DefaultsFile.refuseIfUnreadable(before, name: "grok")
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

    /// Starts only in the idle state with an empty input box. On failure it erases only the text we wrote and stops.
    private func applyUnguarded(_ preset: AgentPreset) throws -> Outcome {
        guard let first = io.freshSnapshot() else { throw SlashCommandError(loc("Not switched: could not read the Grok terminal screen.")) }
        guard GrokScreen.box(first.lines) != nil else {
            throw SlashCommandError(loc("Not switched: the Grok input box is not visible. If a picker or a confirmation is showing, deal with that first."))
        }
        if let draft = GrokScreen.draft(first.lines), !draft.isEmpty {
            throw SlashCommandError(loc("Not switched: there is text in the Grok input box. Send or clear it, then press again."))
        }
        guard GrokScreen.idle(first.lines) else {
            throw SlashCommandError(loc("Not switched: Grok is working, or a picker or command list is showing."))
        }

        // Find the preset's model in the list. If there is no list (no cache), send it as written.
        let known = models.resolve(preset.model)
        if !models.models.isEmpty, known == nil {
            throw SlashCommandError(loc("'%@' is not in the Grok model list.", preset.model))
        }
        let id = known?.id ?? preset.model
        var effort: String? = preset.effort
        if let known {
            if known.efforts.isEmpty { effort = nil }
            else if !known.efforts.contains(preset.effort) {
                throw SlashCommandError(loc("Grok %@ does not support effort '%@' (%@).", known.name, preset.effort, known.efforts.joined(separator: ", ")))
            }
        }
        let command = "/model \(id)" + (effort.map { " \($0)" } ?? "")
        let expected = known.map { $0.name + (effort.map { " (\($0))" } ?? "") }
        return try run(command: command, expectedLabel: expected, effort: effort, first: first.lines)
    }

    /// Leaves the model alone and raises or lowers only the effort by one step. The current value is known from the label on the input box border.
    private func stepEffortUnguarded(up: Bool) throws -> Outcome {
        guard let first = io.freshSnapshot(), let box = GrokScreen.box(first.lines) else {
            throw SlashCommandError(loc("Nothing was changed: the Grok input box is not visible."))
        }
        if let draft = GrokScreen.draft(first.lines), !draft.isEmpty {
            throw SlashCommandError(loc("Nothing was changed: there is text in the Grok input box. Send or clear it, then press again."))
        }
        guard GrokScreen.idle(first.lines), let label = box.label else {
            throw SlashCommandError(loc("Nothing was changed: Grok is working, or a picker or command list is showing."))
        }
        let (name, current) = GrokScreen.parse(label: label)
        guard let model = models.model(named: name), !model.efforts.isEmpty, let current, let at = model.efforts.firstIndex(of: current) else {
            throw SlashCommandError(loc("Nothing was changed: the effort levels of the current Grok model (%@) are not known.", label))
        }
        let next = at + (up ? 1 : -1)
        guard model.efforts.indices.contains(next) else {
            var error = SlashCommandError(up ? loc("Already at the highest level (%@).", current) : loc("Already at the lowest level (%@).", current))
            error.nothingToDo = true
            throw error
        }
        return try run(command: "/model \(model.id) \(model.efforts[next])", expectedLabel: "\(model.name) (\(model.efforts[next]))", effort: model.efforts[next], first: first.lines)
    }

    private func run(command: String, expectedLabel: String?, effort: String?, first: [String]) throws -> Outcome {
        let before = keepDefaults ? defaults.snapshot() : nil
        func finish(_ error: SlashCommandError) -> SlashCommandError {
            if let before { sleep(250); _ = defaults.restore(to: before) }
            return error
        }

        try io.type(command)
        // Enter is sent only after confirming the text we wrote is «visible» in the input box.
        guard (try poll(timeoutMs: 1500) { GrokScreen.draft($0) == command }) != nil else {
            clear(command)
            throw finish(SlashCommandError(loc("Nothing was sent: the command did not appear in the Grok input box.")))
        }
        try io.press(.enter)

        func matches(_ label: String?) -> Bool {
            guard let label else { return false }
            if let expectedLabel { return label.lowercased() == expectedLabel.lowercased() }
            guard let effort else { return true }
            return label.lowercased().hasSuffix("(\(effort.lowercased()))")
        }
        // Success: the label becomes the target value and the input box is empty. Failure: grok newly answered «unknown» (lines from earlier attempts are not counted).
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
            throw finish(SlashCommandError(loc("Grok did not accept '%@': %@", command, failure)))
        }
        guard let landed, let label = GrokScreen.box(landed)?.label else {
            clear(command)
            throw finish(SlashCommandError(loc("Stopped: Grok did not respond to '%@'.", command)))
        }

        var warning: String?
        if let before {
            // The file has already been written. Restore it right away, and look once more in case of a late write.
            if case .failed(let reason) = defaults.restore(to: before) { warning = loc("Could not put back the default for new sessions: %@", reason) }
            sleep(250)
            if case .failed(let reason) = defaults.restore(to: before) { warning = loc("Could not put back the default for new sessions: %@", reason) }
        }
        return Outcome(confirmations: ["Using \(label)"], warning: warning)
    }
}
