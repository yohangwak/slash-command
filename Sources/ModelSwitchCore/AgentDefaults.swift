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
        case .unreadable(let reason): return .failed("\(name) 설정 파일을 전환 전에 읽지 못했습니다: \(reason)")
        case .absent: before = nil
        case .content(let data): before = data
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            guard let before else { return .unchanged }
            do { try before.write(to: url, options: .atomic); return .restored } catch { return .failed(error.localizedDescription) }
        }
        guard let current = try? Data(contentsOf: url) else { return .failed("\(name) 설정 파일을 읽지 못했습니다") }
        if current == before { return .unchanged }
        guard var now = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any] else {
            return .failed("\(name) 설정 파일을 해석하지 못했습니다")
        }
        let old: [String: Any]
        if let before {
            guard let parsed = (try? JSONSerialization.jsonObject(with: before)) as? [String: Any] else {
                return .failed("\(name) 설정 파일(전환 전)을 해석하지 못했습니다")
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
            throw ModelSwitchError("\(name) 설정 파일을 읽지 못해(\(reason)) 새 세션 기본값을 지킬 수 없으므로 전환하지 않았습니다.")
        }
    }
}
