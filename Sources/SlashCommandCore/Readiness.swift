import Foundation

/// Before sending keys, confirm that the agent's input box is on screen.
///
/// When a permission prompt, approval dialog or picker is up, typing text and Enter presses that dialog's default choice (usually "Yes").
/// So the condition is "the input box is visible", not "no dialog is visible"; if it is not visible, nothing is sent.
public enum Readiness {
    public static func inputVisible(agent: Agent, screen: [String]) -> Bool {
        switch agent {
        case .claude: return claudePromptVisible(screen)
        case .codex: return codexComposerVisible(screen)
        case .grok: return GrokScreen.idle(screen)
        case .cursor: return CursorScreen.idle(screen)
        case .antigravity: return AgyScreen.idle(screen)
        case .opencode: return OpenCodeScreen.idle(screen)
        }
    }

    /// Claude's input box starts with `❯` directly below a horizontal rule.
    /// The selection marker of a permission prompt (` ❯ 1. Yes`) is indented and the line above it is not a rule.
    ///
    /// The input box sits at the bottom of the screen: below it there are only (continuation lines of a multi-line draft,) the closing rule and a few status lines.
    /// A similar-looking shape higher up the screen is not treated as the input box.
    static func claudePromptVisible(_ screen: [String]) -> Bool {
        let lines = screen.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let at = lines.indices.last(where: { $0 > 0 && lines[$0].hasPrefix("❯") && lines[$0 - 1].hasPrefix("─") }) else {
            return false
        }
        let below = lines[(at + 1)...]
        if let closing = below.firstIndex(where: { $0.hasPrefix("─") }) {
            // Up to the closing rule there are only continuation (indented) lines of the draft; below it are a few status lines.
            return lines[(at + 1)..<closing].allSatisfy { $0.hasPrefix(" ") } && lines.count - closing - 1 <= 5
        }
        return below.count <= 6
    }

    /// Codex's input box starts with `›` (`»` when effort is ultra, measured on 0.160.0).
    /// Approval dialogs and pickers also mark the selected row with `›`, but with a number, as in `› 1. …`.
    ///
    /// The input box is at the bottom of the screen: the «last» line starting with `›` must be the input box (earlier conversation also keeps `› text I sent`),
    /// and below it there may be only indented lines (continuation lines of a multi-line draft, status lines).
    static func codexComposerVisible(_ screen: [String]) -> Bool {
        let lines = screen.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let at = lines.indices.last(where: { lines[$0].hasPrefix("›") || lines[$0].hasPrefix("»") }) else { return false }
        guard !isNumberedChoice(lines[at]) else { return false }
        let below = lines[(at + 1)...]
        return below.allSatisfy { $0.hasPrefix(" ") } && below.count <= 12
    }

    private static func isNumberedChoice(_ line: String) -> Bool {
        let rest = line.dropFirst().drop(while: { $0 == " " })
        let digits = rest.prefix(while: \.isNumber)
        return !digits.isEmpty && rest.dropFirst(digits.count).hasPrefix(".")
    }
}

public enum ClaudeScreen {
    /// Results of commands starting with `prefix` on screen (top to bottom).
    ///
    /// When idle, claude shows the result as a conversation line (`  ⎿  Set model to …`); while working, as a right-aligned notice line
    /// directly above the input box (`        Set model to …`) (measured on 2.1.289). Both are read.
    public static func results(_ lines: [String], prefix: String) -> [String] {
        lines.compactMap { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("⎿") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return text.hasPrefix(prefix) ? text : nil
        }
    }

