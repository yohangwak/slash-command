import Foundation

public enum Key: Equatable, Sendable {
    case enter
    case escape
    case up
    case down
    case left
    case right
    case backspace
    case tab
    case ctrl(Character)
    #if os(Windows)
    case home, end, pageUp, pageDown
    #endif

    /// The bytes written to the pty as-is.
    public var bytes: String {
        switch self {
        case .enter: return "\r"
        case .escape: return "\u{1B}"
        case .up: return "\u{1B}[A"
        case .down: return "\u{1B}[B"
        case .right: return "\u{1B}[C"
        case .left: return "\u{1B}[D"
        case .backspace: return "\u{7F}"
        case .tab: return "\t"
        case .ctrl(let c):
            let value = (c.asciiValue ?? 0x40) & 0x1F
            return String(UnicodeScalar(value))
        #if os(Windows)
        case .home: return "\u{1B}[H"
        case .end: return "\u{1B}[F"
        case .pageUp: return "\u{1B}[5~"
        case .pageDown: return "\u{1B}[6~"
        #endif
        }
    }
}

public enum Step: Equatable, Sendable {
    case text(String)
    case key(Key)
    case wait(ms: Int)
    /// Confirms that `needle` is «present» on screen. If it does not appear in time, runs `abort` and stops with `failure`.
    /// If `bottom` is given, it must be within that many last lines of the screen, since the same text may appear in the conversation.
    case expect(needle: String, bottom: Int? = nil, timeoutMs: Int, abort: [Step], failure: String)
    /// Confirms that our picker is «open» at the bottom of the screen: the header starts with `header` and the hint line contains `footer` (only the ones given are checked).
    case expectPicker(header: String?, footer: String?, timeoutMs: Int, abort: [Step], failure: String)
    /// Takes a baseline from the state just before a command is sent (the screen, the modification time of claude's defaults file).
    /// Used to tell whether the later `expectResult` and `capture` belong to «this command».
    case arm
    /// Confirms that a result line starting with `prefix` exists and the input box is «visible» again.
    /// If the same phrase was already in the baseline, it is accepted only when that line is «new» or the defaults file «changed». If there was text being typed, it also checks that it «came back»
    /// so that the next Ctrl+S does not overlap with the restore.
    /// If `command` ("/model") is given and a different reply appears directly below that command (e.g. Model 'x' not found), it finishes with that reply instead of waiting.
    case expectResult(prefix: String, command: String? = nil, acceptSwitchTo: [String] = [], timeoutMs: Int, failure: String)
    /// In the codex picker, «puts» the cursor on the `label` row. Reads which row the cursor (`›`) is on, moves only that far, then reads again to confirm.
    /// If that row does not exist and a `via` row does (e.g. More reasoning…), enters that sub-list and looks there.
    case selectRow(label: String, via: String?, timeoutMs: Int, abort: [Step], failure: String)
    /// Presses → once at a time and re-reads each time, until the effort line of the claude picker «becomes» `level` (it wraps from the end to the start).
    /// Skipped if the model does not support effort.
    case setEffort(level: String, timeoutMs: Int, abort: [Step], failure: String)
    /// Confirms that the cursor of the claude picker is on the row of "the model in use" (`✔`), so that changing only effort does not change the model too.
    case expectCurrentRow(abort: [Step], failure: String)
    /// Raises or lowers the effort of the claude picker by one step. If it is already at the end, changes nothing and reports that.
    case stepEffort(up: Bool, timeoutMs: Int, abort: [Step])
    /// In the codex effort list, puts the cursor on the row directly above or below the current value (`(current)`). Max and Ultra are under More reasoning….
    case stepRow(up: Bool, timeoutMs: Int, abort: [Step])
    /// Confirms that the picker has closed and that agent's input box is «visible» again. For claude, also checks that the text being typed came back.
    ///
    /// When model or effort is changed in a conversation claude has just answered, it shows a confirmation dialog ("Switch model?" · "Change effort level?"
    /// — a notice that the conversation history will be re-read). By default nothing is sent to that dialog and the user decides.
    /// If `acceptSwitchTo` is set (when turned on in settings), it is accepted with Enter only when the dialog asks to switch to «one of these values» and the cursor is on Yes.
    /// `Step.steppedEffort` means "the step that `stepEffort` just moved to".
    case expectInput(agent: Agent, acceptSwitchTo: [String] = [], fresh: Bool = false, timeoutMs: Int, abort: [Step], failure: String)

