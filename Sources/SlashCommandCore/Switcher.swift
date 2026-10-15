import Foundation

public struct SwitchResult: Equatable, Sendable {
    public let target: Target
    public let slotName: String
    public let preset: AgentPreset
    /// The reason the default could not be put back. The switch itself succeeded.
    public let warning: String?
    /// The result the agent showed on screen (e.g. "Set model to Sonnet 5.5"): a confirmation that it changed, not just that we sent it.
    public let confirmations: [String]
    /// The pre-switch file content, when a late write of the default must be checked once more (`Switcher.verifyRestore`).
    public let pendingRestore: Data?

    /// The notification title. Uses the name the agent showed on screen if there is one ("Opus 5.5 · high"), otherwise the preset's values ("opus · high").
    public var summary: String {
        var model: String?
        var effort: String?
        var effortKnown = true
        for line in confirmations {
            if line.hasPrefix("Effort not supported") { effortKnown = false; continue }
            // The notice line shown while working arrives cut to the width ("… Opus 5.5 and"); strip the tail wherever it was cut.
            let text = line.trimmingCharacters(in: .whitespaces) + " "
            func head(_ text: Substring, cuts: [String]) -> String {
                var out = String(text)
                for cut in cuts { if let range = out.range(of: cut) { out = String(out[..<range.lowerBound]) } }
                return out.trimmingCharacters(in: .whitespaces)
            }
            if text.hasPrefix("Set model to ") {
                // "Set model to Opus 5.5 for this session only with xhigh effort" (picker)
                // "Set model to Opus 5.5 and saved as your default for new sessions" (command)
                let rest = text.dropFirst("Set model to ".count)
                model = head(rest, cuts: [" for this session", " and ", " with ", " ("])
                // If effort is unchanged, claude does not mention effort; then the value set in the picker (the preset) is right.
                if let with = rest.range(of: " with "), let end = rest[with.upperBound...].range(of: " effort") {
                    effort = String(rest[with.upperBound..<end.lowerBound])
                }
            } else if text.hasPrefix("Kept model as ") {
                // Both the model and the effort were already those values.
                model = head(text.dropFirst("Kept model as ".count), cuts: [" with ", " ("])
            } else if text.hasPrefix("Set effort level to ") {
                effort = head(text.dropFirst("Set effort level to ".count), cuts: [" (", ":"])
                effortKnown = true
            } else if text.hasPrefix("Using ") {
                // grok: "Using Grok 4.7 (xhigh)" · cursor: "Using Grok 4.7 256K Medium"
                let label = String(text.dropFirst("Using ".count)).trimmingCharacters(in: .whitespaces)
                // opencode: "Using GLM-5.3-Flash OpenCode Go · high"
                let dotted = label.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
                let (name, level) = dotted.count == 2 ? (dotted[0], Optional(dotted[1]))
                    : dotted.count == 1 && !label.contains(" · ") && label.hasSuffix(")") ? GrokScreen.parse(label: label)
                    : CursorScreen.parse(status: label)
                model = name
                effort = level
                if level == nil { effortKnown = false }
            } else if text.hasPrefix("Model set to "), text.contains("("), !text.contains(" for this session"), !text.contains(" and saved") {
                // antigravity: "Model set to Gemini 3.7 Flash (Medium)"
                let rest = String(text.dropFirst("Model set to ".count)).trimmingCharacters(in: .whitespaces)
                if let open = rest.lastIndex(of: "("), rest.hasSuffix(")") {
                    model = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
                    effort = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
                }
            } else if text.hasPrefix("Model changed to ") {
                // codex: "Model changed to gpt-6.1-sol high for this session only"
                let words = head(text.dropFirst("Model changed to ".count), cuts: [" for this session"]).split(separator: " ")
                if words.count == 2 { model = String(words[0]); effort = String(words[1]) }
            }
        }
        let name = nonEmpty(model) ?? preset.model
        guard effortKnown else { return name }
        return "\(name) · \(nonEmpty(effort) ?? preset.effort)"
    }

    /// Whether the agent confirmed the result on screen (`summary` is a confirmed value, not the value we sent).
    public var confirmed: Bool { !confirmations.isEmpty }