    /// The text shown in the input box (first line). nil if there is no input box, empty string if it is empty.
    /// Used to check whether the text that was being typed came back, in terminals (Ghostty) that do not give the draft separately.
    public static func promptText(_ lines: [String]) -> String? {
        let shown = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for (index, line) in shown.enumerated() where line.hasPrefix("❯") && index > 0 && shown[index - 1].hasPrefix("─") {
            return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The value to switch to, taken from the confirmation dialog claude shows before changing model or effort in a conversation it has just answered. nil if that dialog is not showing.
    ///
    ///     Switch model?                         ("Change effort level?" for effort)
    ///     Your next response will be slower and use more tokens
    ///     This conversation is cached for the current model. Switching to Sonnet 5.5 means …
    ///     ❯ 1. Yes, switch to Sonnet 5.5        ("Yes, switch to high" for effort)
    ///       2. No, go back
    ///
    /// Returns the value only when the cursor (`❯`) is on the "Yes" item, because this decides whether pressing Enter is safe.
    public static func switchPrompt(_ lines: [String]) -> String? {
        let headers = ["Switch model?", "Change effort level?"]
        guard let header = lines.lastIndex(where: { headers.contains($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        let marker = "❯ 1. Yes, switch to "
        for line in lines[(header + 1)...] {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix(marker) { return String(text.dropFirst(marker.count)) }
        }
        return nil
    }

    /// The reply (`⎿ …`) attached directly below the last command typed (`❯ /model …`). When idle, a command's result stays in this form.
    /// If `command` is given ("/model"), returns the reply only when it belongs to that command, so a previous command's reply is not read as this one's.
    public static func commandReply(_ lines: [String], command: String? = nil) -> String? {
        let shown = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for index in shown.indices.reversed() where index > 0 {
            let text = shown[index].trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("⎿") else { continue }
            guard shown[index - 1].hasPrefix("❯ " + (command ?? "/")) else { return nil }
            return String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The result of the command that just finished: either the notice line directly above the input box (while working), or the reply below the last such command typed (`❯ /model`).
    ///
    /// Do not pick out "new lines" by counting lines: when a picker opens and closes, the range of conversation visible on screen changes,
    /// so old lines can look new (measured 2026-10-06: an old "Kept model as …" was read as this result and the notice was wrong).
    /// If the reply wraps to the next line in a narrow window, the pieces are joined.
    public static func latestResult(_ lines: [String], command: String, prefixes: [String]) -> String? {
        let shown = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let prompt = shown.indices.last(where: { $0 > 0 && shown[$0].hasPrefix("❯") && shown[$0 - 1].hasPrefix("─") }) else { return nil }
        let rule = prompt - 1
        // While working: one right-aligned notice line above the input box.
        if rule > 0 {
            let notice = shown[rule - 1].trimmingCharacters(in: .whitespaces)
            if prefixes.contains(where: { notice.hasPrefix($0) }) { return notice }
        }
        // When idle: `❯ command` in the conversation with `⎿ reply` below it.
        guard let echo = shown[..<rule].lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "❯ " + command }),
              echo + 1 < rule else { return nil }
        let first = shown[echo + 1].trimmingCharacters(in: .whitespaces)
        guard first.hasPrefix("⎿") else { return nil }
        var text = String(first.dropFirst()).trimmingCharacters(in: .whitespaces)
        var index = echo + 2
        // A wrapped line starts in the same column as the reply text (indented 5 columns). A more deeply indented line is a different right-aligned display.
        while index < rule, shown[index].prefix(while: { $0 == " " }).count == 5 {
            text += " " + shown[index].trimmingCharacters(in: .whitespaces)
            index += 1
        }
        return text
    }

    /// The reply attached directly below the command line we typed (`❯ /model sonnet`). nil if that command is not on screen.
    public static func reply(toCommand commandLine: String, in lines: [String]) -> String? {
        let shown = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for index in shown.indices.reversed() where index + 1 < shown.count {
            guard shown[index].trimmingCharacters(in: .whitespaces) == "❯ " + commandLine else { continue }
            let next = shown[index + 1].trimmingCharacters(in: .whitespaces)
            guard next.hasPrefix("⎿") else { return nil }
            return String(next.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

}

/// Reads the `/model` pickers of claude and codex from the screen.
///
/// Both are numbered row lists with a marker before the row that has the cursor (codex `›`, claude `❯`).
/// So we can read "which row the cursor is on", move only that far, then read again to confirm.
public enum Picker {
    public struct Row: Equatable, Sendable {
        public let number: Int
        /// Row name ("High", "More reasoning…", "Opus 5.5"). The `(current)`, `(default)` and `✔` marks are stripped.
        public let label: String
        /// The cursor is on this row.
        public let selected: Bool
        /// Marked as the value currently in use (codex `(current)`, claude `✔`).
        public let current: Bool
    }

    /// The header of the picker we opened. Approval dialogs also use numbered rows, so only a screen with this header counts as a picker.
    static let headers = ["Select Model and Effort", "Select Reasoning Level", "Advanced Reasoning",  // codex
                          "Select model"]                                                           // claude

    /// Phrases that appear only on the picker's bottom line (the hint). Only phrases that do not overlap with an approval dialog's hint ("esc to cancel") are kept.
    static let footerMarks = ["s to use this session only", "Enter to set as default",              // claude
                              "esc back"]                                                         // codex

    /// A picker whose «bottom hint line is cut off» because the window is short: the header (`Select model`) is near the end of the screen and below it there is a row with the cursor, but no hint line
    /// (measured 2026-10-12: claude in an 11-line tmux pane; only the header, two description lines, the cursor row, `… +9 models` and the effort line are drawn).
    public static func clipped(_ lines: [String], header: String) -> Bool {
        guard open(lines) == nil else { return false }
        let shown = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let at = shown.suffix(12).lastIndex(where: { $0 == header }) else { return false }
        return shown[(at + 1)...].contains { row($0)?.selected == true }
    }

    /// The picker open at the «bottom» of the screen.
    public struct Open: Equatable, Sendable {
        /// Text from the header line down to just above the rows (including the description sentence). In a narrow pane the header wraps, so the pieces are joined; compare by its beginning.
        public let header: String
        public let rows: [Row]
        /// The hint on the bottom line (joined if it wraps to two lines in a narrow window).
        public let footer: String
    }

    /// The picker is drawn at the bottom of the screen: only when the bottom line is a picker hint, walk upward from there to find the rows and the header.
    /// Text in the conversation that looks like a picker is not at the bottom, even if it exists (measured 2026-10-06: we almost read its rows and sent arrow keys).
    /// In a narrow window a row's description wraps to a deeply indented next line; such lines are skipped.
    public static func open(_ lines: [String]) -> Open? {
        let shown = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // Hint line: must be within the last three lines (it takes two or three lines when wrapped).
        guard let footerAt = shown.indices.suffix(3).last(where: { index in footerMarks.contains { shown[index].contains($0) } }) else {
            return nil
        }
        let footerStart = shown.indices.suffix(3).first(where: { index in footerMarks.contains { shown[index].contains($0) } }) ?? footerAt
        let footer = shown[footerStart...].map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")

        var index = footerStart - 1
        // Between the rows and the hint: effort line · warning · "… +2 models" · wrapped line of the last row.
        var skipped = 0
        while index >= 0, row(shown[index]) == nil, skipped < 8 { index -= 1; skipped += 1 }
        var rows: [Row] = []
        while index >= 0 {
            if let found = row(shown[index]) {
                rows.insert(found, at: 0)
            } else if !isContinuation(shown[index]) {
                break
            }
            index -= 1
        }
        guard !rows.isEmpty else { return nil }
        // Between the header and the rows: description sentence (several lines if narrow) · codex's warning line.
        let above = index
        skipped = 0
        while index >= 0, skipped < 6 {
            let text = shown[index].trimmingCharacters(in: .whitespaces)
            if headers.contains(where: { text.hasPrefix($0) }) {
                // At 38 columns codex's header wraps into two (`Select Reasoning Level for` / `GPT-6-Astra`; measured in a split pane of iTerm2 on 2026-10-12).
                let whole = shown[index...above].map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                return Open(header: whole, rows: rows, footer: footer)
            }
            index -= 1
            skipped += 1
        }
        return nil
    }

    /// Wrapped line: a deeply indented line without a number (a row's description that overflowed).
    static func isContinuation(_ line: String) -> Bool {
        line.prefix(while: { $0 == " " }).count >= 8
    }

    public static func isOpen(_ lines: [String]) -> Bool {
        open(lines) != nil
    }

    /// Whether the picker has rows folded out of view: a `… +9 models` line, a row starting with `↓` or `↑` that signals more,
    /// or the first visible row's number is not 1 (in a short window, when the cursor is on the bottom row there is no separate marker that the top is folded; measured 2026-10-11).
    public static func hasHiddenRows(_ lines: [String]) -> Bool {
        guard let open = open(lines) else { return false }
        if let first = open.rows.first, first.number > 1 { return true }
        return lines.contains { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.range(of: #"^… \+\d+ "#, options: .regularExpression) != nil { return true }
            return (text.hasPrefix("↓") || text.hasPrefix("↑")) && row(line) != nil
        }
    }

    /// The numbered rows of the bottom picker. An empty array if there is no picker.
    public static func rows(_ lines: [String]) -> [Row] {
        open(lines)?.rows ?? []
    }

    /// codex: `› 3. High (current)   description` · `  4. Extra high       description`
    /// claude: `   ❯ 2.  Opus 5.5 ✔     description` · `     3.  Fable 5.1   description` · `   ↓ 10. Opus 4.7   description` (more below)
    static func row(_ line: String) -> Row? {
        var rest = Substring(line).drop(while: { $0 == " " })
        var selected = false
        if let first = rest.first, first == "›" || first == "❯" {
            selected = true
            rest = rest.dropFirst()
        } else if let first = rest.first, first == "↓" || first == "↑" {
            rest = rest.dropFirst()
        }
        rest = rest.drop(while: { $0 == " " })
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, let number = Int(digits), rest.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        var label = String(rest.dropFirst(digits.count + 1).drop(while: { $0 == " " }))
        if let gap = label.range(of: "  ") { label = String(label[..<gap.lowerBound]) }
        let current = label.contains("(current)") || label.contains("✔")
        for mark in [" (current)", " (default)", " ✔"] {
            label = label.replacingOccurrences(of: mark, with: "")
        }
        label = label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return Row(number: number, label: label, selected: selected, current: current)
    }

    /// The row matching `wanted`. A row with exactly that name comes first; otherwise the first row starting with that word
    /// ("opus" → the top "Opus 5.5", "More reasoning" → "More reasoning…"). The boundary is checked so "High" does not match "Extra high" and "Opus 5" does not match "Opus 5.5".
    public static func index(of wanted: String, in rows: [Row]) -> Int? {
        let wanted = wanted.lowercased()
        if let exact = rows.firstIndex(where: { $0.label.lowercased() == wanted }) { return exact }
        return rows.firstIndex { row in
            let label = row.label.lowercased()
            guard label.hasPrefix(wanted), let next = label.dropFirst(wanted.count).first else { return false }
            return !next.isLetter && !next.isNumber && next != "."
        }
    }

    // MARK: the effort line of the claude picker

    /// `● High effort ←/→ to adjust` → "high". nil if there is no effort line or the model does not support it.
    public static func claudeEffort(_ lines: [String]) -> String? {
        for line in lines.reversed() where line.contains("to adjust") {
            let words = line.split(separator: " ")
            if let index = words.firstIndex(of: "effort"), index > 0 { return words[index - 1].lowercased() }
        }
        return nil
    }

    /// The order in which the claude picker cycles through efforts (wraps from the end to the start; measured on 2.1.289).
    public static let claudeEffortOrder = ["low", "medium", "high", "xhigh", "max"]

    /// `○ Effort not supported for Haiku 4.5`
    public static func claudeEffortUnsupported(_ lines: [String]) -> Bool {
        lines.contains { $0.contains("Effort not supported") }
    }
}

/// Converts a claude preset's model value into a picker row name.
public enum ClaudeModels {
    /// "opus" → "opus" (the top Opus row) · "claude-opus-5-5" → "opus 5.5" · "Opus 5.5" → "opus 5.5".
    public static func rowLabel(_ model: String) -> String {
        var text = model.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("claude-") { text = String(text.dropFirst("claude-".count)) }
        guard text.contains("-"), !text.contains(" ") else { return text }
        // The date tail (-20251001) is not in the row name.
        let parts = text.split(separator: "-").map(String.init).filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        guard let family = parts.first else { return text }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(family) : "\(family) \(version)"
    }
}