    public static let steppedEffort = "{stepped-effort}"
    /// Closes with Esc only «while the picker is visible». If there is no picker, nothing is sent: Esc on a working codex interrupts the work.
    case closePicker
    /// Records the result phrase of the switch that just finished (skipped if there is none).
    /// If `afterCommand` is given (claude), looks in the reply below that command or the notice line above the input box; otherwise (codex), in the last such line on screen.
    case capture(prefixes: [String], afterCommand: String? = nil)
}

public enum Launch {
    /// The command an agent whose `--model` takes an id, not a screen name, runs to find out «name → id». Its output is passed to `resolve`.
    /// (Measured 2026-10-11: `agy models` prints lines of `id<space>name (Effort)`, `opencode models --verbose` prints a `provider/id` line followed by that model's JSON,
    /// `cursor-agent models` prints lines of `id - name [context] [Effort] [Fast]`.)
    public static func listing(agent: Agent) -> [String]? {
        switch agent {
        case .antigravity: return ["agy", "models"]
        case .opencode: return ["opencode", "models", "--verbose"]
        case .cursor: return ["cursor-agent", "models"]
        case .claude, .codex, .grok: return nil
        }
    }

    /// Agents that also save the model given as a launch option as the «new-session default»; the default must be restored after launching.
    /// (Measured 2026-10-11, cursor-agent 2026.10.01: launching with `--model grok-4.7-high` makes that model the default model in `cli-config.json`.
    /// agy left its defaults file unchanged even when launched with `--model`.)
    public static func savesLaunchModelAsDefault(agent: Agent) -> Bool { agent == .cursor }

    /// Whether opencode's help lists the launch option `--model`. 2.0.25 does not have it (only the `run` subcommand does); 1.18.35 did.
    public static func openCodeTakesModel(help: String) -> Bool {
        // Look only in the «options» part before the subcommand list: the same text in a subcommand's description is not a launch option.
        let options = help.components(separatedBy: "SUBCOMMANDS").first ?? help
        return options.range(of: #"(^|\s)--model\b"#, options: .regularExpression) != nil
    }

    /// The terminal this process runs in (known from environment variables); used to continue the switch «in that terminal» after a session is opened.
    /// Looks from the innermost: inside a tmux pane, that pane is it, whatever the outer terminal is. Ghostty has no environment variable that points to the terminal, so nil here.
    public static func currentTerminal(environment: [String: String]) -> TerminalHost? {
        func value(_ name: String) -> String? { environment[name].flatMap { $0.isEmpty ? nil : $0 } }
        // TMUX = `<socket path>,<server pid>,<session>`.
        if let tmux = value("TMUX"), let pane = value("TMUX_PANE"), let socket = tmux.split(separator: ",").first, socket.hasPrefix("/") {
            return .tmux(socket: String(socket), pane: pane)
        }
        if let handle = value("ORCA_TERMINAL_HANDLE") { return .orca(handle: handle) }
        // ITERM_SESSION_ID = `w0t1p0:<session unique id>`.
        if let session = value("ITERM_SESSION_ID"), let id = session.split(separator: ":").last, session.contains(":"), !id.isEmpty {
            return .iterm(sessionID: String(id))
        }
        if let pane = value("WEZTERM_PANE") { return .wezterm(socket: value("WEZTERM_UNIX_SOCKET"), pane: pane) }
        if let window = value("KITTY_WINDOW_ID"), let socket = value("KITTY_LISTEN_ON") { return .kitty(socket: socket, window: window) }
        return nil
    }

    /// That terminal as the target argument of the command line (the form `explicitTarget` reads).
    public static func targetArguments(host: TerminalHost, agent: Agent) -> [String] {
        let named = ["--agent", agent.rawValue]
        switch host {
        case .ghostty(let id): return ["--ghostty", id] + named
        case .orca(let handle): return ["--orca", handle] + named
        case .tmux(let socket, let pane): return ["--tmux", pane] + (socket.map { ["--tmux-socket", $0] } ?? []) + named
        case .kitty(let socket, let window): return ["--kitty", window, "--kitty-socket", socket] + named
        case .wezterm(let socket, let pane): return ["--wezterm", pane] + (socket.map { ["--wezterm-socket", $0] } ?? []) + named
        case .iterm(let id): return ["--iterm", id] + named
        #if os(Windows)
        case .windowsConsole(let pid, _): return ["--console", String(pid)] + named
        #endif
        }
    }

    public struct Resolved: Equatable, Sendable {
        /// The value to pass to `--model`.
        public let model: String
        /// A notice when not everything could be matched as is (e.g. opencode has no launch option for the variant).
        public let note: String?
    }

    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The table of «provider names» opencode shows on screen (provider id → name).
    /// The name on screen is not the id: `opencode` shows as «OpenCode Zen» and `google-vertex` as «Vertex» (confirmed 2026-10-11).
    /// Read from two places: `cache`: opencode's model cache (`models.json`, a copy of models.dev; top level is provider id → `name`),
    /// `config`: the «applied configuration» that `opencode debug config` prints (for a provider added by hand the name is in `provider.<id>.name`). The configuration wins over the cache.
    /// Only names are taken; values (keys, addresses and so on) are not read.
    public static func openCodeProviderNames(cache: Data?, config: Data? = nil) -> [String: String] {
        var names: [String: String] = [:]
        func take(_ providers: Any?) {
            guard let providers = providers as? [String: Any] else { return }
            for (id, value) in providers {
                if let name = (value as? [String: Any])?["name"] as? String, !name.isEmpty { names[id] = name }
            }
        }
        if let cache { take(try? JSONSerialization.jsonObject(with: cache)) }
        if let config { take(((try? JSONSerialization.jsonObject(with: config)) as? [String: Any])?["provider"]) }
        return names
    }

    /// The location of that cache file (follows `XDG_CACHE_HOME`).
    public static var openCodeModelsCache: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return base.appendingPathComponent("opencode/models.json")
    }

