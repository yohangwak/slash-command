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
/// 기본값을 연 «전» 값으로 되돌리는 일. `run` 은 자기 자신을 에이전트로 바꾸므로(exec) 되돌리기는 따로 띄운 프로세스가 맡는다.
///
/// 두 가지를 지킨다(2026-10-11 리뷰):
/// - **이 열기가 쓴 것만 되돌린다.** 기본값 파일의 모델이 «연 모델» 로 바뀌었을 때만 되돌리고, 다른 모델로 바뀐 것은
///   다른 세션이 일부러 바꾼 것으로 보고 그 값을 새 기준으로 삼는다.
/// - **겹쳐 연 것끼리 기준을 나눠 쓴다.** 앞의 열기가 쓴 값이 아직 되돌려지기 전에 또 열면, 그 잠깐의 값을 «연 전» 으로 잡지 않도록
///   기준(모델 키 네 개 — 비밀이 아니다)을 한 파일에 두고 살아 있는 열기들이 같이 본다. 인증 정보가 든 설정 파일 전체는 어디에도 복사하지 않는다.
public enum LaunchDefaults {
    /// 살아 있는 열기들이 같이 보는 기록의 자리(사용자별 임시 폴더).
    public static var recordURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("slashcommand-cursor-launch.json")
    }

    /// 한 번의 열기를 지켜보는 시간(초). 에이전트가 언제 쓰는지 모른다 — 폴더를 믿느냐는 물음에 답한 뒤일 수도 있다.
    static let watchSeconds: TimeInterval = 60

    struct Record {
        /// 연 전에 기본값 파일이 있었는가.
        var fileExisted: Bool
        /// 연 전의 모델 키들(없던 키는 없다).
        var original: [String: Any]
        /// 살아 있는 열기: 표 → (연 모델 id, 끝나는 때).
        var launches: [String: (model: String, until: TimeInterval)]

        init(fileExisted: Bool, original: [String: Any], launches: [String: (model: String, until: TimeInterval)] = [:]) {
            self.fileExisted = fileExisted
            self.original = original
            self.launches = launches
        }

        init?(data: Data) {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let fileExisted = object["fileExisted"] as? Bool, let original = object["original"] as? [String: Any],
                  let launches = object["launches"] as? [String: [String: Any]] else { return nil }
            self.fileExisted = fileExisted
            self.original = original
            self.launches = [:]
            for (ticket, value) in launches {
                if let model = value["model"] as? String, let until = value["until"] as? Double { self.launches[ticket] = (model, until) }
            }
        }

        var data: Data? {
            let launches = self.launches.mapValues { ["model": $0.model, "until": $0.until] as [String: Any] }
            return try? JSONSerialization.data(withJSONObject: ["fileExisted": fileExisted, "original": original, "launches": launches], options: [.sortedKeys])
        }
    }

    /// 열기 직전에 부른다: 기준을 잡고(이미 살아 있는 열기가 있으면 그 기준을 같이 쓴다) 이 열기를 적는다. 돌려주는 값은 이 열기의 표다.
    /// 기본값 파일을 읽지 못하면 던진다 — 되돌릴 값을 모르면 열지 않는다.
    public static func begin(agent: Agent, model: String, defaults: URL? = nil, record: URL? = nil, now: Date = Date()) throws -> String {
        let defaults = defaults ?? CursorDefaults.defaultURL
        let record = record ?? recordURL
        return try locked(record) {
            var current = load(record, now: now)
            if current == nil {
                let snapshot = DefaultsFile.snapshot(defaults)
                try DefaultsFile.refuseIfUnreadable(snapshot, name: agent.rawValue)
                var keys: [String: Any] = [:]
                if case .content(let data) = snapshot {
                    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                        throw SlashCommandError(loc("Could not parse the %@ settings file", agent.rawValue))
                    }
                    for key in CursorDefaults.keys { keys[key] = object[key] }
                }
                current = Record(fileExisted: snapshot != .absent, original: keys)
            }
            let ticket = UUID().uuidString
            current?.launches[ticket] = (model, now.timeIntervalSince1970 + watchSeconds + 15)
            try save(current, to: record)
            return ticket
        }
    }

    /// 그 열기를 기록에서 지운다(지킴이를 못 띄웠을 때, 지킴이가 끝날 때). 남은 열기가 없으면 기록도 지운다.
    public static func end(ticket: String, record: URL? = nil, now: Date = Date()) {
        let record = record ?? recordURL
        _ = try? locked(record) {
            guard var current = load(record, now: now) else { return try save(nil, to: record) }
            current.launches[ticket] = nil
            try save(current.launches.isEmpty ? nil : current, to: record)
        }
    }

    /// `rounds` 번(사이마다 150ms) 기본값 파일을 본다. 모델이 살아 있는 열기의 모델로 바뀌어 있으면 기준 값으로 되돌리고,
    /// 다른 값으로 바뀌어 있으면 그 값을 새 기준으로 삼는다. «이 열기» 가 쓴 것을 되돌린 뒤에는 3초만 더 본다 —
    /// 겹쳐 연 다른 열기의 것을 되돌렸을 때는 줄이지 않는다(이 열기는 아직 쓰지 않았을 수 있다). 이 프로세스가 되돌린 횟수를 돌려준다.
    @discardableResult
    public static func keep(agent: Agent, ticket: String, defaults: URL? = nil, record: URL? = nil, rounds: Int,
                            sleep: (Int) -> Void, now: () -> Date = { Date() }) -> Int {
        guard agent == .cursor else { return 0 }
        let defaults = defaults ?? CursorDefaults.defaultURL
        let record = record ?? recordURL
        var restored = 0
        var left = rounds
        var shortened = false
        while left > 0 {
            left -= 1
            sleep(150)
            let outcome: Round? = try? locked(record) {
                guard var current = load(record, now: now()), let mine = current.launches[ticket] else { return nil }
                // 읽지 못한 회차는 건너뛴다(에이전트가 쓰는 중일 수 있다).
                guard let keys = modelKeys(defaults) else { return .nothing }
                if NSDictionary(dictionary: keys).isEqual(to: current.original) { return .nothing }
                let written = keys["model"] as? [String: Any] ?? [:]
                guard current.launches.values.contains(where: { wrote(launch: $0.model, model: written) }) else {
                    // 살아 있는 열기의 모델이 아니다 — 다른 세션이 바꾼 값이다. 되돌리지 않고 기준으로 삼는다.
                    current.original = keys
                    current.fileExisted = FileManager.default.fileExists(atPath: defaults.path)
                    try save(current, to: record)
                    return .nothing
                }
                let snapshot: DefaultsSnapshot
                if current.fileExisted {
                    snapshot = .content((try? JSONSerialization.data(withJSONObject: current.original, options: [.sortedKeys])) ?? Data("{}".utf8))
                } else {
                    snapshot = .absent
                }
                guard CursorDefaults(url: defaults).restore(to: snapshot) == .restored else { return .nothing }
                return wrote(launch: mine.model, model: written) ? .restoredMine : .restoredAnother
            }
            guard let outcome else { break }   // 기록에 이 열기가 없다 — 끝났다
            if outcome != .nothing { restored += 1 }
            if outcome == .restoredMine, !shortened {
                shortened = true
                left = min(left, 20)
            }
        }
        end(ticket: ticket, record: record, now: now())
        return restored
    }

    enum Round { case nothing, restoredMine, restoredAnother }

    /// 기본값 파일의 `model` 값이 그 id 로 «연» 결과인가. 여는 id 에서 꾸밈(effort · `thinking` · `fast`, 앞의 `cursor-`)을 떼어 낸
    /// «모델 id 전체» 가 같을 때만이다 — 앞머리만 같은 다른 모델(`claude-opus-5-5-high` 로 열었는데 저장된 것은 `claude-opus-5`)은 아니다.
    /// 2026-10-11 실측(여덟 가지 id): `grok-4.7-high` → `grok-4.7` · `claude-opus-5-thinking-high` → `claude-opus-5` ·
    /// `cursor-grok-4.6-high` → `grok-4.6` · `gpt-5.5-extra-high` → `gpt-5.5` · `composer-2.5` → 그대로 · `auto` → `default`(aliases 에 `auto`).
    /// 다른 세션이 «같은 모델» 로 일부러 바꾼 것은 가려낼 수 없다 — 그 경우는 되돌린다.
    static func wrote(launch: String, model: [String: Any]) -> Bool {
        let launch = launch.lowercased()
        if let aliases = model["aliases"] as? [String], aliases.contains(where: { $0.lowercased() == launch }) { return true }
        let bases = launchBases(launch)
        for key in ["modelId", "displayModelId"] {
            guard let id = (model[key] as? String)?.lowercased(), !id.isEmpty else { continue }
            if bases.contains(id) { return true }
        }
        return false
    }

    /// 여는 id 가 가리키는 모델 id 의 후보: 꾸밈을 뗀 것과, 거기서 앞의 `cursor-` 까지 뗀 것.
    static func launchBases(_ launch: String) -> Set<String> {
        let decorations: Set<String> = ["fast", "thinking", "low", "medium", "high", "xhigh", "extra", "max", "none", "minimal"]
        var parts = launch.lowercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        while parts.count > 1, let last = parts.last, decorations.contains(last) { parts.removeLast() }
        // `claude-4.6-sonnet-medium-thinking` 처럼 꾸밈이 이어 붙는 것은 위에서 다 떼인다. 가운데에 낀 것은 떼지 않는다.
        let base = parts.joined(separator: "-")
        var bases: Set<String> = [launch, base]
        if base.hasPrefix("cursor-") { bases.insert(String(base.dropFirst("cursor-".count))) }
        return bases
    }

    /// 기본값 파일의 모델 키들. 파일이 없으면 빈 것, 읽거나 풀지 못하면 nil.
    static func modelKeys(_ url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var keys: [String: Any] = [:]
        for key in CursorDefaults.keys { keys[key] = object[key] }
        return keys
    }

    /// 기록을 읽는다. 끝난 열기는 버리고, 살아 있는 열기가 없으면 nil(기준을 새로 잡아야 한다).
    static func load(_ url: URL, now: Date) -> Record? {
        guard let data = try? Data(contentsOf: url), var record = Record(data: data) else { return nil }
        record.launches = record.launches.filter { $0.value.until > now.timeIntervalSince1970 }
        return record.launches.isEmpty ? nil : record
    }

    static func save(_ record: Record?, to url: URL) throws {
        guard let record, let data = record.data else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 기록을 읽고 고치는 동안 다른 열기·지킴이가 끼어들지 못하게 한다(`flock`).
    static func locked<T>(_ record: URL, _ body: () throws -> T) throws -> T {
        let descriptor = open(record.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw SlashCommandError("could not open \(record.lastPathComponent).lock: \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw SlashCommandError("could not lock \(record.lastPathComponent).lock: \(String(cString: strerror(errno)))") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
