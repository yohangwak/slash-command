import Foundation

/// 키를 보내기 전에 「에이전트의 입력창이 화면에 있음」을 확인한다.
///
/// 권한 확인 창·승인 창·선택창이 떠 있을 때 글자와 Enter 를 보내면 그 창의 기본 선택지(대개 "Yes")가 눌린다.
/// 그래서 "창이 없다"가 아니라 "입력창이 보인다"를 조건으로 삼고, 안 보이면 아무것도 보내지 않는다.
public enum Readiness {
    public static func inputVisible(agent: Agent, screen: [String]) -> Bool {
        switch agent {
        case .claude: return claudePromptVisible(screen)
        case .codex: return codexComposerVisible(screen)
        }
    }

    /// claude 의 입력창은 가로줄 바로 아래에서 `❯` 로 시작한다.
    /// 권한 확인 창의 선택 표시(` ❯ 1. Yes`)는 들여쓰기가 있고 위가 가로줄이 아니다.
    ///
    /// 입력창은 화면 맨 아래에 있다: 그 아래에는 (여러 줄 초안의 이어지는 줄과) 닫는 가로줄, 상태 줄 몇 개뿐이다.
    /// 화면 위쪽에 남아 있는 비슷한 모양은 입력창으로 보지 않는다.
    static func claudePromptVisible(_ screen: [String]) -> Bool {
        let lines = screen.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let at = lines.indices.last(where: { $0 > 0 && lines[$0].hasPrefix("❯") && lines[$0 - 1].hasPrefix("─") }) else {
            return false
        }
        let below = lines[(at + 1)...]
        if let closing = below.firstIndex(where: { $0.hasPrefix("─") }) {
            // 닫는 가로줄까지는 초안의 이어지는 줄(들여쓴 줄)뿐이고, 그 아래는 상태 줄 몇 개다.
            return lines[(at + 1)..<closing].allSatisfy { $0.hasPrefix(" ") } && lines.count - closing - 1 <= 5
        }
        return below.count <= 6
    }

    /// codex 의 입력창은 `›` 로 시작한다(effort 가 ultra 일 때는 `»` — 0.160.0 실측).
    /// 승인 창·선택창도 `›` 로 선택 행을 표시하지만 `› 1. …` 처럼 번호가 붙는다.
    ///
    /// 입력창은 화면 맨 아래에 있다: `›` 로 시작하는 «마지막» 줄이 입력창이어야 하고(지난 대화에도 `› 내가 보낸 글` 이 남는다),
    /// 그 아래에는 들여쓴 줄(여러 줄 초안 · 상태 줄)만 있어야 한다.
    static func codexComposerVisible(_ screen: [String]) -> Bool {
        let lines = screen.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let at = lines.indices.last(where: { lines[$0].hasPrefix("›") || lines[$0].hasPrefix("»") }) else { return false }
        guard !isNumberedChoice(lines[at]) else { return false }
        let below = lines[(at + 1)...]
        return below.allSatisfy { $0.hasPrefix(" ") } && below.count <= 12
    }

    private static func isNumberedChoice(_ line: String) -> Bool {
        let rest = line.dropFirst().drop(while: { $0 == " " })
        let digits = rest.prefix(while: \.isNumber)
        return !digits.isEmpty && rest.dropFirst(digits.count).hasPrefix(".")
    }
}

public enum ClaudeScreen {
    /// 화면에서 `prefix` 로 시작하는 명령 결과들(위에서 아래 순서).
    ///
    /// claude 는 한가할 때는 결과를 대화 줄(`  ⎿  Set model to …`)로, 작업 중일 때는 입력창 바로 위에
    /// 오른쪽 정렬된 알림 줄(`        Set model to …`)로 보여 준다(2.1.289 실측). 둘 다 본다.
    public static func results(_ lines: [String], prefix: String) -> [String] {
        lines.compactMap { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("⎿") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return text.hasPrefix(prefix) ? text : nil
        }
    }