    /// Finds the model id for the preset's screen name (and effort) in the output of the `listing` command.
    /// `providerNames` is opencode's provider name table; without it, matching uses only the provider id (only providers whose name equals the id resolve).
    public static func resolve(agent: Agent, preset: AgentPreset, listing output: String, providerNames: [String: String] = [:]) throws -> Resolved {
        switch agent {
        case .antigravity:
            // `gemini-3.8-flash-high   Gemini 3.8 Flash (High)`: the effort is part of the id.
            var rows: [(id: String, name: String, effort: String?)] = []
            for line in output.split(separator: "\n") {
                let parts = line.split(maxSplits: 1, whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
                guard parts.count == 2, !parts[0].contains(".."), parts[0].contains("-") else { continue }
                var name = parts[1].trimmingCharacters(in: .whitespaces)
                var effort: String?
                if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
                    effort = String(name[name.index(after: open)..<name.index(before: name.endIndex)]).lowercased()
                    name = name[..<open].trimmingCharacters(in: .whitespaces)
                }
                rows.append((parts[0], name, effort))
            }
            let named = rows.filter { key($0.name) == key(preset.model) }
            guard !named.isEmpty else { throw SlashCommandError(loc("'%@' is not in the Antigravity model list.", preset.model)) }
            if let row = named.first(where: { $0.effort == preset.effort.lowercased() }) ?? (named.count == 1 && named[0].effort == nil ? named[0] : nil) {
                return Resolved(model: row.id, note: nil)
            }
            let available = named.compactMap(\.effort).joined(separator: ", ")
            throw SlashCommandError(loc("Antigravity '%@' has no effort '%@' (%@).", preset.model, preset.effort, available))
        case .opencode:
            // `opencode-go/glm-5.3-flash` line followed by that model's JSON (`name`, `providerID`, `variants`).
            // The preset's name is the «model name + provider» shown on screen (`GLM-5.3-Flash OpenCode Go`).
            var rows: [(id: String, name: String, provider: String, variants: [String])] = []
            let lines = output.components(separatedBy: "\n")
            var index = 0
            while index < lines.count {
                let id = lines[index]
                index += 1
                guard id.contains("/"), !id.contains(" "), index < lines.count, lines[index] == "{" else { continue }
                var body: [String] = []
                while index < lines.count {
                    body.append(lines[index])
                    index += 1
                    if body.last == "}" { break }
                }
                guard let object = (try? JSONSerialization.jsonObject(with: Data(body.joined(separator: "\n").utf8))) as? [String: Any],
                      let name = object["name"] as? String else { continue }
                let provider = (object["providerID"] as? String) ?? String(id.split(separator: "/")[0])
                rows.append((id, name, provider, ((object["variants"] as? [String: Any]) ?? [:]).keys.sorted()))
            }
            let wanted = key(preset.model)
            // The provider is shown on screen by «name». A provider not in the name table (for example one added by hand) is matched by id.
            var found = rows.filter { row in
                [providerNames[row.provider], row.provider].compactMap { $0 }.contains { key(row.name) + key($0) == wanted }
            }
            if found.isEmpty {
                // A name without a provider is accepted only when exactly one model has that name.
                let byName = rows.filter { key($0.name) == wanted }
                if byName.count == 1 { found = byName }
            }
            guard let row = found.first else { throw SlashCommandError(loc("'%@' is not in the OpenCode model list.", preset.model)) }
            // opencode reloads the variant the model used last; `--model` alone cannot set the variant.
            // This holds even if the preset is Default (if it was last used with high, it opens with high), so the note is always given.
            let note = loc("OpenCode has no option to set the variant when it opens: it opens with this model and whichever variant the model used last. Use the shortcut afterwards to set '%@'.", preset.effort)
            return Resolved(model: row.id, note: note)
        case .cursor:
            let rows = cursorRows(listing: output)
            let named = rows.filter { key($0.name) == key(preset.model) }
            guard !named.isEmpty else { throw SlashCommandError(loc("'%@' is not in the Cursor model list.", preset.model)) }
            // There are separate entries with Thinking on and off for the same name and effort; pick the one without a mark (the model's default state) first.
            func pick(_ candidates: [CursorRow]) -> CursorRow? { candidates.first { !$0.marked } ?? candidates.first }
            if let row = pick(named.filter { row in row.effort.map { CursorScreen.effortMatches(preset.effort, label: $0) } ?? false }) {
                return Resolved(model: row.id, note: nil)
            }
            // A model with no effort at all (`Auto` · `Composer 2.5`) is matched by model only.
            if named.allSatisfy({ $0.effort == nil }), let row = pick(named) { return Resolved(model: row.id, note: nil) }
            var available: [String] = []
            for effort in named.compactMap(\.effort) where !available.contains(effort) { available.append(effort) }
            throw SlashCommandError(loc("Cursor '%@' has no effort '%@' (%@).", preset.model, preset.effort, available.joined(separator: ", ")))
        case .claude, .codex, .grok:
            return Resolved(model: preset.model, note: nil)
        }
    }