    private func nonEmpty(_ text: String?) -> String? {
        text.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Collects the time of each step (`slashcommand apply --trace`, app log). Meant to avoid asserting a cause before measuring.
public final class Trace: @unchecked Sendable {
    public private(set) var events: [(label: String, ms: Int)] = []
    private let start = DispatchTime.now()
    private var last = DispatchTime.now()

    public init() {}

    /// Records the time elapsed since the previous record under `label`.
    public func mark(_ label: String) {
        let now = DispatchTime.now()
        events.append((label, Int((now.uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000)))
        last = now
    }

    public var totalMs: Int { Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000) }

    public var report: String {
        events.map { "\($0.label) \($0.ms)ms" }.joined(separator: " · ") + " · total \(totalMs)ms"
    }
}

/// A wrapper that times each terminal call.
struct TracingIO: TerminalIO {
    let base: TerminalIO
    let trace: Trace

    func type(_ text: String) throws { try base.type(text); trace.mark("type") }
    func press(_ key: Key) throws { try base.press(key); trace.mark("key(\(key))") }
    func screen() -> [String]? { let r = base.screen(); trace.mark("read"); return r }
    func draft() -> String? { let r = base.draft(); trace.mark("read draft"); return r }
    func snapshot() -> ScreenSnapshot? { let r = base.snapshot(); trace.mark("read"); return r }
    var screenLagMs: Int { base.screenLagMs }
    func freshSnapshot() -> ScreenSnapshot? { let r = base.freshSnapshot(); trace.mark("fresh read"); return r }
}

public struct Switcher {
    public var trace: Trace?
    /// Called when claude is asking "Switch model?" and we decided not to answer (the argument is the model name).
    /// After that, it waits until the user chooses and then finishes the rest.
    public var onAwaitingUser: ((String) -> Void)?
    public var config: SlashCommandConfig
    public var claudeDefaults: ClaudeDefaults
    public var codexModels: () throws -> CodexModels
    public var grokModels: () -> GrokModels
    public var grokDefaults: GrokDefaults
    public var cursorDefaults: CursorDefaults
    public var antigravityDefaults: AntigravityDefaults
    /// If nil (the default), finds the state folder «that session uses» each time it switches (`OpenCodeDefaults.resolve`).
    public var opencodeDefaults: OpenCodeDefaults?
    public var makeIO: (Target) throws -> TerminalIO
    public var sleep: (Int) -> Void

    public init(config: SlashCommandConfig,
                claudeDefaults: ClaudeDefaults = ClaudeDefaults(),
                codexModels: @escaping () throws -> CodexModels = { try CodexModels.load() },
                grokModels: @escaping () -> GrokModels = { GrokModels.load() },
                grokDefaults: GrokDefaults = GrokDefaults(),
                cursorDefaults: CursorDefaults = CursorDefaults(),
                antigravityDefaults: AntigravityDefaults = AntigravityDefaults(),
                opencodeDefaults: OpenCodeDefaults? = nil,
                makeIO: @escaping (Target) throws -> TerminalIO = Switcher.terminalIO,
                sleep: @escaping (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1000) }) {
        self.config = config
        self.claudeDefaults = claudeDefaults
        self.codexModels = codexModels
        self.grokModels = grokModels
        self.grokDefaults = grokDefaults
        self.cursorDefaults = cursorDefaults
        self.antigravityDefaults = antigravityDefaults
        self.opencodeDefaults = opencodeDefaults
        self.makeIO = makeIO
        self.sleep = sleep
    }

    private func openCodeDefaults(for target: Target) throws -> OpenCodeDefaults {
        if let opencodeDefaults { return opencodeDefaults }
        // If we are not protecting the defaults, we do not need to know which file it is.
        guard config.keepDefaults else { return OpenCodeDefaults() }
        var handle: String?
        if case .orca(let orca) = target.host { handle = orca }
        let processes = ProcessTable.snapshot().entries.map { (arguments: $0.arguments, environment: $0.environment) }
        return try OpenCodeDefaults.resolve(processes: processes, orcaHandle: handle)
    }

    public static func terminalIO(for target: Target) throws -> TerminalIO {
        switch target.host {
        case .ghostty(let terminalID):
            return GhosttyIO(terminalID: terminalID)
        case .orca(let handle):
            let io = OrcaIO(orca: Proc.locate("orca"), handle: handle)
            // For testing: exercises the path of terminals whose screen lags behind (Ghostty) in an Orca session.
            if let lag = ProcessInfo.processInfo.environment["SLASHCOMMAND_SCREEN_LAG_MS"].flatMap(Int.init), lag > 0 {
                return LaggingIO(base: io, lagMs: lag)
            }
            return io
        case .tmux(let socket, let pane):
            guard let tmux = Proc.locate("tmux") else { throw SlashCommandError(loc("The tmux command was not found.")) }
            return TmuxIO(tmux: tmux, socket: socket, pane: pane)
        case .kitty(let socket, let window):
            guard let kitty = Proc.locate("kitty", extra: ["/Applications/kitty.app/Contents/MacOS"]) else {
                throw SlashCommandError(loc("The kitty command was not found."))
            }
            return KittyIO(kitty: kitty, socket: socket, window: window)
        case .wezterm(let socket, let pane):
            guard let wezterm = Proc.locate("wezterm", extra: ["/Applications/WezTerm.app/Contents/MacOS"]) else {
                throw SlashCommandError(loc("The wezterm command was not found."))
            }
            return WezTermIO(wezterm: wezterm, socket: socket, pane: pane)
        case .iterm(let sessionID):
            return ITermIO(sessionID: sessionID)
        }
    }

    static func unreadable(_ host: TerminalHost) -> String {
        switch host {
        case .ghostty:
            return loc("Not switched: could not read the Ghostty screen. Allow Slash Command in System Settings → Privacy & Security → %@.", SettingsNames.accessibility)
        case .orca:
            return loc("Not switched: could not read the Orca terminal screen.")
        case .tmux, .kitty, .wezterm, .iterm:
            return loc("Not switched: could not read the %@ screen. Check that the target is still there.", host.appName)
        }
    }

    public struct Planned {
        public let slot: Slot
        public let preset: AgentPreset
        public let steps: [Step]
        /// The steps to use instead when `steps` closed the picker and backed out cleanly. They touch the new-session default, so it must be put back after running.
        public let fallback: [Step]?
    }

    /// The agent's settings for preset number `slot` (1-based).
    public func preset(slot: Int, agent: Agent) throws -> AgentPreset {
        guard slot >= 1, slot <= config.slots.count else {
            throw SlashCommandError(loc("There is no preset %@ (there are %@).", slot, config.slots.count))
        }
        guard let preset = config.slots[slot - 1].preset(for: agent) else {
            throw SlashCommandError(loc("Preset %@ has no %@ entry.", slot, agent.displayName))
        }
        return preset
    }

    /// `slot` is 1-based.
    public func plan(slot: Int, agent: Agent) throws -> Planned {
        let preset = try preset(slot: slot, agent: agent)
        let chosen = config.slots[slot - 1]
        switch agent {
        case .claude:
            // Confirming with "this session only" in the picker does not touch the defaults. Use commands only when the picker has no row for that model.
            let picker = Plans.claudePicker(modelLabel: ClaudeModels.rowLabel(preset.model), effort: preset.effort,
                                            saveAsDefault: !config.keepDefaults, acceptSwitch: config.acceptSwitchPrompt)
            return Planned(slot: chosen, preset: preset, steps: picker,
                           fallback: Plans.claude(preset, acceptSwitch: config.acceptSwitchPrompt))
        case .codex:
            let selection = try codexModels().selection(of: preset)
            let steps = Plans.codex(modelIndex: selection.modelIndex, displayName: selection.displayName,
                                    effortLabel: selection.effortLabel)
            return Planned(slot: chosen, preset: preset, steps: steps, fallback: nil)
        case .grok, .cursor, .antigravity, .opencode:
            // These agents are driven by their own drivers (`GrokDriver`, `CursorDriver`, `AntigravityDriver`) that watch the screen, not by a step list.
            return Planned(slot: chosen, preset: preset, steps: [], fallback: nil)
        }
    }

    /// Send only when the input box is visible: if something like a permission prompt is up, the Enter we send would approve it.
    /// The screen and the draft are read at once.
    private func readyScreen(_ io: TerminalIO, target: Target) throws -> ScreenSnapshot {
        // Judging from a stale screen would miss a window that just appeared; always look at the screen as it is now.
        guard let screen = io.freshSnapshot() else {
            throw SlashCommandError(Switcher.unreadable(target.host))
        }
        guard Readiness.inputVisible(agent: target.agent, screen: screen.lines) else {
            throw SlashCommandError(loc("Not switched: the %@ input box is not visible. If a permission prompt or a picker is showing, deal with that first.", target.agent.displayName))
        }
        return screen
    }

    /// If `deferFinalCheck` is true, puts the default back only once and returns; the caller shows the notification and then calls `verifyRestore`.
    public func apply(slot: Int, to target: Target, deferFinalCheck: Bool = false) throws -> SwitchResult {
        trace?.mark("ready")
        let planned = try plan(slot: slot, agent: target.agent)
        trace?.mark("plan")
        let raw = try makeIO(target)
        let io: TerminalIO = trace.map { TracingIO(base: raw, trace: $0) } ?? raw

        if target.agent.usesDriver {
            let traced = trace
            let timed: (Int) -> Void = { ms in self.sleep(ms); traced?.mark("wait(\(ms))") }
            let warning: String?
            let confirmations: [String]
            if target.agent == .grok {
                let outcome = try GrokDriver(io: io, sleep: timed, models: grokModels(), defaults: grokDefaults, keepDefaults: config.keepDefaults).apply(planned.preset)
                (warning, confirmations) = (outcome.warning, outcome.confirmations)
            } else if target.agent == .cursor {
                let outcome = try CursorDriver(io: io, sleep: timed, defaults: cursorDefaults, keepDefaults: config.keepDefaults).apply(planned.preset)
                (warning, confirmations) = (outcome.warning, outcome.confirmations)
            } else if target.agent == .antigravity {
                let outcome = try AntigravityDriver(io: io, sleep: timed, defaults: antigravityDefaults, keepDefaults: config.keepDefaults).apply(planned.preset)
                (warning, confirmations) = (outcome.warning, outcome.confirmations)
            } else {
                let outcome = try OpenCodeDriver(io: io, sleep: timed, defaults: try openCodeDefaults(for: target), keepDefaults: config.keepDefaults).apply(planned.preset)
                (warning, confirmations) = (outcome.warning, outcome.confirmations)
            }
            return SwitchResult(target: target, slotName: planned.slot.name, preset: planned.preset,
                                warning: warning, confirmations: confirmations, pendingRestore: nil)
        }
        let first = try readyScreen(io, target: target)
        // codex can clear and restore the text being typed only up to one line. With several lines the remaining lines would mix with the command, so leave it alone.
        if target.agent == .codex, let draft = first.draft, draft.contains("\n") {
            throw SlashCommandError(loc("Not switched: there is a multi-line draft in the Codex input box. Send or clear it, then press again."))
        }

        let traced = trace
        let timedSleep: (Int) -> Void = { ms in self.sleep(ms); traced?.mark("wait(\(ms))") }
        // In a terminal whose screen lags behind (Ghostty), the claude picker takes 0.5 seconds per step (measured 2.4 to 3.8 seconds).
        // There, the command approach, which uses the defaults file changing as the signal instead of the screen, is faster.
        if target.agent == .claude, io.screenLagMs > 0, planned.fallback != nil {
            return try applyCommands(planned, io: io, target: target, screen: first, sleep: timedSleep, deferFinalCheck: deferFinalCheck)
        }
        do {
            var asked = false
            var runner = Runner(io: io, sleep: timedSleep, initial: first)
            runner.onAwaitingUser = { model in asked = true; self.onAwaitingUser?(model) }
            let confirmations = try runner.run(planned.steps)
            // If "No, go back" is chosen in the confirmation dialog, claude leaves only "Kept model as …".
            if asked, !confirmations.contains(where: { $0.hasPrefix("Set model to") }) { throw Runner.declined() }
            return SwitchResult(target: target, slotName: planned.slot.name, preset: planned.preset,
                                warning: nil, confirmations: confirmations, pendingRestore: nil)
        } catch let error as SlashCommandError where error.cleanlyAborted && planned.fallback != nil {
            // The picker closed and we are back at the input box. Nothing changed, so do it again with commands.
            trace?.mark("command instead of picker (\(error.message))")
        }
        return try applyCommands(planned, io: io, target: target, screen: try readyScreen(io, target: target),
                                 sleep: timedSleep, deferFinalCheck: deferFinalCheck)
    }

    /// Leaves the model alone and moves only effort up or down by one step.
    public func stepEffort(up: Bool, on target: Target) throws -> SwitchResult {
        trace?.mark("ready")
        let raw = try makeIO(target)
        let io: TerminalIO = trace.map { TracingIO(base: raw, trace: $0) } ?? raw
        let traced = trace
        let timedSleep: (Int) -> Void = { ms in self.sleep(ms); traced?.mark("wait(\(ms))") }
        if target.agent.usesDriver {
            let warning: String?
            let confirmations: [String]
            if target.agent == .grok {
                let outcome = try GrokDriver(io: io, sleep: timedSleep, models: grokModels(), defaults: grokDefaults, keepDefaults: config.keepDefaults).stepEffort(up: up)
                (warning, confirmations) = (outcome.warning, outcome.confirmations)
            } else if target.agent == .cursor {
                let outcome = try CursorDriver(io: io, sleep: timedSleep, defaults: cursorDefaults, keepDefaults: config.keepDefaults).stepEffort(up: up)
                (warning, confirmations) = (outcome.warning, outcome.confirmations)
            } else if target.agent == .antigravity {
                let outcome = try AntigravityDriver(io: io, sleep: timedSleep, defaults: antigravityDefaults, keepDefaults: config.keepDefaults).stepEffort(up: up)
                (warning, confirmations) = (outcome.warning, outcome.confirmations)
            } else {
                let outcome = try OpenCodeDriver(io: io, sleep: timedSleep, defaults: try openCodeDefaults(for: target), keepDefaults: config.keepDefaults).stepEffort(up: up)
                (warning, confirmations) = (outcome.warning, outcome.confirmations)
            }
            return SwitchResult(target: target, slotName: "", preset: AgentPreset(model: target.agent.rawValue, effort: up ? loc("one level up") : loc("one level down")),
                                warning: warning, confirmations: confirmations, pendingRestore: nil)
        }
        let first = try readyScreen(io, target: target)

        let steps: [Step]
        let preset: AgentPreset
        switch target.agent {
        case .claude:
            // The current model and effort are only known by opening the picker: open it, move one step, and confirm with "this session only".
            steps = Plans.claudeEffortStep(up: up, saveAsDefault: !config.keepDefaults, acceptSwitch: config.acceptSwitchPrompt)
            preset = AgentPreset(model: "claude", effort: up ? loc("one level up") : loc("one level down"))
        case .codex:
            if let draft = first.draft, draft.contains("\n") {
                throw SlashCommandError(loc("Nothing was changed: there is a multi-line draft in the Codex input box. Send or clear it, then press again."))
            }
            steps = Plans.codexEffortStep(up: up)
            preset = AgentPreset(model: "codex", effort: up ? loc("one level up") : loc("one level down"))
        case .grok, .cursor, .antigravity, .opencode:
            return try stepEffort(up: up, on: target)   // handled above (not reached)
        }
        var runner = Runner(io: io, sleep: timedSleep, initial: first)
        runner.onAwaitingUser = onAwaitingUser
        let confirmations = try runner.run(steps)
        return SwitchResult(target: target, slotName: "", preset: preset,
                            warning: nil, confirmations: confirmations, pendingRestore: nil)
    }

    /// Switches with claude's `/model X` and `/effort Y` commands. Both also change the new-session default, so it is put back to its pre-switch value.
    private func applyCommands(_ planned: Planned, io: TerminalIO, target: Target, screen: ScreenSnapshot,
                               sleep timedSleep: @escaping (Int) -> Void, deferFinalCheck: Bool) throws -> SwitchResult {
        let before = config.keepDefaults ? claudeDefaults.snapshot() : nil
        var runner = Runner(io: io, sleep: timedSleep, stamp: { claudeDefaults.stamp() }, initial: screen)
        runner.onAwaitingUser = onAwaitingUser
        let confirmations: [String]
        do {
            confirmations = try runner.run(planned.fallback ?? [])
        } catch var error as SlashCommandError where error.awaitingUser {
            // No reply came while waiting. If Yes is chosen later, claude writes the default then, and we have already let go; report it as it is.
            error = SlashCommandError(error.message + " " + loc("If you confirm now, this model also becomes the default for new sessions and the effort has to be set separately (cancel and press again to get both)."))
            error.awaitingUser = true
            throw error
        } catch {
            // Even if it stopped midway, an earlier command may already have changed the default; put it back and then report the failure.
            if let before {
                timedSleep(300)
                _ = claudeDefaults.restore(to: before)
                trace?.mark("restore defaults")
            }
            throw error
        }

        var warning: String?
        var pending: Data?
        if let before {
            // The result line of the last command was confirmed, so the file has already been written. Put it back right away and look once more to guard against a late write.
            if case .failed(let reason) = claudeDefaults.restore(to: before) {
                warning = loc("Could not put back the default for new sessions: %@", reason)
            }
            trace?.mark("restore defaults")
            if deferFinalCheck {
                pending = before
            } else if let late = verifyRestore(before) {
                warning = late
            }
        }
        return SwitchResult(target: target, slotName: planned.slot.name, preset: planned.preset,
                            warning: warning, confirmations: confirmations, pendingRestore: pending)
    }

    /// Waits a moment, checks again that the default is as it was, and puts it back if not. Returns the reason if it cannot be put back.
    public func verifyRestore(_ before: Data) -> String? {
        sleep(250)
        trace?.mark("wait(250)")
        if case .failed(let reason) = claudeDefaults.restore(to: before) {
            return loc("Could not put back the default for new sessions: %@", reason)
        }
        return nil
    }
}

/// Runs a list of steps on the terminal.
public struct Runner {
    public let io: TerminalIO
    public let sleep: (Int) -> Void
    /// An external signal (the modification time of claude's defaults file). If nil, only the screen is used.
    public let stamp: (() -> Int64?)?
    /// The screen before running. The text being typed and any result lines already showing are known from here.
    public let initial: ScreenSnapshot?

