import Carbon
import Foundation

/// 한 터미널에 글자·키를 넣고, 가능하면 화면을 읽는다.
public protocol TerminalIO {
    func type(_ text: String) throws
    func press(_ key: Key) throws
    /// 지금 화면의 줄들. 화면을 읽을 수 없는 터미널이면 nil.
    func screen() -> [String]?
    /// 입력창에 쓰던 글. 알 수 없으면 nil.
    func draft() -> String?
    /// 화면과 초안을 한 번에. 따로 주는 터미널(Orca)은 한 번의 호출로 둘 다 준다.
    func snapshot() -> ScreenSnapshot?
}

public struct ScreenSnapshot: Sendable {
    public let lines: [String]
    /// 입력창에 쓰던 글. 터미널이 따로 주지 않으면 nil.
    public let draft: String?
}

public extension TerminalIO {
    func draft() -> String? { nil }

    func snapshot() -> ScreenSnapshot? {
        screen().map { ScreenSnapshot(lines: $0, draft: draft()) }
    }
}

// MARK: - Orca

public struct OrcaIO: TerminalIO {
    /// `orca` 명령의 위치. 앱에 직접 말을 걸지 못할 때만 쓴다.
    public let orca: String?
    public let handle: String

    public init(orca: String?, handle: String) {
        self.orca = orca
        self.handle = handle
    }

    /// Orca 터미널 안에서 실행돼도 「그 터미널」이 아니라 지정한 핸들만 겨냥하도록 ORCA_* 환경변수를 뺀다.
    static var cleanEnv: [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ORCA_") }
    }

    /// 바이트를 그대로 넣는다. Enter 도 `\r` 로 글에 넣어 보낸다.
    private func send(_ text: String) throws {
        let params: [String: Any] = ["terminal": handle, "text": text, "enter": false, "interrupt": false,
                                     "client": ["id": "modelswitch", "type": "desktop"]]
        switch OrcaRuntime.call("terminal.send", params) {
        case .success(let result):
            guard (result["send"] as? [String: Any])?["accepted"] as? Bool == true else {
                throw ModelSwitchError("Orca 터미널이 입력을 받지 않았습니다.")
            }
            return
        case .failure(.failed(let message)):
            // 이미 들어갔을 수 있다 — 다른 길로 다시 보내지 않는다.
            throw ModelSwitchError("Orca 터미널에 입력하지 못했습니다: \(message)")
        case .failure(.unavailable):
            break
        }
        guard let orca else { throw ModelSwitchError("Orca 앱에 연결하지 못했고 orca 명령도 찾지 못했습니다.") }
        let result = Proc.run(orca, ["terminal", "send", "--terminal", handle, "--text", text, "--json"],
                              env: OrcaIO.cleanEnv, cwd: "/", timeout: 15)
        guard result.ok else {
            throw ModelSwitchError("Orca 터미널에 입력하지 못했습니다: \(Self.errorSummary(result))")
        }
    }

    public func type(_ text: String) throws {
        try send(text)
    }

    public func press(_ key: Key) throws {
        try send(key.bytes)
    }

    private func readScreen() -> [String: Any]? {
        var terminal: [String: Any]?
        if case .success(let result) = OrcaRuntime.call("terminal.read", ["terminal": handle, "screen": true]) {
            terminal = result["terminal"] as? [String: Any]
        } else if let orca {
            let result = Proc.run(orca, ["terminal", "read", "--terminal", handle, "--screen", "--json"],
                                  env: OrcaIO.cleanEnv, cwd: "/", timeout: 10)
            if result.ok, let json = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any] {
                terminal = (json["result"] as? [String: Any])?["terminal"] as? [String: Any]
            }
        }
        // "screen-unavailable" 은 화면이 아니라 누적 출력이라 판정에 쓰지 않는다.
        guard let terminal, terminal["source"] as? String == "screen" else { return nil }
        return terminal
    }

    public func screen() -> [String]? {
        readScreen()?["tail"] as? [String]
    }

    public func snapshot() -> ScreenSnapshot? {
        guard let terminal = readScreen(), let lines = terminal["tail"] as? [String] else { return nil }
        return ScreenSnapshot(lines: lines, draft: Self.draft(in: terminal))
    }

    /// Orca 는 입력창의 글을 화면 줄에서 떼어 `draft` 로 따로 준다. 입력창이 비어 있으면 항목 자체가 없다(2026-10-06 실측).
    public func draft() -> String? {
        readScreen().map(Self.draft(in:))
    }

    static func draft(in terminal: [String: Any]) -> String {
        terminal["draft"] as? String ?? ""
    }

    static func errorSummary(_ result: ProcResult) -> String {
        if result.timedOut { return "시간 초과" }
        if let json = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["code"] as? String) ?? "알 수 없는 오류"
        }
        let text = result.err.isEmpty ? result.out : result.err
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }
}