    struct CursorRow: Equatable {
        let id: String
        let name: String
        /// The screen label (`Extra High`), or, for a line without a label, the value read from the end of the id (`xhigh`).
        let effort: String?
        /// A line with `Thinking` or `No Thinking` after the name; this is the side that is not the model's default state.
        let marked: Bool
    }

    /// Lines of `cursor-agent models`: `grok-4.7-high - Grok 4.7  High` · `claude-opus-5-5-medium - Claude Opus 5.5 1M` · `auto - Auto (default)`.
    /// After the name come the context (`1M`) · effort · `Thinking`/`No Thinking` · `Fast` · a tag (`(NO ZDR)`).
    /// A line without an effort label means the model's «default» effort, which differs per model (`claude-opus-5-5-medium` is Medium, `claude-opus-5-high` is High) —
    /// so without a label it is read from the end of the id. `Fast` lines are dropped: presets have no such switch.
    static func cursorRows(listing output: String) -> [CursorRow] {
        let labels: [[String]] = [["Extra", "High"], ["High"], ["Medium"], ["Low"], ["Max"], ["None"], ["Minimal"]]
        var rows: [CursorRow] = []
        for line in output.split(separator: "\n") {
            guard let cut = line.range(of: " - ") else { continue }
            let id = line[..<cut.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !id.contains(" ") else { continue }
            // Zero-width characters may be attached at the end of a line (after `Fast`) and words may be separated by two spaces.
            var text = String(String.UnicodeScalarView(line[cut.upperBound...].unicodeScalars.filter { !(0x200B...0x200D).contains($0.value) && $0.value != 0xFEFF }))
            while let tag = text.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) { text.removeSubrange(tag) }
            var words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if words.last == "Fast" { continue }
            var marked = false
            if words.last == "Thinking" {
                marked = true
                words.removeLast()
                if words.last == "No" { words.removeLast() }
            }
            var effort: String?
            for label in labels where words.count > label.count && Array(words.suffix(label.count)) == label {
                effort = label.joined(separator: " ")
                words.removeLast(label.count)
                break
            }
            if let last = words.last, words.count > 1, last.range(of: #"^\d+[KkMm]$"#, options: .regularExpression) != nil { words.removeLast() }
            guard !words.isEmpty else { continue }
            rows.append(CursorRow(id: id, name: words.joined(separator: " "), effort: effort ?? cursorEffort(inID: id), marked: marked))
        }
        return rows
    }

    /// The effort at the end of the id: `claude-opus-5-thinking-high` → `high`, `gpt-5.5-extra-high` → `xhigh`, `gpt-5.3-codex` → none.
    static func cursorEffort(inID id: String) -> String? {
        let parts = id.lowercased().split(separator: "-").map(String.init).filter { $0 != "fast" && $0 != "thinking" }
        guard let last = parts.last, parts.count > 1 else { return nil }
        if last == "high", parts.count > 2, parts[parts.count - 2] == "extra" { return "xhigh" }
        return ["low", "medium", "high", "xhigh", "max", "none", "minimal"].contains(last) ? last : nil
    }

    /// The command line that opens a «new session» with that preset. Both options apply only to this session, so the defaults do not change.
    /// `model` is the id that `resolve` produced (antigravity · opencode · cursor). cursor also saves a model opened with `--model` as the default — `savesLaunchModelAsDefault`.
    public static func command(agent: Agent, preset: AgentPreset, model: String? = nil, extra: [String] = []) -> [String] {
        switch agent {
        case .claude:
            return ["claude", "--model", preset.model, "--effort", preset.effort] + extra
        case .codex:
            return ["codex", "-m", preset.model, "-c", "model_reasoning_effort=\"\(preset.effort)\""] + extra
        case .grok:
            return ["grok", "-m", preset.model, "--reasoning-effort", preset.effort] + extra
        case .antigravity, .opencode, .cursor:
            // `--model` takes an id, not a screen name; pass it only when there is an id resolved by `resolve` (passing the screen name as is would be a wrong value).
            return [agent.executable] + (model.map { ["--model", $0] } ?? []) + extra
        }
    }
}

public enum Plans {
    /// claude: sets the model row and effort in the `/model` picker and confirms.
    ///
    /// The picker has a "this session only" (`s`) confirm (measured on 2.1.289: the defaults file does not change). `/model X` and `/effort Y`
    /// also change the new-session default and so would have to be undone, but this approach does not touch the defaults at all.
    /// If `saveAsDefault` is true, confirms with Enter, which also saves it as the default.
    public static func claudePicker(modelLabel: String, effort: String, saveAsDefault: Bool, acceptSwitch: Bool = false) -> [Step] {
        let footer = "s to use this session only"
        return [
            // Ctrl+S stashes the text being typed and opens the picker. When the picker closes (confirm or Esc), claude puts the text back.
            .text("\u{13}/model\r"),
            // If this fails we do not know what is on screen, so no more keys are sent.
            .expectPicker(header: "Select model", footer: footer, timeoutMs: 3000, abort: [],
                          failure: loc("The Claude Code model picker did not open.")),
            .selectRow(label: modelLabel, via: nil, timeoutMs: 2000, abort: [.closePicker],
                       failure: loc("The Claude Code model picker has no '%@' row.", modelLabel)),
            .setEffort(level: effort, timeoutMs: 2500, abort: [.closePicker],
                       failure: loc("Could not set effort to '%@' in the Claude Code model picker.", effort)),
            .expectPicker(header: "Select model", footer: footer, timeoutMs: 1000, abort: [.closePicker],
                          failure: loc("Not switched: the Claude Code model picker has no \"this session only\" (s) choice.")),
            .arm,
            .text(saveAsDefault ? "\r" : "s"),
            .expectInput(agent: .claude, acceptSwitchTo: acceptSwitch ? [modelLabel, effort] : [], timeoutMs: 3000, abort: [.closePicker],
                         failure: loc("Stopped: the Claude Code input box did not come back.")),
            .capture(prefixes: ["Set model to", "Kept model as"], afterCommand: "/model"),
        ]
    }

