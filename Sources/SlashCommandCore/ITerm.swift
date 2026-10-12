import AppKit
import ApplicationServices
import Foundation

// iTerm2: 맨 앞 세션은 AppleScript 로 알고(`current session of current window` 의 `unique id` · `tty`), 그 세션에 `write text … newline NO` 로
// 바이트를 넣고 `contents` 로 화면을 읽는다. 2026-10-07 맥북(iTerm2 3.7.3)에서 재 본 것 — 바이트가 그대로 들어가고 붙여넣기 표시로 감싸지 않는다.

/// iTerm2 의 «입력 방송»(Broadcast Input) 상태.
///
/// 켜져 있으면 AppleScript `write text` 도 다른 칸(·다른 탭)에 같이 들어간다 — 2026-10-07 맥북 실측: 「모든 탭의 모든 칸에 입력 보내기」를
/// 켠 두 칸 창에서 한 칸에 `write text` 를 했더니 다른 칸에도 같은 글이 도착했다. 다른 칸은 입력창이 보이는지 확인한 적이 없으므로
/// 방송 중에는 보내지 않는다. 상태는 iTerm2 의 Shell ▸ Broadcast Input 메뉴 체크 표시를 접근성(AX)으로 읽는다(손쉬운 사용 권한 필요).
/// 방송은 «창마다» 따로 켜지고 메뉴는 «맨 앞 창» 의 상태를 보여 주므로, 쓰는 세션이 맨 앞 창에 있을 때만 이 상태를 믿을 수 있다(`ITermIO` 가 확인).
public enum ITermBroadcast {
    public enum State: Equatable, Sendable {
        case off
        case on(String)
        /// 손쉬운 사용 권한이 없어 메뉴를 읽지 못했다.
        case notTrusted
        /// 메뉴를 못 찾았거나 체크 표시를 알아보지 못했다 — 방송이 꺼져 있다고 말할 수 없으므로 보내지 않는다.
        case unknown

        public var allowsSending: Bool { self == .off }
    }

    struct MenuItem: Equatable {
        let title: String
        let marked: Bool
    }

    /// 메뉴 항목들로 상태를 가른다. 「현재 세션에만 입력」이 체크돼 있어야 꺼진 것이다.
    static func classify(_ items: [MenuItem]) -> State {
        if let active = items.first(where: { $0.marked && $0.title.localizedCaseInsensitiveContains("All Panes") }) {
            return .on(active.title)
        }
        if items.contains(where: { $0.marked && $0.title.localizedCaseInsensitiveContains("Current Session Only") }) {
            return .off
        }
        // 메뉴가 없거나, 체크된 항목이 없거나, 모르는 항목이 체크됐다(칸을 골라 묶은 방송 등) — 형식이 달라졌을 수도 있다.
        return .unknown
    }

    /// 쓰기 직전마다 새로 읽는다 — 앞서 «꺼짐» 이었다는 기억으로 다음 쓰기를 허락하지 않는다(그 사이 켜질 수 있다).
    public static func state() -> State {
        guard GhosttyScreen.trusted() else { return .notTrusted }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Detector.itermBundleID).first else { return .unknown }
        return classify(menuItems(pid: app.processIdentifier))
    }

    /// 사람이 보는 줄들(`doctor`).
    public static func report() -> [String] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Detector.itermBundleID).first else { return ["iTerm2 not running"] }
        let items = GhosttyScreen.trusted() ? menuItems(pid: app.processIdentifier) : []
        return ["broadcast     \(state())"] + items.map { "  [\($0.marked ? "x" : " ")] \($0.title)" }
    }

    static func menuItems(pid: pid_t) -> [MenuItem] {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = attribute(app, "AXMenuBar") else { return [] }
        var items: [MenuItem] = []
        for top in children(of: bar as! AXUIElement) where title(of: top) == "Shell" {
            for menu in children(of: top) {
                for entry in children(of: menu) where title(of: entry).hasPrefix("Broadcast") {
                    for submenu in children(of: entry) {
                        for item in children(of: submenu) {
                            let name = title(of: item)
                            guard !name.isEmpty else { continue }
                            let mark = attribute(item, "AXMenuItemMarkChar") as? String ?? ""
                            items.append(MenuItem(title: name, marked: !mark.trimmingCharacters(in: .whitespaces).isEmpty))
                        }
                    }
                }
            }
        }
        return items
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (attribute(element, "AXChildren") as? [AXUIElement]) ?? []
    }

    private static func title(of element: AXUIElement) -> String {
        (attribute(element, "AXTitle") as? String) ?? ""
    }
}

