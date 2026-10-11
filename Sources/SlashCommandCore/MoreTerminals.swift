import Foundation

// tmux · kitty · WezTerm 에 쓰고 읽는 연결. 셋 다 2026-10-07 맥북에서 재 본 것이다(tmux 3.7c · kitty 0.49.2 · WezTerm 20240203):
// 바이트가 그대로 들어가는지(붙여넣기 감싸기 없이), 화면이 얼마나 빨리 읽히는지, 없는 대상에 쓰면 어떻게 되는지.

/// tmux: `send-keys -H` 로 바이트를 16진수로 넣고 `capture-pane -p` 로 화면을 읽는다.
/// 실측: 쓰기 7ms, 쓴 글이 화면에 보이기까지 13~40ms, 없는 pane 에 쓰면 실패(종료 코드 1).
public struct TmuxIO: TerminalIO {
    public let tmux: String
    public let socket: String?
    public let pane: String

    private func run(_ arguments: [String]) -> ProcResult {
        Proc.run(tmux, TmuxFront.arguments(socket: socket) + arguments, timeout: 5)
    }

    static let synchronizedMark = "SLASHCOMMAND-PANES-SYNCHRONIZED"

    /// tmux 명령 글 안에 넣을 대상 이름(세션 이름에 빈칸·따옴표가 있을 수 있다).
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 그 칸에 바이트를 넣는 tmux 인자. 🔴 그 창의 `synchronize-panes` 가 켜져 있으면 `send-keys -t <칸>` 은 대상을 적었어도 «다른 칸들에도»
    /// 같은 글을 넣는다(2026-10-12 실측 — PR #25 리뷰). 확인과 쓰기를 tmux 의 한 명령(`if-shell -F`)으로 묶어, 켜져 있으면 쓰지 않고 표지를 찍는다.
    static func sendArguments(pane: String, bytes: String) -> [String] {
        let hex = Array(bytes.utf8).map { String(format: "%02x", $0) }.joined(separator: " ")
        return ["if-shell", "-F", "-t", pane, "#{pane_synchronized}",
                "display-message -p \(synchronizedMark)", "send-keys -t \(quoted(pane)) -H \(hex)"]
    }

    private func write(_ bytes: String) throws {
        let result = run(TmuxIO.sendArguments(pane: pane, bytes: bytes))
        guard result.ok else {
            throw SlashCommandError(loc("Could not type into tmux: %@", result.err.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if result.out.contains(TmuxIO.synchronizedMark) {
            throw SlashCommandError(loc("Not sent: tmux `synchronize-panes` is on in this window, so the keys would go to its other panes too. Turn it off, then press again."))
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
        guard exists else { throw SlashCommandError(loc("Could not find kitty window %@.", window)) }
        let result = run(["send-text", "--match", "id:\(window)", "--", bytes])
        guard result.ok else {
            throw SlashCommandError(loc("Could not type into kitty: %@", result.err.trimmingCharacters(in: .whitespacesAndNewlines)))
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
    /// 그 GUI 의 mux 소켓. 대상을 찾을 때 쓴 것과 같은 GUI 에 쓰고 읽는다.
    public var socket: String?
    public let pane: String

    private func run(_ arguments: [String]) -> ProcResult {
        Proc.run(wezterm, ["cli"] + arguments, env: WezTermFront.environment(socket: socket), timeout: 5)
    }

    private func write(_ bytes: String) throws {
        let result = run(["send-text", "--pane-id", pane, "--no-paste", "--", bytes])
        guard result.ok else {
            throw SlashCommandError(loc("Could not type into WezTerm: %@", result.err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(120)))
        }
    }

    public func type(_ text: String) throws { try write(text) }
    public func press(_ key: Key) throws { try write(key.bytes) }

    public func screen() -> [String]? {
        let result = run(["get-text", "--pane-id", pane])
        return result.ok ? result.out.components(separatedBy: "\n") : nil
    }
}
