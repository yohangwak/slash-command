import Foundation

/// 한 터미널에 글자·키를 넣고, 가능하면 화면을 읽는다.
public protocol TerminalIO {
    func type(_ text: String) throws
    func press(_ key: Key) throws
    /// 지금 화면의 줄들. 화면을 읽을 수 없는 터미널이면 nil.
    func screen() -> [String]?
    /// 입력창에 쓰던 글. 알 수 없으면 nil.
    func draft() -> String?
}

public extension TerminalIO {
    func draft() -> String? { nil }
}

// MARK: - Orca

public struct OrcaIO: TerminalIO {
    public let orca: String
    public let handle: String

    public init(orca: String, handle: String) {
        self.orca = orca
        self.handle = handle
    }

    /// Orca 터미널 안에서 실행돼도 「그 터미널」이 아니라 지정한 핸들만 겨냥하도록 ORCA_* 환경변수를 뺀다.
    static var cleanEnv: [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ORCA_") }
    }

    private func send(_ args: [String]) throws {
        let result = Proc.run(orca, ["terminal", "send", "--terminal", handle] + args + ["--json"],
                              env: OrcaIO.cleanEnv, cwd: "/", timeout: 15)
        guard result.ok else {
            throw GearError("Orca 터미널에 입력하지 못했습니다: \(Self.errorSummary(result))")
        }
    }

    public func type(_ text: String) throws {
        try send(["--text", text])
    }

    public func press(_ key: Key) throws {
        if key == .enter {
            try send(["--enter"])
        } else {
            try send(["--text", key.bytes])
        }
    }

    private func readScreen() -> [String: Any]? {
        let result = Proc.run(orca, ["terminal", "read", "--terminal", handle, "--screen", "--json"],
                              env: OrcaIO.cleanEnv, cwd: "/", timeout: 10)
        guard result.ok,
              let json = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any],
              let terminal = (json["result"] as? [String: Any])?["terminal"] as? [String: Any],
              // "screen-unavailable" 은 화면이 아니라 누적 출력이라 판정에 쓰지 않는다.
              terminal["source"] as? String == "screen" else {
            return nil
        }
        return terminal
    }

    public func screen() -> [String]? {
        readScreen()?["tail"] as? [String]
    }

    /// Orca 는 입력창의 글을 화면 줄에서 떼어 `draft` 로 따로 준다.
    public func draft() -> String? {
        readScreen()?["draft"] as? String
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

    static func osascript(_ script: String) -> ProcResult {
        Proc.run("/usr/bin/osascript", ["-e", script], timeout: 10)
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
            throw GearError("Ghostty 에 입력하지 못했습니다: \(detail.isEmpty ? "대상 터미널이 더 이상 맨 앞 창에 없습니다" : detail)")
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
