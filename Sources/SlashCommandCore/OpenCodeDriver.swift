import Foundation

// Switch model and variant (effort) with opencode (1.18.35 · 2.0.25).
//
// Measured 2026-10-07 (in a separately opened test terminal):
// - `/models` opens a «Select model» dialog. Typing filters by «name + provider» (a line like `GLM-5.3-Flash OpenCode Go` leaves one row),
//   and after filtering the top row is selected (the cursor is shown only by color, so «top row» is the basis, not text). `●` marks the current model. Enter picks.
// - `/variants` opens «Select variant» (Default · low · high · max etc., per model). Picking changes the `Build · <model> <provider> · <variant>` line inside the input box.
//   Picking a model with no remembered variant opens the variant dialog automatically.
// - 🔴 Both save the «new-session default» in `~/.local/state/opencode/model.json` as `recent` (the model used last) and `variant` (the variant per model).
//   There is no "this session only", so after switching only those two keys are put back to their values from before.
// - While working, the line below the input box is `esc interrupt`. The input box still looks empty.
//
// Measured 2026-10-11/12 on a test Mac (2.0.25, in a separately opened test session):
// - With two or more providers, filtering is by «name + provider» as before, and the filtered rows have a provider column on the right.
//   With only one provider, filtering is by name alone (`Big Pickle OpenCode Zen` → `No results found`, `Big Pickle` → one row) and rows have no provider column.
//   Even then the current model's row has `●` (`● Big Pickle        Free`).
// - The order of filtered rows is not «most similar first»: typing `GLM-5.3 OpenCode Go` puts `GLM-5.3-Flash` on top and `GLM-5.3` second.
//   Right after filtering the cursor is on the top row and each ↓ moves down one row (choosing the second and third rows 6 times each landed on that row 6 times).
// - The bottom line of the dialog is `Connect an integration ctrl+a  Favorite ctrl+f` (`View all integrations ctrl+a` with one provider).

public enum OpenCodeScreen {
    public struct Row: Equatable, Sendable {
        /// In the form `GLM-5.3-Flash OpenCode Go` (name + provider).
        public let text: String
        public let current: Bool
    }