    /// Called when we do not answer claude's "Switch model?" dialog. Waits for `awaitUserMs` for the user to choose.
    public var onAwaitingUser: ((String) -> Void)?
    static let awaitUserMs = 20_000

    /// Time elapsed since the screen was last read. Used to know whether "reading now gives a fresh screen" in terminals whose screen lags behind.
    private final class ReadClock {
        var last = DispatchTime.now()
        var slept = 0
        func elapsedMs() -> Int {
            max(Int((DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000), slept)
        }
        func reset() { last = .now(); slept = 0 }
    }
    private let clock = ReadClock()

    public init(io: TerminalIO, sleep: @escaping (Int) -> Void,
                stamp: (() -> Int64?)? = nil, initial: ScreenSnapshot? = nil) {
        self.io = io
        self.sleep = sleep
        self.stamp = stamp
        self.initial = initial
    }

    /// Reads a screen that is not stale: waits until the terminal's lag has passed since the last read, then reads.
    private func freshSnapshot() -> ScreenSnapshot? {
        let remaining = io.screenLagMs - clock.elapsedMs()
        if remaining > 0 { sleep(remaining) }
        defer { clock.reset() }
        return io.snapshot()
    }

    /// The returned values are the result lines that `expectResult` saw.
    @discardableResult
    public func run(_ steps: [Step]) throws -> [String] {
        var armedStamp: Int64?
        var armedLines: [String] = []
        // The screen seen last. `arm` takes this as the "state before the command".
        var seenLines = initial?.lines ?? []
        var confirmations: [String] = []
        // Results that were passed without looking at the screen (by the defaults file signal alone); after the end, look for their phrase on the screen.
        var unseen: [(prefix: String, command: String?)] = []
        // The command line typed last ("/model sonnet"). Used at the end to find that command and its reply on the screen.
        var typedCommand: String?
        // The step `stepEffort` moved to. Used to accept a confirmation dialog only when it asks about «that step».
        var stepped: String?
        func wanted(_ values: [String]) -> [String] {
            values.compactMap { $0 == Step.steppedEffort ? stepped : $0 }
        }
        for step in steps {
            switch step {
            case .text(let text):
                try io.type(text)
                let line = text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(String.init).joined()
                if line.hasPrefix("/") { typedCommand = line }
            case .key(let key):
                try io.press(key)
            case .wait(let ms):
                sleep(ms)
            case .expect(let needle, let bottom, let timeoutMs, let abort, let failure):
                if try !waitFor(needle, bottom: bottom, timeoutMs: timeoutMs) {
                    _ = try? run(abort)
                    throw SlashCommandError(failure)
                }
            case .expectPicker(let header, let footer, let timeoutMs, let abort, let failure):
                let shown = try poll(timeoutMs: timeoutMs) { lines in
                    guard let open = Picker.open(lines) else { return false }
                    return (header.map { open.header.hasPrefix($0) } ?? true) && (footer.map { open.footer.contains($0) } ?? true)
                }
                if !shown {
                    // If the window is low, the picker's bottom hint line is cut off and we cannot recognize it although it is open. If the header and the cursor row are visible, it is that picker:
                    // close it instead of ending with it left open (before, it said "did not open" and left the picker; measured 2026-10-12).
                    if let header, let lines = io.screen(), Picker.clipped(lines, header: header) {
                        try io.press(.escape)
                        _ = try poll(timeoutMs: 1500) { !Picker.clipped($0, header: header) }
                        var error = SlashCommandError(loc("Nothing was changed: the window is too low to show the whole model picker. Make it taller, then press again."))
                        if let after = io.screen(), !Picker.clipped(after, header: header), !Picker.isOpen(after),
                           Readiness.claudePromptVisible(after) || Readiness.codexComposerVisible(after) {
                            error.cleanlyAborted = true
                        }
                        throw error
                    }
                    _ = try? run(abort)
                    throw SlashCommandError(failure)
                }
            case .arm:
                armedStamp = stamp?() ?? nil
                armedLines = io.screen() ?? seenLines
            case .expectResult(let prefix, let command, let acceptSwitchTo, let timeoutMs, let failure):
                if io.screenLagMs > 0, stamp != nil {
                    if let seen = try waitForStamp(prefix: prefix, command: command, acceptSwitchTo: wanted(acceptSwitchTo),
                                                   armedStamp: armedStamp, armedLines: armedLines,
                                                   timeoutMs: timeoutMs, failure: failure) {
                        confirmations.append(seen)
                    } else {
                        unseen.append((prefix, typedCommand))
                    }
                } else {
                    let found = try waitForResult(prefix: prefix, command: command, acceptSwitchTo: wanted(acceptSwitchTo),
                                                  armedStamp: armedStamp, armedLines: armedLines,
                                                  timeoutMs: timeoutMs, failure: failure)
                    seenLines = found.lines
                    confirmations.append(found.result)
                }
            case .selectRow(let label, let via, let timeoutMs, let abort, let failure):
                if try !selectRow(label: label, via: via, timeoutMs: timeoutMs) {
                    throw try aborted(abort, failure)
                }
            case .setEffort(let level, let timeoutMs, let abort, let failure):
                switch try setEffort(level, timeoutMs: timeoutMs) {
                case .set: break
                case .unsupported(let note): confirmations.append(note)
                case .failed: throw try aborted(abort, failure)
                }
            case .expectCurrentRow(let abort, let failure):
                let rows = Picker.rows(io.screen() ?? [])
                guard let cursor = rows.first(where: \.selected), cursor.current else {
                    throw try aborted(abort, failure)
                }
            case .stepEffort(let up, let timeoutMs, let abort):
                switch try stepEffort(up: up, timeoutMs: timeoutMs) {
                case .moved(let level):
                    stepped = level
                    // Record the value seen here, in case the result line after the picker closes does not show the effort.
                    confirmations.append("Set effort level to \(level)")
                case .stopped(let reason, let atEdge):
                    var error = try aborted(abort, reason)
                    error.nothingToDo = atEdge
                    throw error
                }
            case .stepRow(let up, let timeoutMs, let abort):
                if case .stopped(let reason, let atEdge) = try stepRow(up: up, timeoutMs: timeoutMs) {
                    var error = try aborted(abort, reason)
                    error.nothingToDo = atEdge
                    throw error
                }
            case .expectInput(let agent, let acceptSwitchTo, let timeoutMs, let abort, let failure):
                switch try waitForInput(agent: agent, acceptSwitchTo: wanted(acceptSwitchTo), timeoutMs: timeoutMs) {
                case .ready:
                    break
                case .declined:
                    // "No, go back" returns to the picker: close the picker and report that nothing was changed.
                    _ = try? run(abort)
                    throw Runner.declined()
                case .timedOut:
                    if let asking = io.screen().flatMap(ClaudeScreen.switchPrompt) { throw Runner.awaitingSwitch(asking) }
                    _ = try? run(abort)
                    throw SlashCommandError(failure)
                }
            case .closePicker:
                try closePicker()
            case .capture(let prefixes, let afterCommand):
                guard let lines = io.screen() else { break }
                if let afterCommand {
                    if let found = ClaudeScreen.latestResult(lines, command: afterCommand, prefixes: prefixes),
                       prefixes.contains(where: { found.hasPrefix($0) }) {
                        confirmations.append(found)
                    }
                } else if let found = prefixes.compactMap({ Runner.matching(lines, prefix: $0).last }).last {
                    confirmations.append(found)
                }
            }
        }
        if !unseen.isEmpty {
            // Other claude sessions also write the defaults file, so the file changing alone does not prove «our command» ran.
            // Read a fresh screen once at the end and count it as success only if the result line made this time is «visible».
            guard let snap = freshSnapshot() else { throw SlashCommandError(loc("Could not read the terminal screen, so the result could not be checked.")) }
            let before = initial?.lines ?? []
            for (prefix, command) in unseen {
                let now = ClaudeScreen.results(snap.lines, prefix: prefix)
                if Runner.isNew(now, since: ClaudeScreen.results(before, prefix: prefix)), let found = now.last {
                    confirmations.append(found)
                } else if let command, let reply = ClaudeScreen.reply(toCommand: command, in: snap.lines), reply.hasPrefix(prefix) {
                    // Even if the same switch is repeated and the number of lines is unchanged, that reply is below the command we typed.
                    confirmations.append(reply)
                } else {
                    throw SlashCommandError(loc("The command was sent, but Claude Code's result line (%@ …) is not on screen. Check on screen whether it changed.", prefix))
                }
            }
        }
        return confirmations
    }