    /// codex: leaves the model alone and moves only effort by one step.
    ///
    /// The current value is known from the `(current)` mark in the picker. The status line below the input box also shows the value, but right after switching to max or ultra
    /// it shows the old value for a while (measured on 0.160.0), so pressing in quick succession goes to a wrong step.
    public static func codexEffortStep(up: Bool) -> [Step] {
        let restoreDraft: [Step] = [.text("\u{19}\u{7F}")]
        let leave: [Step] = [.closePicker] + restoreDraft
        return [
            .text("\u{05} \u{01}\u{0B}/model"),
            .expect(needle: "choose what model and reasoning effort", bottom: 5,
                    timeoutMs: 2500,
                    abort: [.text(String(repeating: "\u{7F}", count: 6))] + restoreDraft,
                    failure: loc("Nothing was changed: there is a multi-line draft in the Codex input box. Send or clear it, then press again.")),
            .key(.enter),
            .expectPicker(header: "Select Model and Effort", footer: nil, timeoutMs: 4000, abort: leave,
                          failure: loc("The Codex model picker did not open.")),
            // The cursor of the model list starts at the current model. Enter only when that row is right.
            .expectCurrentRow(abort: leave, failure: loc("Nothing was changed: the Codex model picker's cursor is not on the current model.")),
            .key(.enter),
            .expectPicker(header: "Select Reasoning Level", footer: nil, timeoutMs: 4000, abort: leave,
                          failure: loc("The Codex effort list did not open.")),
            .stepRow(up: up, timeoutMs: 3000, abort: leave),
            .expectPicker(header: nil, footer: "s session", timeoutMs: 1000, abort: leave,
                          failure: loc("Nothing was changed: the Codex picker has no \"this session only\" (s) choice.")),
            .arm,
            .text("s"),
            .expectInput(agent: .codex, timeoutMs: 3000, abort: [.closePicker],
                         failure: loc("Stopped: the Codex input box did not come back. If you had text there, Ctrl+Y brings it back.")),
            .capture(prefixes: ["Model changed to"]),
        ] + restoreDraft
    }

