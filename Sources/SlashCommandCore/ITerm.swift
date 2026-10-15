import AppKit
import ApplicationServices
import Foundation

// iTerm2: the frontmost session is found with AppleScript (`unique id` and `tty` of `current session of current window`), and bytes are written to that session with `write text … newline NO`
// and the screen is read with `contents`. Re-checked on 2026-10-07 on a test Mac (iTerm2 3.7.3): the bytes arrive as they are and are not wrapped in paste markers.

/// iTerm2's «Broadcast Input» state.
///
/// When on, AppleScript `write text` also goes into other panes (and tabs) — measured 2026-10-07 on a test Mac: with "Send input to all panes of all tabs"
/// on in a two-pane window, doing `write text` to one pane delivered the same text to the other. Nothing checks that the other panes show an input box, so
/// nothing is sent while broadcasting. The state is read from the check mark in iTerm2's Shell ▸ Broadcast Input menu through accessibility (AX) (needs the Accessibility permission).
/// Broadcast is turned on «per window» and the menu shows the state of the «frontmost window», so the state can be trusted only when the session being written to is in the frontmost window (`ITermIO` checks).
public enum ITermBroadcast {
    public enum State: Equatable, Sendable {
        case off
        case on(String)
        /// The menu could not be read because the Accessibility permission is missing.
        case notTrusted
        /// The menu was not found or the check marks were not recognized — broadcast cannot be said to be off, so nothing is sent.
        case unknown

        public var allowsSending: Bool { self == .off }
    }

    struct MenuItem: Equatable {
        let title: String
        let marked: Bool
    }

    /// Decides the state from the menu items. It is off only when "Toggle Broadcast Input to Current Session" is checked.
    static func classify(_ items: [MenuItem]) -> State {
        if let active = items.first(where: { $0.marked && $0.title.localizedCaseInsensitiveContains("All Panes") }) {
            return .on(active.title)
        }
        if items.contains(where: { $0.marked && $0.title.localizedCaseInsensitiveContains("Current Session Only") }) {
            return .off
        }
        // No menu, nothing checked, or an unknown item is checked (broadcast to a chosen group of panes, etc.) — the format may have changed.
        return .unknown
    }

    /// Read afresh just before every write — the memory that it was «off» earlier does not allow the next write (it can turn on in between).
    public static func state() -> State {
        guard GhosttyScreen.trusted() else { return .notTrusted }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Detector.itermBundleID).first else { return .unknown }
        return classify(menuItems(pid: app.processIdentifier))
    }

    /// Lines a person reads (`doctor`).
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

/// A session is addressed by `unique id`, so even if focus moves elsewhere it «writes to the session that was read».
public struct ITermIO: TerminalIO {
    public let sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// Bytes as AppleScript: ordinary characters become quoted strings, control characters are joined as `(ASCII character N)`.
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

    /// A script that runs `body` in that session. With `frontWindowOnly` it looks only in iTerm2's frontmost (current) window. It returns `missing` if not found.
    /// `body` must end with `return`.
    ///
    /// Takes the session ids in «one call», finds which tab each is in, and addresses it directly by that tab's `session id "…"`. Asking for ids by going through windows, tabs and sessions one by one makes
    /// the call count grow with the number of sessions (2026-10-12 test Mac: with 4 sessions one screen read took 200ms — 15–20ms per call).
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
        // If input broadcast is on, this text also goes into other panes — those have never been checked, so nothing is sent.
        // Broadcast is turned on per window and the menu shows only the frontmost window's state — the session being written to must be inside the frontmost window for that state to be trusted.
        // Wrapped as check → read menu → «write only while in the frontmost window»: if the window changed while reading the menu, the writing script does not write.
        let notFront = SlashCommandError(loc("Not sent: the session is not in iTerm2's front window, so whether Broadcast Input is off cannot be checked."))
        guard inFrontWindow() else { throw notFront }
        switch ITermBroadcast.state() {
        case .off: break
        case .on(let mode):
            throw SlashCommandError(loc("Not sent: iTerm2 Broadcast Input is on (%@), so the keys would go to other panes too. Choose Shell ▸ Broadcast Input ▸ Send Input to Current Session Only, then press again.", mode))
        case .notTrusted:
            var error = SlashCommandError(loc("Not sent: Slash Command needs the %@ permission to check that iTerm2 Broadcast Input is off. Turn it on in System Settings → Privacy & Security, then press again.", SettingsNames.accessibility))
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
        // `contents` includes scrollback (measured 2026-10-07: 88 lines for a 25-line screen) — to use it for the «bottom of the screen» decision, only the lines of the current screen must remain.
        // Row and column counts (`rows`, `columns`) and the profile name are read in the same call so they do not disagree with the text.
        let body = "return ((rows as text) & linefeed & (columns as text) & linefeed & (profile name) & linefeed & contents)"
        let result = GhosttyIO.osascript(ITermIO.script(sessionID: sessionID, frontWindowOnly: false, body: body))
        guard result.ok, result.out != ITermIO.missing else { return nil }
        let head = result.out.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", maxSplits: 3, omittingEmptySubsequences: false)
        guard head.count == 4 else { return nil }
        let profile = ITermProfile.ambiguousIsDoubleWidth(named: String(head[2]), in: ITermProfile.all())
        return ITermIO.screenLines(from: "\(head[0])\n\(head[1])\n\(head[3])", profileIsDoubleWidth: profile)
    }