    /// For terminals whose screen lags behind (Ghostty): uses claude rewriting the defaults file when a command runs as the signal.
    /// The screen is read only when it is not stale, to see whether a confirmation dialog appeared and whether claude refused.
    ///
    /// Return value: nil if we passed on the file signal (the result phrase has not been seen yet), or the line if a new result line was seen on the screen.
    /// Some commands do not rewrite the file: `/effort max` applies only to this session and leaves the defaults file as it is (measured on 2.1.283).
    private func waitForStamp(prefix: String, command: String?, acceptSwitchTo: [String], armedStamp: Int64?, armedLines: [String],
                              timeoutMs: Int, failure: String) throws -> String? {
        let started = DispatchTime.now()
        var simulated = 0
        var accepted = false
        let repliedBefore = ClaudeScreen.commandReply(armedLines, command: command)
        let matchedBefore = ClaudeScreen.results(armedLines, prefix: prefix)
        // If a confirmation dialog is up and waiting for the user's choice, the model name. Also watches when the dialog went away.
        var awaiting: String?
        var goneAt: Int?
        var deadline = timeoutMs
        while true {
            if (stamp?() ?? nil) != armedStamp {
                // Right after writing the file, claude puts the text being typed back in the input box. Wait briefly so the next Ctrl+S does not overlap with it.
                sleep(120)
                clock.slept += 120
                return nil
            }
            let elapsed = max(Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000), simulated)
            if clock.elapsedMs() >= io.screenLagMs {
                guard let snap = io.snapshot() else { throw SlashCommandError(loc("Stopped: could not read the terminal screen.")) }
                clock.reset()
                // The file did not change, but this command's result newly appeared on screen.
                let matched = ClaudeScreen.results(snap.lines, prefix: prefix)
                if Runner.isNew(matched, since: matchedBefore), Readiness.claudePromptVisible(snap.lines), let seen = matched.last {
                    return seen
                }
                if command != nil, let reply = ClaudeScreen.commandReply(snap.lines, command: command),
                   reply != repliedBefore, !reply.hasPrefix(prefix), Readiness.claudePromptVisible(snap.lines) {
                    throw Runner.refused(reply)
                }
                if !accepted, try acceptSwitch(snap.lines, to: acceptSwitchTo) { accepted = true }
                if !accepted, let asking = ClaudeScreen.switchPrompt(snap.lines) {
                    if awaiting == nil { onAwaitingUser?(asking); deadline = Runner.awaitUserMs }
                    awaiting = asking
                    goneAt = nil
                } else if awaiting != nil {
                    // The dialog went away. If it was Yes, the file will change soon. If it does not change after a short wait, it was No.
                    if let gone = goneAt, elapsed - gone >= 700 { throw Runner.declined() }
                    goneAt = goneAt ?? elapsed
                }
            }
            if elapsed >= deadline { throw awaiting.map(Runner.awaitingSwitch) ?? SlashCommandError(failure) }
            sleep(15)
            simulated += 15
            clock.slept += 15
        }
    }