    static func trimmed(_ screen: [String]) -> [String] {
        var lines = screen.map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    // MARK: input box

    /// The input box = `┃` lines + the `╹▀▀▀` border below them. The bottom four lines (margin · input · margin · `Build · model · variant`) are the box.
    /// When the slash-command list is up, its lines also start with `┃` and attach above.
    static func box(_ screen: [String]) -> (input: String, model: String, popup: Bool, footer: String)? {
        let lines = screen.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let border = lines.lastIndex(where: { $0.hasPrefix("╹▀") }) else { return nil }
        var rows: [String] = []
        var index = border - 1
        while index >= 0, lines[index].hasPrefix("┃") {
            rows.insert(String(lines[index].dropFirst()).trimmingCharacters(in: .whitespaces), at: 0)
            index -= 1
        }
        guard rows.count >= 4, let model = rows.last, model.contains(" · ") else { return nil }
        let input = rows[rows.count - 3]
        let popup = rows.dropLast(4).contains { !$0.isEmpty }
        let footer = lines[(border + 1)...].first { !$0.isEmpty } ?? ""
        return (input, model, popup, footer)
    }

    /// Placeholder of an empty input box: `Ask anything… "Fix broken tests"`. The example inside the quotes differs by version and each time it appears
    /// (measured 2026-10-11, 2.0.25: `"Fix a TODO in the codebase"`), so match by shape.
    static func isPlaceholder(_ input: String) -> Bool {
        input.range(of: #"^Ask anything… ".*"$"#, options: .regularExpression) != nil
    }

    /// (title, column where the title starts) from a dialog's header line. The header looks like `Select model        esc`, and during a conversation the conversation text overlaps on its left
    /// (measured 2026-10-07), so look for `Select …  esc` «inside» the line, not at its start.
    static func dialogHeader(_ line: String) -> (title: String, column: Int)? {
        guard let start = line.range(of: "Select ") ?? line.range(of: "Commands") else { return nil }
        let tail = line[start.lowerBound...].trimmingCharacters(in: .whitespaces)
        guard tail.hasSuffix("esc"), tail.range(of: #"^(Select [A-Za-z ]+?|Commands)\s{2,}esc$"#, options: .regularExpression) != nil else { return nil }
        let title = String(tail.dropLast(3)).trimmingCharacters(in: .whitespaces)
        return (title, line.distance(from: line.startIndex, to: start.lowerBound))
    }

    /// The «No variants available» notice (shown instead of a dialog when `/variants` is typed on a model with no variants; 2.0.25).
    /// To tell it from the same text in the conversation, the notice box's border (`┃ … ┃`) is checked too.
    static func noVariants(_ screen: [String]) -> Bool {
        screen.contains { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.hasPrefix("┃") && text.hasSuffix("┃") && text.contains("No variants available")
        }
    }

    /// Whether the model dialog, the variant dialog or the command palette is up.
    static func dialogTitle(_ screen: [String]) -> String? {
        screen.lazy.compactMap { dialogHeader($0)?.title }.first
    }

    public static func idle(_ screen: [String]) -> Bool {
        guard dialogTitle(screen) == nil, let box = box(screen), !box.popup else { return false }
        guard box.input.isEmpty || isPlaceholder(box.input) else { return false }
        return !isBusy(footer: box.footer)
    }

    /// While working, the line below the box is `⬝■■■■■■⬝  esc interrupt`. In a narrow window the hint on the right is cut off, so match the shape «progress bar + esc», not the whole text.
    static func isBusy(footer: String) -> Bool {
        footer.contains("interrupt") || footer.range(of: #"^[⬝■▪\s]+esc\b"#, options: .regularExpression) != nil
    }

    public static func draft(_ screen: [String]) -> String? {
        guard let box = box(screen) else { return nil }
        return isPlaceholder(box.input) ? "" : box.input
    }

    /// (model, variant) from the model line of the input box (`Build · GLM-5.3-Flash OpenCode Go · high`).
    public static func status(_ screen: [String]) -> (model: String, variant: String?)? {
        guard let line = box(screen)?.model else { return nil }
        // A branch name is attached at the right end of the line (`… · high          yohangwak/agents`); anything after a gap of two or more columns is dropped.
        let parts = line.components(separatedBy: " · ").map { ($0.components(separatedBy: "  ").first ?? $0).trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        return (parts[1], parts.count >= 3 ? parts[2] : nil)
    }

    // MARK: dialog

    /// The search field text and rows of the open dialog (`Select model` · `Select variant`). The dialog floats in the center, so the input box's `┃` overlaps on its left;
    /// read only from the header's column to the right.
    public static func dialog(_ screen: [String]) -> (title: String, search: String, rows: [Row])? {
        guard let titleIndex = screen.firstIndex(where: { dialogHeader($0).map { $0.title.hasPrefix("Select ") } == true }),
              let header = dialogHeader(screen[titleIndex]) else { return nil }
        let column = header.column - 2
        func cut(_ line: String) -> String {
            let chars = Array(line)
            guard chars.count > column, column >= 0 else { return "" }
            return String(chars[column...]).trimmingCharacters(in: .whitespaces)
        }
        let title = header.title
        // During a conversation there are blank lines (margins) between the header, the search field and the rows: the first non-blank line is the search field, and from the next non-blank line up to a blank line are the rows.
        var index = titleIndex + 1
        func nextNonBlank() -> String? {
            while index < screen.count {
                let text = cut(screen[index])
                index += 1
                if !text.isEmpty { return text }
            }
            return nil
        }
        guard let search = nextNonBlank() else { return nil }
        var rows: [Row] = []
        if var text = nextNonBlank() {
            // If nothing is filtered, a single `No results found` line takes the place of the rows. The hint line at the bottom is not a row either.
            while !isDialogFooter(text), text != "No results found" {
                var current = false
                if text.hasPrefix("●") { current = true; text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
                rows.append(Row(text: normalizeRow(text), current: current))
                guard index < screen.count else { break }
                let following = cut(screen[index])
                index += 1
                if following.isEmpty { break }
                text = following
            }
        }
        return (title, search, rows)
    }

    /// The hint line at the bottom of the dialog: `Connect provider …` (1.x) · `Connect an integration ctrl+a  Favorite ctrl+f` · `View all integrations ctrl+a` (2.x).
    static func isDialogFooter(_ text: String) -> Bool {
        text.hasPrefix("Connect provider") || text.hasPrefix("Connect an integration") || text.hasPrefix("View all integrations")
    }

    /// `GLM-5.3-Flash (Favorite)        OpenCode Go` → `GLM-5.3-Flash OpenCode Go`.
    static func normalizeRow(_ text: String) -> String {
        var parts = text.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let first = parts.first, first.hasSuffix("(Favorite)") { parts[0] = String(first.dropLast("(Favorite)".count)).trimmingCharacters(in: .whitespaces) }
        // The value column at the far right (`Free`, `$0.50`) is not part of the model's name; it does not appear on the input box's model line either.
        // (Measured 2026-10-08: in the unfiltered list a free model's row has a separate `Free` column on the right. A Free «inside» a name is separated by a single space, so it does not split off.)
        if parts.count >= 2, let last = parts.last, last == "Free" || last.range(of: #"^\$\d"#, options: .regularExpression) != nil { parts.removeLast() }
        return parts.joined(separator: " ")
    }

    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

/// The two keys `recent` and `variant` of `~/.local/state/opencode/model.json`.
public struct OpenCodeDefaults: Sendable {
    public let url: URL

    public init(url: URL = OpenCodeDefaults.defaultURL) { self.url = url }

    /// opencode keeps its state in `$XDG_STATE_HOME/opencode/` (`~/.local/state` if unset).
    public static var defaultURL: URL { url(stateHome: nil, environment: ProcessInfo.processInfo.environment) }

    static func url(stateHome: String?, environment: [String: String]) -> URL {
        let home = stateHome ?? environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state").path
        return URL(fileURLWithPath: home).appendingPathComponent("opencode/model.json")
    }

    /// The state folders used by running opencode processes (distinct ones only). If `orcaHandle` is given, narrows to the processes of that Orca terminal.
    /// Looks at the environment of «that session», not Slash Command's own: for a session started with XDG_STATE_HOME changed in the shell, the defaults file is there too.
    static func stateHomes(processes: [(arguments: [String], environment: [String])], orcaHandle: String?) -> [String] {
        var candidates = processes.filter { AgentProcesses.agent(forCommandLine: $0.arguments.joined(separator: " ")) == .opencode }
        if let orcaHandle {
            let narrowed = candidates.filter { $0.environment.contains("ORCA_TERMINAL_HANDLE=\(orcaHandle)") }
            if !narrowed.isEmpty { candidates = narrowed }
        }
        func value(_ name: String, in environment: [String]) -> String? {
            environment.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let homes = candidates.map { process -> String in
            if let state = value("XDG_STATE_HOME", in: process.environment) { return state }
            let home = value("HOME", in: process.environment) ?? FileManager.default.homeDirectoryForCurrentUser.path
            return home + "/.local/state"
        }
        return Array(Set(homes)).sorted()
    }

    /// The defaults file of that session. If the sessions use different state folders and we cannot narrow it down, throw, so we never claim to have «protected» the wrong file.
    static func resolve(processes: [(arguments: [String], environment: [String])], orcaHandle: String?,
                        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> OpenCodeDefaults {
        // If `orcaHandle` is given but that terminal has no opencode process, do not substitute another session's.
        if let orcaHandle, !processes.contains(where: { $0.environment.contains("ORCA_TERMINAL_HANDLE=\(orcaHandle)") && AgentProcesses.agent(forCommandLine: $0.arguments.joined(separator: " ")) == .opencode }) {
            throw SlashCommandError(loc("Not switched: the OpenCode process of this Orca terminal was not found, so there is no telling which state folder's default for new sessions to protect."))
        }
        let homes = stateHomes(processes: processes, orcaHandle: orcaHandle)
        switch homes.count {
        case 0:
            // The session's process was not found: nothing says our environment's folder is that session's folder. Stop rather than claim to have «protected» the wrong file.
            throw SlashCommandError(loc("Not switched: the process of the OpenCode session was not found, so there is no telling which state folder's default for new sessions to protect."))
        case 1: return OpenCodeDefaults(url: url(stateHome: homes[0], environment: environment))
        default:
            throw SlashCommandError(loc("Not switched: the OpenCode sessions use different state folders (XDG_STATE_HOME), so there is no telling whose default for new sessions to protect (%@).", homes.joined(separator: ", ")))
        }
    }

    static let keys = ["recent", "variant"]

    public func snapshot() -> DefaultsSnapshot { DefaultsFile.snapshot(url) }

    public enum Outcome: Equatable, Sendable {
        case unchanged
        case restored
        case failed(String)
    }

    /// Puts only the model-related keys back to their pre-switch values (`DefaultsFile.restoreJSON`). If the file did not exist before the switch, those keys are removed, and if nothing is left the file is removed too.
    public func restore(to snapshot: DefaultsSnapshot) -> Outcome {
        switch DefaultsFile.restoreJSON(url: url, keys: OpenCodeDefaults.keys, to: snapshot, pretty: false, name: "opencode") {
        case .unchanged: return .unchanged
        case .restored: return .restored
        case .failed(let reason): return .failed(reason)
        }
    }

    public func restore(to before: Data) -> Outcome { restore(to: .content(before)) }
}

public struct OpenCodeDriver {
    public let io: TerminalIO
    public let sleep: (Int) -> Void
    public let defaults: OpenCodeDefaults
    public let keepDefaults: Bool

    public init(io: TerminalIO, sleep: @escaping (Int) -> Void, defaults: OpenCodeDefaults = OpenCodeDefaults(), keepDefaults: Bool) {
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
            guard let screen = io.freshSnapshot() else { throw SlashCommandError(io.lastFailure ?? loc("Stopped: could not read the OpenCode terminal screen.")) }
            if condition(screen.lines) { return screen.lines }
            let real = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            if max(real, simulated) >= timeoutMs { return nil }
            sleep(Runner.pollMs)
            simulated += Runner.pollMs
        }
    }

    /// Closes open dialogs with Esc (at most 3 times) and erases text we wrote in the input box if any is left.
    private func back(clearing leftover: String? = nil) {
        guard io.lastFailure == nil else { return }
        for _ in 0..<3 {
            guard let lines = io.freshSnapshot()?.lines, OpenCodeScreen.dialogTitle(lines) != nil else { break }
            try? io.press(.escape)
            _ = try? poll(timeoutMs: 800) { OpenCodeScreen.dialogTitle($0) == nil }
        }
        guard let leftover, let lines = io.freshSnapshot()?.lines, let now = OpenCodeScreen.draft(lines), !now.isEmpty, leftover.hasPrefix(now) else { return }
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
        try DefaultsFile.refuseIfUnreadable(before, name: "opencode")
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
        let currentModel = OpenCodeScreen.status(io.freshSnapshot()?.lines ?? [])?.model
        // One space between words, so that the character count matches when erasing words from the text typed in the search field.
        let model = preset.model.split(separator: " ").joined(separator: " ")
        if currentModel.map({ OpenCodeScreen.key($0) }) != OpenCodeScreen.key(model) {
            try pickModel(model, current: currentModel, failure: fail)
        }
        let variant = preset.effort.trimmingCharacters(in: .whitespaces)
        var note: String?
        if !variant.isEmpty {
            // A model with no variants (Big Pickle etc.) is matched by model only; before, it changed the model and still reported failure with «the dialog did not open».
            if try !pickVariant(variant, failure: fail) {
                note = loc("This OpenCode model has no variants, so the effort (%@) was not set.", variant)
            }
        } else if OpenCodeScreen.dialogTitle(io.freshSnapshot()?.lines ?? []) == "Select variant" {
            back()   // A preset that sets no variant: close the automatically opened dialog as is
        }
        let outcome = try finish(before: before, model: model, failure: fail)
        let warnings = [note, outcome.warning].compactMap { $0 }
        return Outcome(confirmations: outcome.confirmations, warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
    }

    /// Leaves the model alone and moves only variant up or down by one step. The steps are in the order of the `/variants` dialog (Default · low · high · max…).
    private func stepEffortUnguarded(up: Bool) throws -> Outcome {
        try start()
        let before = keepDefaults ? defaults.snapshot() : nil
        func fail(_ message: String, leftover: String? = nil) -> SlashCommandError {
            back(clearing: leftover)
            if let before { sleep(250); _ = defaults.restore(to: before) }
            return SlashCommandError(message)
        }
        // Current value: the `●` in the dialog if there is one. A model with no saved variant runs as Default yet has no `●` on any row
        // (measured 2026-10-08: DeepSeek V4 Pro); then the input box's model line is the basis (the row of the variant written there, or the Default row if none).
        let shown = OpenCodeScreen.status(io.freshSnapshot()?.lines ?? [])?.variant
        guard try openVariants(failure: fail) else {
            if let before { sleep(250); _ = defaults.restore(to: before) }
            var error = SlashCommandError(loc("This OpenCode model has no effort levels (it has no variants)."))
            error.nothingToDo = true
            if let reason = io.lastFailure { throw SlashCommandError(reason) }
            throw error
        }
        guard let dialog = OpenCodeScreen.dialog(io.freshSnapshot()?.lines ?? []),
              let at = dialog.rows.firstIndex(where: \.current)
                ?? dialog.rows.firstIndex(where: { OpenCodeScreen.key($0.text) == OpenCodeScreen.key(shown ?? "Default") }) else {
            throw fail(loc("Nothing was changed: could not read the current value in the OpenCode variant dialog."))
        }
        let next = at + (up ? 1 : -1)
        guard dialog.rows.indices.contains(next) else {
            var error = fail(up ? loc("Already at the highest level (%@).", dialog.rows[at].text) : loc("Already at the lowest level (%@).", dialog.rows[at].text))
            error.nothingToDo = true
            if let reason = io.lastFailure { throw SlashCommandError(reason) }
            throw error
        }
        try chooseInOpenDialog(text: dialog.rows[next].text, failure: fail)
        return try finish(before: before, model: nil, failure: fail)
    }

    // MARK: steps

    private func start() throws {
        guard let first = io.freshSnapshot() else { throw SlashCommandError(io.lastFailure ?? loc("Not switched: could not read the OpenCode terminal screen.")) }
        guard OpenCodeScreen.idle(first.lines) else {
            if let draft = OpenCodeScreen.draft(first.lines), !draft.isEmpty {
                throw SlashCommandError(loc("Not switched: there is text in the OpenCode input box. Send or clear it, then press again."))
            }
            throw SlashCommandError(loc("Not switched: the OpenCode input box is not visible, or it is working."))
        }
    }

    private func openDialog(command: String, title: String, failure: (String, String?) -> SlashCommandError) throws {
        try io.type(command)
        guard (try poll(timeoutMs: 1500) { OpenCodeScreen.draft($0) == command }) != nil else {
            throw failure(loc("Nothing was sent: the command did not appear in the OpenCode input box."), command)
        }
        try io.press(.enter)
        guard (try poll(timeoutMs: 3000) { OpenCodeScreen.dialog($0)?.title == title }) != nil else {
            throw failure(loc("The OpenCode '%@' dialog did not open.", title), command)
        }
    }

    /// Opens «Select variant» with `/variants`. If the model has no variants, opencode shows a notice («No variants available») instead of a dialog
    /// and returns to the input box (2.0.25, measured 2026-10-12); then false.
    private func openVariants(failure: (String, String?) -> SlashCommandError) throws -> Bool {
        let command = "/variants"
        try io.type(command)
        guard (try poll(timeoutMs: 1500) { OpenCodeScreen.draft($0) == command }) != nil else {
            throw failure(loc("Nothing was sent: the command did not appear in the OpenCode input box."), command)
        }
        // The notice stays for a few seconds. If it was already up before Enter (left over from another model earlier), it is not the reply to this command; then wait only for the dialog.
        let stale = OpenCodeScreen.noVariants(io.freshSnapshot()?.lines ?? [])
        try io.press(.enter)
        func opened(_ lines: [String]) -> Bool { OpenCodeScreen.dialog(lines)?.title == "Select variant" }
        if stale { return try poll(timeoutMs: 1500, opened) != nil }
        guard let lines = try poll(timeoutMs: 3000, { opened($0) || OpenCodeScreen.noVariants($0) }) else {
            throw failure(loc("The OpenCode '%@' dialog did not open.", "Select variant"), command)
        }
        return opened(lines)
    }

    typealias Dialog = (title: String, search: String, rows: [OpenCodeScreen.Row])

    /// The dialog when the search field text has become `text` and the rows read the same twice in a row. The filtered rows can change later than the text.
    private func settled(search text: String) throws -> Dialog? {
        var last: [OpenCodeScreen.Row]?
        let lines = try poll(timeoutMs: 2000) { lines in
            guard let dialog = OpenCodeScreen.dialog(lines), dialog.search.lowercased() == text.lowercased() else { last = nil; return false }
            defer { last = dialog.rows }
            return last == dialog.rows
        }
        return lines.flatMap { OpenCodeScreen.dialog($0) }
    }

    /// Moves down to the filtered row that is «equal» to `text` and picks it with Enter. The cursor is not visible as text: right after filtering it is on the top row
    /// and each ↓ moves down one row (measured). Similar names often come first (`GLM-5.3-Flash` above `GLM-5.3`), so looking only at the top row is not enough.
    /// The caller checks what was picked with the input box's model line.
    private func choose(row text: String, in dialog: Dialog, failure: (String, String?) -> SlashCommandError) throws {
        guard let at = dialog.rows.firstIndex(where: { OpenCodeScreen.key($0.text) == OpenCodeScreen.key(text) }) else {
            let top = dialog.rows.first?.text ?? loc("no rows")
            throw failure(loc("Not chosen: the OpenCode dialog has no row '%@' (top row: %@).", text, top), nil)
        }
        if at > 0 {
            for _ in 0..<at { try io.press(.down) }
            // If the rows changed while moving down, the counted number of steps does not point at that row.
            guard let now = OpenCodeScreen.dialog(io.freshSnapshot()?.lines ?? []), now.rows == dialog.rows else {
                throw failure(loc("The OpenCode dialog was not filtered to '%@'.", text), nil)
            }
        }
        try io.press(.enter)
    }

    /// Types `text` in the open dialog to filter it, then picks the row equal to that text.
    private func chooseInOpenDialog(text: String, failure: (String, String?) -> SlashCommandError) throws {
        try io.type(text)
        guard let dialog = try settled(search: text) else {
            throw failure(loc("The OpenCode dialog was not filtered to '%@'.", text), nil)
        }
        try choose(row: text, in: dialog, failure: failure)
    }

    /// Erases `count` characters of the search field. Sent in one go; depending on the terminal a single write takes tens of ms.
    private func erase(_ count: Int) throws {
        if count > 0 { try io.type(String(repeating: Key.backspace.bytes, count: count)) }
    }

    /// In the dialog of opencode 2 with a single provider (filtered by name only, rows have no provider column), finds out «what the provider is» from the dialog itself.
    /// Starting from the current model line (`Exo Free OpenCode Zen`), remove trailing words one at a time and filter; if a row with the `●` (current model) mark equal to the remaining text appears,
    /// the remaining text is the model name and the removed words are the provider. That the ends of the text merely happen to match is not taken as the provider
    /// (the `Free OpenCode Zen` of `Big Pickle Free OpenCode Zen` equals the end of `Exo Free OpenCode Zen` but is not a provider; PR #24 review).
    /// `typed` is the text currently in the search field. The search field is empty on return.
    private func soleProvider(current: String, typed: String, failure: (String, String?) -> SlashCommandError) throws -> [String]? {
        try erase(typed.count)
        try io.type(current)
        guard try settled(search: current) != nil else {
            throw failure(loc("The OpenCode dialog was not filtered to '%@'.", current), nil)
        }
        var words = current.split(separator: " ").map(String.init)
        var provider: [String] = []
        while words.count > 1 {
            let word = words.removeLast()
            provider.insert(word, at: 0)
            try erase(word.count + 1)
            let name = words.joined(separator: " ")
            guard let dialog = try settled(search: name) else {
                throw failure(loc("The OpenCode dialog was not filtered to '%@'.", name), nil)
            }
            if dialog.rows.contains(where: { $0.current && OpenCodeScreen.key($0.text) == OpenCodeScreen.key(name) }) {
                try erase(name.count)
                return provider
            }
        }
        try erase(words.joined(separator: " ").count)
        return nil
    }

    private func pickModel(_ model: String, current: String?, failure: (String, String?) -> SlashCommandError) throws {
        try openDialog(command: "/models", title: "Select model", failure: failure)
        try io.type(model)
        guard var dialog = try settled(search: model) else {
            throw failure(loc("The OpenCode dialog was not filtered to '%@'.", model), nil)
        }
        var row = model
        // Nothing is filtered: it may be a dialog with a single provider, filtered by name only. After confirming the provider, if the preset belongs to that provider, filter again by name.
        if dialog.rows.isEmpty, let current, let provider = try soleProvider(current: current, typed: model, failure: failure) {
            let words = model.split(separator: " ").map(String.init)
            let ending = words.suffix(provider.count)
            guard words.count > provider.count, zip(ending, provider).allSatisfy({ OpenCodeScreen.key($0) == OpenCodeScreen.key($1) }) else {
                throw failure(loc("Not chosen: the OpenCode dialog has no row '%@' (top row: %@).", model, loc("no rows")), nil)
            }
            row = words.dropLast(provider.count).joined(separator: " ")
            try io.type(row)
            guard let named = try settled(search: row) else {
                throw failure(loc("The OpenCode dialog was not filtered to '%@'.", row), nil)
            }
            dialog = named
        }
        try choose(row: row, in: dialog, failure: failure)
        // A model with no remembered variant is followed by the variant dialog; wait until it settles (the next step handles it).
        guard (try poll(timeoutMs: 3000) { lines in
            if OpenCodeScreen.dialogTitle(lines) == "Select variant" { return true }
            return OpenCodeScreen.dialogTitle(lines) == nil && OpenCodeScreen.status(lines).map { OpenCodeScreen.key($0.model) == OpenCodeScreen.key(model) } == true
        }) != nil else {
            throw failure(loc("The OpenCode model line did not change to '%@'.", model), nil)
        }
    }

    /// False if the model has no variants and nothing could be picked.
    private func pickVariant(_ variant: String, failure: (String, String?) -> SlashCommandError) throws -> Bool {
        let screen = io.freshSnapshot()?.lines ?? []
        // If the variant dialog is already up automatically after picking the model, use it; otherwise check whether it is already that value and open it only when needed.
        if OpenCodeScreen.dialogTitle(screen) != "Select variant" {
            if OpenCodeScreen.status(screen)?.variant.map({ OpenCodeScreen.key($0) }) == OpenCodeScreen.key(variant) { return true }
            guard try openVariants(failure: failure) else { return false }
        }
        guard let dialog = OpenCodeScreen.dialog(io.freshSnapshot()?.lines ?? []) else { throw failure(loc("Could not read the OpenCode variant dialog."), nil) }
        guard let wanted = dialog.rows.first(where: { OpenCodeScreen.key($0.text) == OpenCodeScreen.key(variant) }) else {
            throw failure(loc("This OpenCode model has no variant '%@' (%@).", variant, dialog.rows.map(\.text).joined(separator: ", ")), nil)
        }
        if wanted.current { try io.press(.escape); return true }
        try chooseInOpenDialog(text: wanted.text, failure: failure)
        return true
    }

    /// If `model` is given, success only when the input box's model line is that model: rows in the dialog were picked by «counting», so the result is checked in text.
    private func finish(before: DefaultsSnapshot?, model: String?, failure: (String, String?) -> SlashCommandError) throws -> Outcome {
        guard let lines = try poll(timeoutMs: 4000, { OpenCodeScreen.idle($0) }), let status = OpenCodeScreen.status(lines) else {
            throw failure(loc("Stopped: the OpenCode input box did not come back."), nil)
        }
        if let model, OpenCodeScreen.key(status.model) != OpenCodeScreen.key(model) {
            throw failure(loc("The OpenCode model line did not change to '%@'.", model), nil)
        }
        var warning: String?
        if let before {
            if case .failed(let reason) = defaults.restore(to: before) { warning = loc("Could not put back the default for new sessions: %@", reason) }
            sleep(250)
            if case .failed(let reason) = defaults.restore(to: before) { warning = loc("Could not put back the default for new sessions: %@", reason) }
        }
        return Outcome(confirmations: ["Using \(status.model)" + (status.variant.map { " · \($0)" } ?? "")], warning: warning)
    }
}
