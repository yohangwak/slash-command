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
    /// 5번 행(More reasoning…)에 들어갔다 Esc 로 나오면 커서가 항상 5번 행에 오므로 그걸 기준점으로 쓴다.
    public static func codex(modelIndex: Int, effortRow: Int) -> [Step] {
        let restoreDraft: [Step] = [.key(.ctrl("y")), .key(.backspace)]
        var steps: [Step] = [
            // 쓰던 글 한 줄을 kill 버퍼로 옮긴다. 공백을 붙여 두면 빈 입력창에서도 Ctrl+Y 가 옛 내용을 꺼내지 않는다.
            .key(.ctrl("e")), .text(" "), .key(.ctrl("a")), .key(.ctrl("k")), .wait(ms: 200),
            .text("/model"),
            .expect(needle: "choose what model and reasoning effort",
                    timeoutMs: 2500,
                    abort: Array(repeating: .key(.backspace), count: 6) + restoreDraft,
                    failure: "codex 입력창에 여러 줄 초안이 있어 전환하지 않았습니다. 먼저 보내거나 지운 뒤 다시 눌러 주세요."),
            .key(.enter),
            .expect(needle: "Select Model and Effort",
                    timeoutMs: 4000,
                    abort: [],
                    failure: "codex 모델 선택창이 열리지 않았습니다."),
            .text(String(modelIndex)),
            .expect(needle: "Select Reasoning Level",
                    timeoutMs: 4000,
                    abort: [.key(.escape)],
                    failure: "codex effort 목록이 열리지 않았습니다."),
            .text("5"),
            .expect(needle: "Advanced Reasoning",
                    timeoutMs: 4000,
                    abort: [.key(.escape), .key(.escape)],
                    failure: "codex effort 목록의 기준 행(More reasoning…)을 찾지 못했습니다."),
            .key(.escape), .wait(ms: 450),
        ]
        steps.append(contentsOf: Array(repeating: .key(.up), count: 5 - effortRow))
        steps.append(contentsOf: [.wait(ms: 250), .text("s"), .wait(ms: 900)])
        steps.append(contentsOf: restoreDraft)
        return steps
    }
}