    /// A reply directly below the command that is not what we were waiting for.
    static func refused(_ reply: String) -> SlashCommandError {
        // Cancelling in the confirmation dialog makes claude leave "Kept model as …": that is the user's choice, not a refusal.
        if reply.hasPrefix("Kept model as") { return declined() }
        return SlashCommandError(loc("Claude Code did not accept it: %@", reply.prefix(120)))
    }

    /// The user chose "No, go back" in the confirmation dialog.
    static func declined() -> SlashCommandError {
        var error = SlashCommandError(loc("Nothing was changed: the confirmation was cancelled."))
        error.nothingToDo = true
        return error
    }

    /// claude is asking whether to change the model; we do not answer and hand it to the user.
    static func awaitingSwitch(_ model: String) -> SlashCommandError {
        var error = SlashCommandError(loc("Claude Code is asking whether to switch to %@ (it re-reads the conversation). Press Enter to switch.", model))
        error.awaitingUser = true
        return error
    }

    /// If claude's confirmation dialog is asking to switch to «the value we chose» (the model name or effort step), accept it with Enter.
    /// If it is not that dialog or the value differs, send nothing.
    private func acceptSwitch(_ lines: [String], to wanted: [String]) throws -> Bool {
        guard !wanted.isEmpty, let asked = ClaudeScreen.switchPrompt(lines) else { return false }
        let row = Picker.Row(number: 1, label: asked, selected: true, current: false)
        guard wanted.contains(where: { Picker.index(of: $0, in: [row]) != nil }) else { return false }
        try io.press(.enter)
        return true
    }

