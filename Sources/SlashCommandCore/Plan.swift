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
        case .tab: return "\t"
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
    /// `bottom` 을 주면 화면의 마지막 그 몇 줄 안에 있어야 한다 — 대화 내용에 같은 글이 있을 수 있다.
    case expect(needle: String, bottom: Int? = nil, timeoutMs: Int, abort: [Step], failure: String)
    /// 화면 맨 아래에 우리 선택창이 «떠 있음»을 확인한다: 머리말이 `header` 로 시작하고 안내 줄에 `footer` 가 있다(준 것만 본다).
    case expectPicker(header: String?, footer: String?, timeoutMs: Int, abort: [Step], failure: String)
    /// 명령을 보내기 직전의 상태(화면, claude 기본값 파일의 수정 시각)를 기준으로 잡는다.
    /// 뒤의 `expectResult`·`capture` 가 «이번 명령의» 결과인지 가리는 데 쓴다.
    case arm
    /// `prefix` 로 시작하는 결과 줄이 있고 입력창이 다시 «보임»을 확인한다.
    /// 같은 문구가 기준에 이미 있었으면 그 줄이 «새로 생겼거나» 기본값 파일이 «변했을» 때만 인정한다. 쓰던 글이 있었으면 그것이 «돌아왔음»도 본다
    /// — 그래야 다음 Ctrl+S 가 복원과 겹치지 않는다.
    /// `command`("/model") 를 주면, 그 명령 바로 아래에 다른 답이 붙었을 때(예: Model 'x' not found) 기다리지 않고 그 말로 끝낸다.
    case expectResult(prefix: String, command: String? = nil, acceptSwitchTo: [String] = [], timeoutMs: Int, failure: String)
    /// codex 선택창에서 `label` 행에 커서를 «둔다». 화면에서 커서(`›`)가 어느 행에 있는지 읽고 그만큼만 움직인 뒤 다시 읽어 확인한다.
    /// 그 행이 없고 `via` 행이 있으면(예: More reasoning…) 그 하위 목록으로 들어가서 찾는다.
    case selectRow(label: String, via: String?, timeoutMs: Int, abort: [Step], failure: String)
    /// claude 선택창의 effort 줄이 `level` 이 «될 때까지» → 를 한 번씩 누르고 그때마다 다시 읽는다(끝에서 처음으로 돈다).
    /// effort 를 지원하지 않는 모델이면 그냥 넘어간다.
    case setEffort(level: String, timeoutMs: Int, abort: [Step], failure: String)
    /// claude 선택창의 커서가 「지금 쓰는 모델」(`✔`) 행에 있음을 확인한다 — effort 만 바꿀 때 모델이 따라 바뀌지 않게 한다.
    case expectCurrentRow(abort: [Step], failure: String)
    /// claude 선택창의 effort 를 한 단계 올리거나 내린다. 이미 끝이면 아무것도 바꾸지 않고 그렇게 알린다.
    case stepEffort(up: Bool, timeoutMs: Int, abort: [Step])
    /// codex effort 목록에서 지금 값(`(current)`)의 바로 위·아래 행에 커서를 둔다. Max·Ultra 는 More reasoning… 아래에 있다.
    case stepRow(up: Bool, timeoutMs: Int, abort: [Step])
    /// 선택창이 닫히고 그 에이전트의 입력창이 다시 «보임»을 확인한다. claude 는 쓰던 글이 돌아온 것까지 본다.
    ///
    /// claude 는 방금 응답한 대화에서 모델이나 effort 를 바꾸면 확인 창을 띄운다(「Switch model?」·「Change effort level?」
    /// — 대화 기록을 다시 읽는다는 안내). 기본은 그 창에 아무것도 보내지 않고 사용자가 고르게 한다.
    /// `acceptSwitchTo` 가 있으면(설정에서 켰을 때) 그 창이 «이 값들 중 하나로» 바꾸겠느냐고 묻고 커서가 Yes 에 있을 때만
    /// Enter 로 받아들인다. `Step.steppedEffort` 는 「방금 `stepEffort` 가 옮겨 놓은 단계」를 뜻한다.
    case expectInput(agent: Agent, acceptSwitchTo: [String] = [], timeoutMs: Int, abort: [Step], failure: String)

    public static let steppedEffort = "{stepped-effort}"
    /// 선택창이 «보이는 동안만» Esc 로 닫는다. 선택창이 없으면 아무것도 보내지 않는다 — 작업 중인 codex 에 Esc 는 작업 중단이다.
    case closePicker
    /// 방금 끝난 전환의 결과 문구를 남긴다(없으면 넘어간다).
    /// `afterCommand` 를 주면(claude) 그 명령 아래의 답이나 입력창 위 알림 줄에서, 아니면(codex) 화면의 마지막 그런 줄에서 찾는다.
    case capture(prefixes: [String], afterCommand: String? = nil)
}

