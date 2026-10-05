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

/// 단계별 소요 시간을 모은다(`modelswitch apply --trace`, 앱 기록). 측정 전에는 원인을 단정하지 않기 위한 것.
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
        events.map { "\($0.label) \($0.ms)ms" }.joined(separator: " · ") + " · 합계 \(totalMs)ms"
    }
}

/// 터미널 호출마다 시간을 재는 감싸개.
struct TracingIO: TerminalIO {
    let base: TerminalIO
    let trace: Trace

    func type(_ text: String) throws { try base.type(text); trace.mark("입력") }
    func press(_ key: Key) throws { try base.press(key); trace.mark("키(\(key))") }
    func screen() -> [String]? { let r = base.screen(); trace.mark("화면읽기"); return r }
    func draft() -> String? { let r = base.draft(); trace.mark("초안읽기"); return r }
    func snapshot() -> ScreenSnapshot? { let r = base.snapshot(); trace.mark("화면읽기"); return r }
    var screenLagMs: Int { base.screenLagMs }
    func freshSnapshot() -> ScreenSnapshot? { let r = base.freshSnapshot(); trace.mark("새화면읽기"); return r }
}

public struct Switcher {
    public var trace: Trace?
    public var config: ModelSwitchConfig
    public var claudeDefaults: ClaudeDefaults
    public var codexModels: () throws -> CodexModels
    public var makeIO: (Target) throws -> TerminalIO
    public var sleep: (Int) -> Void