// MARK: - Ghostty

/// Ghostty 는 AppleScript 의 `perform action "text:…"` 로 pty 에 바이트를 그대로 쓰고, 화면은 접근성(AX)으로 읽는다.
/// (`input text` 는 붙여넣기로 감싸져 선택창의 숫자·글자 키로 먹지 않고, `send key` 는 화살표·숫자 이름을 모른다.)
public struct GhosttyIO: TerminalIO {
    public let terminalID: String

    public init(terminalID: String) {
        self.terminalID = terminalID
    }

    /// AppleScript 를 이 프로세스 안에서 실행한다. `osascript` 를 띄우면 한 번에 0.2~0.3초가 든다(2026-10-06 실측).
    /// 결과는 `osascript` 가 찍던 것과 같은 꼴(참·거짓은 "true"·"false")로 돌려준다.
    static func osascript(_ script: String) -> ProcResult {
        // NSAppleScript 는 주 스레드에서만 쓰게 돼 있다.
        if Thread.isMainThread { return runAppleScript(script) }
        return DispatchQueue.main.sync { runAppleScript(script) }
    }

    private static func runAppleScript(_ source: String) -> ProcResult {
        guard let script = NSAppleScript(source: source) else {
            return Proc.run("/usr/bin/osascript", ["-e", source], timeout: 10)
        }
        var error: NSDictionary?
        let value = script.executeAndReturnError(&error)
        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "AppleScript 오류"
            let number = (error[NSAppleScript.errorNumber] as? Int).map { " (\($0))" } ?? ""
            return ProcResult(status: 1, out: "", err: message + number, timedOut: false)
        }
        let out: String
        switch value.descriptorType {
        case typeTrue: out = "true"
        case typeFalse: out = "false"
        case typeBoolean: out = value.booleanValue ? "true" : "false"
        default: out = value.stringValue ?? ""
        }
        return ProcResult(status: 0, out: out, err: "", timedOut: false)
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Ghostty 의 `text:` 액션은 Zig 문자열 이스케이프를 푼다. 제어 문자와 역슬래시만 이스케이프하고 나머지는 그대로 둔다.
    static func actionEscaped(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar == "\\" {
                out += "\\\\"
            } else if scalar.value < 0x20 || scalar.value == 0x7F {
                out += String(format: "\\x%02x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private func write(_ bytes: String) throws {
        let action = "text:" + GhosttyIO.actionEscaped(bytes)
        let script = """
        tell application "Ghostty" to perform action \(GhosttyIO.quoted(action)) \
        on (first terminal of front window whose id is \(GhosttyIO.quoted(terminalID)))
        """
        let result = GhosttyIO.osascript(script)
        guard result.ok, result.out.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            let detail = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ModelSwitchError("Ghostty 에 입력하지 못했습니다: \(detail.isEmpty ? "대상 터미널이 더 이상 맨 앞 창에 없습니다" : detail)")
        }
    }

    public func type(_ text: String) throws {
        try write(text)
    }

    public func press(_ key: Key) throws {
        try write(key.bytes)
    }

    public func screen() -> [String]? {
        GhosttyScreen.lines()
    }
}
