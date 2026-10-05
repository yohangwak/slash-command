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

    /// codex 의 입력창은 `›` 로 시작한다. 승인 창·선택창도 `›` 로 선택 행을 표시하지만 `› 1. …` 처럼 번호가 붙는다.
    static func codexComposerVisible(_ screen: [String]) -> Bool {
        let marked = screen.filter { $0.hasPrefix("›") }
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
    /// 화면에서 마지막 결과 줄(`⎿ …`)의 내용. 없으면 nil.
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
