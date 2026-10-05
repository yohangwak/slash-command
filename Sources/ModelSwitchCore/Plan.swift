import Foundation

public enum Key: Equatable, Sendable {
    case enter
    case escape
    case up
    case down
    case left
    case right
    case backspace
    case ctrl(Character)

    /// pty 에 그대로 쓰는 바이트.
    public var bytes: String {
        switch self {
        case .enter: return "\r"
        case .escape: return "\u{1B}"
        case .up: return "\u{1B}[A"
        case .down: return "\u{1B}[B"
        case .right: return "\u{1B}[C"
        case .left: return "\u{1B}[D"
        case .backspace: return "\u{7F}"
        case .ctrl(let c):
            let value = (c.asciiValue ?? 0x40) & 0x1F
            return String(UnicodeScalar(value))
        }
    }
}

public enum Step: Equatable, Sendable {
    case text(String)
    case key(Key)
    case wait(ms: Int)
    /// 화면에 `needle` 이 «있음»을 확인한다. 시간 안에 안 보이면 `abort` 를 실행하고 `failure` 로 중단한다.
    case expect(needle: String, timeoutMs: Int, abort: [Step], failure: String)
    /// 명령을 보내기 직전의 상태(화면, claude 기본값 파일의 수정 시각)를 기준으로 잡는다.
    /// 뒤의 `expectResult`·`capture` 가 «이번 명령의» 결과인지 가리는 데 쓴다.
    case arm
    /// `prefix` 로 시작하는 결과 줄이 있고 입력창이 다시 «보임»을 확인한다.
    /// 같은 문구가 기준에 이미 있었으면 그 줄이 «새로 생겼거나» 기본값 파일이 «변했을» 때만 인정한다. 쓰던 글이 있었으면 그것이 «돌아왔음»도 본다
    /// — 그래야 다음 Ctrl+S 가 복원과 겹치지 않는다.
    /// `command`("/model") 를 주면, 그 명령 바로 아래에 다른 답이 붙었을 때(예: Model 'x' not found) 기다리지 않고 그 말로 끝낸다.
    case expectResult(prefix: String, command: String? = nil, acceptSwitchTo: String? = nil, timeoutMs: Int, failure: String)
    /// codex 선택창에서 `label` 행에 커서를 «둔다». 화면에서 커서(`›`)가 어느 행에 있는지 읽고 그만큼만 움직인 뒤 다시 읽어 확인한다.
    /// 그 행이 없고 `via` 행이 있으면(예: More reasoning…) 그 하위 목록으로 들어가서 찾는다.
    case selectRow(label: String, via: String?, timeoutMs: Int, abort: [Step], failure: String)
    /// claude 선택창의 effort 줄이 `level` 이 «될 때까지» → 를 한 번씩 누르고 그때마다 다시 읽는다(끝에서 처음으로 돈다).
    /// effort 를 지원하지 않는 모델이면 그냥 넘어간다.
    case setEffort(level: String, timeoutMs: Int, abort: [Step], failure: String)
    /// 선택창이 닫히고 그 에이전트의 입력창이 다시 «보임»을 확인한다. claude 는 쓰던 글이 돌아온 것까지 본다.
    ///
    /// claude 는 대화 도중 모델을 바꾸면 「Switch model?」 확인 창을 띄운다(대화 기록을 새 모델로 다시 읽는다는 안내).
    /// 기본은 그 창에 아무것도 보내지 않고 사용자가 고르게 한다. `acceptSwitchTo` 가 있으면(설정에서 켰을 때)
    /// 그 창이 «이 모델로» 바꾸겠느냐고 묻고 커서가 Yes 에 있을 때만 Enter 로 받아들인다.
    case expectInput(agent: Agent, acceptSwitchTo: String? = nil, timeoutMs: Int, abort: [Step], failure: String)
    /// 선택창이 «보이는 동안만» Esc 로 닫는다. 선택창이 없으면 아무것도 보내지 않는다 — 작업 중인 codex 에 Esc 는 작업 중단이다.
    case closePicker
    /// 기준(`arm`) 뒤에 새로 생긴, `prefix` 로 시작하는 마지막 줄을 결과로 남긴다(없으면 넘어간다).
    case capture(prefix: String)
}

public enum Plans {
    /// claude: `/model` 선택창에서 모델 행과 effort 를 맞추고 확정한다.
    ///
    /// 선택창에는 「이 세션만」(`s`) 확정이 있다(2.1.289 실측: 기본값 파일이 바뀌지 않는다). `/model X`·`/effort Y` 는
    /// 새 세션 기본값까지 바꾸므로 되돌려야 하지만, 이 방식은 기본값을 아예 건드리지 않는다.
    /// `saveAsDefault` 가 참이면 Enter 로 확정해 기본값으로도 저장한다.
    public static func claudePicker(modelLabel: String, effort: String, saveAsDefault: Bool, acceptSwitch: Bool = false) -> [Step] {
        let footer = "s to use this session only"
        return [
            // Ctrl+S 로 쓰던 글을 보관하고 선택창을 연다. 선택창이 닫히면(확정이든 Esc 든) claude 가 글을 되돌린다.
            .text("\u{13}/model\r"),
            // 여기서 실패하면 화면에 뭐가 떠 있는지 모른다 — 아무 키도 더 보내지 않는다.
            .expect(needle: footer, timeoutMs: 3000, abort: [],
                    failure: "claude 모델 선택창이 열리지 않았습니다."),
            .selectRow(label: modelLabel, via: nil, timeoutMs: 2000, abort: [.closePicker],
                       failure: "claude 모델 선택창에 '\(modelLabel)' 행이 없습니다."),
            .setEffort(level: effort, timeoutMs: 2500, abort: [.closePicker],
                       failure: "claude 모델 선택창에서 effort 를 '\(effort)' 로 맞추지 못했습니다."),
            .expect(needle: footer, timeoutMs: 1000, abort: [.closePicker],
                    failure: "claude 모델 선택창에 「이 세션만」(s) 선택지가 없어 전환하지 않았습니다."),
            .arm,
            .text(saveAsDefault ? "\r" : "s"),
            .expectInput(agent: .claude, acceptSwitchTo: acceptSwitch ? modelLabel : nil, timeoutMs: 3000, abort: [.closePicker],
                         failure: "claude 입력창이 돌아오지 않아 멈췄습니다."),
            .capture(prefix: "Set model to"),
            .capture(prefix: "Kept model as"),
        ]
    }