public enum Launch {
    /// 그 프리셋으로 새 세션을 열 수 없는 에이전트면 그 사유.
    /// cursor-agent 는 `--model` 이 받는 id 가 화면 이름과 다른데(`grok-4.7` 대 `Grok 4.7`), 그 대응을 알려 주는 출력을 확인하지 못했다.
    public static func unsupportedReason(agent: Agent) -> String? {
        switch agent {
        case .claude, .codex, .grok, .antigravity, .opencode: return nil
        case .cursor:
            return loc("%@ does not support `run`: the model id it takes when opening a session differs from the on-screen name in the preset. Open the session, then switch with the shortcut.", agent.displayName)
        }
    }

    /// `--model` 이 화면 이름이 아니라 id 를 받는 에이전트가 «이름 → id» 를 알아내려고 부르는 명령. 그 출력을 `resolve` 에 넘긴다.
    /// (2026-10-11 실측: `agy models` 는 `id<빈칸>이름 (Effort)` 줄들, `opencode models --verbose` 는 `제공자/id` 줄과 그 모델의 JSON.)
    public static func listing(agent: Agent) -> [String]? {
        switch agent {
        case .antigravity: return ["agy", "models"]
        case .opencode: return ["opencode", "models", "--verbose"]
        case .claude, .codex, .grok, .cursor: return nil
        }
    }

    public struct Resolved: Equatable, Sendable {
        /// `--model` 에 넘길 값.
        public let model: String
        /// 그대로는 다 맞추지 못한 것이 있을 때의 안내(예: opencode 는 variant 를 여는 옵션이 없다).
        public let note: String?
    }

    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// 프리셋의 화면 이름(과 effort)에 해당하는 모델 id 를 `listing` 명령의 출력에서 찾는다.
    public static func resolve(agent: Agent, preset: AgentPreset, listing output: String) throws -> Resolved {
        switch agent {
        case .antigravity:
            // `gemini-3.8-flash-high   Gemini 3.8 Flash (High)` — effort 가 id 에 들어 있다.
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
            // `opencode-go/glm-5.3-flash` 줄 다음에 그 모델의 JSON(`name`·`providerID`·`variants`).
            // 프리셋의 이름은 화면에 보이는 «모델 이름 + 제공자» 다(`GLM-5.3-Flash OpenCode Go`).
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
            var found = rows.filter { key($0.name) + key($0.provider) == wanted }
            if found.isEmpty {
                // 제공자를 적지 않은 이름은 그 이름의 모델이 하나뿐일 때만 받는다.
                let byName = rows.filter { key($0.name) == wanted }
                if byName.count == 1 { found = byName }
            }
            guard let row = found.first else { throw SlashCommandError(loc("'%@' is not in the OpenCode model list.", preset.model)) }
            let variant = preset.effort
            let note = variant.lowercased() == "default" ? nil
                : loc("OpenCode has no option to set the variant when it opens, so it opens with the model only. Use the shortcut afterwards to set '%@'.", variant)
            return Resolved(model: row.id, note: note)
        case .claude, .codex, .grok, .cursor:
            return Resolved(model: preset.model, note: nil)
        }
    }

