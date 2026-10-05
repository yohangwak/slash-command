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

    public var summary: String {
        "\(slotName) — \(preset.model) · \(preset.effort)"
    }

    /// 확인 문구에서 "… and saved as your default" 같은 꼬리를 떼어 알림에 쓸 만하게 줄인다.
    public var confirmationSummary: String? {
        guard !confirmations.isEmpty else { return nil }
        return confirmations.map { line in
            // 작업 중 알림 줄은 폭에 맞춰 잘려 온다("… Opus 5.5 and") — 꼬리가 어디서 끊겼든 떼어 낸다.
            var text = line + " "
            for cut in [" and ", " (saved", " for this session", ":"] {
                if let range = text.range(of: cut) { text = String(text[..<range.lowerBound]) }
            }
            return text.trimmingCharacters(in: .whitespaces)
        }.joined(separator: " · ")
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
            return OrcaIO(orca: Proc.locate("orca"), handle: handle)
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

    /// `slot` 은 1부터.
    public func plan(slot: Int, agent: Agent) throws -> (slot: Slot, preset: AgentPreset, steps: [Step]) {
        guard slot >= 1, slot <= config.slots.count else {
            throw ModelSwitchError("\(slot)번 프리셋이 없습니다(지금 \(config.slots.count)개).")
        }
        let chosen = config.slots[slot - 1]
        guard let preset = chosen.preset(for: agent) else {
            throw ModelSwitchError("\(slot)번 '\(chosen.name)' 에는 \(agent.rawValue) 설정이 없습니다.")
        }
        switch agent {
        case .claude:
            return (chosen, preset, Plans.claude(preset))
        case .codex:
            let selection = try codexModels().selection(of: preset)
            return (chosen, preset, Plans.codex(modelIndex: selection.modelIndex, displayName: selection.displayName,
                                                effortLabel: selection.effortLabel))
        }
    }

    /// `deferFinalCheck` 가 참이면 기본값을 한 번만 되돌리고 돌아온다 — 호출한 쪽이 알림을 띄운 뒤 `verifyRestore` 를 부른다.
    public func apply(slot: Int, to target: Target, deferFinalCheck: Bool = false) throws -> SwitchResult {
        trace?.mark("준비")
        let planned = try plan(slot: slot, agent: target.agent)
        trace?.mark("계획")
        let raw = try makeIO(target)
        let io: TerminalIO = trace.map { TracingIO(base: raw, trace: $0) } ?? raw

        // 입력창이 보일 때만 보낸다 — 권한 확인 창 같은 것이 떠 있으면 우리가 보낸 Enter 가 그 창을 승인해 버린다.
        // 화면과 초안은 한 번에 읽는다(Orca 는 호출 한 번이 약 0.2초).
        guard let first = io.snapshot() else {
            throw ModelSwitchError(Switcher.unreadable(target.host))
        }
        guard Readiness.inputVisible(agent: target.agent, screen: first.lines) else {
            throw ModelSwitchError("\(target.agent.rawValue) 입력창이 보이지 않아 전환하지 않았습니다. 권한 확인 창이나 선택창이 떠 있으면 먼저 처리해 주세요.")
        }
        // codex 는 쓰던 글을 한 줄까지만 치웠다 되돌릴 수 있다. 여러 줄이면 남은 줄이 명령과 섞이므로 손대지 않는다.
        if target.agent == .codex, let draft = first.draft, draft.contains("\n") {
            throw ModelSwitchError("codex 입력창에 여러 줄 초안이 있어 전환하지 않았습니다. 먼저 보내거나 지운 뒤 다시 눌러 주세요.")
        }

        let keep = config.keepDefaults && target.agent == .claude
        let before = keep ? claudeDefaults.snapshot() : nil

        let traced = trace
        let timedSleep: (Int) -> Void = { ms in self.sleep(ms); traced?.mark("대기(\(ms))") }
        let runner = Runner(io: io, sleep: timedSleep,
                            stamp: target.agent == .claude ? { claudeDefaults.stamp() } : nil,
                            initial: first)
        let confirmations: [String]
        do {
            confirmations = try runner.run(planned.steps)
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

    /// 화면의 결과 줄이 이번 명령의 것인지 가릴 수 없을 때(같은 문구가 이미 떠 있었고 기본값 파일도 안 변함) 기다리는 시간.
    /// claude 가 기본값 파일을 다른 곳에 두는 환경에서도 전환이 멈추지 않게 하는 여유다.
    static let staleGraceMs = 1200

    public init(io: TerminalIO, sleep: @escaping (Int) -> Void,
                stamp: (() -> Int64?)? = nil, initial: ScreenSnapshot? = nil) {
        self.io = io
        self.sleep = sleep
        self.stamp = stamp
        self.initial = initial
    }

    /// 돌려주는 값은 `expectResult` 가 본 결과 줄들.
    @discardableResult
    public func run(_ steps: [Step]) throws -> [String] {
        var armedStamp: Int64?
        var armedLines: [String] = []
        // 마지막으로 본 화면. `arm` 이 이것을 「명령 전 상태」로 잡는다.
        var seenLines = initial?.lines ?? []
        var confirmations: [String] = []
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
                armedLines = seenLines
            case .expectResult(let prefix, let timeoutMs, let failure):
                let found = try waitForResult(prefix: prefix, armedStamp: armedStamp, armedLines: armedLines,
                                              timeoutMs: timeoutMs, failure: failure)
                seenLines = found.lines
                confirmations.append(found.result)
            case .selectRow(let label, let via, let timeoutMs, let abort, let failure):
                if try !selectRow(label: label, via: via, timeoutMs: timeoutMs) {
                    _ = try? run(abort)
                    throw ModelSwitchError(failure)
                }
            case .expectComposer(let timeoutMs, let abort, let failure):
                let closed = try poll(timeoutMs: timeoutMs) { lines in
                    !CodexPicker.isOpen(lines) && Readiness.codexComposerVisible(lines)
                }
                if !closed {
                    _ = try? run(abort)
                    throw ModelSwitchError(failure)
                }
            case .closePicker:
                try closePicker()
            case .capture(let prefix):
                if let lines = io.screen(), let found = Runner.lastLine(lines, prefix: prefix) {
                    confirmations.append(found)
                }
            }
        }
        return confirmations
    }

    private func waitForResult(prefix: String, armedStamp: Int64?, armedLines: [String],
                               timeoutMs: Int, failure: String) throws -> (result: String, lines: [String]) {
        let started = DispatchTime.now()
        var simulated = 0
        // 같은 문구가 명령 전부터 화면에 있었으면 화면만으로는 새 결과인지 알 수 없다.
        let stale = !ClaudeScreen.results(armedLines, prefix: prefix).isEmpty
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
            let fresh = !stale || stampChanged || elapsed >= Runner.staleGraceMs
            // 입력창이 다시 «보임» — 다음 명령의 Enter 가 그 사이 뜬 확인 창을 누르지 않게 한다.
            let promptBack = Readiness.claudePromptVisible(snap.lines)
            // 쓰던 글이 있었으면 그것이 입력창에 «돌아왔음». 그 사이 사용자가 더 쳤을 수 있어 같은지는 따지지 않는다.
            let draftBack = draftBefore.isEmpty || !draft(snap).isEmpty
            if let result = ClaudeScreen.results(snap.lines, prefix: prefix).last, fresh, promptBack, draftBack {
                return (result, snap.lines)
            }
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

    // MARK: codex 선택창

    /// `label` 행에 커서를 둔다. 성공하면 참.
    private func selectRow(label: String, via: String?, timeoutMs: Int) throws -> Bool {
        var found = false
        // 목록이 그려질 때까지 기다린다: 목표 행이 있거나, 하위 목록으로 가는 행이 있어야 한다.
        let listed = try poll(timeoutMs: timeoutMs) { lines in
            let rows = CodexPicker.rows(lines)
            found = rows.contains { CodexPicker.matches($0, label) }
            return found || (via.map { via in rows.contains { CodexPicker.matches($0, via) } } ?? false)
        }
        guard listed else { return false }
        if !found, let via {
            guard try moveCursor(to: via, timeoutMs: timeoutMs) else { return false }
            try io.press(.enter)
            let entered = try poll(timeoutMs: timeoutMs) { lines in
                CodexPicker.rows(lines).contains { CodexPicker.matches($0, label) }
            }
            guard entered else { return false }
        }
        return try moveCursor(to: label, timeoutMs: timeoutMs)
    }

    /// 커서가 `label` 행에 올 때까지: 화면에서 커서 행을 읽고, 차이만큼 위·아래를 보내고, 커서가 움직인 것을 본 뒤 다시 읽는다.
    private func moveCursor(to label: String, timeoutMs: Int) throws -> Bool {
        var budget = 4
        while budget > 0 {
            budget -= 1
            guard let lines = io.screen() else { throw ModelSwitchError("터미널 화면을 읽지 못해 중단했습니다.") }
            let rows = CodexPicker.rows(lines)
            guard let target = rows.firstIndex(where: { CodexPicker.matches($0, label) }),
                  let cursor = rows.firstIndex(where: \.selected) else { return false }
            if target == cursor { return true }
            let key = target > cursor ? Key.down : Key.up
            try io.type(String(repeating: key.bytes, count: abs(target - cursor)))
            // 화면이 따라오기 전에 다시 계산하면 두 번 움직인다 — 커서가 «도착함»을 보고 넘어간다.
            let arrived = try poll(timeoutMs: min(timeoutMs, 1000)) { lines in
                let now = CodexPicker.rows(lines)
                guard let at = now.firstIndex(where: \.selected) else { return false }
                return now.indices.contains(at) && CodexPicker.matches(now[at], label)
            }
            if arrived { return true }
        }
        return false
    }

    /// 선택창이 보이는 동안만 Esc 를 누른다. 누를 때마다 화면을 다시 읽는다.
    private func closePicker() throws {
        for _ in 0..<4 {
            guard let lines = io.screen() else { return }
            let before = CodexPicker.rows(lines)
            guard !before.isEmpty else { return }
            try io.press(.escape)
            _ = try poll(timeoutMs: 800) { CodexPicker.rows($0) != before }
        }
    }

    static func lastLine(_ lines: [String], prefix: String) -> String? {
        for line in lines.reversed() {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("•") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if text.hasPrefix(prefix) { return text }
        }
        return nil
    }
}