    /// claude: 쓰던 글을 임시 보관(Ctrl+S)하고 `/model`·`/effort` 를 차례로 실행한다(선택창을 읽지 못할 때의 대안).
    /// 명령이 끝나면 claude 가 보관한 글을 되돌리므로 두 번째 명령 앞에서 다시 보관한다.
    public static func claude(_ preset: AgentPreset, acceptSwitch: Bool = false) -> [Step] {
        [
            // Ctrl+S 와 명령과 Enter 를 한 번에 쓴다(2026-10-06 실측: 한 덩이여도 글이 보관·복원되고 명령이 실행된다).
            // 고정 대기 대신 결과 줄이 «보임»을 확인하고 다음으로 간다 — 응답은 0.2초 안에 온다.
            .arm,
            .text("\u{13}/model \(preset.model)\r"),
            .expectResult(prefix: "Set model to", command: "/model", acceptSwitchTo: acceptSwitch ? ClaudeModels.rowLabel(preset.model) : nil, timeoutMs: 3000,
                          failure: "claude 가 /model \(preset.model) 에 응답하지 않았습니다."),
            .arm,
            .text("\u{13}/effort \(preset.effort)\r"),
            .expectResult(prefix: "Set effort level", command: "/effort", timeoutMs: 3000,
                          failure: "claude 가 /effort \(preset.effort) 에 응답하지 않았습니다."),
        ]
    }

    /// codex: `/model` 선택창을 키로 조작한다. `s` 로 확정해 이 세션에만 적용한다(기본값을 건드리지 않는다).
    ///
    /// effort 목록의 처음 커서 위치는 상황마다 다르다(현재 모델이면 현재 effort, 아니면 그 모델 기본값).
    /// 그래서 화면에서 커서 행을 읽고 목표 행까지만 움직인다. 숫자 키로 고르면 기본값까지 저장되므로 쓰지 않는다.
    public static func codex(modelIndex: Int, displayName: String?, effortLabel: String) -> [Step] {
        let restoreDraft: [Step] = [.text("\u{19}\u{7F}")]   // Ctrl+Y, Backspace
        let leave: [Step] = [.closePicker] + restoreDraft
        return [
            // 쓰던 글 한 줄을 kill 버퍼로 옮긴다(Ctrl+E, 공백, Ctrl+A, Ctrl+K).
            // 공백을 붙여 두면 빈 입력창에서도 Ctrl+Y 가 옛 내용을 꺼내지 않는다.
            .text("\u{05} \u{01}\u{0B}/model"),
            .expect(needle: "choose what model and reasoning effort",
                    timeoutMs: 2500,
                    abort: [.text(String(repeating: "\u{7F}", count: 6))] + restoreDraft,
                    failure: "codex 입력창에 여러 줄 초안이 있어 전환하지 않았습니다. 먼저 보내거나 지운 뒤 다시 눌러 주세요."),
            .key(.enter),
            .expect(needle: "Select Model and Effort",
                    timeoutMs: 4000,
                    abort: leave,
                    failure: "codex 모델 선택창이 열리지 않았습니다."),
            .text(String(modelIndex)),
            // 머리말에 모델 이름이 나온다 — 숫자 키가 의도한 모델을 골랐는지까지 본다.
            .expect(needle: "Select Reasoning Level" + (displayName.map { " for \($0)" } ?? ""),
                    timeoutMs: 4000,
                    abort: leave,
                    failure: "codex effort 목록이 열리지 않았습니다(다른 모델이 골라졌을 수도 있습니다)."),
            .selectRow(label: effortLabel, via: "More reasoning",
                       timeoutMs: 3000,
                       abort: leave,
                       failure: "codex effort 목록에서 '\(effortLabel)' 행을 고르지 못했습니다."),
            .expect(needle: "s session",
                    timeoutMs: 1000,
                    abort: leave,
                    failure: "codex 선택창에 「이 세션만」(s) 선택지가 없어 전환하지 않았습니다."),
            .arm,
            .text("s"),
            // 여기서 실패하면 화면에 뭐가 떠 있는지 모른다 — 선택창이면 닫되, 쓰던 글을 되돌리는 키는 보내지 않는다.
            .expectInput(agent: .codex, timeoutMs: 3000, abort: [.closePicker],
                            failure: "codex 입력창이 돌아오지 않아 멈췄습니다. 쓰던 글이 있었다면 Ctrl+Y 로 되살릴 수 있습니다."),
            .capture(prefix: "Model changed to"),
        ] + restoreDraft
    }
}
