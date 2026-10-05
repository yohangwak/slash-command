import Foundation

public enum Key: Equatable, Sendable {
    case enter
    case escape
    case up
    case down
    case backspace
    case ctrl(Character)

    /// pty 에 그대로 쓰는 바이트.
    public var bytes: String {
        switch self {
        case .enter: return "\r"
        case .escape: return "\u{1B}"
        case .up: return "\u{1B}[A"
        case .down: return "\u{1B}[B"
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
    /// 명령을 보내기 직전의 상태(화면의 마지막 결과 줄, claude 기본값 파일의 수정 시각)를 기준으로 잡는다.
    /// 다음 `expectResult` 가 «이번 명령의» 결과인지 가리는 데 쓴다.
    case arm
    /// 마지막 결과 줄(`⎿ …`)이 `prefix` 로 시작하고 입력창이 다시 «보임»을 확인한다.
    /// 같은 문구가 기준에 이미 있었으면 기본값 파일이 «변함»까지 본다. 쓰던 글이 있었으면 그것이 «돌아왔음»도 본다
    /// — 그래야 다음 Ctrl+S 가 복원과 겹치지 않는다.
    case expectResult(prefix: String, timeoutMs: Int, failure: String)
    /// codex 선택창에서 `label` 행에 커서를 «둔다». 화면에서 커서(`›`)가 어느 행에 있는지 읽고 그만큼만 움직인 뒤 다시 읽어 확인한다.
    /// 그 행이 없고 `via` 행이 있으면(예: More reasoning…) 그 하위 목록으로 들어가서 찾는다.
    case selectRow(label: String, via: String?, timeoutMs: Int, abort: [Step], failure: String)
    /// codex 선택창이 닫히고 입력창이 다시 «보임»을 확인한다.
    case expectComposer(timeoutMs: Int, abort: [Step], failure: String)
    /// 선택창이 «보이는 동안만» Esc 로 닫는다. 선택창이 없으면 아무것도 보내지 않는다 — 작업 중인 codex 에 Esc 는 작업 중단이다.
    case closePicker
    /// 화면에서 `prefix` 로 시작하는 마지막 줄을 결과로 남긴다(없으면 넘어간다).
    case capture(prefix: String)
}

public enum Plans {
    /// claude: 쓰던 글을 임시 보관(Ctrl+S)하고 `/model`·`/effort` 를 차례로 실행한다.
    /// 명령이 끝나면 claude 가 보관한 글을 되돌리므로 두 번째 명령 앞에서 다시 보관한다.
    public static func claude(_ preset: AgentPreset) -> [Step] {
        [
            // Ctrl+S 와 명령과 Enter 를 한 번에 쓴다(2026-10-06 실측: 한 덩이여도 글이 보관·복원되고 명령이 실행된다).
            // 고정 대기 대신 결과 줄이 «보임»을 확인하고 다음으로 간다 — 응답은 0.2초 안에 온다.
            .arm,
            .text("\u{13}/model \(preset.model)\r"),
            .expectResult(prefix: "Set model to", timeoutMs: 3000,
                          failure: "claude 가 /model \(preset.model) 에 응답하지 않았습니다."),
            .arm,
            .text("\u{13}/effort \(preset.effort)\r"),
            .expectResult(prefix: "Set effort level", timeoutMs: 3000,
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
            .text("s"),
            // 여기서 실패하면 화면에 뭐가 떠 있는지 모른다 — 선택창이면 닫되, 쓰던 글을 되돌리는 키는 보내지 않는다.
            .expectComposer(timeoutMs: 3000, abort: [.closePicker],
                            failure: "codex 입력창이 돌아오지 않아 멈췄습니다. 쓰던 글이 있었다면 Ctrl+Y 로 되살릴 수 있습니다."),
            .capture(prefix: "Model changed to"),
        ] + restoreDraft
    }
}