    /// claude: leaves the model alone and moves only effort by one step. One → or ← in the same picker.
    public static func claudeEffortStep(up: Bool, saveAsDefault: Bool, acceptSwitch: Bool = false) -> [Step] {
        let footer = "s to use this session only"
        return [
            .text("\u{13}/model\r"),
            .expectPicker(header: "Select model", footer: footer, timeoutMs: 3000, abort: [],
                          failure: loc("The Claude Code model picker did not open.")),
            .expectCurrentRow(abort: [.closePicker],
                              failure: loc("Effort alone cannot be changed: the current model is not in the picker list. Use /effort instead.")),
            .stepEffort(up: up, timeoutMs: 2500, abort: [.closePicker]),
            .expectPicker(header: "Select model", footer: footer, timeoutMs: 1000, abort: [.closePicker],
                          failure: loc("Nothing was changed: the Claude Code model picker has no \"this session only\" (s) choice.")),
            .arm,
            .text(saveAsDefault ? "\r" : "s"),
            .expectInput(agent: .claude, acceptSwitchTo: acceptSwitch ? [Step.steppedEffort] : [], timeoutMs: 3000, abort: [.closePicker],
                         failure: loc("Stopped: the Claude Code input box did not come back.")),
            .capture(prefixes: ["Set model to", "Kept model as"], afterCommand: "/model"),
        ]
    }