    private func waitForResult(prefix: String, command: String?, acceptSwitchTo: [String], armedStamp: Int64?, armedLines: [String],
                               timeoutMs: Int, failure: String) throws -> (result: String, lines: [String]) {
        let started = DispatchTime.now()
        var simulated = 0
        var accepted = false
        // If the same phrase was on screen from before the command, count it as this command's result only when that line is «new» or the defaults file «changed».
        let matchedBefore = ClaudeScreen.results(armedLines, prefix: prefix)
        let repliedBefore = ClaudeScreen.commandReply(armedLines, command: command)
        let saidBefore = ClaudeScreen.lastResult(armedLines)
        // A terminal that gives the draft separately (Orca) uses that value; otherwise look at the input box line on the screen.
        func draft(_ snap: ScreenSnapshot) -> String {
            snap.draft ?? ClaudeScreen.promptText(snap.lines) ?? ""
        }
        let draftBefore = initial.map(draft) ?? ""
        var awaiting: String?
        var goneAt: Int?
        var deadline = timeoutMs
        while true {
            guard let snap = io.snapshot() else { throw SlashCommandError(loc("Stopped: could not read the terminal screen.")) }
            let elapsed = max(Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000), simulated)

            let stampChanged = stamp != nil && (stamp?() ?? nil) != armedStamp
            let matched = ClaudeScreen.results(snap.lines, prefix: prefix)
            let fresh = matchedBefore.isEmpty || stampChanged || Runner.isNew(matched, since: matchedBefore)
            // The input box is «visible» again, so the next command's Enter does not press a confirmation dialog that came up in between.
            let promptBack = Readiness.claudePromptVisible(snap.lines)
            // If there was text being typed, it «came back» in the input box. The user may have typed more meanwhile, so whether it is the same is not checked.
            let draftBack = draftBefore.isEmpty || !draft(snap).isEmpty
            if let result = matched.last, fresh, promptBack, draftBack {
                return (result, snap.lines)
            }
            // If a different reply appears directly below the command (e.g. Model 'x' not found), finish with that instead of waiting.
            if promptBack, command != nil, let reply = ClaudeScreen.commandReply(snap.lines, command: command),
               reply != repliedBefore, !reply.hasPrefix(prefix) {
                throw Runner.refused(reply)
            }
            if !accepted, try acceptSwitch(snap.lines, to: acceptSwitchTo) { accepted = true }
            if !accepted, let asking = ClaudeScreen.switchPrompt(snap.lines) {
                if awaiting == nil { onAwaitingUser?(asking); deadline = Runner.awaitUserMs }
                awaiting = asking
                goneAt = nil
            } else if awaiting != nil {
                // The dialog went away yet no result came: it was "No, go back".
                if let gone = goneAt, elapsed - gone >= 700 { throw Runner.declined() }
                goneAt = goneAt ?? elapsed
            }
            if elapsed >= deadline, let awaiting { throw Runner.awaitingSwitch(awaiting) }
            if elapsed >= deadline {
                // If claude said something new (e.g. Model 'x' not found), append it.
                let said = ClaudeScreen.lastResult(snap.lines)
                let detail = said.flatMap { $0 != saidBefore ? " (claude: \($0.prefix(80)))" : nil } ?? ""
                throw SlashCommandError(failure + detail)
            }
            sleep(40)
            simulated += 40
        }
    }

    private func waitFor(_ needle: String, bottom: Int?, timeoutMs: Int) throws -> Bool {
        try poll(timeoutMs: timeoutMs) { lines in
            guard let bottom else { return lines.contains { $0.contains(needle) } }
            let shown = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return Runner.contains(needle, in: Array(shown.suffix(bottom)))
        }
    }