    /// 입력창에 보이는 글(첫 줄). 입력창이 없으면 nil, 비어 있으면 빈 문자열.
    /// 초안을 따로 주지 않는 터미널(Ghostty)에서 쓰던 글이 돌아왔는지 보는 데 쓴다.
    public static func promptText(_ lines: [String]) -> String? {
        let shown = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for (index, line) in shown.enumerated() where line.hasPrefix("❯") && index > 0 && shown[index - 1].hasPrefix("─") {
            return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// claude 가 방금 응답한 대화에서 모델이나 effort 를 바꾸기 전에 띄우는 확인 창에서, 바꾸려는 값. 그 창이 아니면 nil.
    ///
    ///     Switch model?                         (effort 일 때는 "Change effort level?")
    ///     Your next response will be slower and use more tokens
    ///     This conversation is cached for the current model. Switching to Sonnet 5.5 means …
    ///     ❯ 1. Yes, switch to Sonnet 5.5        (effort 일 때는 "Yes, switch to high")
    ///       2. No, go back
    ///
    /// 커서(`❯`)가 「Yes」 항목에 있을 때만 값을 돌려준다 — Enter 를 눌러도 되는지의 판단에 쓰기 때문이다.
    public static func switchPrompt(_ lines: [String]) -> String? {
        let headers = ["Switch model?", "Change effort level?"]
        guard let header = lines.lastIndex(where: { headers.contains($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        let marker = "❯ 1. Yes, switch to "
        for line in lines[(header + 1)...] {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix(marker) { return String(text.dropFirst(marker.count)) }
        }
        return nil
    }

    /// 마지막으로 친 명령(`❯ /model …`) 바로 아래에 붙은 답(`⎿ …`). 한가할 때 명령의 결과는 이 꼴로 남는다.
    /// `command` 를 주면("/model") 그 명령의 답일 때만 돌려준다 — 앞 명령의 답을 이번 명령의 것으로 읽지 않기 위해서다.
    public static func commandReply(_ lines: [String], command: String? = nil) -> String? {
        let shown = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for index in shown.indices.reversed() where index > 0 {
            let text = shown[index].trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("⎿") else { continue }
            guard shown[index - 1].hasPrefix("❯ " + (command ?? "/")) else { return nil }
            return String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// 방금 끝난 명령의 결과: 입력창 바로 위의 알림 줄(작업 중일 때)이거나, 마지막으로 친 그 명령(`❯ /model`) 아래의 답.
    ///
    /// 줄 수를 세어 「새로 생긴 줄」을 가리면 안 된다 — 선택창이 열렸다 닫히면 화면에 보이는 대화 범위가 달라져서,
    /// 예전 줄이 새로 보이기도 한다(2026-10-06 실측: 예전 "Kept model as …" 를 이번 결과로 읽어 알림이 틀렸다).
    /// 좁은 창에서 답이 다음 줄로 접히면 이어 붙인다.
    public static func latestResult(_ lines: [String], command: String, prefixes: [String]) -> String? {
        let shown = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let prompt = shown.indices.last(where: { $0 > 0 && shown[$0].hasPrefix("❯") && shown[$0 - 1].hasPrefix("─") }) else { return nil }
        let rule = prompt - 1
        // 작업 중: 입력창 위에 오른쪽 정렬된 알림 한 줄.
        if rule > 0 {
            let notice = shown[rule - 1].trimmingCharacters(in: .whitespaces)
            if prefixes.contains(where: { notice.hasPrefix($0) }) { return notice }
        }
        // 한가할 때: 대화에 `❯ 명령` 과 그 아래 `⎿ 답`.
        guard let echo = shown[..<rule].lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "❯ " + command }),
              echo + 1 < rule else { return nil }
        let first = shown[echo + 1].trimmingCharacters(in: .whitespaces)
        guard first.hasPrefix("⎿") else { return nil }
        var text = String(first.dropFirst()).trimmingCharacters(in: .whitespaces)
        var index = echo + 2
        // 접힌 줄은 답의 글과 같은 칸(5칸 들여쓰기)에서 시작한다. 더 깊이 들여쓴 줄은 오른쪽 정렬된 다른 표시다.
        while index < rule, shown[index].prefix(while: { $0 == " " }).count == 5 {
            text += " " + shown[index].trimmingCharacters(in: .whitespaces)
            index += 1
        }
        return text
    }

    /// 우리가 친 그 명령 줄(`❯ /model sonnet`) 바로 아래에 붙은 답. 화면에 그 명령이 없으면 nil.
    public static func reply(toCommand commandLine: String, in lines: [String]) -> String? {
        let shown = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for index in shown.indices.reversed() where index + 1 < shown.count {
            guard shown[index].trimmingCharacters(in: .whitespaces) == "❯ " + commandLine else { continue }
            let next = shown[index + 1].trimmingCharacters(in: .whitespaces)
            guard next.hasPrefix("⎿") else { return nil }
            return String(next.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// 화면에서 마지막 대화 결과 줄(`⎿ …`)의 내용. 없으면 nil. 실패했을 때 claude 가 뭐라고 했는지 보여 주는 데 쓴다.
    public static func lastResult(_ lines: [String]) -> String? {
        for line in lines.reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("⎿") {
                return String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

/// claude·codex 의 `/model` 선택창을 화면에서 읽는다.
///
/// 둘 다 번호 붙은 행 목록이고 커서가 있는 행 앞에 표시가 붙는다(codex `›`, claude `❯`).
/// 그래서 「지금 커서가 어느 행인가」를 읽고 그만큼만 움직인 뒤 다시 읽어 확인할 수 있다.
public enum Picker {
    public struct Row: Equatable, Sendable {
        public let number: Int
        /// 행 이름("High", "More reasoning…", "Opus 5.5"). `(current)`·`(default)`·`✔` 표시는 뗀다.
        public let label: String
        /// 커서가 이 행에 있다.
        public let selected: Bool
        /// 지금 쓰고 있는 값이라는 표시(codex `(current)`, claude `✔`)가 붙어 있다.
        public let current: Bool
    }

    /// 우리가 연 선택창의 머리말. 승인 창도 번호 행을 쓰므로, 이 머리말이 있을 때만 선택창으로 본다.
    static let headers = ["Select Model and Effort", "Select Reasoning Level", "Advanced Reasoning",  // codex
                          "Select model"]                                                           // claude

    /// 선택창 맨 아랫줄(안내)에만 나오는 문구. 승인 창의 안내("esc to cancel")와 겹치지 않는 것만 둔다.
    static let footerMarks = ["s to use this session only", "Enter to set as default",              // claude
                              "esc back"]                                                         // codex

    /// 화면 «맨 아래»에 떠 있는 선택창.
    public struct Open: Equatable, Sendable {
        public let header: String
        public let rows: [Row]
        /// 맨 아랫줄 안내(좁은 창에서 두 줄로 접히면 이어 붙인다).
        public let footer: String
    }

    /// 선택창은 화면의 맨 아래에 그려진다 — 맨 아랫줄이 선택창의 안내일 때만, 거기서 위로 올라가며 행과 머리말을 찾는다.
    /// 대화 내용에 선택창처럼 보이는 글이 있어도(2026-10-06 실측: 그 글의 행을 읽고 화살표를 보낼 뻔했다) 그것은 맨 아래가 아니다.
    /// 좁은 창에서는 행의 설명이 깊게 들여쓴 다음 줄로 접힌다 — 그런 줄은 건너뛴다.
    public static func open(_ lines: [String]) -> Open? {
        let shown = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // 안내 줄: 마지막 세 줄 안에 있어야 한다(접히면 두세 줄이 된다).
        guard let footerAt = shown.indices.suffix(3).last(where: { index in footerMarks.contains { shown[index].contains($0) } }) else {
            return nil
        }
        let footerStart = shown.indices.suffix(3).first(where: { index in footerMarks.contains { shown[index].contains($0) } }) ?? footerAt
        let footer = shown[footerStart...].map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")

        var index = footerStart - 1
        // 행과 안내 사이: effort 줄 · 경고 · "… +2 models" · 마지막 행의 접힌 줄.
        var skipped = 0
        while index >= 0, row(shown[index]) == nil, skipped < 8 { index -= 1; skipped += 1 }
        var rows: [Row] = []
        while index >= 0 {
            if let found = row(shown[index]) {
                rows.insert(found, at: 0)
            } else if !isContinuation(shown[index]) {
                break
            }
            index -= 1
        }
        guard !rows.isEmpty else { return nil }
        // 머리말과 행 사이: 설명 문장(좁으면 여러 줄) · codex 의 경고 줄.
        skipped = 0
        while index >= 0, skipped < 6 {
            let text = shown[index].trimmingCharacters(in: .whitespaces)
            if headers.contains(where: { text.hasPrefix($0) }) { return Open(header: text, rows: rows, footer: footer) }
            index -= 1
            skipped += 1
        }
        return nil
    }

    /// 접힌 줄: 번호 없이 깊게 들여쓴 줄(행의 설명이 넘친 것).
    static func isContinuation(_ line: String) -> Bool {
        line.prefix(while: { $0 == " " }).count >= 8
    }

    public static func isOpen(_ lines: [String]) -> Bool {
        open(lines) != nil
    }

    /// 맨 아래 선택창의 번호 행들. 선택창이 아니면 빈 배열.
    public static func rows(_ lines: [String]) -> [Row] {
        open(lines)?.rows ?? []
    }

    /// codex: `› 3. High (current)   설명` · `  4. Extra high       설명`
    /// claude: `   ❯ 2.  Opus 5.5 ✔     설명` · `     3.  Fable 5.1   설명` · `   ↓ 10. Opus 4.7   설명`(아래에 더 있음)
    static func row(_ line: String) -> Row? {
        var rest = Substring(line).drop(while: { $0 == " " })
        var selected = false
        if let first = rest.first, first == "›" || first == "❯" {
            selected = true
            rest = rest.dropFirst()
        } else if let first = rest.first, first == "↓" || first == "↑" {
            rest = rest.dropFirst()
        }
        rest = rest.drop(while: { $0 == " " })
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, let number = Int(digits), rest.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        var label = String(rest.dropFirst(digits.count + 1).drop(while: { $0 == " " }))
        if let gap = label.range(of: "  ") { label = String(label[..<gap.lowerBound]) }
        let current = label.contains("(current)") || label.contains("✔")
        for mark in [" (current)", " (default)", " ✔"] {
            label = label.replacingOccurrences(of: mark, with: "")
        }
        label = label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return Row(number: number, label: label, selected: selected, current: current)
    }

    /// `wanted` 에 해당하는 행. 이름이 똑같은 행이 먼저고, 없으면 그 낱말로 시작하는 첫 행이다
    /// ("opus" → 맨 위의 "Opus 5.5", "More reasoning" → "More reasoning…"). "High" 가 "Extra high" 나 "Opus 5" 가 "Opus 5.5" 에 걸리지 않게 경계를 본다.
    public static func index(of wanted: String, in rows: [Row]) -> Int? {
        let wanted = wanted.lowercased()
        if let exact = rows.firstIndex(where: { $0.label.lowercased() == wanted }) { return exact }
        return rows.firstIndex { row in
            let label = row.label.lowercased()
            guard label.hasPrefix(wanted), let next = label.dropFirst(wanted.count).first else { return false }
            return !next.isLetter && !next.isNumber && next != "."
        }
    }

    // MARK: claude 선택창의 effort 줄

    /// `● High effort ←/→ to adjust` → "high". effort 줄이 없거나 지원하지 않는 모델이면 nil.
    public static func claudeEffort(_ lines: [String]) -> String? {
        for line in lines.reversed() where line.contains("to adjust") {
            let words = line.split(separator: " ")
            if let index = words.firstIndex(of: "effort"), index > 0 { return words[index - 1].lowercased() }
        }
        return nil
    }

    /// claude 선택창이 effort 를 도는 순서(끝에서 처음으로 돈다 — 2.1.289 실측).
    public static let claudeEffortOrder = ["low", "medium", "high", "xhigh", "max"]

    /// `○ Effort not supported for Haiku 4.5`
    public static func claudeEffortUnsupported(_ lines: [String]) -> Bool {
        lines.contains { $0.contains("Effort not supported") }
    }
}

/// claude 프리셋의 모델 값을 선택창 행 이름으로 바꾼다.
public enum ClaudeModels {
    /// "opus" → "opus"(맨 위 Opus 행) · "claude-opus-5-5" → "opus 5.5" · "Opus 5.5" → "opus 5.5".
    public static func rowLabel(_ model: String) -> String {
        var text = model.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("claude-") { text = String(text.dropFirst("claude-".count)) }
        guard text.contains("-"), !text.contains(" ") else { return text }
        // 날짜 꼬리(-20251001)는 행 이름에 없다.
        let parts = text.split(separator: "-").map(String.init).filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        guard let family = parts.first else { return text }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(family) : "\(family) \(version)"
    }
}