    public init(config: ModelSwitchConfig,
                claudeDefaults: ClaudeDefaults = ClaudeDefaults(),
                codexModels: @escaping () throws -> CodexModels = { try CodexModels.load() },
                makeIO: @escaping (Target) throws -> TerminalIO = Switcher.terminalIO,
                sleep: @escaping (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1000) }) {
        self.config = config
        self.claudeDefaults = claudeDefaults
        self.codexModels = codexModels
        self.makeIO = makeIO
        self.sleep = sleep
    }

    public static func terminalIO(for target: Target) throws -> TerminalIO {
        switch target.host {
        case .ghostty(let terminalID):
            return GhosttyIO(terminalID: terminalID)
        case .orca(let handle):
            let io = OrcaIO(orca: Proc.locate("orca"), handle: handle)
            // 시험용: Orca 세션에서 화면이 늦게 따라오는 터미널(Ghostty)의 경로를 태운다.
            if let lag = ProcessInfo.processInfo.environment["MODELSWITCH_SCREEN_LAG_MS"].flatMap(Int.init), lag > 0 {
                return LaggingIO(base: io, lagMs: lag)
            }
            return io
        }
    }

    static func unreadable(_ host: TerminalHost) -> String {
        switch host {
        case .ghostty:
            return "Ghostty 화면을 읽지 못해 전환하지 않았습니다. 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 ModelSwitch 를 허용해 주세요."
        case .orca:
            return "Orca 터미널 화면을 읽지 못해 전환하지 않았습니다."
        }
    }

    public struct Planned {
        public let slot: Slot
        public let preset: AgentPreset
        public let steps: [Step]
        /// `steps` 가 선택창을 닫고 깨끗이 물러났을 때 대신 쓸 단계. 새 세션 기본값을 건드리므로 실행 뒤 되돌려야 한다.
        public let fallback: [Step]?
    }

    /// `slot` 은 1부터.
    public func plan(slot: Int, agent: Agent) throws -> Planned {
        guard slot >= 1, slot <= config.slots.count else {
            throw ModelSwitchError("\(slot)번 프리셋이 없습니다(지금 \(config.slots.count)개).")
        }
        let chosen = config.slots[slot - 1]
        guard let preset = chosen.preset(for: agent) else {
            throw ModelSwitchError("\(slot)번 프리셋에는 \(agent.rawValue) 설정이 없습니다.")
        }
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
        }
    }

    /// 입력창이 보일 때만 보낸다 — 권한 확인 창 같은 것이 떠 있으면 우리가 보낸 Enter 가 그 창을 승인해 버린다.
    /// 화면과 초안은 한 번에 읽는다.
    private func readyScreen(_ io: TerminalIO, target: Target) throws -> ScreenSnapshot {
        // 낡은 화면으로 판단하면 방금 뜬 창을 못 본다 — 반드시 지금 화면으로 본다.
        guard let screen = io.freshSnapshot() else {
            throw ModelSwitchError(Switcher.unreadable(target.host))
        }
        guard Readiness.inputVisible(agent: target.agent, screen: screen.lines) else {
            throw ModelSwitchError("\(target.agent.rawValue) 입력창이 보이지 않아 전환하지 않았습니다. 권한 확인 창이나 선택창이 떠 있으면 먼저 처리해 주세요.")
        }
        return screen
    }

    /// `deferFinalCheck` 가 참이면 기본값을 한 번만 되돌리고 돌아온다 — 호출한 쪽이 알림을 띄운 뒤 `verifyRestore` 를 부른다.
    public func apply(slot: Int, to target: Target, deferFinalCheck: Bool = false) throws -> SwitchResult {
        trace?.mark("준비")
        let planned = try plan(slot: slot, agent: target.agent)
        trace?.mark("계획")
        let raw = try makeIO(target)
        let io: TerminalIO = trace.map { TracingIO(base: raw, trace: $0) } ?? raw

        let first = try readyScreen(io, target: target)
        // codex 는 쓰던 글을 한 줄까지만 치웠다 되돌릴 수 있다. 여러 줄이면 남은 줄이 명령과 섞이므로 손대지 않는다.
        if target.agent == .codex, let draft = first.draft, draft.contains("\n") {
            throw ModelSwitchError("codex 입력창에 여러 줄 초안이 있어 전환하지 않았습니다. 먼저 보내거나 지운 뒤 다시 눌러 주세요.")
        }

        let traced = trace
        let timedSleep: (Int) -> Void = { ms in self.sleep(ms); traced?.mark("대기(\(ms))") }
        // 화면이 늦게 따라오는 터미널(Ghostty)에서 claude 선택창은 단계마다 0.5초씩 걸린다(실측 2.4~3.8초).
        // 거기서는 화면 대신 기본값 파일이 바뀌는 것을 신호로 삼는 명령 방식이 빠르다.
        if target.agent == .claude, io.screenLagMs > 0, planned.fallback != nil {
            return try applyCommands(planned, io: io, target: target, screen: first, sleep: timedSleep, deferFinalCheck: deferFinalCheck)
        }
        do {
            let confirmations = try Runner(io: io, sleep: timedSleep, initial: first).run(planned.steps)
            return SwitchResult(target: target, slotName: planned.slot.name, preset: planned.preset,
                                warning: nil, confirmations: confirmations, pendingRestore: nil)
        } catch let error as ModelSwitchError where error.cleanlyAborted && planned.fallback != nil {
            // 선택창을 닫고 입력창으로 돌아왔다. 아무것도 바뀌지 않았으니 명령으로 다시 한다.
            trace?.mark("선택창 대신 명령으로(\(error.message))")
        }
        return try applyCommands(planned, io: io, target: target, screen: try readyScreen(io, target: target),
                                 sleep: timedSleep, deferFinalCheck: deferFinalCheck)
    }

    /// claude 의 `/model X`·`/effort Y` 명령으로 전환한다. 둘 다 새 세션 기본값까지 바꾸므로 전환 전 값으로 되돌린다.
    private func applyCommands(_ planned: Planned, io: TerminalIO, target: Target, screen: ScreenSnapshot,
                               sleep timedSleep: @escaping (Int) -> Void, deferFinalCheck: Bool) throws -> SwitchResult {
        let before = config.keepDefaults ? claudeDefaults.snapshot() : nil
        let runner = Runner(io: io, sleep: timedSleep, stamp: { claudeDefaults.stamp() }, initial: screen)
        let confirmations: [String]
        do {
            confirmations = try runner.run(planned.fallback ?? [])
        } catch var error as ModelSwitchError where error.awaitingUser {
            // 사용자가 확인 창에서 Yes 를 고르면 claude 가 그때 기본값을 쓴다 — 지금 되돌려 봐야 소용없다. 있는 그대로 알린다.
            error = ModelSwitchError(error.message + " 이 모델은 선택창에 없어 명령으로 바꾸는 중이라, 확정하면 새 세션 기본값도 이 모델이 되고 effort 는 따로 맞춰야 합니다.")
            error.awaitingUser = true
            throw error
        } catch {
            // 도중에 멈췄어도 앞 명령은 이미 기본값을 바꿨을 수 있다 — 되돌리고 나서 실패를 알린다.
            if let before {
                timedSleep(300)
                _ = claudeDefaults.restore(to: before)
                trace?.mark("기본값복원")
            }
            throw error
        }

        var warning: String?
        var pending: Data?
        if let before {
            // 마지막 명령의 결과 줄을 확인했으니 파일은 이미 써졌다. 바로 되돌리고, 늦게 오는 쓰기에 대비해 한 번 더 본다.
            if case .failed(let reason) = claudeDefaults.restore(to: before) {
                warning = "새 세션 기본값을 되돌리지 못했습니다: \(reason)"
            }
            trace?.mark("기본값복원")
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
        trace?.mark("대기(250)")
        if case .failed(let reason) = claudeDefaults.restore(to: before) {
            return "새 세션 기본값을 되돌리지 못했습니다: \(reason)"
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
        var unseen: [String] = []
        for step in steps {
            switch step {
            case .text(let text):
                try io.type(text)
            case .key(let key):
                try io.press(key)
            case .wait(let ms):
                sleep(ms)
            case .expect(let needle, let timeoutMs, let abort, let failure):
                if try !waitFor(needle, timeoutMs: timeoutMs) {
                    _ = try? run(abort)
                    throw ModelSwitchError(failure)
                }
            case .arm:
                armedStamp = stamp?() ?? nil
                armedLines = io.screen() ?? seenLines
            case .expectResult(let prefix, let command, let acceptSwitchTo, let timeoutMs, let failure):
                if io.screenLagMs > 0, stamp != nil {
                    try waitForStamp(prefix: prefix, command: command, acceptSwitchTo: acceptSwitchTo, armedStamp: armedStamp,
                                     armedLines: armedLines, timeoutMs: timeoutMs, failure: failure)
                    unseen.append(prefix)
                } else {
                    let found = try waitForResult(prefix: prefix, command: command, acceptSwitchTo: acceptSwitchTo,
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
            case .expectInput(let agent, let acceptSwitchTo, let timeoutMs, let abort, let failure):
                if try !waitForInput(agent: agent, acceptSwitchTo: acceptSwitchTo, timeoutMs: timeoutMs) {
                    if let asking = io.screen().flatMap(ClaudeScreen.switchPrompt) { throw Runner.awaitingSwitch(asking) }
                    _ = try? run(abort)
                    throw ModelSwitchError(failure)
                }
            case .closePicker:
                try closePicker()
            case .capture(let prefix):
                // `arm` 뒤에 새로 생긴 줄만 결과로 친다 — 예전 전환의 줄이 화면에 남아 있을 수 있다.
                if let lines = io.screen() {
                    let now = Runner.matching(lines, prefix: prefix)
                    if Runner.isNew(now, since: Runner.matching(armedLines, prefix: prefix)), let found = now.last {
                        confirmations.append(found)
                    }
                }
            }
        }
        if !unseen.isEmpty, let snap = freshSnapshot() {
            let before = initial?.lines ?? []
            for prefix in unseen {
                let now = ClaudeScreen.results(snap.lines, prefix: prefix)
                if Runner.isNew(now, since: ClaudeScreen.results(before, prefix: prefix)), let found = now.last {
                    confirmations.append(found)
                }
            }
        }
        return confirmations
    }

    /// 화면이 늦게 따라오는 터미널(Ghostty)용: 명령이 실행되면 claude 가 기본값 파일을 다시 쓰는 것을 신호로 삼는다.
    /// 화면은 낡지 않았을 때만 읽어, 확인 창이 떴는지와 claude 가 거절했는지를 본다.
    private func waitForStamp(prefix: String, command: String?, acceptSwitchTo: String?, armedStamp: Int64?, armedLines: [String],
                              timeoutMs: Int, failure: String) throws {
        let started = DispatchTime.now()
        var simulated = 0
        var accepted = false
        let repliedBefore = ClaudeScreen.commandReply(armedLines, command: command)
        while true {
            if (stamp?() ?? nil) != armedStamp {
                // 파일을 쓴 직후에 claude 가 쓰던 글을 입력창에 되돌린다. 다음 Ctrl+S 가 그것과 겹치지 않게 잠깐 둔다.
                sleep(120)
                clock.slept += 120
                return
            }
            if clock.elapsedMs() >= io.screenLagMs {
                guard let snap = io.snapshot() else { throw ModelSwitchError("터미널 화면을 읽지 못해 중단했습니다.") }
                clock.reset()
                if command != nil, let reply = ClaudeScreen.commandReply(snap.lines, command: command),
                   reply != repliedBefore, !reply.hasPrefix(prefix), Readiness.claudePromptVisible(snap.lines) {
                    throw ModelSwitchError("claude 가 받아들이지 않았습니다: \(reply.prefix(120))")
                }
                if !accepted, try acceptSwitch(snap.lines, to: acceptSwitchTo) { accepted = true }
                if !accepted, let asking = ClaudeScreen.switchPrompt(snap.lines) { throw Runner.awaitingSwitch(asking) }
            }
            let real = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            if max(real, simulated) >= timeoutMs { throw ModelSwitchError(failure) }
            sleep(15)
            simulated += 15
            clock.slept += 15
        }
    }

    /// claude 가 모델을 바꿀지 묻고 있다 — 우리는 답하지 않고 사용자에게 넘긴다.
    static func awaitingSwitch(_ model: String) -> ModelSwitchError {
        var error = ModelSwitchError("claude 가 \(model) 로 바꿀지 묻고 있습니다(대화 기록을 새 모델로 다시 읽습니다). Enter 를 누르면 바뀝니다.")
        error.awaitingUser = true
        return error
    }

    /// claude 의 「Switch model?」 확인 창이 «우리가 고른 그 모델»로 바꾸겠느냐고 묻고 있으면 Enter 로 받아들인다.
    /// 그 창이 아니거나 모델이 다르면 아무것도 보내지 않는다.
    private func acceptSwitch(_ lines: [String], to wanted: String?) throws -> Bool {
        guard let wanted, let asked = ClaudeScreen.switchPrompt(lines) else { return false }
        let row = Picker.Row(number: 1, label: asked, selected: true, current: false)
        guard Picker.index(of: wanted, in: [row]) != nil else { return false }
        try io.press(.enter)
        return true
    }

    private func waitForResult(prefix: String, command: String?, acceptSwitchTo: String?, armedStamp: Int64?, armedLines: [String],
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
        while true {
            guard let snap = io.snapshot() else { throw ModelSwitchError("터미널 화면을 읽지 못해 중단했습니다.") }
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
                throw ModelSwitchError("claude 가 받아들이지 않았습니다: \(reply.prefix(120))")
            }
            if !accepted, try acceptSwitch(snap.lines, to: acceptSwitchTo) { accepted = true }
            if !accepted, let asking = ClaudeScreen.switchPrompt(snap.lines) { throw Runner.awaitingSwitch(asking) }
            if elapsed >= timeoutMs {
                // claude 가 새로 뭐라고 했으면(예: Model 'x' not found) 그 말을 붙인다.
                let said = ClaudeScreen.lastResult(snap.lines)
                let detail = said.flatMap { $0 != saidBefore ? " (claude: \($0.prefix(80)))" : nil } ?? ""
                throw ModelSwitchError(failure + detail)
            }
            sleep(40)
            simulated += 40
        }
    }

    private func waitFor(_ needle: String, timeoutMs: Int) throws -> Bool {
        try poll(timeoutMs: timeoutMs) { lines in lines.contains { $0.contains(needle) } }
    }

    /// 화면이 `condition` 을 만족할 때까지 다시 읽는다. 시간 안에 만족하면 참.
    private func poll(timeoutMs: Int, _ condition: ([String]) -> Bool) throws -> Bool {
        let started = DispatchTime.now()
        var simulated = 0
        while true {
            guard let lines = io.screen() else { throw ModelSwitchError("터미널 화면을 읽지 못해 중단했습니다.") }
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
    private func aborted(_ abort: [Step], _ failure: String) throws -> ModelSwitchError {
        _ = try? run(abort)
        var error = ModelSwitchError(failure)
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
        guard found || (via.map { Picker.index(of: $0, in: rows) != nil } ?? false) else { return false }
        if !found, let via {
            guard try moveCursor(to: via, timeoutMs: timeoutMs) else { return false }
            try io.press(.enter)
            let entered = try poll(timeoutMs: timeoutMs) { Picker.index(of: label, in: Picker.rows($0)) != nil }
            guard entered else { return false }
        }
        return try moveCursor(to: label, timeoutMs: timeoutMs)
    }

    /// 커서가 `label` 행에 올 때까지: 화면에서 커서 행을 읽고, 차이만큼 위·아래를 보내고, 커서가 «도착함»을 본다.
    private func moveCursor(to label: String, timeoutMs: Int) throws -> Bool {
        for _ in 0..<4 {
            guard let lines = io.screen() else { throw ModelSwitchError("터미널 화면을 읽지 못해 중단했습니다.") }
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

    /// 선택창이 닫히고 입력창이 다시 보일 때까지 기다린다.
    private func waitForInput(agent: Agent, acceptSwitchTo: String?, timeoutMs: Int) throws -> Bool {
        func draft(_ snap: ScreenSnapshot) -> String {
            snap.draft ?? ClaudeScreen.promptText(snap.lines) ?? ""
        }
        let draftBefore = agent == .claude ? (initial.map(draft) ?? "") : ""
        let started = DispatchTime.now()
        var simulated = 0
        var accepted = false
        while true {
            guard let snap = io.snapshot() else { throw ModelSwitchError("터미널 화면을 읽지 못해 중단했습니다.") }
            let draftBack = draftBefore.isEmpty || !draft(snap).isEmpty
            if !Picker.isOpen(snap.lines), Readiness.inputVisible(agent: agent, screen: snap.lines), draftBack { return true }
            if !accepted, try acceptSwitch(snap.lines, to: acceptSwitchTo) { accepted = true }
            // 받아들이지 않기로 한 확인 창이 떠 있으면 시간 끝까지 기다릴 이유가 없다.
            if !accepted, ClaudeScreen.switchPrompt(snap.lines) != nil { return false }
            let real = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            if max(real, simulated) >= timeoutMs { return false }
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