    /// Whether `needle` is in those lines. In a narrow pane one line wraps into two (codex at 38 columns: `/model  choose what model and` / `reasoning effort to use`
    /// — measured in a split pane of iTerm2 on 2026-10-12); also look in the text made by joining two neighboring lines.
    static func contains(_ needle: String, in lines: [String]) -> Bool {
        if lines.contains(where: { $0.contains(needle) }) { return true }
        func words(_ text: String) -> String { text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
        return zip(lines, lines.dropFirst()).contains { words($0 + " " + $1).contains(needle) }
    }

    /// Re-reads the screen until it satisfies `condition`. True if it does within the time.
    private func poll(timeoutMs: Int, _ condition: ([String]) -> Bool) throws -> Bool {
        let started = DispatchTime.now()
        var simulated = 0
        while true {
            guard let lines = io.screen() else { throw SlashCommandError(loc("Stopped: could not read the terminal screen.")) }
            if condition(lines) { return true }
            let real = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            if max(real, simulated) >= timeoutMs { return false }
            sleep(Runner.pollMs)
            simulated += Runner.pollMs
        }
    }

    /// Reading the screen is cheap (under 1ms with Orca). Look often and briefly.
    static let pollMs = 30

    // MARK: picker

    /// Runs the cleanup steps and, if the picker closed and we are back at the input box, marks the failure as one that «backed out cleanly».
    private func aborted(_ abort: [Step], _ failure: String) throws -> SlashCommandError {
        _ = try? run(abort)
        var error = SlashCommandError(failure)
        if let lines = io.screen(), !Picker.isOpen(lines),
           Readiness.claudePromptVisible(lines) || Readiness.codexComposerVisible(lines) {
            error.cleanlyAborted = true
        }
        return error
    }

    /// Puts the cursor on the `label` row. True on success.
    private func selectRow(label: String, via: String?, timeoutMs: Int) throws -> Bool {
        // Wait only until the list is drawn. If it is drawn and the row is not there, waiting longer will not make it appear.
        var rows: [Picker.Row] = []
        guard try poll(timeoutMs: timeoutMs, { lines in
            rows = Picker.rows(lines)
            return !rows.isEmpty
        }) else { return false }
        let found = Picker.index(of: label, in: rows) != nil
        guard found || (via.map { Picker.index(of: $0, in: rows) != nil } ?? false) else {
            // In a low window only one or two rows show and the rest are folded into `… +9 models` (measured 2026-10-11, claude at 90×14);
            // move the cursor one row at a time to find the row. If it is not found it is a failure as before (then the command approach is used).
            guard via == nil, let lines = io.screen(), Picker.hasHiddenRows(lines), try scroll(to: label, timeoutMs: timeoutMs) else { return false }
            return try moveCursor(to: label, timeoutMs: timeoutMs)
        }
        if !found, let via {
            guard try moveCursor(to: via, timeoutMs: timeoutMs) else { return false }
            try io.press(.enter)
            let entered = try poll(timeoutMs: timeoutMs) { Picker.index(of: label, in: Picker.rows($0)) != nil }
            guard entered else { return false }
        }
        return try moveCursor(to: label, timeoutMs: timeoutMs)
    }

    /// Finds a row that is folded out of view: raises the cursor to the top (number 1), then goes down one row at a time to see whether the row appears on screen.
    /// Why from the top: names are matched by their beginning ("opus" → `Opus 5.5`), so several rows share the same beginning; the one picked in a tall window is the topmost of them.
    /// (Measured 2026-10-11: searching only downward from the current position picked the `Opus 5` below instead of `Opus 5.5`.)
    /// If it cannot reach the top, it does not search. It never sends the picking keys (Enter, s).
    private func scroll(to label: String, timeoutMs: Int) throws -> Bool {
        func cursor(_ lines: [String]) -> Int? { Picker.rows(lines).first(where: \.selected)?.number }
        func step(_ key: Key, from number: Int) throws -> Bool {
            try io.press(key)
            return try poll(timeoutMs: min(timeoutMs, 700)) { lines in cursor(lines).map { $0 != number } ?? false }
        }
        func read() throws -> [String] {
            guard let lines = io.screen() else { throw SlashCommandError(loc("Stopped: could not read the terminal screen.")) }
            return lines
        }
        for _ in 0..<40 {
            guard let at = cursor(try read()), at > 1 else { break }
            guard try step(.up, from: at) else { break }
        }
        guard cursor(try read()) == 1 else { return false }
        var seen: Set<Int> = []
        for _ in 0..<40 {
            let lines = try read()
            if Picker.index(of: label, in: Picker.rows(lines)) != nil { return true }
            guard let at = cursor(lines), seen.insert(at).inserted else { return false }
            guard try step(.down, from: at) else { return false }
        }
        return false
    }

    /// Until the cursor is on the `label` row: read the cursor row from the screen, send up or down by the difference, and see that the cursor «has arrived».
    private func moveCursor(to label: String, timeoutMs: Int) throws -> Bool {
        for _ in 0..<4 {
            guard let lines = io.screen() else { throw SlashCommandError(loc("Stopped: could not read the terminal screen.")) }
            let rows = Picker.rows(lines)
            guard let target = Picker.index(of: label, in: rows),
                  let cursor = rows.firstIndex(where: \.selected) else { return false }
            if target == cursor { return true }
            let key = target > cursor ? Key.down : Key.up
            try io.type(String(repeating: key.bytes, count: abs(target - cursor)))
            // Recalculating before the screen catches up would move twice; move on after seeing it arrive.
            let arrived = try poll(timeoutMs: min(timeoutMs, 1000)) { lines in
                let now = Picker.rows(lines)
                guard let wanted = Picker.index(of: label, in: now) else { return false }
                return now.firstIndex(where: \.selected) == wanted
            }
            if arrived { return true }
        }
        return false
    }

    enum EffortOutcome {
        case set
        /// A model with no effort (Haiku). Carries the hint line on the screen as it is.
        case unsupported(String)
        case failed
    }

    /// Sets the effort line of the claude picker to `level`. One step per ←/→.
    /// Some versions wrap from the end to the other end (2.1.289) and some do not (2.1.296; measured 2026-10-13: going from `xhigh` to `high` it pressed only → and
    /// stopped at `max`, which failed). So go first toward where it should go, and if blocked there, go all the way to the other direction.
    private func setEffort(_ level: String, timeoutMs: Int) throws -> EffortOutcome {
        var current: String?
        var note: String?
        let shown = try poll(timeoutMs: timeoutMs) { lines in
            current = Picker.claudeEffort(lines)
            note = lines.first { $0.contains("Effort not supported") }?.trimmingCharacters(in: .whitespaces)
            return current != nil || note != nil
        }
        guard shown else { return .failed }
        if current == nil, let note { return .unsupported(note.drop(while: { !$0.isLetter }).description) }
        let wanted = level.lowercased()
        enum Walk { case reached, blocked, lost }
        /// Goes one step at a time in one direction. `blocked` if it no longer moves (the end). `lost` if the effort line disappears from the screen: the picker closed or
        /// changed to another dialog, so no more arrows are sent after that (they would move the cursor in the text being typed or a selection in another dialog).
        func walk(_ key: Key) throws -> Walk {
            var presses = 0
            while let now = current, now != wanted {
                guard presses < 8 else { return .blocked }   // if it is not found after a full cycle, the model does not have that step
                try io.press(key)
                presses += 1
                var seen: String?
                let moved = try poll(timeoutMs: min(timeoutMs, 1000)) { lines in
                    seen = Picker.claudeEffort(lines)
                    return seen != nil && seen != now
                }
                guard let seen else { return .lost }
                current = seen
                if !moved { return .blocked }
            }
            return current == wanted ? .reached : .lost
        }
        let order = Picker.claudeEffortOrder
        var first = Key.right
        if let now = current, let from = order.firstIndex(of: now), let to = order.firstIndex(of: wanted), to < from { first = .left }
        switch try walk(first) {
        case .reached: return .set
        case .lost: return .failed
        case .blocked: return try walk(first == .right ? .left : .right) == .reached ? .set : .failed
        }
    }

    enum StepOutcome {
        case moved(String)
        /// Nothing was changed. If `atEdge`, it was already at the end step so there was nothing to change.
        case stopped(String, atEdge: Bool = false)
    }

    /// Moves the effort of the claude picker by one row. At the end, pressing wraps to the other end, so it is not pressed at the end.
    private func stepEffort(up: Bool, timeoutMs: Int) throws -> StepOutcome {
        var current: String?
        var unsupported = false
        let shown = try poll(timeoutMs: timeoutMs) { lines in
            current = Picker.claudeEffort(lines)
            unsupported = Picker.claudeEffortUnsupported(lines)
            return current != nil || unsupported
        }
        guard shown, let now = current else {
            return .stopped(unsupported ? loc("The current model does not support effort.") : loc("Could not read the effort in the Claude Code picker."))
        }
        let order = Picker.claudeEffortOrder
        let edge = up ? order.last : order.first
        if now == edge { return .stopped(up ? loc("Already at the highest level (%@).", now) : loc("Already at the lowest level (%@).", now), atEdge: true) }
        try io.press(up ? .right : .left)
        var after: String?
        let moved = try poll(timeoutMs: min(timeoutMs, 1000)) { lines in
            after = Picker.claudeEffort(lines)
            return after != nil && after != now
        }
        guard moved, let after else { return .stopped(loc("The effort in the Claude Code picker did not move.")) }
        // In a model with few steps it wraps earlier than the end we know. If it crossed to the other side, put it back and report that it is the end.
        if let from = order.firstIndex(of: now), let to = order.firstIndex(of: after), (to > from) != up {
            try io.press(up ? .left : .right)
            _ = try poll(timeoutMs: min(timeoutMs, 1000)) { Picker.claudeEffort($0) == now }
            return .stopped(up ? loc("Already at the highest level (%@).", now) : loc("Already at the lowest level (%@).", now), atEdge: true)
        }
        return .moved(after)
    }

    /// In the codex effort list, puts the cursor on the row directly above the `(current)` row (effort down) or below it (effort up).
    /// The list has "More reasoning…" after Low … Extra high, and Max · Ultra are in the list below it.
    private func stepRow(up: Bool, timeoutMs: Int) throws -> StepOutcome {
        let more = "More reasoning"
        func edge(_ label: String) -> StepOutcome {
            .stopped(up ? loc("Already at the highest level (%@).", label) : loc("Already at the lowest level (%@).", label), atEdge: true)
        }
        var rows: [Picker.Row] = []
        guard try poll(timeoutMs: timeoutMs, { lines in
            rows = Picker.rows(lines)
            return rows.contains(where: \.current)
        }), let current = rows.firstIndex(where: \.current) else {
            return .stopped(loc("Could not find the current value in the Codex effort list."))
        }
        let moreIndex = Picker.index(of: more, in: rows)
        let plain = rows.indices.filter { $0 != moreIndex }

        if current != moreIndex {
            // The current value is in this list (Low … Extra high).
            guard let at = plain.firstIndex(of: current) else { return .stopped(loc("Could not read the Codex effort list.")) }
            if !up {
                guard at > 0 else { return edge(rows[current].label) }
                return try moveCursor(to: rows[plain[at - 1]].label, timeoutMs: timeoutMs) ? .moved(rows[plain[at - 1]].label) : .stopped(loc("Could not move the cursor in the Codex effort list."))
            }
            if at + 1 < plain.count {
                return try moveCursor(to: rows[plain[at + 1]].label, timeoutMs: timeoutMs) ? .moved(rows[plain[at + 1]].label) : .stopped(loc("Could not move the cursor in the Codex effort list."))
            }
            // This is the last of this list; the next step is the first row below More reasoning….
            guard moreIndex != nil else { return edge(rows[current].label) }
            guard try moveCursor(to: more, timeoutMs: timeoutMs) else { return .stopped(loc("Could not move the cursor in the Codex effort list.")) }
            try io.press(.enter)
            var inner: [Picker.Row] = []
            guard try poll(timeoutMs: timeoutMs, { lines in
                inner = Picker.rows(lines)
                return Picker.open(lines)?.header.hasPrefix("Advanced Reasoning") == true && !inner.isEmpty
            }), let first = inner.first else { return .stopped(loc("The Codex \"More reasoning\" list did not open.")) }
            return try moveCursor(to: first.label, timeoutMs: timeoutMs) ? .moved(first.label) : .stopped(loc("Could not move the cursor in the Codex effort list."))
        }

        // The current value is below More reasoning… (Max · Ultra).
        guard try moveCursor(to: more, timeoutMs: timeoutMs) else { return .stopped(loc("Could not move the cursor in the Codex effort list.")) }
        try io.press(.enter)
        var inner: [Picker.Row] = []
        guard try poll(timeoutMs: timeoutMs, { lines in
            inner = Picker.rows(lines)
            return Picker.open(lines)?.header.hasPrefix("Advanced Reasoning") == true && inner.contains(where: \.current)
        }), let at = inner.firstIndex(where: \.current) else { return .stopped(loc("Could not find the current value in the Codex \"More reasoning\" list.")) }
        if up {
            guard at + 1 < inner.count else { return edge(inner[at].label) }
            return try moveCursor(to: inner[at + 1].label, timeoutMs: timeoutMs) ? .moved(inner[at + 1].label) : .stopped(loc("Could not move the cursor in the Codex effort list."))
        }
        if at > 0 {
            return try moveCursor(to: inner[at - 1].label, timeoutMs: timeoutMs) ? .moved(inner[at - 1].label) : .stopped(loc("Could not move the cursor in the Codex effort list."))
        }
        // This is the first row of the lower list; one step down is the last row of the outer list (Extra high).
        guard let last = plain.last else { return edge(inner[at].label) }
        try io.press(.escape)
        guard try poll(timeoutMs: timeoutMs, { Picker.open($0)?.header.hasPrefix("Select Reasoning Level") == true }) else {
            return .stopped(loc("Could not get back to the Codex effort list."))
        }
        return try moveCursor(to: rows[last].label, timeoutMs: timeoutMs) ? .moved(rows[last].label) : .stopped(loc("Could not move the cursor in the Codex effort list."))
    }

    /// Waits until the picker closes and the input box is visible again.
    enum InputOutcome { case ready, declined, timedOut }

    private func waitForInput(agent: Agent, acceptSwitchTo: [String], timeoutMs: Int) throws -> InputOutcome {
        func draft(_ snap: ScreenSnapshot) -> String {
            snap.draft ?? ClaudeScreen.promptText(snap.lines) ?? ""
        }
        let draftBefore = agent == .claude ? (initial.map(draft) ?? "") : ""
        let started = DispatchTime.now()
        var simulated = 0
        var accepted = false
        var awaiting = false
        var deadline = timeoutMs
        while true {
            guard let snap = io.snapshot() else { throw SlashCommandError(loc("Stopped: could not read the terminal screen.")) }
            let draftBack = draftBefore.isEmpty || !draft(snap).isEmpty
            if !Picker.isOpen(snap.lines), Readiness.inputVisible(agent: agent, screen: snap.lines), draftBack { return .ready }
            if !accepted, try acceptSwitch(snap.lines, to: acceptSwitchTo) { accepted = true }
            // If it is a confirmation dialog we decided not to accept, tell the user and wait until they choose.
            let asking = ClaudeScreen.switchPrompt(snap.lines)
            if !accepted, !awaiting, let asking {
                awaiting = true
                onAwaitingUser?(asking)
                deadline = Runner.awaitUserMs
            }
            // If the confirmation dialog went away and the picker is visible again, the user chose "No, go back".
            if awaiting, asking == nil, Picker.isOpen(snap.lines) { return .declined }
            let real = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            if max(real, simulated) >= deadline { return .timedOut }
            sleep(Runner.pollMs)
            simulated += Runner.pollMs
        }
    }

    /// Presses Esc only while the picker is visible. Re-reads the screen after each press.
    private func closePicker() throws {
        for _ in 0..<4 {
            guard let lines = io.screen() else { return }
            let before = Picker.rows(lines)
            if before.isEmpty {
                // A picker with its bottom hint line cut off is also a picker: in a low window, when the effort description gets long (`Max` adds two more lines), the hint line
                // is pushed off the screen (measured 2026-10-13: in a 16-line window we ended with a picker left open that way). If the header and cursor row are visible, close it.
                guard let header = Picker.headers.first(where: { Picker.clipped(lines, header: $0) }) else { return }
                try io.press(.escape)
                _ = try poll(timeoutMs: 800) { !Picker.clipped($0, header: header) }
                continue
            }
            try io.press(.escape)
            _ = try poll(timeoutMs: 800) { Picker.rows($0) != before }
        }
    }

    /// Lines on screen starting with `prefix` (top to bottom). The leading `•` (codex) or `⎿` (claude) is stripped.
    static func matching(_ lines: [String], prefix: String) -> [String] {
        lines.compactMap { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("•") || text.hasPrefix("⎿") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return text.hasPrefix(prefix) ? text : nil
        }
    }

    /// Whether a line is new since `before`: the count increased or the last line differs.
    static func isNew(_ now: [String], since before: [String]) -> Bool {
        !now.isEmpty && (now.count > before.count || now.last != before.last)
    }
}