/// 세션은 `unique id` 로 지정하므로 포커스가 다른 곳으로 옮겨져도 «읽은 세션에 쓴다».
public struct ITermIO: TerminalIO {
    public let sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// 바이트를 AppleScript 식으로: 보통 글자는 따옴표 문자열, 제어 문자는 `(ASCII character N)` 으로 잇는다.
    static func expression(for text: String) -> String {
        var parts: [String] = []
        var literal = ""
        func flush() { if !literal.isEmpty { parts.append(GhosttyIO.quoted(literal)); literal = "" } }
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                flush()
                parts.append("(ASCII character \(scalar.value))")
            } else {
                literal.unicodeScalars.append(scalar)
            }
        }
        flush()
        return parts.isEmpty ? "\"\"" : parts.joined(separator: " & ")
    }

    static let missing = "missing"

    /// 그 세션에서 `body` 를 실행하는 스크립트. `frontWindowOnly` 면 iTerm2 의 맨 앞(현재) 창에서만 찾는다. 못 찾으면 `missing` 을 돌려준다.
    /// `body` 는 `return` 으로 끝나야 한다.
    ///
    /// 세션 id 들을 «한 번의 호출» 로 받아 어느 탭인지 찾고, 그 탭의 `session id "…"` 로 바로 짚는다. 창·탭·세션을 하나씩 돌며 id 를 물으면
    /// 호출 수가 세션 수만큼 늘어난다(2026-10-12 집 맥 2: 세션 4개에서 화면 읽기 한 번이 200ms — 호출 하나가 15~20ms).
    static func script(sessionID: String, frontWindowOnly: Bool, body: String) -> String {
        let id = GhosttyIO.quoted(sessionID)
        func search(window: String, indent: String) -> String {
            """
            \(indent)repeat with i from 1 to (count of groups)
            \(indent)    if (item i of groups) contains \(id) then
            \(indent)        tell session id \(id) of tab i of \(window)
            \(indent)            \(body.replacingOccurrences(of: "\n", with: "\n\(indent)            "))
            \(indent)        end tell
            \(indent)    end if
            \(indent)end repeat
            """
        }
        if frontWindowOnly {
            return """
            tell application "iTerm2"
                if (count of windows) is 0 then return \(GhosttyIO.quoted(missing))
                set groups to unique id of sessions of tabs of current window
            \(search(window: "current window", indent: "    "))
                return \(GhosttyIO.quoted(missing))
            end tell
            """
        }
        return """
        tell application "iTerm2"
            set everything to unique id of sessions of tabs of windows
            repeat with k from 1 to (count of everything)
                set groups to item k of everything
        \(search(window: "window k", indent: "        "))
            end repeat
            return \(GhosttyIO.quoted(missing))
        end tell
        """
    }

    private func inFrontWindow() -> Bool {
        let result = GhosttyIO.osascript(ITermIO.script(sessionID: sessionID, frontWindowOnly: true, body: "return \"true\""))
        return result.ok && result.out == "true"
    }

    private func write(_ bytes: String) throws {
        // 입력 방송이 켜져 있으면 이 글이 다른 칸에도 들어간다 — 그 칸들은 확인한 적이 없으므로 보내지 않는다.
        // 방송은 창마다 켜지고 메뉴는 맨 앞 창의 상태만 보여 준다 — 쓰는 세션이 맨 앞 창 안에 있어야 그 상태를 믿을 수 있다.
        // 확인 → 메뉴 읽기 → «맨 앞 창에 있을 때만 쓰기» 로 감싼다: 메뉴를 읽는 사이에 창이 바뀌었으면 쓰는 스크립트가 쓰지 않는다.
        let notFront = SlashCommandError(loc("Not sent: the session is not in iTerm2's front window, so whether Broadcast Input is off cannot be checked."))
        guard inFrontWindow() else { throw notFront }
        switch ITermBroadcast.state() {
        case .off: break
        case .on(let mode):
            throw SlashCommandError(loc("Not sent: iTerm2 Broadcast Input is on (%@), so the keys would go to other panes too. Choose Shell ▸ Broadcast Input ▸ Send Input to Current Session Only, then press again.", mode))
        case .notTrusted:
            var error = SlashCommandError(loc("Not sent: Slash Command needs the Accessibility permission to check that iTerm2 Broadcast Input is off. Turn it on in System Settings → Privacy & Security → Accessibility, then press again."))
            error.needsAccessibility = true
            throw error
        case .unknown:
            throw SlashCommandError(loc("Not sent: could not confirm from iTerm2's Shell ▸ Broadcast Input menu that it is off."))
        }
        let body = "write text \(ITermIO.expression(for: bytes)) newline NO\nreturn \"true\""
        let result = GhosttyIO.osascript(ITermIO.script(sessionID: sessionID, frontWindowOnly: true, body: body))
        if result.ok, result.out == ITermIO.missing { throw notFront }
        guard result.ok, result.out == "true" else {
            throw SlashCommandError(loc("Could not type into iTerm2: %@", result.err.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    public func type(_ text: String) throws { try write(text) }
    public func press(_ key: Key) throws { try write(key.bytes) }

    public func screen() -> [String]? {
        // `contents` 는 스크롤백까지 준다(2026-10-07 실측: 화면 25줄에 88줄) — 화면 «맨 아래» 판정에 쓰려면 지금 화면의 줄만 남겨야 한다.
        // 줄 수·칸 수(`rows`·`columns`)는 같은 호출에서 읽어 글과 어긋나지 않게 한다.
        let body = "return ((rows as text) & linefeed & (columns as text) & linefeed & contents)"
        let result = GhosttyIO.osascript(ITermIO.script(sessionID: sessionID, frontWindowOnly: false, body: body))
        guard result.ok else { return nil }
        return ITermIO.visibleLines(from: result.out)
    }

    /// `"<rows>\n<columns>\n<contents>"` 에서 지금 화면의 줄들. 줄·칸 수를 못 읽으면 nil(스크롤백이 섞인 글을 현재 화면으로 쓰지 않는다).
    ///
    /// `rows` 는 «물리적인» 행 수인데 `contents` 는 글줄 단위라, 긴 줄이 접혀 여러 행을 차지할 수 있다(합쳐서 줄 수가 적다).
    /// 그래서 맨 아래에서부터 줄마다 «차지하는 행 수»(폭 ÷ 칸 수, 올림)를 더해 `rows` 를 채울 때까지만 가져온다.
    ///
    /// 폭은 iTerm2 의 기본 설정대로 센다(`displayWidth`). 🔴 전에는 ASCII 가 아닌 글자를 전부 2칸으로 «넉넉히» 셌는데, 그러면 칸 수에 꼭 맞는
    /// 줄(`› 1. …` · `enter select · esc back` 처럼 끝까지 채워진 행, claude 의 구분선)이 2행으로 세어져 «보이는» 윗줄을 버린다 — 11줄짜리 칸에서
    /// codex 선택창의 머리말이 잘려 선택창을 못 알아보고 열어 둔 채 끝났다(2026-10-12 집 맥 2 실측 · PR #27 리뷰). 폭을 적게 세는 쪽은 위쪽에
    /// 스크롤백 몇 줄이 더 딸려올 뿐이다: 입력창·선택창 판정은 맨 아래에서부터 읽으므로 아래쪽 줄은 어느 쪽으로 틀려도 같다.
    static func visibleLines(from output: String) -> [String]? {
        let text = output.replacingOccurrences(of: "\r", with: "\n")
        let head = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard head.count == 3, let rows = Int(head[0]), rows > 0, let columns = Int(head[1]), columns > 0 else { return nil }
        var lines = String(head[2]).components(separatedBy: "\n")
        // 글 끝의 줄바꿈이 만드는 마지막 빈 원소는 화면 줄이 아니다.
        if lines.last == "" { lines.removeLast() }
        var used = 0
        var kept: [String] = []
        for line in lines.reversed() {
            used += max(1, (displayWidth(line) + columns - 1) / columns)
            if used > rows { break }
            kept.append(line)
        }
        return kept.reversed()
    }

    /// 터미널 칸 수로 센 폭 — iTerm2 의 기본 설정(«모호한 폭» 글자는 1칸)대로: 한글·한자·가나·전각 글자·이모지는 2칸, 결합 문자와 폭 없는 글자는 0칸,
    /// 나머지(상자 선 `─` · `›` · `·` · `❯` 포함)는 1칸. 「Ambiguous characters are double-width」 를 켠 프로필에서는 실제보다 적게 센다(위 설명대로 안전한 쪽).
    static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + width(of: $1) }
    }

    static func width(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value < 0x300 { return 1 }
        switch value {
        case 0x0300...0x036F, 0x200B...0x200F, 0x2060...0x2064, 0xFE00...0xFE0F, 0xFEFF, 0xE0100...0xE01EF:
            return 0
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}

extension Detector {
    public static let itermBundleID = "com.googlecode.iterm2"

    /// `"<unique id>\n<tty>\n<name>"` → (id, tty, name). 창이 없으면(빈 글) nil.
    static func itermSession(from output: String) -> (id: String, tty: String, name: String)? {
        let parts = output.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// iTerm2 의 맨 앞 창이 포커스한 세션. 에이전트는 그 세션의 tty 에서 도는 프로세스로 가리고, 거기서 tmux 가 돌면 그 칸으로 들어간다.
    public static func iterm() throws -> Target {
        let script = """
        tell application "iTerm2"
            if (count of windows) is 0 then return ""
            tell current session of current window
                return (unique id) & linefeed & (tty) & linefeed & (name)
            end tell
        end tell
        """
        let result = GhosttyIO.osascript(script)
        guard result.ok else {
            throw SlashCommandError(loc("Could not read the frontmost %@ terminal: %@", "iTerm2", result.err.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        guard let found = itermSession(from: result.out) else { throw SlashCommandError(loc("iTerm2 has no open window.")) }
        guard let device = TTYProcesses.device(ofTTY: found.tty) else {
            throw SlashCommandError(loc("The frontmost %@ terminal (%@) is not a supported agent session (Claude Code · Codex · Grok · Cursor · Antigravity · OpenCode).", "iTerm2", found.name))
        }
        return try session(host: .iterm(sessionID: found.id), appName: "iTerm2", label: found.name, table: ProcessTable.snapshot(), device: device)
    }
}
