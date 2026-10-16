import Foundation

/// State of the new-session defaults file "before" the switch. Distinguishes a file that "did not exist" from one that "could not be read" —
/// a file that did not exist can simply be removed again on restore, but for a file that could not be read the value to restore is unknown, so the switch itself is not made.
public enum DefaultsSnapshot: Equatable, Sendable {
    /// The file did not exist (e.g. the first time the agent is used). The agent creates it during the switch.
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

    /// Restores only `keys` in the JSON config file to their values before the switch (keys that did not exist are removed).
    /// If everything outside those keys is the same as before the switch, the original bytes are written back (and a file that did not exist is removed); if it changed (written by another session), that value is kept and only the keys are changed.
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
            #if os(macOS)
            let restEqual = NSDictionary(dictionary: rest).isEqual(to: oldRest)
            #else
            let restEqual = jsonEqual(rest, oldRest)
            #endif
            if restEqual {
                if let before {
                    try before.write(to: url, options: .atomic)
                } else {
                    // The file did not exist and nothing is left — it is the file the agent created this time.
                    try FileManager.default.removeItem(at: url)
                }
            } else {
                if keys.allSatisfy({ key in
                    switch (now[key], old[key]) {
                    case (nil, nil): return true
                    case (let a?, let b?):
                        #if os(macOS)
                        return (a as AnyObject).isEqual(b)
                        #else
                        return jsonEqual(a, b)
                        #endif
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

    /// Equality of JSON values without Objective-C dispatch. NSNumber preserves Foundation's
    /// numeric equality (including 1 == 1.0 and true == 1); arrays remain order-sensitive.
    static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (let a as [String: Any], let b as [String: Any]):
            return a.count == b.count && a.allSatisfy { key, value in
                b[key].map { jsonEqual(value, $0) } ?? false
            }
        case (let a as [Any], let b as [Any]):
            return a.count == b.count && zip(a, b).allSatisfy { jsonEqual($0, $1) }
        case (let a as String, let b as String): return a == b
        case (let a as NSNumber, let b as NSNumber): return a.isEqual(to: b)
        case (is NSNull, is NSNull): return true
        default: return false
        }
    }

    /// If `keepDefaults` is set but the state before the switch could not be read, stops before sending anything, since the value to restore is unknown.
    static func refuseIfUnreadable(_ snapshot: DefaultsSnapshot?, name: String) throws {
        if case .unreadable(let reason)? = snapshot {
            throw SlashCommandError(loc("Not switched: the %@ settings file could not be read (%@), so the default for new sessions could not be protected.", name, reason))
        }
    }
}

/// When opening with `run` an agent that also saves the model given as a launch option as the new-session default (`Launch.savesLaunchModelAsDefault` — cursor),
/// this restores the default to its value from "before" the launch. `run` turns itself into the agent (exec), so a separately launched process does the restoring.
///
/// Two things are kept (2026-10-11 review):
/// - **Restore only what this launch wrote.** Restore only when the model in the defaults file changed to the "launched model"; a change to another model is
///   treated as deliberately changed by another session, and that value becomes the new baseline.
/// - **Launches that overlap share the baseline.** If another launch happens before the value written by an earlier launch is restored, to avoid taking that transient value as "before launch",
///   the baseline (four model keys — not secrets) is kept in one file that the live launches all look at. The whole config file, which holds credentials, is not copied anywhere.
public enum LaunchDefaults {
    /// Where the record that live launches share is kept (a per-user temporary folder).
    public static var recordURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("slashcommand-cursor-launch.json")
    }

    /// Seconds to watch a single launch. We do not know when the agent writes — it may be after the answer to the question of whether to trust the folder.
    static let watchSeconds: TimeInterval = 60

    struct Record {
        /// Whether the defaults file existed before the launch.
        var fileExisted: Bool
        /// The model keys from before the launch (keys that did not exist are absent).
        var original: [String: Any]
        /// Live launches: key -> (launched model id, end time).
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

    /// Called right before launching: establishes the baseline (shared with an already live launch if there is one) and records this launch. The returned value is this launch's key.
    /// Throws if the defaults file cannot be read — if the value to restore is unknown, do not launch.
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

    /// Removes that launch from the record (when the guard could not be started, or when the guard finishes). When no launch remains, the record is removed too.
    public static func end(ticket: String, record: URL? = nil, now: Date = Date()) {
        let record = record ?? recordURL
        _ = try? locked(record) {
            guard var current = load(record, now: now) else { return try save(nil, to: record) }
            current.launches[ticket] = nil
            try save(current.launches.isEmpty ? nil : current, to: record)
        }
    }

    /// Looks at the defaults file `rounds` times (150 ms apart). If the model has changed to a live launch's model, restores the baseline value;
    /// if it has changed to another value, takes that value as the new baseline. After restoring something written by "this launch", it watches only 3 more seconds —
    /// it does not shorten when it restored one from another overlapping launch (this one may not have written yet). Returns the number of restores this process made.
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
                // Skip a round that could not be read (the agent may be writing).
                guard let keys = modelKeys(defaults) else { return .nothing }
                if NSDictionary(dictionary: keys).isEqual(to: current.original) { return .nothing }
                let written = keys["model"] as? [String: Any] ?? [:]
                guard current.launches.values.contains(where: { wrote(launch: $0.model, model: written) }) else {
                    // Not a live launch's model — it is a value another session changed. Do not restore; take it as the baseline.
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
            guard let outcome else { break }   // This launch is not in the record — it has finished
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

    /// Whether the `model` value in the defaults file is the result of "launching" with that id. After stripping decorations (effort, `thinking`, `fast`, a leading `cursor-`) from the launch id,
    /// it counts only when the "whole model id" matches — a different model with just the same prefix (launched `claude-opus-5-5-high` but the saved one is `claude-opus-5`) does not.
    /// Measured 2026-10-11 (eight ids): `grok-4.7-high` -> `grok-4.7`, `claude-opus-5-thinking-high` -> `claude-opus-5`,
    /// `cursor-grok-4.6-high` -> `grok-4.6`, `gpt-5.5-extra-high` -> `gpt-5.5`, `composer-2.5` -> unchanged, `auto` -> `default` (`auto` is in aliases).
    /// A change another session deliberately made to the "same model" cannot be told apart — that case is restored.
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

    /// Candidates for the model id the launch id points to: with the decoration stripped, and also with the leading `cursor-` stripped.
    static func launchBases(_ launch: String) -> Set<String> {
        let decorations: Set<String> = ["fast", "thinking", "low", "medium", "high", "xhigh", "extra", "max", "none", "minimal"]
        var parts = launch.lowercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        while parts.count > 1, let last = parts.last, decorations.contains(last) { parts.removeLast() }
        // Decorations attached in a run, as in `claude-4.6-sonnet-medium-thinking`, are all stripped above. Ones in the middle are not stripped.
        let base = parts.joined(separator: "-")
        var bases: Set<String> = [launch, base]
        if base.hasPrefix("cursor-") { bases.insert(String(base.dropFirst("cursor-".count))) }
        return bases
    }

    /// The model keys of the defaults file. Empty if the file does not exist; nil if it cannot be read or parsed.
    static func modelKeys(_ url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var keys: [String: Any] = [:]
        for key in CursorDefaults.keys { keys[key] = object[key] }
        return keys
    }

    /// Reads the record. Discards finished launches; nil if no launch is live (the baseline must be established anew).
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

    /// Keeps other launches and guards from interfering while the record is read and modified (`flock`).
    static func locked<T>(_ record: URL, _ body: () throws -> T) throws -> T {
        #if os(macOS)
        let descriptor = open(record.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw SlashCommandError("could not open \(record.lastPathComponent).lock: \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw SlashCommandError("could not lock \(record.lastPathComponent).lock: \(String(cString: strerror(errno)))") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
        #else
        throw SlashCommandError(loc("This is not supported on this operating system yet."))
        #endif
    }
}
