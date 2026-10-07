import Foundation

// 시험 단계의 터미널 연결. 셋 다 2026-10-07 맥북에서 재 본 것이다(tmux 3.7c · kitty 0.49.2 · WezTerm 20240203):
// 바이트가 그대로 들어가는지(붙여넣기 감싸기 없이), 화면이 얼마나 빨리 읽히는지, 없는 대상에 쓰면 어떻게 되는지.

/// tmux: `send-keys -H` 로 바이트를 16진수로 넣고 `capture-pane -p` 로 화면을 읽는다.
/// 실측: 쓰기 7ms, 쓴 글이 화면에 보이기까지 13~40ms, 없는 pane 에 쓰면 실패(종료 코드 1).
public struct TmuxIO: TerminalIO {
    public let tmux: String
    public let socket: String?
    public let pane: String

    private func run(_ arguments: [String]) -> ProcResult {
        Proc.run(tmux, (socket.map { ["-L", $0] } ?? []) + arguments, timeout: 5)
    }

    private func write(_ bytes: String) throws {
        let hex = Array(bytes.utf8).map { String(format: "%02x", $0) }
        let result = run(["send-keys", "-t", pane, "-H"] + hex)
        guard result.ok else {
            throw ModelSwitchError("tmux 에 입력하지 못했습니다: \(result.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    public func type(_ text: String) throws { try write(text) }
    public func press(_ key: Key) throws { try write(key.bytes) }

    public func screen() -> [String]? {
        let result = run(["capture-pane", "-p", "-t", pane])
        return result.ok ? result.out.components(separatedBy: "\n") : nil
    }
}

/// kitty: 원격 제어(`kitty @ send-text` · `get-text`). 사용자가 kitty 설정에서 원격 제어를 켜 둬야 한다.
/// 실측: 쓰기 26ms, 화면에 보이기까지 약 50ms. 🔴 없는 창에 `send-text` 를 해도 성공(종료 코드 0)을 돌려준다
/// — 그래서 쓰기 전에 그 창이 «있음»을 먼저 확인한다.
public struct KittyIO: TerminalIO {
    public let kitty: String
    public let socket: String
    public let window: String

    private func run(_ arguments: [String]) -> ProcResult {
        Proc.run(kitty, ["@", "--to", socket] + arguments, timeout: 5)
    }

    private var exists: Bool {
        let result = run(["ls", "--match", "id:\(window)"])
        guard result.ok, let json = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [[String: Any]] else { return false }
        return !json.isEmpty
    }

    private func write(_ bytes: String) throws {
        guard exists else { throw ModelSwitchError("kitty 창 \(window) 을(를) 찾지 못했습니다.") }
        let result = run(["send-text", "--match", "id:\(window)", "--", bytes])
        guard result.ok else {
            throw ModelSwitchError("kitty 에 입력하지 못했습니다: \(result.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    public func type(_ text: String) throws { try write(text) }
    public func press(_ key: Key) throws { try write(key.bytes) }

    public func screen() -> [String]? {
        let result = run(["get-text", "--match", "id:\(window)"])
        guard result.ok, !result.out.isEmpty || exists else { return nil }
        return result.out.components(separatedBy: "\n")
    }
}

/// WezTerm: `wezterm cli send-text --no-paste` · `get-text`.
/// 실측: 쓰기 15ms, 화면에 보이기까지 약 23ms, 없는 pane 은 실패. 🔴 `--no-paste` 가 없으면 글이 붙여넣기 표시로 감싸여 들어간다.
public struct WezTermIO: TerminalIO {
    public let wezterm: String
    public let pane: String

    private func run(_ arguments: [String]) -> ProcResult {
        Proc.run(wezterm, ["cli"] + arguments, timeout: 5)
    }

    private func write(_ bytes: String) throws {
        let result = run(["send-text", "--pane-id", pane, "--no-paste", "--", bytes])
        guard result.ok else {
            throw ModelSwitchError("WezTerm 에 입력하지 못했습니다: \(result.err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(120))")
        }
    }

    public func type(_ text: String) throws { try write(text) }
    public func press(_ key: Key) throws { try write(key.bytes) }

    public func screen() -> [String]? {
        let result = run(["get-text", "--pane-id", pane])
        return result.ok ? result.out.components(separatedBy: "\n") : nil
    }
}

/// iTerm2: AppleScript 의 `write text … newline NO` 로 바이트를 그대로 넣고 `contents` 로 화면을 읽는다.
/// 실측(2026-10-07, 맥북, iTerm2 3.7.3): `^S/model⏎` · `ESC[A ESC[B` · 한글이 그대로 도착했고 붙여넣기 표시로 감싸지 않았다.
/// 세션은 `unique id` 로 지정하므로 포커스가 다른 곳으로 옮겨져도 «읽은 세션에 쓴다».
/// `contents` 는 스크롤백까지 돌려주므로 화면 «맨 아래» 판정에 그대로 쓸 수 있다(마지막 줄들이 지금 화면의 아래쪽).
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

    /// 세션을 찾아 `body` 를 그 세션에서 실행하는 스크립트. 못 찾으면 오류.
    static func script(sessionID: String, body: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (unique id of s) is \(GhosttyIO.quoted(sessionID)) then
                            tell s
                                \(body)
                            end tell
                        end if
                    end repeat
                end repeat
            end repeat
            error "iTerm2 세션을 찾지 못했습니다"
        end tell
        """
    }

    private func write(_ bytes: String) throws {
        // `return` 이 있어야 찾은 뒤 반복을 끝낸다(없으면 아래의 «못 찾음» 오류까지 간다).
        let body = "write text \(ITermIO.expression(for: bytes)) newline NO\nreturn \"true\""
        let result = GhosttyIO.osascript(ITermIO.script(sessionID: sessionID, body: body))
        guard result.ok, result.out == "true" else {
            let detail = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ModelSwitchError("iTerm2 에 입력하지 못했습니다: \(detail.isEmpty ? "세션이 없습니다" : detail)")
        }
    }

    public func type(_ text: String) throws { try write(text) }
    public func press(_ key: Key) throws { try write(key.bytes) }

    public func screen() -> [String]? {
        // `contents` 는 스크롤백까지 준다(2026-10-07 실측: 화면 25줄에 88줄) — 화면 «맨 아래» 판정에 쓰려면 지금 화면의 줄만 남겨야 한다.
        // 줄 수·칸 수(`rows`·`columns`)는 같은 호출에서 읽어 글과 어긋나지 않게 한다.
        let body = "return ((rows as text) & linefeed & (columns as text) & linefeed & contents)"
        let result = GhosttyIO.osascript(ITermIO.script(sessionID: sessionID, body: body))
        guard result.ok else { return nil }
        return ITermIO.visibleLines(from: result.out)
    }

    /// `"<rows>\n<columns>\n<contents>"` 에서 지금 화면의 줄들. 줄·칸 수를 못 읽으면 nil(스크롤백이 섞인 글을 현재 화면으로 쓰지 않는다).
    ///
    /// `rows` 는 «물리적인» 행 수인데 `contents` 는 글줄 단위라, 긴 줄이 접혀 여러 행을 차지할 수 있다(합쳐서 줄 수가 적다).
    /// 그래서 맨 아래에서부터 줄마다 «차지하는 행 수»(폭 ÷ 칸 수, 올림)를 더해 `rows` 를 채울 때까지만 가져온다.
    /// 행 수를 넉넉히(폭이 넓은 글자는 2칸) 세므로 틀리면 위쪽 줄을 덜 가져오는 쪽이다 — 맨 아래 입력창 판정에는 안전한 방향이다.
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

    /// 터미널 칸 수로 센 폭(넉넉히): 한글·한자·이모지 등은 2칸.
    static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            let v = scalar.value
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE6F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v)
            return total + (wide ? 2 : 1)
        }
    }
}
