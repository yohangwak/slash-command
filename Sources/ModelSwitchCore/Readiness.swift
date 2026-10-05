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

/// codex 의 `/model` 선택창을 화면에서 읽는다.
public enum CodexPicker {
    public struct Row: Equatable, Sendable {
        public let number: Int
        /// 행 이름("High", "More reasoning…"). `(current)`·`(default)` 표시는 뗀다.
        public let label: String
        /// 커서(`›`)가 이 행에 있다.
        public let selected: Bool
    }

    /// 우리가 연 선택창의 머리말. 승인 창도 번호 행을 쓰므로, 이 머리말이 있을 때만 선택창으로 본다.
    static let headers = ["Select Model and Effort", "Select Reasoning Level", "Advanced Reasoning"]

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

    /// `› 3. High (current)   설명` 또는 `  4. Extra high       설명`.
    static func row(_ line: String) -> Row? {
        let selected = line.hasPrefix("›")
        let rest = (selected ? line.dropFirst() : Substring(line)).drop(while: { $0 == " " })
        let digits = rest.prefix(while: \.isNumber)
        guard !digits.isEmpty, let number = Int(digits), rest.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        var label = String(rest.dropFirst(digits.count + 2))
        if let gap = label.range(of: "  ") { label = String(label[..<gap.lowerBound]) }
        for mark in [" (current)", " (default)"] {
            label = label.replacingOccurrences(of: mark, with: "")
        }
        return Row(number: number, label: label.trimmingCharacters(in: .whitespaces), selected: selected)
    }

    /// 행 이름이 `wanted` 인가. "High" 가 "Higher…" 에 걸리지 않게 낱말 경계를 본다.
    static func matches(_ row: Row, _ wanted: String) -> Bool {
        let label = row.label.lowercased()
        let wanted = wanted.lowercased()
        guard label.hasPrefix(wanted) else { return false }
        return label.dropFirst(wanted.count).first.map { !$0.isLetter && !$0.isNumber } ?? true
    }
}
