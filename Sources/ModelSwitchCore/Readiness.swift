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
    static func claudePromptVisible(_ screen: [String]) -> Bool {
        let lines = screen.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for (index, line) in lines.enumerated() where line.hasPrefix("❯") && index > 0 {
            if lines[index - 1].hasPrefix("─") { return true }
        }
        return false
    }

    /// codex 의 입력창은 `›` 로 시작한다(effort 가 ultra 일 때는 `»` — 0.160.0 실측).
    /// 승인 창·선택창도 `›` 로 선택 행을 표시하지만 `› 1. …` 처럼 번호가 붙는다.
    static func codexComposerVisible(_ screen: [String]) -> Bool {
        let marked = screen.filter { $0.hasPrefix("›") || $0.hasPrefix("»") }
        guard !marked.isEmpty else { return false }
        return !marked.contains(where: isNumberedChoice)
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

    /// claude 가 대화 도중 모델을 바꾸기 전에 띄우는 확인 창에서, 바꾸려는 모델 이름. 그 창이 아니면 nil.
    ///
    ///     Switch model?
    ///     Your next response will be slower and use more tokens
    ///     This conversation is cached for the current model. Switching to Sonnet 5.5 means …
    ///     ❯ 1. Yes, switch to Sonnet 5.5
    ///       2. No, go back
    ///
    /// 커서(`❯`)가 「Yes」 항목에 있을 때만 이름을 돌려준다 — Enter 를 눌러도 되는지의 판단에 쓰기 때문이다.
    public static func switchPrompt(_ lines: [String]) -> String? {
        guard let header = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Switch model?" }) else { return nil }
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

    /// 머리말 줄의 위치. 선택창이 아니면 nil.
    static func headerIndex(_ lines: [String]) -> Int? {
        lines.lastIndex { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return headers.contains { text.hasPrefix($0) }
        }
    }

    public static func isOpen(_ lines: [String]) -> Bool {
        !rows(lines).isEmpty
    }

    /// 머리말 아래의 번호 행들. 선택창이 아니면 빈 배열.
    public static func rows(_ lines: [String]) -> [Row] {
        guard let header = headerIndex(lines) else { return [] }
        var rows: [Row] = []
        for line in lines[(header + 1)...] {
            if let row = row(line) {
                rows.append(row)
            } else if !rows.isEmpty {
                break
            }
        }
        return rows
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

public enum CodexScreen {
    /// 입력창 아래 상태 줄(`  GPT-6.1-Sol high · ~/path`)에서 지금 모델 이름과 effort.
    /// `known` 에 있는 모델 이름일 때만 돌려준다 — 다른 글을 상태 줄로 잘못 읽지 않기 위해서다.
    public static func status(_ lines: [String], known: [String]) -> (model: String, effort: String)? {
        for line in lines.reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let dot = text.range(of: " · ") else { continue }
            let words = text[..<dot.lowerBound].split(separator: " ")
            guard words.count == 2, known.contains(String(words[0])) else { continue }
            return (String(words[0]), String(words[1]))
        }
        return nil
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