    /// The lines of the current screen. `profileIsDoubleWidth` is that session profile's «ambiguous-width characters take 2 cells» setting (nil if unknown).
    ///
    /// - 2 cells or unknown: the screen counted at 2 cells (contains only visible lines — errs on the side of not reading off-screen lines as the screen).
    /// - 1 cell: the screen counted at 1 cell. But if the input box is visible on that screen and not on the 2-cell screen, the 2-cell one is returned.
    ///   The profile may say 1 cell while that one session was switched to 2 cells on its own (Edit Session… — not knowable from the profile name), and then the 1-cell screen
    ///   may contain an off-screen input box. Lines of the 2-cell screen are «really visible» under any setting, so the decision that allows input (the input box is visible)
    ///   passes only when it also holds there (PR #27 review). A screen with no input box, such as a picker, stays as the 1-cell one — the header of a picker that fits exactly is not lost.
    static func screenLines(from output: String, profileIsDoubleWidth: Bool?) -> [String]? {
        guard let safe = visibleLines(from: output, ambiguousIsDoubleWidth: true) else { return nil }
        guard profileIsDoubleWidth == false, let generous = visibleLines(from: output, ambiguousIsDoubleWidth: false), generous != safe else { return safe }
        let onlyInGenerous = Agent.allCases.contains { Readiness.inputVisible(agent: $0, screen: generous) && !Readiness.inputVisible(agent: $0, screen: safe) }
        return onlyInGenerous ? safe : generous
    }

    /// The lines of the current screen from `"<rows>\n<columns>\n<contents>"`. nil if the row and column counts cannot be read (text mixed with scrollback is not used as the current screen).
    ///
    /// `rows` is the «physical» row count but `contents` is in units of text lines, so a long line may wrap and take several rows (so there are fewer lines in total).
    /// So, from the bottom, add up each line's «rows taken» (width ÷ column count, rounded up) and take lines only until `rows` is filled.
    ///
    /// Width must be counted according to that session's profile — a miscount either way causes trouble (both from the PR #27 review):
    /// - Counting too wide: a line that exactly fits the column count (`› 1. …`, hint line, claude's separator) is counted as 2 rows and drops a «visible» upper line. In an 11-line pane the codex picker's
    ///   header was cut off, so the picker was not recognized and was left open (measured 2026-10-12 on a test Mac).
    /// - Counting too narrow: with the "Ambiguous characters are double-width" profile on, an input box off screen (in scrollback) is read as on screen and input is allowed.
    /// So `ambiguousIsDoubleWidth` is read from the profile (`ITermProfile`), and counted at 2 cells when unknown (errs on the side of not reading invisible lines as the screen).
    static func visibleLines(from output: String, ambiguousIsDoubleWidth: Bool) -> [String]? {
        let text = output.replacingOccurrences(of: "\r", with: "\n")
        let head = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard head.count == 3, let rows = Int(head[0]), rows > 0, let columns = Int(head[1]), columns > 0 else { return nil }
        var lines = String(head[2]).components(separatedBy: "\n")
        // The last empty element produced by a trailing newline is not a screen line.
        if lines.last == "" { lines.removeLast() }
        var used = 0
        var kept: [String] = []
        for line in lines.reversed() {
            used += max(1, (displayWidth(line, ambiguousIsDoubleWidth: ambiguousIsDoubleWidth) + columns - 1) / columns)
            if used > rows { break }
            kept.append(line)
        }
        return kept.reversed()
    }

