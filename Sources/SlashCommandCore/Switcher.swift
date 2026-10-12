import Foundation

public struct SwitchResult: Equatable, Sendable {
    public let target: Target
    public let slotName: String
    public let preset: AgentPreset
    /// 기본값을 되돌리지 못했을 때의 사유. 전환 자체는 성공했다.
    public let warning: String?
    /// 에이전트가 화면에 알려 준 결과(예: "Set model to Sonnet 5.5"). 보냈다는 사실이 아니라 바뀌었다는 확인.
    public let confirmations: [String]
    /// 늦게 오는 기본값 쓰기를 한 번 더 확인해야 할 때의 전환 전 파일 내용(`Switcher.verifyRestore`).
    public let pendingRestore: Data?

    /// 알림 제목. 에이전트가 화면에 알려 준 이름이 있으면 그것을("Opus 5.5 · high"), 없으면 프리셋 값을("opus · high") 쓴다.
    public var summary: String {
        var model: String?
        var effort: String?
        var effortKnown = true
        for line in confirmations {
            if line.hasPrefix("Effort not supported") { effortKnown = false; continue }
            // 작업 중 알림 줄은 폭에 맞춰 잘려 온다("… Opus 5.5 and") — 꼬리가 어디서 끊겼든 떼어 낸다.
            let text = line.trimmingCharacters(in: .whitespaces) + " "
            func head(_ text: Substring, cuts: [String]) -> String {
                var out = String(text)
                for cut in cuts { if let range = out.range(of: cut) { out = String(out[..<range.lowerBound]) } }
                return out.trimmingCharacters(in: .whitespaces)
            }
            if text.hasPrefix("Set model to ") {
                // "Set model to Opus 5.5 for this session only with xhigh effort" (선택창)
                // "Set model to Opus 5.5 and saved as your default for new sessions" (명령)
                let rest = text.dropFirst("Set model to ".count)
                model = head(rest, cuts: [" for this session", " and ", " with ", " ("])
                // effort 가 그대로면 claude 는 effort 를 말하지 않는다 — 그때는 선택창에서 맞춘 값(프리셋)이 맞다.
                if let with = rest.range(of: " with "), let end = rest[with.upperBound...].range(of: " effort") {
                    effort = String(rest[with.upperBound..<end.lowerBound])
                }
            } else if text.hasPrefix("Kept model as ") {
                // 모델도 effort 도 이미 그 값이었다.
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

    /// 에이전트가 결과를 화면으로 확인해 줬는가(`summary` 가 보낸 값이 아니라 확인된 값인가).
    public var confirmed: Bool { !confirmations.isEmpty }

    private func nonEmpty(_ text: String?) -> String? {
        text.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// 단계별 소요 시간을 모은다(`slashcommand apply --trace`, 앱 기록). 측정 전에는 원인을 단정하지 않기 위한 것.
public final class Trace: @unchecked Sendable {
    public private(set) var events: [(label: String, ms: Int)] = []
    private let start = DispatchTime.now()
    private var last = DispatchTime.now()

    public init() {}

    /// 직전 기록 이후 흐른 시간을 `label` 로 남긴다.
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

/// 터미널 호출마다 시간을 재는 감싸개.
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
    /// claude 가 「Switch model?」을 묻고 있고 우리가 답하지 않기로 했을 때 불린다(인자는 모델 이름).
    /// 그 뒤로도 사용자가 고를 때까지 기다렸다가 나머지를 마무리한다.
    public var onAwaitingUser: ((String) -> Void)?
    public var config: SlashCommandConfig
    public var claudeDefaults: ClaudeDefaults
    public var codexModels: () throws -> CodexModels
    public var grokModels: () -> GrokModels
    public var grokDefaults: GrokDefaults
    public var cursorDefaults: CursorDefaults
    public var antigravityDefaults: AntigravityDefaults
    /// nil(기본)이면 전환할 때마다 «그 세션이 쓰는» 상태 폴더를 찾는다(`OpenCodeDefaults.resolve`).
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
        // 기본값을 지키지 않기로 했으면 어느 파일인지 알 필요가 없다.
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
            // 시험용: Orca 세션에서 화면이 늦게 따라오는 터미널(Ghostty)의 경로를 태운다.
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
        /// `steps` 가 선택창을 닫고 깨끗이 물러났을 때 대신 쓸 단계. 새 세션 기본값을 건드리므로 실행 뒤 되돌려야 한다.
        public let fallback: [Step]?
    }

    /// `slot`(1부터)번 프리셋의 그 에이전트 설정.
    public func preset(slot: Int, agent: Agent) throws -> AgentPreset {
        guard slot >= 1, slot <= config.slots.count else {
            throw SlashCommandError(loc("There is no preset %@ (there are %@).", slot, config.slots.count))
        }
        guard let preset = config.slots[slot - 1].preset(for: agent) else {
            throw SlashCommandError(loc("Preset %@ has no %@ entry.", slot, agent.displayName))
        }
        return preset
    }

    /// `slot` 은 1부터.
    public func plan(slot: Int, agent: Agent) throws -> Planned {
        let preset = try preset(slot: slot, agent: agent)
        let chosen = config.slots[slot - 1]
        switch agent {
        case .claude:
            // 선택창에서 「이 세션만」으로 확정하면 기본값을 건드리지 않는다. 선택창에 그 모델 행이 없을 때만 명령으로 한다.
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
            // 이 에이전트들은 단계 목록이 아니라 전용 드라이버(`GrokDriver`·`CursorDriver`·`AntigravityDriver`)가 화면을 보며 진행한다.
            return Planned(slot: chosen, preset: preset, steps: [], fallback: nil)
        }
    }

    /// 입력창이 보일 때만 보낸다 — 권한 확인 창 같은 것이 떠 있으면 우리가 보낸 Enter 가 그 창을 승인해 버린다.
    /// 화면과 초안은 한 번에 읽는다.
    private func readyScreen(_ io: TerminalIO, target: Target) throws -> ScreenSnapshot {
        // 낡은 화면으로 판단하면 방금 뜬 창을 못 본다 — 반드시 지금 화면으로 본다.
        guard let screen = io.freshSnapshot() else {
            throw SlashCommandError(Switcher.unreadable(target.host))
        }
        guard Readiness.inputVisible(agent: target.agent, screen: screen.lines) else {
            throw SlashCommandError(loc("Not switched: the %@ input box is not visible. If a permission prompt or a picker is showing, deal with that first.", target.agent.displayName))
        }
        return screen
    }

    /// `deferFinalCheck` 가 참이면 기본값을 한 번만 되돌리고 돌아온다 — 호출한 쪽이 알림을 띄운 뒤 `verifyRestore` 를 부른다.
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
        // codex 는 쓰던 글을 한 줄까지만 치웠다 되돌릴 수 있다. 여러 줄이면 남은 줄이 명령과 섞이므로 손대지 않는다.
        if target.agent == .codex, let draft = first.draft, draft.contains("\n") {
            throw SlashCommandError(loc("Not switched: there is a multi-line draft in the Codex input box. Send or clear it, then press again."))
        }

        let traced = trace
        let timedSleep: (Int) -> Void = { ms in self.sleep(ms); traced?.mark("wait(\(ms))") }
        // 화면이 늦게 따라오는 터미널(Ghostty)에서 claude 선택창은 단계마다 0.5초씩 걸린다(실측 2.4~3.8초).
        // 거기서는 화면 대신 기본값 파일이 바뀌는 것을 신호로 삼는 명령 방식이 빠르다.
        if target.agent == .claude, io.screenLagMs > 0, planned.fallback != nil {
            return try applyCommands(planned, io: io, target: target, screen: first, sleep: timedSleep, deferFinalCheck: deferFinalCheck)
        }
        do {
            var asked = false
            var runner = Runner(io: io, sleep: timedSleep, initial: first)
            runner.onAwaitingUser = { model in asked = true; self.onAwaitingUser?(model) }
            let confirmations = try runner.run(planned.steps)
            // 확인 창에서 「No, go back」을 고르면 claude 는 "Kept model as …" 만 남긴다.
            if asked, !confirmations.contains(where: { $0.hasPrefix("Set model to") }) { throw Runner.declined() }
            return SwitchResult(target: target, slotName: planned.slot.name, preset: planned.preset,
                                warning: nil, confirmations: confirmations, pendingRestore: nil)
        } catch let error as SlashCommandError where error.cleanlyAborted && planned.fallback != nil {
            // 선택창을 닫고 입력창으로 돌아왔다. 아무것도 바뀌지 않았으니 명령으로 다시 한다.
            trace?.mark("command instead of picker (\(error.message))")
        }
        return try applyCommands(planned, io: io, target: target, screen: try readyScreen(io, target: target),
                                 sleep: timedSleep, deferFinalCheck: deferFinalCheck)
    }

    /// 모델은 그대로 두고 effort 만 한 단계 올리거나 내린다.
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
            // 지금 모델과 effort 는 선택창을 열어야 안다 — 열고, 한 칸 옮기고, 이 세션만으로 확정한다.
            steps = Plans.claudeEffortStep(up: up, saveAsDefault: !config.keepDefaults, acceptSwitch: config.acceptSwitchPrompt)
            preset = AgentPreset(model: "claude", effort: up ? loc("one level up") : loc("one level down"))
        case .codex:
            if let draft = first.draft, draft.contains("\n") {
                throw SlashCommandError(loc("Nothing was changed: there is a multi-line draft in the Codex input box. Send or clear it, then press again."))
            }
            steps = Plans.codexEffortStep(up: up)
            preset = AgentPreset(model: "codex", effort: up ? loc("one level up") : loc("one level down"))
        case .grok, .cursor, .antigravity, .opencode:
            return try stepEffort(up: up, on: target)   // 위에서 처리했다(도달하지 않는다)
        }
        var runner = Runner(io: io, sleep: timedSleep, initial: first)
        runner.onAwaitingUser = onAwaitingUser
        let confirmations = try runner.run(steps)
        return SwitchResult(target: target, slotName: "", preset: preset,
                            warning: nil, confirmations: confirmations, pendingRestore: nil)
    }

    /// claude 의 `/model X`·`/effort Y` 명령으로 전환한다. 둘 다 새 세션 기본값까지 바꾸므로 전환 전 값으로 되돌린다.
    private func applyCommands(_ planned: Planned, io: TerminalIO, target: Target, screen: ScreenSnapshot,
                               sleep timedSleep: @escaping (Int) -> Void, deferFinalCheck: Bool) throws -> SwitchResult {
        let before = config.keepDefaults ? claudeDefaults.snapshot() : nil
        var runner = Runner(io: io, sleep: timedSleep, stamp: { claudeDefaults.stamp() }, initial: screen)
        runner.onAwaitingUser = onAwaitingUser
        let confirmations: [String]
        do {
            confirmations = try runner.run(planned.fallback ?? [])
        } catch var error as SlashCommandError where error.awaitingUser {
            // 기다리는 동안 답이 없었다. 나중에 Yes 를 고르면 claude 가 그때 기본값을 쓰고, 우리는 이미 손을 뗀 뒤다 — 있는 그대로 알린다.
            error = SlashCommandError(error.message + " " + loc("If you confirm now, this model also becomes the default for new sessions and the effort has to be set separately (cancel and press again to get both)."))
            error.awaitingUser = true
            throw error
        } catch {
            // 도중에 멈췄어도 앞 명령은 이미 기본값을 바꿨을 수 있다 — 되돌리고 나서 실패를 알린다.
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
            // 마지막 명령의 결과 줄을 확인했으니 파일은 이미 써졌다. 바로 되돌리고, 늦게 오는 쓰기에 대비해 한 번 더 본다.
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

    /// 잠깐 기다린 뒤 기본값이 원래대로인지 다시 보고, 아니면 되돌린다. 되돌리지 못하면 사유를 돌려준다.
    public func verifyRestore(_ before: Data) -> String? {
        sleep(250)
        trace?.mark("wait(250)")
        if case .failed(let reason) = claudeDefaults.restore(to: before) {
            return loc("Could not put back the default for new sessions: %@", reason)
        }
        return nil
    }
}

/// 단계 목록을 터미널에 실행한다.
public struct Runner {
    public let io: TerminalIO
    public let sleep: (Int) -> Void
    /// 외부 신호(claude 기본값 파일의 수정 시각). 없으면 화면만 본다.
    public let stamp: (() -> Int64?)?
    /// 실행 전 화면. 쓰던 글과, 이미 떠 있던 결과 줄을 여기서 안다.
    public let initial: ScreenSnapshot?

    /// claude 의 「Switch model?」 창에 우리가 답하지 않을 때 불린다. 사용자가 고를 때까지 `awaitUserMs` 동안 기다린다.
    public var onAwaitingUser: ((String) -> Void)?
    static let awaitUserMs = 20_000

    /// 화면을 마지막으로 읽은 뒤 흐른 시간. 화면이 늦게 따라오는 터미널에서 「지금 읽으면 새 화면인가」를 아는 데 쓴다.
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

    /// 낡지 않은 화면을 읽는다: 마지막으로 읽은 뒤 터미널의 지연 시간이 지날 때까지 기다렸다 읽는다.
    private func freshSnapshot() -> ScreenSnapshot? {
        let remaining = io.screenLagMs - clock.elapsedMs()
        if remaining > 0 { sleep(remaining) }
        defer { clock.reset() }
        return io.snapshot()
    }

    /// 돌려주는 값은 `expectResult` 가 본 결과 줄들.
    @discardableResult
    public func run(_ steps: [Step]) throws -> [String] {
        var armedStamp: Int64?
        var armedLines: [String] = []
        // 마지막으로 본 화면. `arm` 이 이것을 「명령 전 상태」로 잡는다.
        var seenLines = initial?.lines ?? []
        var confirmations: [String] = []
        // 화면을 보지 않고(기본값 파일 신호만으로) 넘어간 결과들 — 끝나고 화면에서 문구를 찾는다.
        var unseen: [(prefix: String, command: String?)] = []
        // 마지막으로 친 명령 줄("/model sonnet"). 끝에 화면에서 그 명령과 답을 찾는 데 쓴다.
        var typedCommand: String?
        // `stepEffort` 가 옮겨 놓은 단계. 확인 창이 «그 단계»를 물을 때만 받아들이는 데 쓴다.
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
                    // 창이 낮으면 선택창의 맨 아래 안내 줄이 잘려, 열려 있는데도 알아보지 못한다. 머리말과 커서 행이 보이면 그 선택창이다 —
                    // 열어 둔 채 끝내지 않고 닫는다(전에는 «열리지 않았다» 고 하고 선택창을 남겼다 — 2026-10-12 실측).
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
                    // 선택창이 닫힌 뒤의 결과 줄에 effort 가 안 나오는 경우에 대비해 여기서 본 값을 남긴다.
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
                    // 「No, go back」은 선택창으로 되돌아간다 — 선택창을 닫고, 바꾸지 않았다고 알린다.
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
            // 기본값 파일은 다른 claude 세션도 쓴다 — 파일이 바뀐 것만으로는 «우리 명령»이 실행됐다고 할 수 없다.
            // 끝에 새 화면을 한 번 읽어, 이번에 생긴 결과 줄이 «보일 때만» 성공으로 친다.
            guard let snap = freshSnapshot() else { throw SlashCommandError(loc("Could not read the terminal screen, so the result could not be checked.")) }
            let before = initial?.lines ?? []
            for (prefix, command) in unseen {
                let now = ClaudeScreen.results(snap.lines, prefix: prefix)
                if Runner.isNew(now, since: ClaudeScreen.results(before, prefix: prefix)), let found = now.last {
                    confirmations.append(found)
                } else if let command, let reply = ClaudeScreen.reply(toCommand: command, in: snap.lines), reply.hasPrefix(prefix) {
                    // 같은 전환을 되풀이해 줄 수가 그대로여도, 우리가 친 그 명령 아래에 그 답이 있다.
                    confirmations.append(reply)
                } else {
                    throw SlashCommandError(loc("The command was sent, but Claude Code's result line (%@ …) is not on screen. Check on screen whether it changed.", prefix))
                }
            }
        }
        return confirmations
    }

    /// 화면이 늦게 따라오는 터미널(Ghostty)용: 명령이 실행되면 claude 가 기본값 파일을 다시 쓰는 것을 신호로 삼는다.
    /// 화면은 낡지 않았을 때만 읽어, 확인 창이 떴는지와 claude 가 거절했는지를 본다.
    ///
    /// 돌려주는 값: 파일 신호로 넘어갔으면 nil(결과 문구는 아직 못 봤다), 화면에서 새 결과 줄을 봤으면 그 줄.
    /// 파일을 다시 쓰지 않는 명령도 있다 — `/effort max` 는 이 세션에만 적용되고 기본값 파일은 그대로다(2.1.283 실측).
    private func waitForStamp(prefix: String, command: String?, acceptSwitchTo: [String], armedStamp: Int64?, armedLines: [String],
                              timeoutMs: Int, failure: String) throws -> String? {
        let started = DispatchTime.now()
        var simulated = 0
        var accepted = false
        let repliedBefore = ClaudeScreen.commandReply(armedLines, command: command)
        let matchedBefore = ClaudeScreen.results(armedLines, prefix: prefix)
        // 확인 창이 떠서 사용자의 선택을 기다리는 중이면 그 모델 이름. 창이 사라진 시각도 본다.
        var awaiting: String?
        var goneAt: Int?
        var deadline = timeoutMs
        while true {
            if (stamp?() ?? nil) != armedStamp {
                // 파일을 쓴 직후에 claude 가 쓰던 글을 입력창에 되돌린다. 다음 Ctrl+S 가 그것과 겹치지 않게 잠깐 둔다.
                sleep(120)
                clock.slept += 120
                return nil
            }
            let elapsed = max(Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000), simulated)
            if clock.elapsedMs() >= io.screenLagMs {
                guard let snap = io.snapshot() else { throw SlashCommandError(loc("Stopped: could not read the terminal screen.")) }
                clock.reset()
                // 파일은 안 바뀌었지만 화면에 이번 명령의 결과가 새로 떴다.
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
                    // 창이 사라졌다. Yes 였으면 곧 파일이 바뀐다. 조금 기다려도 안 바뀌면 No 였다.
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

    /// 명령 바로 아래에 붙은, 우리가 기다리던 것이 아닌 답.
    static func refused(_ reply: String) -> SlashCommandError {
        // 확인 창에서 취소하면 claude 는 "Kept model as …" 라고 남긴다 — 거절이 아니라 사용자의 선택이다.
        if reply.hasPrefix("Kept model as") { return declined() }
        return SlashCommandError(loc("Claude Code did not accept it: %@", reply.prefix(120)))
    }

    /// 사용자가 확인 창에서 「No, go back」을 골랐다.
    static func declined() -> SlashCommandError {
        var error = SlashCommandError(loc("Nothing was changed: the confirmation was cancelled."))
        error.nothingToDo = true
        return error
    }

    /// claude 가 모델을 바꿀지 묻고 있다 — 우리는 답하지 않고 사용자에게 넘긴다.
    static func awaitingSwitch(_ model: String) -> SlashCommandError {
        var error = SlashCommandError(loc("Claude Code is asking whether to switch to %@ (it re-reads the conversation). Press Enter to switch.", model))
        error.awaitingUser = true
        return error
    }

    /// claude 의 확인 창이 «우리가 고른 그 값»(모델 이름이나 effort 단계)으로 바꾸겠느냐고 묻고 있으면 Enter 로 받아들인다.
    /// 그 창이 아니거나 값이 다르면 아무것도 보내지 않는다.
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
        // 같은 문구가 명령 전부터 화면에 있었으면, 그 줄이 «새로 생겼거나» 기본값 파일이 «변했을» 때만 이번 명령의 결과로 친다.
        let matchedBefore = ClaudeScreen.results(armedLines, prefix: prefix)
        let repliedBefore = ClaudeScreen.commandReply(armedLines, command: command)
        let saidBefore = ClaudeScreen.lastResult(armedLines)
        // 초안을 따로 주는 터미널(Orca)은 그 값을, 아니면 화면의 입력창 줄을 본다.
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
            // 입력창이 다시 «보임» — 다음 명령의 Enter 가 그 사이 뜬 확인 창을 누르지 않게 한다.
            let promptBack = Readiness.claudePromptVisible(snap.lines)
            // 쓰던 글이 있었으면 그것이 입력창에 «돌아왔음». 그 사이 사용자가 더 쳤을 수 있어 같은지는 따지지 않는다.
            let draftBack = draftBefore.isEmpty || !draft(snap).isEmpty
            if let result = matched.last, fresh, promptBack, draftBack {
                return (result, snap.lines)
            }
            // 명령 바로 아래에 다른 답이 붙었으면(예: Model 'x' not found) 기다릴 것 없이 그 말로 끝낸다.
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
                // 창이 사라졌는데 결과가 안 온다 — 「No, go back」이었다.
                if let gone = goneAt, elapsed - gone >= 700 { throw Runner.declined() }
                goneAt = goneAt ?? elapsed
            }
            if elapsed >= deadline, let awaiting { throw Runner.awaitingSwitch(awaiting) }
            if elapsed >= deadline {
                // claude 가 새로 뭐라고 했으면(예: Model 'x' not found) 그 말을 붙인다.
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

    /// 그 줄들 가운데 `needle` 이 있는가. 좁은 칸에서는 한 줄이 둘로 접힌다(38칸의 codex: `/model  choose what model and` / `reasoning effort to use`
    /// — 2026-10-12 iTerm2 의 나뉜 칸에서 실측) — 이웃한 두 줄을 이은 글에서도 찾는다.
    static func contains(_ needle: String, in lines: [String]) -> Bool {
        if lines.contains(where: { $0.contains(needle) }) { return true }
        func words(_ text: String) -> String { text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
        return zip(lines, lines.dropFirst()).contains { words($0 + " " + $1).contains(needle) }
    }

    /// 화면이 `condition` 을 만족할 때까지 다시 읽는다. 시간 안에 만족하면 참.
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

    /// 화면 읽기는 싸다(Orca 1ms 안쪽). 짧게 자주 본다.
    static let pollMs = 30

    // MARK: 선택창

    /// 정리 단계를 실행하고, 선택창이 닫혀 입력창으로 돌아온 것을 확인했으면 「깨끗이 물러난」 실패로 표시한다.
    private func aborted(_ abort: [Step], _ failure: String) throws -> SlashCommandError {
        _ = try? run(abort)
        var error = SlashCommandError(failure)
        if let lines = io.screen(), !Picker.isOpen(lines),
           Readiness.claudePromptVisible(lines) || Readiness.codexComposerVisible(lines) {
            error.cleanlyAborted = true
        }
        return error
    }

    /// `label` 행에 커서를 둔다. 성공하면 참.
    private func selectRow(label: String, via: String?, timeoutMs: Int) throws -> Bool {
        // 목록이 그려질 때까지만 기다린다. 그려졌는데 그 행이 없으면 더 기다려도 생기지 않는다.
        var rows: [Picker.Row] = []
        guard try poll(timeoutMs: timeoutMs, { lines in
            rows = Picker.rows(lines)
            return !rows.isEmpty
        }) else { return false }
        let found = Picker.index(of: label, in: rows) != nil
        guard found || (via.map { Picker.index(of: $0, in: rows) != nil } ?? false) else {
            // 창이 낮으면 행이 한두 개만 보이고 나머지는 `… +9 models` 로 접힌다(2026-10-11 실측, 90×14 의 claude) —
            // 커서를 한 칸씩 옮겨 그 행을 찾는다. 못 찾으면 전처럼 실패다(그러면 명령 방식으로 간다).
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

    /// 접혀서 보이지 않는 행을 찾는다: 커서를 맨 위(1번)로 올린 뒤 한 칸씩 내려가며 그 행이 화면에 나타나는지 본다.
    /// 위에서부터 보는 이유: 이름은 앞머리로 맞추므로("opus" → `Opus 5.5`) 같은 앞머리의 행이 여럿이다 — 높은 창에서 고르는 것은 그중 맨 위다.
    /// (2026-10-11 실측: 지금 자리에서 아래로만 찾았더니 `Opus 5.5` 대신 그 아래의 `Opus 5` 를 골랐다.)
    /// 맨 위에 닿지 못하면 찾지 않는다. 고르는 키(Enter·s)는 보내지 않는다.
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

    /// 커서가 `label` 행에 올 때까지: 화면에서 커서 행을 읽고, 차이만큼 위·아래를 보내고, 커서가 «도착함»을 본다.
    private func moveCursor(to label: String, timeoutMs: Int) throws -> Bool {
        for _ in 0..<4 {
            guard let lines = io.screen() else { throw SlashCommandError(loc("Stopped: could not read the terminal screen.")) }
            let rows = Picker.rows(lines)
            guard let target = Picker.index(of: label, in: rows),
                  let cursor = rows.firstIndex(where: \.selected) else { return false }
            if target == cursor { return true }
            let key = target > cursor ? Key.down : Key.up
            try io.type(String(repeating: key.bytes, count: abs(target - cursor)))
            // 화면이 따라오기 전에 다시 계산하면 두 번 움직인다 — 도착을 보고 넘어간다.
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
        /// effort 가 없는 모델(Haiku). 화면의 안내 줄을 그대로 들고 온다.
        case unsupported(String)
        case failed
    }

    /// claude 선택창의 effort 줄을 `level` 로 맞춘다. → 한 번에 한 단계, 끝에서 처음으로 돈다.
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
        var presses = 0
        while let now = current, now != wanted {
            guard presses < 8 else { return .failed }   // 한 바퀴를 돌아도 없으면 그 모델에 없는 단계다
            try io.press(.right)
            presses += 1
            let moved = try poll(timeoutMs: min(timeoutMs, 1000)) { lines in
                current = Picker.claudeEffort(lines)
                return current != nil && current != now
            }
            if !moved { return .failed }
        }
        return current == wanted ? .set : .failed
    }

    enum StepOutcome {
        case moved(String)
        /// 바꾸지 않았다. `atEdge` 면 이미 끝 단계라 바꿀 것이 없었던 것이다.
        case stopped(String, atEdge: Bool = false)
    }

    /// claude 선택창의 effort 를 한 칸 옮긴다. 끝에서 누르면 반대쪽 끝으로 돌기 때문에, 끝이면 누르지 않는다.
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
        // 단계가 적은 모델에서는 우리가 아는 끝보다 먼저 돈다. 반대쪽으로 넘어갔으면 되돌리고 끝이라고 알린다.
        if let from = order.firstIndex(of: now), let to = order.firstIndex(of: after), (to > from) != up {
            try io.press(up ? .left : .right)
            _ = try poll(timeoutMs: min(timeoutMs, 1000)) { Picker.claudeEffort($0) == now }
            return .stopped(up ? loc("Already at the highest level (%@).", now) : loc("Already at the lowest level (%@).", now), atEdge: true)
        }
        return .moved(after)
    }

    /// codex effort 목록에서 `(current)` 행의 바로 위(effort 내림)·아래(effort 올림) 행에 커서를 둔다.
    /// 목록은 Low … Extra high 다음에 「More reasoning…」이 있고, 그 아래 목록에 Max · Ultra 가 있다.
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
            // 지금 값이 이 목록(Low … Extra high)에 있다.
            guard let at = plain.firstIndex(of: current) else { return .stopped(loc("Could not read the Codex effort list.")) }
            if !up {
                guard at > 0 else { return edge(rows[current].label) }
                return try moveCursor(to: rows[plain[at - 1]].label, timeoutMs: timeoutMs) ? .moved(rows[plain[at - 1]].label) : .stopped(loc("Could not move the cursor in the Codex effort list."))
            }
            if at + 1 < plain.count {
                return try moveCursor(to: rows[plain[at + 1]].label, timeoutMs: timeoutMs) ? .moved(rows[plain[at + 1]].label) : .stopped(loc("Could not move the cursor in the Codex effort list."))
            }
            // 이 목록의 마지막이다 — 다음 단계는 More reasoning… 아래의 첫 행이다.
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

        // 지금 값이 More reasoning… 아래(Max · Ultra)에 있다.
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
        // 아래 목록의 첫 행이다 — 한 단계 아래는 바깥 목록의 마지막 행(Extra high)이다.
        guard let last = plain.last else { return edge(inner[at].label) }
        try io.press(.escape)
        guard try poll(timeoutMs: timeoutMs, { Picker.open($0)?.header.hasPrefix("Select Reasoning Level") == true }) else {
            return .stopped(loc("Could not get back to the Codex effort list."))
        }
        return try moveCursor(to: rows[last].label, timeoutMs: timeoutMs) ? .moved(rows[last].label) : .stopped(loc("Could not move the cursor in the Codex effort list."))
    }

    /// 선택창이 닫히고 입력창이 다시 보일 때까지 기다린다.
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
            // 받아들이지 않기로 한 확인 창이면 사용자에게 알리고, 고를 때까지 기다린다.
            let asking = ClaudeScreen.switchPrompt(snap.lines)
            if !accepted, !awaiting, let asking {
                awaiting = true
                onAwaitingUser?(asking)
                deadline = Runner.awaitUserMs
            }
            // 확인 창이 사라지고 선택창이 다시 보이면 사용자가 「No, go back」을 고른 것이다.
            if awaiting, asking == nil, Picker.isOpen(snap.lines) { return .declined }
            let real = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            if max(real, simulated) >= deadline { return .timedOut }
            sleep(Runner.pollMs)
            simulated += Runner.pollMs
        }
    }

    /// 선택창이 보이는 동안만 Esc 를 누른다. 누를 때마다 화면을 다시 읽는다.
    private func closePicker() throws {
        for _ in 0..<4 {
            guard let lines = io.screen() else { return }
            let before = Picker.rows(lines)
            guard !before.isEmpty else { return }
            try io.press(.escape)
            _ = try poll(timeoutMs: 800) { Picker.rows($0) != before }
        }
    }

    /// 화면에서 `prefix` 로 시작하는 줄들(위에서 아래). 줄 머리의 `•`(codex)·`⎿`(claude) 는 뗀다.
    static func matching(_ lines: [String], prefix: String) -> [String] {
        lines.compactMap { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("•") || text.hasPrefix("⎿") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return text.hasPrefix(prefix) ? text : nil
        }
    }

    /// `before` 이후에 줄이 새로 생겼는가: 개수가 늘었거나 마지막 줄이 달라졌다.
    static func isNew(_ now: [String], since before: [String]) -> Bool {
        !now.isEmpty && (now.count > before.count || now.last != before.last)
    }
}