    /// 그 프리셋으로 «새 세션»을 여는 명령줄. 둘 다 이 세션에만 적용되는 옵션이라 기본값은 바뀌지 않는다.
    /// `model` 은 `resolve` 가 푼 id(antigravity · opencode).
    public static func command(agent: Agent, preset: AgentPreset, model: String? = nil, extra: [String] = []) -> [String] {
        switch agent {
        case .claude:
            return ["claude", "--model", preset.model, "--effort", preset.effort] + extra
        case .codex:
            return ["codex", "-m", preset.model, "-c", "model_reasoning_effort=\"\(preset.effort)\""] + extra
        case .grok:
            return ["grok", "-m", preset.model, "--reasoning-effort", preset.effort] + extra
        case .antigravity, .opencode:
            // `--model` 이 화면 이름이 아니라 id 를 받는다 — `resolve` 로 푼 id 가 있을 때만 넘긴다(화면 이름을 그대로 넘기면 틀린 값이다).
            return [agent.executable] + (model.map { ["--model", $0] } ?? []) + extra
        case .cursor:
            // `unsupportedReason` 이 먼저 막는다; 여기서는 모델 없이 띄운다.
            return [agent.executable] + extra
        }
    }
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

    /// codex: 모델은 그대로 두고 effort 만 한 단계 옮긴다.
    ///
    /// 지금 값은 선택창의 `(current)` 표시로 안다. 입력창 아래 상태 줄도 값을 보여 주지만, max·ultra 로 바꾼 직후
    /// 한동안 옛 값을 보여 줘서(0.160.0 실측) 연달아 누르면 엉뚱한 단계로 간다.
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
            // 모델 목록의 커서는 지금 모델에서 시작한다. 그 행이 맞을 때만 Enter 로 들어간다.
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

    /// claude: 모델은 그대로 두고 effort 만 한 단계 옮긴다. 같은 선택창에서 → · ← 한 번이다.
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

    /// claude: 쓰던 글을 임시 보관(Ctrl+S)하고 `/model`·`/effort` 를 차례로 실행한다(선택창을 읽지 못할 때의 대안).
    /// 명령이 끝나면 claude 가 보관한 글을 되돌리므로 두 번째 명령 앞에서 다시 보관한다.
    public static func claude(_ preset: AgentPreset, acceptSwitch: Bool = false) -> [Step] {
        [
            // Ctrl+S 와 명령과 Enter 를 한 번에 쓴다(2026-10-06 실측: 한 덩이여도 글이 보관·복원되고 명령이 실행된다).
            // 고정 대기 대신 결과 줄이 «보임»을 확인하고 다음으로 간다 — 응답은 0.2초 안에 온다.
            .arm,
            .text("\u{13}/model \(preset.model)\r"),
            .expectResult(prefix: "Set model to", command: "/model", acceptSwitchTo: acceptSwitch ? [ClaudeModels.rowLabel(preset.model)] : [], timeoutMs: 3000,
                          failure: loc("Claude Code did not respond to /model %@.", preset.model)),
            .arm,
            .text("\u{13}/effort \(preset.effort)\r"),
            .expectResult(prefix: "Set effort level", command: "/effort", acceptSwitchTo: acceptSwitch ? [preset.effort] : [], timeoutMs: 3000,
                          failure: loc("Claude Code did not respond to /effort %@.", preset.effort)),
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
            .expect(needle: "choose what model and reasoning effort", bottom: 5,
                    timeoutMs: 2500,
                    abort: [.text(String(repeating: "\u{7F}", count: 6))] + restoreDraft,
                    failure: loc("Not switched: there is a multi-line draft in the Codex input box. Send or clear it, then press again.")),
            .key(.enter),
            .expectPicker(header: "Select Model and Effort", footer: nil, timeoutMs: 4000, abort: leave,
                          failure: loc("The Codex model picker did not open.")),
            .text(String(modelIndex)),
            // 머리말에 모델 이름이 나온다 — 숫자 키가 의도한 모델을 골랐는지까지 본다.
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
            // 여기서 실패하면 화면에 뭐가 떠 있는지 모른다 — 선택창이면 닫되, 쓰던 글을 되돌리는 키는 보내지 않는다.
            .expectInput(agent: .codex, timeoutMs: 3000, abort: [.closePicker],
                            failure: loc("Stopped: the Codex input box did not come back. If you had text there, Ctrl+Y brings it back.")),
            .capture(prefixes: ["Model changed to"]),
        ] + restoreDraft
    }
}
