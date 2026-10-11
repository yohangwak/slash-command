import Foundation

/// 전환 «전» 의 새 세션 기본값 파일 상태. 파일이 «없던» 것과 «읽지 못한» 것을 구분한다 —
/// 없던 파일은 되돌릴 때 다시 없애면 되지만, 읽지 못한 파일은 되돌릴 값을 모르므로 전환 자체를 하지 않는다.
public enum DefaultsSnapshot: Equatable, Sendable {
    /// 파일이 없었다(에이전트를 처음 쓰는 경우 등). 에이전트가 전환하면서 새로 만든다.
    case absent
    case content(Data)
    case unreadable(String)
}

enum DefaultsFile {
    static func snapshot(_ url: URL) -> DefaultsSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do {
            return .content(try Data(contentsOf: url))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    enum Result: Equatable {
        case unchanged
        case restored
        case failed(String)
    }

    /// JSON 설정 파일에서 `keys` 만 전환 전 값으로 되돌린다(없던 키는 없앤다).
    /// 그 키들 밖이 전환 전과 같으면 원래 바이트를 그대로 쓰고(없던 파일이면 파일을 없앤다), 달라졌으면(다른 세션이 쓴 것) 그 값은 두고 키만 바꾼다.
    static func restoreJSON(url: URL, keys: [String], to snapshot: DefaultsSnapshot, pretty: Bool, name: String) -> Result {
        let before: Data?
        switch snapshot {
        case .unreadable(let reason): return .failed(loc("Could not read the %@ settings file before switching: %@", name, reason))
        case .absent: before = nil
        case .content(let data): before = data
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            guard let before else { return .unchanged }
            do { try before.write(to: url, options: .atomic); return .restored } catch { return .failed(error.localizedDescription) }
        }
        guard let current = try? Data(contentsOf: url) else { return .failed(loc("Could not read the %@ settings file", name)) }
        if current == before { return .unchanged }
        guard var now = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any] else {
            return .failed(loc("Could not parse the %@ settings file", name))
        }
        let old: [String: Any]
        if let before {
            guard let parsed = (try? JSONSerialization.jsonObject(with: before)) as? [String: Any] else {
                return .failed(loc("Could not parse the %@ settings file as it was before switching", name))
            }
            old = parsed
        } else {
            old = [:]
        }
        var rest = now
        var oldRest = old
        for key in keys { rest[key] = nil; oldRest[key] = nil }
        do {
            if NSDictionary(dictionary: rest).isEqual(to: oldRest) {
                if let before {
                    try before.write(to: url, options: .atomic)
                } else {
                    // 없던 파일이고 남은 것도 없다 — 에이전트가 이번에 만든 파일이다.
                    try FileManager.default.removeItem(at: url)
                }
            } else {
                if keys.allSatisfy({ key in
                    switch (now[key], old[key]) {
                    case (nil, nil): return true
                    case (let a?, let b?): return (a as AnyObject).isEqual(b)
                    default: return false
                    }
                }) { return .unchanged }
                for key in keys { now[key] = old[key] }
                var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
                if pretty { options.insert(.prettyPrinted) }
                try JSONSerialization.data(withJSONObject: now, options: options).write(to: url, options: .atomic)
            }
            return .restored
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// `keepDefaults` 인데 전환 전 상태를 읽지 못했으면 — 되돌릴 값을 모르므로 — 아무것도 보내기 전에 멈춘다.
    static func refuseIfUnreadable(_ snapshot: DefaultsSnapshot?, name: String) throws {
        if case .unreadable(let reason)? = snapshot {
            throw SlashCommandError(loc("Not switched: the %@ settings file could not be read (%@), so the default for new sessions could not be protected.", name, reason))
        }
    }
}

/// 여는 옵션으로 준 모델을 새 세션 기본값으로도 저장하는 에이전트(`Launch.savesLaunchModelAsDefault` — cursor)를 `run` 으로 열 때,
/// 기본값을 연 «전» 값으로 되돌리는 일. `run` 은 자기 자신을 에이전트로 바꾸므로(exec) 되돌리기는 따로 띄운 프로세스가 맡는다 —
/// 그래서 연 전 상태를 한 덩이로 넘길 수 있어야 한다(파일로 남기지 않는다: cursor 의 설정 파일에는 인증 정보가 있다).
public enum LaunchDefaults {
    /// 지금 기본값 파일의 상태: 첫 바이트가 `A`(파일 없음) 또는 `C`(그 뒤가 파일 내용). 읽지 못하면 던진다 — 되돌릴 값을 모르면 열지 않는다.
    public static func capture(agent: Agent, url: URL? = nil) throws -> Data {
        let snapshot = DefaultsFile.snapshot(url ?? CursorDefaults.defaultURL)
        try DefaultsFile.refuseIfUnreadable(snapshot, name: agent.rawValue)
        if case .content(let data) = snapshot { return Data("C".utf8) + data }
        return Data("A".utf8)
    }

    /// `capture` 가 낸 덩이의 값으로 `rounds` 번(사이마다 150ms) 되돌려 본다. 되돌린 횟수를 돌려준다.
    /// 에이전트가 언제 쓰는지 모르므로(폴더를 믿느냐는 물음에 답한 뒤일 수도 있다) 한 번 되돌리고 끝내지 않고 끝까지 지켜본다.
    @discardableResult
    public static func keep(agent: Agent, captured: Data, url: URL? = nil, rounds: Int, sleep: (Int) -> Void) -> Int {
        guard agent == .cursor, let flag = captured.first else { return 0 }
        let snapshot: DefaultsSnapshot = flag == UInt8(ascii: "C") ? .content(Data(captured.dropFirst())) : .absent
        let defaults = CursorDefaults(url: url ?? CursorDefaults.defaultURL)
        var restored = 0
        for _ in 0..<rounds {
            sleep(150)
            if defaults.restore(to: snapshot) == .restored { restored += 1 }
        }
        return restored
    }
}