    /// claude: stashes the text being typed (Ctrl+S) and runs `/model` and `/effort` one after the other (an alternative when the picker cannot be read).
    /// When a command finishes, claude puts the stashed text back, so it is stashed again before the second command.
    public static func claude(_ preset: AgentPreset, acceptSwitch: Bool = false) -> [Step] {
        [
            // Ctrl+S, the command and Enter are written in one go (measured 2026-10-06: even as one chunk the text is stashed and restored and the command runs).
            // Instead of a fixed wait, confirms the result line is «visible» and moves on; the response comes within 0.2 seconds.
            .arm,
            .text("\u{13}/model \(preset.model)\r"),
            .expectResult(prefix: "Set model to", command: "/model", acceptSwitchTo: acceptSwitch ? [ClaudeModels.rowLabel(preset.model)] : [], timeoutMs: 3000,
                          failure: loc("Claude Code did not respond to /model %@.", preset.model)),
            .expectInput(agent: .claude, acceptSwitchTo: acceptSwitch ? [ClaudeModels.rowLabel(preset.model)] : [], fresh: true, timeoutMs: 3000, abort: [],
                         failure: loc("Stopped: the Claude Code input box did not come back.")),
            .arm,
            .text("\u{13}/effort \(preset.effort)\r"),
            .expectResult(prefix: "Set effort level", command: "/effort", acceptSwitchTo: acceptSwitch ? [preset.effort] : [], timeoutMs: 3000,
                          failure: loc("Claude Code did not respond to /effort %@.", preset.effort)),
        ]
    }

    /// codex: operates the `/model` picker with keys. Confirms with `s` so it applies to this session only (the defaults are not touched).
    ///
    /// Where the cursor starts in the effort list varies (the current effort if it is the current model, otherwise that model's default).
    /// So the cursor row is read from the screen and moved only to the target row. Choosing with a number key also saves the default, so it is not used.
    public static func codex(modelIndex: Int, displayName: String?, effortLabel: String) -> [Step] {
        let restoreDraft: [Step] = [.text("\u{19}\u{7F}")]   // Ctrl+Y, Backspace
        let leave: [Step] = [.closePicker] + restoreDraft
        return [
            // Move the one line being typed into the kill buffer (Ctrl+E, space, Ctrl+A, Ctrl+K).
            // With a space attached, Ctrl+Y does not pull out old content even from an empty input box.
            .text("\u{05} \u{01}\u{0B}/model"),
            .expect(needle: "choose what model and reasoning effort", bottom: 5,
                    timeoutMs: 2500,
                    abort: [.text(String(repeating: "\u{7F}", count: 6))] + restoreDraft,
                    failure: loc("Not switched: there is a multi-line draft in the Codex input box. Send or clear it, then press again.")),
            .key(.enter),
            .expectPicker(header: "Select Model and Effort", footer: nil, timeoutMs: 4000, abort: leave,
                          failure: loc("The Codex model picker did not open.")),
            .text(String(modelIndex)),
            // The model name appears in the header; this also checks that the number key chose the intended model.
            .expectPicker(header: "Select Reasoning Level" + (displayName.map { " for \($0)" } ?? ""), footer: nil,
                          timeoutMs: 4000, abort: leave,
                          failure: loc("The Codex effort list did not open (a different model may have been selected).")),
            .selectRow(label: effortLabel, via: "More reasoning",
                       timeoutMs: 3000,
                       abort: leave,
                       failure: loc("Could not choose the '%@' row in the Codex effort list.", effortLabel)),
            .expectPicker(header: nil, footer: "s session", timeoutMs: 1000, abort: leave,
                          failure: loc("Not switched: the Codex picker has no \"this session only\" (s) choice.")),
            .arm,
            .text("s"),
            // If this fails we do not know what is on screen: close it if it is a picker, but do not send the key that restores the text being typed.
            .expectInput(agent: .codex, timeoutMs: 3000, abort: [.closePicker],
                            failure: loc("Stopped: the Codex input box did not come back. If you had text there, Ctrl+Y brings it back.")),
            .capture(prefixes: ["Model changed to"]),
        ] + restoreDraft
    }
}
