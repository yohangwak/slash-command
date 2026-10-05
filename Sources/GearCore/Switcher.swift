import Foundation

public struct SwitchResult: Equatable, Sendable {
    public let target: Target
    public let slotName: String
    public let preset: AgentPreset
    /// 기본값을 되돌리지 못했을 때의 사유. 전환 자체는 성공했다.
    public let warning: String?

    public var summary: String {
        "\(slotName) — \(preset.model) · \(preset.effort)"
    }
}

public struct Switcher {
    public var config: GearConfig
    public var claudeDefaults: ClaudeDefaults
    public var codexModels: () throws -> CodexModels
    public var makeIO: (Target) throws -> TerminalIO
    public var sleep: (Int) -> Void

    public init(config: GearConfig,
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
            guard let orca = Proc.locate("orca") else { throw GearError("orca 명령을 찾지 못했습니다.") }
            return OrcaIO(orca: orca, handle: handle)
        }
    }

    static func unreadable(_ host: TerminalHost) -> String {
        switch host {
        case .ghostty:
            return "Ghostty 화면을 읽지 못해 전환하지 않았습니다. 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 Gear 를 허용해 주세요."
        case .orca:
            return "Orca 터미널 화면을 읽지 못해 전환하지 않았습니다."
        }
    }

    /// `slot` 은 1부터.
    public func plan(slot: Int, agent: Agent) throws -> (slot: Slot, preset: AgentPreset, steps: [Step]) {
        guard slot >= 1, slot <= config.slots.count else {
            throw GearError("\(slot)번 프리셋이 없습니다(지금 \(config.slots.count)개).")
        }
        let chosen = config.slots[slot - 1]
        guard let preset = chosen.preset(for: agent) else {
            throw GearError("\(slot)번 '\(chosen.name)' 에는 \(agent.rawValue) 설정이 없습니다.")
        }
        switch agent {
        case .claude:
            return (chosen, preset, Plans.claude(preset))
        case .codex:
            let position = try codexModels().position(of: preset)
            return (chosen, preset, Plans.codex(modelIndex: position.modelIndex, effortRow: position.effortRow))
        }
    }

    public func apply(slot: Int, to target: Target) throws -> SwitchResult {
        let planned = try plan(slot: slot, agent: target.agent)
        let io = try makeIO(target)

        // 입력창이 보일 때만 보낸다 — 권한 확인 창 같은 것이 떠 있으면 우리가 보낸 Enter 가 그 창을 승인해 버린다.
        guard let screen = io.screen() else {
            throw GearError(Switcher.unreadable(target.host))
        }
        guard Readiness.inputVisible(agent: target.agent, screen: screen) else {
            throw GearError("\(target.agent.rawValue) 입력창이 보이지 않아 전환하지 않았습니다. 권한 확인 창이나 선택창이 떠 있으면 먼저 처리해 주세요.")
        }
        // codex 는 쓰던 글을 한 줄까지만 치웠다 되돌릴 수 있다. 여러 줄이면 남은 줄이 명령과 섞이므로 손대지 않는다.
        if target.agent == .codex, let draft = io.draft(), draft.contains("\n") {
            throw GearError("codex 입력창에 여러 줄 초안이 있어 전환하지 않았습니다. 먼저 보내거나 지운 뒤 다시 눌러 주세요.")
        }

        let keep = config.keepDefaults && target.agent == .claude
        let before = keep ? claudeDefaults.snapshot() : nil

        try Runner(io: io, sleep: sleep).run(planned.steps)

        var warning: String?
        if let before {
            // claude 가 설정 파일을 쓰는 건 명령 직후지만 조금 늦을 수 있어 두 번 확인한다.
            for delay in [900, 1500] {
                sleep(delay)
                if case .failed(let reason) = claudeDefaults.restore(to: before) {
                    warning = "새 세션 기본값을 되돌리지 못했습니다: \(reason)"
                }
            }
        }
        return SwitchResult(target: target, slotName: planned.slot.name, preset: planned.preset, warning: warning)
    }
}

/// 단계 목록을 터미널에 실행한다.
public struct Runner {
    public let io: TerminalIO
    public let sleep: (Int) -> Void

    public init(io: TerminalIO, sleep: @escaping (Int) -> Void) {
        self.io = io
        self.sleep = sleep
    }

    public func run(_ steps: [Step]) throws {
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
                    try? run(abort)
                    throw GearError(failure)
                }
            }
        }
    }

    private func waitFor(_ needle: String, timeoutMs: Int) throws -> Bool {
        let interval = 200
        var waited = 0
        while true {
            guard let lines = io.screen() else { throw GearError("터미널 화면을 읽지 못해 중단했습니다.") }
            if lines.contains(where: { $0.contains(needle) }) { return true }
            if waited >= timeoutMs { return false }
            sleep(interval)
            waited += interval
        }
    }
}