    /// Width in terminal cells (the `CharacterWidth` table): wide characters 2 cells, combining characters 0, «ambiguous-width» characters (`─`, `·`, `●` …) 1 or 2 cells depending on the profile setting,
    /// everything else 1 cell — `›` and `❯` are not ambiguous-width, so they stay 1 cell even with that setting on (PR #27 third review: counting everything as 2 cells makes an exactly fitting cursor row 2 rows).
    static func displayWidth(_ text: String, ambiguousIsDoubleWidth: Bool) -> Int {
        CharacterWidth.cells(text, ambiguousIsDoubleWidth: ambiguousIsDoubleWidth)
    }
}

/// iTerm2 profile setting "Ambiguous characters are double-width" (Profiles ▸ Text). Read from iTerm2's settings file and the DynamicProfiles folder.
enum ITermProfile {
    static let key = "Ambiguous Double Width"

    /// Whether the profile with that name draws ambiguous-width characters in 2 cells. nil if the profile is not found or profiles with the same name differ from each other.
    /// If a dynamic profile does not write the value, it follows the parent profile (`Dynamic Profile Parent Name`, or the default profile if none).
    static func ambiguousIsDoubleWidth(named name: String, in store: Store) -> Bool? {
        let found = store.profiles.filter { $0["Name"] as? String == name }
        let values = Set(found.map { value(of: $0, in: store, depth: 0) })
        guard !found.isEmpty, values.count == 1, let only = values.first else { return nil }
        return only
    }

    private static func value(of profile: [String: Any], in store: Store, depth: Int) -> Bool? {
        if let own = profile[key] as? Bool { return own }
        if let own = profile[key] as? NSNumber { return own.boolValue }
        // An ordinary profile in the settings file is off when it lacks the key. A dynamic profile inherits unwritten values from its parent.
        guard profile["__dynamic"] as? Bool == true else { return false }
        guard depth < 4 else { return nil }
        // iTerm2 looks up the parent by GUID first, then by name (v3.7.3 `prototypeForDynamicProfile` — PR #27 third review).
        // If neither is written, it is the default profile. If a parent is written but not found, the answer is unknown (iTerm2 falls back to the default profile, but the 2-cell side beats an answer that may be wrong).
        let parentGUID = profile["Dynamic Profile Parent GUID"] as? String
        let parentName = profile["Dynamic Profile Parent Name"] as? String
        var parent: [String: Any]?
        if let parentGUID { parent = store.profiles.first { $0["Guid"] as? String == parentGUID } }
        if parent == nil, let parentName {
            let named = store.profiles.filter { $0["Name"] as? String == parentName }
            let values = Set(named.map { value(of: $0, in: store, depth: depth + 1) })
            // If several parents share the name, use the value only when they agree.
            return !named.isEmpty && values.count == 1 ? values.first! : nil
        }
        if parent == nil, parentGUID == nil, parentName == nil, let defaultGUID = store.defaultGUID {
            parent = store.profiles.first { $0["Guid"] as? String == defaultGUID }
        }
        return parent.flatMap { value(of: $0, in: store, depth: depth + 1) }
    }

    struct Store {
        var profiles: [[String: Any]]
        var defaultGUID: String?
    }

    /// Profiles in the settings file and profiles in the DynamicProfiles folder (the latter get a `__dynamic` marker).
    static func all() -> Store {
        let domain = Detector.itermBundleID as CFString
        CFPreferencesAppSynchronize(domain)
        var store = Store(profiles: (CFPreferencesCopyAppValue("New Bookmarks" as CFString, domain) as? [[String: Any]]) ?? [],
                          defaultGUID: CFPreferencesCopyAppValue("Default Bookmark Guid" as CFString, domain) as? String)
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/iTerm2/DynamicProfiles")
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: file) else { continue }
            store.profiles += dynamicProfiles(in: data)
        }
        return store
    }

    /// `Profiles` of a dynamic profile file (JSON or plist).
    static func dynamicProfiles(in data: Data) -> [[String: Any]] {
        let object = (try? JSONSerialization.jsonObject(with: data)) ?? (try? PropertyListSerialization.propertyList(from: data, format: nil))
        let profiles = (object as? [String: Any])?["Profiles"] as? [[String: Any]] ?? []
        return profiles.map { $0.merging(["__dynamic": true]) { _, new in new } }
    }
}

extension Detector {
    public static let itermBundleID = "com.googlecode.iterm2"

    /// `"<unique id>\n<tty>\n<name>"` → (id, tty, name). nil if there is no window (empty text).
    static func itermSession(from output: String) -> (id: String, tty: String, name: String)? {
        let parts = output.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// The session focused in iTerm2's frontmost window. The agent is picked out by the process running on that session's tty, and if tmux runs there, it goes into that pane.
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
