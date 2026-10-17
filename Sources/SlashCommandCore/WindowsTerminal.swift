import Foundation

/// Console read-back replaces non-BMP scalars with U+FFFD. Do not make that a general wildcard.
enum WindowsTerminalMatching {
    static func rows(_ text: String) -> [String] {
        var rows = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { line -> String in
                var line = line
                while line.last == " " || line.last == "\t" { line.removeLast() }
                return line
            }
        while rows.last == "" { rows.removeLast() }
        return rows
    }
    static func equal(console: String, visible: String) -> Bool {
        // UIA joins soft wraps, whereas the console returns physical screen rows.
        let lhs = console.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        let rhs = visible.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        let nonblank = rows(visible).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        guard nonblank >= 3 || rhs.count >= 60, lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { x, y in x == y || (x.value == 0xFFFD && y.value > 0xFFFF) }
    }
    /// Callers deduplicate by the console's sorted member list before invoking this.
    static func uniqueMatch(consoles: [String], visible: String) -> Int? {
        let matches = consoles.indices.filter { equal(console: consoles[$0], visible: visible) }
        return matches.count == 1 ? matches[0] : nil
    }
}

#if os(Windows)
import WinSDK
import CWindowsTerminal

struct WindowsConsoleKey: Codable, Equatable {
    let vk: UInt16
    let scan: UInt16
    let character: UInt16
    let modifiers: UInt32

    init(vk: UInt16, character: UInt16 = 0, modifiers: UInt32 = 0) {
        self.vk = vk; scan = UInt16(MapVirtualKeyW(UInt32(vk), UInt32(MAPVK_VK_TO_VSC)))
        self.character = character; self.modifiers = modifiers
    }
    static func character(_ unit: UInt16) -> WindowsConsoleKey {
        switch unit {
        case 13: return .init(vk: UInt16(VK_RETURN), character: 13)
        case 27: return .init(vk: UInt16(VK_ESCAPE), character: 27)
        case 9: return .init(vk: UInt16(VK_TAB), character: 9)
        case 8, 127: return .init(vk: UInt16(VK_BACK), character: 8)
        case 1...26: return .init(vk: unit + 64, character: unit, modifiers: UInt32(LEFT_CTRL_PRESSED))
        default:
            let mapped = VkKeyScanW(unit)
            guard mapped != -1 else { return .init(vk: 0, character: unit) }
            let bits = UInt16(bitPattern: mapped)
            var modifiers: UInt32 = 0
            if bits & 0x100 != 0 { modifiers |= UInt32(SHIFT_PRESSED) }
            if bits & 0x200 != 0 { modifiers |= UInt32(LEFT_CTRL_PRESSED) }
            if bits & 0x400 != 0 { modifiers |= UInt32(LEFT_ALT_PRESSED) }
            return .init(vk: bits & 0xFF, character: unit, modifiers: modifiers)
        }
    }
    static func key(_ key: Key) -> WindowsConsoleKey {
        switch key {
        case .up: return .init(vk: UInt16(VK_UP), modifiers: UInt32(ENHANCED_KEY))
        case .down: return .init(vk: UInt16(VK_DOWN), modifiers: UInt32(ENHANCED_KEY))
        case .left: return .init(vk: UInt16(VK_LEFT), modifiers: UInt32(ENHANCED_KEY))
        case .right: return .init(vk: UInt16(VK_RIGHT), modifiers: UInt32(ENHANCED_KEY))
        case .home: return .init(vk: UInt16(VK_HOME), modifiers: UInt32(ENHANCED_KEY))
        case .end: return .init(vk: UInt16(VK_END), modifiers: UInt32(ENHANCED_KEY))
        case .pageUp: return .init(vk: UInt16(VK_PRIOR), modifiers: UInt32(ENHANCED_KEY))
        case .pageDown: return .init(vk: UInt16(VK_NEXT), modifiers: UInt32(ENHANCED_KEY))
        case .ctrl(let c):
            let code = UInt16((c.asciiValue ?? 0x40) & 0x1F)
            return .init(vk: code + 64, character: code, modifiers: UInt32(LEFT_CTRL_PRESSED))
        default: return character(key.bytes.utf16.first ?? 0)
        }
    }
    var native: SCKey { SCKey(vk: vk, scan: scan, character: character, modifiers: modifiers) }
}

struct WindowsConsoleMember: Codable, Hashable {
    let pid: UInt32
    let start: UInt64
}
struct WindowsConsoleScreen {
    let text: String
    let members: [WindowsConsoleMember]
}
protocol WindowsConsoleReading: AnyObject {
    func read() throws -> WindowsConsoleScreen
    func members() throws -> [WindowsConsoleMember]
    func pin(pid: Int32, start: UInt64) throws
    /// One chunk: the bridge writes all of its records without a check in between.
    func write(_ keys: [WindowsConsoleKey]) throws
}
struct WindowsConsoleReply: Codable {
    var ok: Bool
    var text: String? = nil
    var members: [WindowsConsoleMember]? = nil
    var changed: Bool? = nil
}

/// Owns only a CLI child and two pipes. The tray process never attaches to a console.
final class WindowsConsoleBridge: WindowsConsoleReading {
    private var channel: OpaquePointer?
    private let pid: Int32
    static var executable: String {
        var path = [WCHAR](repeating: 0, count: 32768)
        let n = GetModuleFileNameW(nil, &path, DWORD(path.count))
        return URL(fileURLWithPath: String(decoding: path.prefix(Int(n)), as: UTF16.self))
            .deletingLastPathComponent().appendingPathComponent("slashcommand.exe").path
    }
    init(pid: Int32, executable: String = WindowsConsoleBridge.executable) throws {
        self.pid = pid
        channel = executable.withCString(encodedAs: UTF16.self) { sc_channel_start($0, UInt32(bitPattern: pid)) }
        guard channel != nil else { throw WindowsTerminal.failure(pid: pid) }
    }
    deinit { close() }
    @discardableResult func close() -> Bool {
        guard let channel else { return true }; self.channel = nil
        return sc_channel_close(channel) == 1
    }
    func request(_ request: String) throws -> WindowsConsoleReply {
        guard let channel, let buffer = request.withCString({ sc_channel_request(channel, $0, 5000) }) else {
            close(); throw WindowsTerminal.failure(pid: pid)
        }
        defer { sc_free(buffer) }
        guard let reply = try? JSONDecoder().decode(WindowsConsoleReply.self, from: Data(String(cString: buffer).utf8)) else {
            close(); throw WindowsTerminal.unreadable
        }
        guard reply.ok else {
            if reply.changed == true { throw WindowsTerminal.changed }
            throw WindowsTerminal.unreadable
        }
        return reply
    }
    func read() throws -> WindowsConsoleScreen {
        let reply = try request("read")
        guard let text = reply.text, let members = reply.members, !members.isEmpty else { throw WindowsTerminal.unreadable }
        return WindowsConsoleScreen(text: text, members: members.sorted { $0.pid < $1.pid })
    }
    func members() throws -> [WindowsConsoleMember] {
        guard let members = try request("members").members, !members.isEmpty else { throw WindowsTerminal.unreadable }
        return members.sorted { $0.pid < $1.pid }
    }
    func pin(pid: Int32, start: UInt64) throws { _ = try request("pin \(pid) \(start)") }
    func write(_ keys: [WindowsConsoleKey]) throws {
        let data = try JSONEncoder().encode(keys)
        _ = try request("keys " + String(decoding: data, as: UTF8.self))
    }

    /// Hidden CLI entry point. Its saved standard handles remain pipes after AttachConsole.
    public static func serve(pid: UInt32) -> Int32 {
        guard let console = sc_console_attach(pid) else { return 1 }
        defer { sc_console_close(console) }
        while let buffer = sc_console_receive(console) {
            let request = String(cString: buffer); sc_free(buffer)
            var reply = WindowsConsoleReply(ok: false)
            var leave = false
            if sc_console_valid(console) != 1 { reply.changed = true; leave = true }
            else if request == "read" || request == "members" {
                var count: UInt32 = 0
                if let ids = sc_console_members(console, &count) {
                    reply.members = UnsafeBufferPointer(start: ids, count: Int(count)).map { .init(pid: $0.pid, start: $0.start) }
                    sc_free(ids)
                    if request == "members" { reply.ok = true }
                    else if let screen = sc_console_screen(console) {
                        reply.text = String(decodingCString: screen, as: UTF16.self); sc_free(screen); reply.ok = true
                    }
                }
            } else if request.hasPrefix("pin ") {
                let fields = request.split(separator: " ")
                if fields.count == 3, let pid = UInt32(fields[1]), let start = UInt64(fields[2]), start > 0 {
                    reply.ok = sc_console_pin(console, pid, start) == 1
                    if !reply.ok { reply.changed = true; leave = true }
                }
            } else if request.hasPrefix("keys "),
                      let keys = try? JSONDecoder().decode([WindowsConsoleKey].self, from: Data(request.dropFirst(5).utf8)), !keys.isEmpty {
                reply.ok = true
                for key in keys {
                    guard sc_console_key(console, key.native) == 1 else {
                        reply.ok = false
                        if sc_console_valid(console) != 1 { reply.changed = true; leave = true }
                        break
                    }
                    // ConPTY must not merge Escape and the following record into Alt+key.
                    if key.vk == UInt16(VK_ESCAPE) { Thread.sleep(forTimeInterval: 0.25) }
                }
            }
            guard let data = try? JSONEncoder().encode(reply),
                  String(decoding: data, as: UTF8.self).withCString({ sc_console_reply(console, $0) }) == 1 else { return 1 }
            if leave { return 1 }
        }
        return 0
    }
}

// The public CLI entry point does not expose the bridge protocol as a normal command.
public enum WindowsConsoleCommand {
    public static func run(pid: UInt32) -> Int32 { WindowsConsoleBridge.serve(pid: pid) }
}

enum WindowsTerminal {
    static var unreadable: SlashCommandError {
        SlashCommandError(loc("Stopped: could not read the Windows Terminal pane."))
    }
    static var changed: SlashCommandError {
        SlashCommandError(loc("The Windows Terminal pane or its agent changed. Press the shortcut again."))
    }
    static var unmatched: SlashCommandError {
        SlashCommandError(loc("Could not uniquely match the focused Windows Terminal pane to a readable console. Keep at least three non-blank rows or 60 non-whitespace characters visible, return to the live screen, and try again."))
    }
    static func failure(pid: Int32) -> SlashCommandError {
        if elevated(pid: pid) {
            return SlashCommandError(loc("This Windows Terminal pane runs as administrator. Run it without administrator privileges to switch its agent."))
        }
        return unreadable
    }
    static func elevated(pid: Int32) -> Bool {
        guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(bitPattern: pid)) else { return false }
        defer { CloseHandle(process) }
        var token: HANDLE?
        guard OpenProcessToken(process, DWORD(TOKEN_QUERY), &token), let token else { return false }
        defer { CloseHandle(token) }
        var elevation = TOKEN_ELEVATION(), size: DWORD = 0
        return GetTokenInformation(token, TokenElevation, &elevation, DWORD(MemoryLayout<TOKEN_ELEVATION>.size), &size) && elevation.TokenIsElevated != 0
    }
    struct Pane: Equatable { let text: String; let identity: String }
    final class FocusReader {
        private let context: OpaquePointer
        init() throws {
            guard let context = sc_uia_create() else { throw unreadable }
            self.context = context
        }
        deinit { sc_uia_close(context) }
        func focused(window: UInt) throws -> Pane {
            var text: UnsafeMutablePointer<UInt16>?, identity: UnsafeMutablePointer<UInt16>?
            var panes: Int32 = 0, focused: Int32 = 0
            let ok = sc_focused_pane(context, window, &text, &identity, &panes, &focused)
            defer { sc_free(text); sc_free(identity) }
            guard ok == 1, focused == 1, panes >= 1, let text, let identity else {
                throw SlashCommandError(loc("Could not tell which Windows Terminal pane is in front. Close any palette or dialog and focus the agent's input box."))
            }
            return Pane(text: String(decodingCString: text, as: UTF16.self), identity: String(decodingCString: identity, as: UTF16.self))
        }
    }
    static func focused(window: UInt) throws -> Pane { try FocusReader().focused(window: window) }
    struct Identity: Equatable { let agent: Agent; let pid: Int32 }
    static func identity(entries: [ProcessTable.Entry]) -> Identity? {
        guard !entries.isEmpty else { return nil }
        for entry in entries {
            let name = WindowsPaths.normalized(entry.executable).split(separator: "/").last.map(String.init) ?? ""
            if name.isEmpty || entry.arguments.joined().isEmpty || AgentProcesses.isWindowsNestedTerminal(entry)
                || WindowsWezTerm.remoteShells.contains(name) { return nil }
        }
        let agents = entries.compactMap { entry -> (ProcessTable.Entry, Agent)? in
            AgentProcesses.agent(forCommandLine: entry.arguments.joined(separator: " ")).map { (entry, $0) }
        }
        let parents = Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0.parent) })
        let pids = Set(agents.map { $0.0.pid })
        let outermost = agents.filter { entry, _ in
            var current = parents[entry.pid], seen: Set<Int32> = [entry.pid]
            while let pid = current, seen.insert(pid).inserted {
                if pids.contains(pid) { return false }; current = parents[pid]
            }
            return true
        }
        guard Set(outermost.map { $0.1 }).count == 1,
              let selected = outermost.sorted(by: { $0.0.pid < $1.0.pid }).first else { return nil }
        return Identity(agent: selected.1, pid: selected.0.pid)
    }
    static func requireWindowsLocal(members: [WindowsConsoleMember], expected: Agent? = nil,
                                    refresh: () throws -> [WindowsConsoleMember],
                                    read: (WindowsConsoleMember) -> ProcessTable.Entry? = ProcessTable.consoleMember) throws -> (Identity, UInt64) {
        var entries: [ProcessTable.Entry] = []
        for member in members {
            if member.start > 0, let entry = read(member) { entries.append(entry); continue }
            // A short-lived helper may have left since the bridge enumerated it. Only the console can say so.
            let current = try refresh()
            guard let now = current.first(where: { $0.pid == member.pid }) else { continue }
            guard now.start == member.start else { throw changed }
            throw unreadable
        }
        guard let identity = identity(entries: entries), expected == nil || identity.agent == expected else {
            throw SlashCommandError(loc("Not switched: this Windows Terminal pane's agent could not be identified as a local Windows process, so its own defaults cannot be protected (WSL, tmux and remote shells are not supported)."))
        }
        guard let start = members.first(where: { $0.pid == UInt32(bitPattern: identity.pid) })?.start, start > 0 else { throw unreadable }
        return (identity, start)
    }
    static func matchedConsole(candidates: [Int32], visible: String,
                               read: (Int32) throws -> WindowsConsoleScreen) throws -> WindowsConsoleScreen {
        var consoles: [WindowsConsoleScreen] = [], seen: Set<Set<WindowsConsoleMember>> = []
        for pid in candidates {
            let screen: WindowsConsoleScreen
            do { screen = try read(pid) } catch { throw unmatched }
            guard !screen.members.isEmpty else { throw unmatched }
            if seen.insert(Set(screen.members)).inserted { consoles.append(screen) }
        }
        guard let match = WindowsTerminalMatching.uniqueMatch(consoles: consoles.map(\.text), visible: visible) else { throw unmatched }
        return consoles[match]
    }
    static func requireInput(text: String, agent: Agent) throws {
        guard Detector.agent(onScreen: WindowsTerminalMatching.rows(text)) == agent else {
            throw SlashCommandError(loc("Not switched: the %@ input box is not visible. If a permission prompt or a picker is showing, deal with that first.", agent.displayName))
        }
    }
    static func requireWindow(_ window: UInt?) throws -> UInt {
        guard let window, HWND(bitPattern: window) != nil else { throw SlashCommandError(loc("No Windows Terminal window is open.")) }
        return window
    }
    static func window(pid: UInt32? = nil) -> UInt? {
        var current = GetTopWindow(nil)
        while let window = current {
            var owner: DWORD = 0; GetWindowThreadProcessId(window, &owner)
            var name = [WCHAR](repeating: 0, count: 256)
            let n = GetClassNameW(window, &name, Int32(name.count))
            if IsWindowVisible(window), (pid == nil || owner == pid),
               String(decoding: name.prefix(Int(max(0, n))), as: UTF16.self) == "CASCADIA_HOSTING_WINDOW_CLASS",
               WindowsAppModel.app(image: ProcessTable.executablePath(of: Int32(bitPattern: owner))) == "windowsterminal" {
                return UInt(bitPattern: window)
            }
            current = GetWindow(window, UINT(GW_HWNDNEXT))
        }
        return nil
    }
}

extension Detector {
    public static func windowsConsoleExplicit(pid: Int32, agent: Agent) throws -> Target {
        let bridge = try WindowsConsoleBridge(pid: pid)
        defer { bridge.close() }
        let screen = try bridge.read()
        let (identity, start) = try WindowsTerminal.requireWindowsLocal(members: screen.members, expected: agent, refresh: bridge.members)
        try WindowsTerminal.requireInput(text: screen.text, agent: agent)
        return Target(host: .windowsConsole(pid: identity.pid, start: start), agent: agent, label: String(pid))
    }
    static func windowsTerminal(window: UInt? = nil, requireForeground: Bool = false) throws -> Target {
        let window = try WindowsTerminal.requireWindow(window ?? WindowsTerminal.window())
        guard let hwnd = HWND(bitPattern: window) else { throw WindowsTerminal.unreadable }
        var pid: DWORD = 0; GetWindowThreadProcessId(hwnd, &pid)
        guard WindowsAppModel.app(image: ProcessTable.executablePath(of: Int32(bitPattern: pid))) == "windowsterminal" else { throw WindowsTerminal.changed }
        if requireForeground, GetForegroundWindow() != hwnd { throw WindowsTerminal.changed }
        let pane: WindowsTerminal.Pane
        let focusReader = try WindowsTerminal.FocusReader()
        do { pane = try focusReader.focused(window: window) }
        catch {
            if WindowsTerminal.elevated(pid: Int32(bitPattern: pid)) { throw WindowsTerminal.failure(pid: Int32(bitPattern: pid)) }
            throw error
        }
        let candidates = try ProcessTable.consoleCandidates(of: Int32(bitPattern: pid)).filter {
            let name = WindowsPaths.normalized($0.executable).split(separator: "/").last.map(String.init) ?? ""
            return $0.parent == Int32(bitPattern: pid) && !["openconsole.exe", "conhost.exe"].contains(name)
        }
        var probes: [(WindowsConsoleScreen, Int32)] = []
        let selected = try WindowsTerminal.matchedConsole(candidates: candidates.map(\.pid), visible: pane.text) { candidate in
            let bridge = try WindowsConsoleBridge(pid: candidate)
            // Close before probing another candidate: another bridge would itself join that console's member list.
            defer { bridge.close() }
            let screen = try bridge.read(); probes.append((screen, candidate)); return screen
        }
        guard let candidate = probes.first(where: { $0.0.members == selected.members })?.1 else { throw WindowsTerminal.unmatched }
        let bridge = try WindowsConsoleBridge(pid: candidate)
        defer { bridge.close() }
        let (identity, start) = try WindowsTerminal.requireWindowsLocal(members: selected.members, refresh: bridge.members)
        try WindowsTerminal.requireInput(text: selected.text, agent: identity.agent)
        let current = try focusReader.focused(window: window)
        guard current.identity == pane.identity, WindowsTerminalMatching.equal(console: selected.text, visible: current.text) else { throw WindowsTerminal.changed }
        if requireForeground, GetForegroundWindow() != hwnd { throw WindowsTerminal.changed }
        var title = [WCHAR](repeating: 0, count: 32768)
        let n = GetWindowTextW(hwnd, &title, Int32(title.count))
        var target = Target(host: .windowsConsole(pid: identity.pid, start: start), agent: identity.agent,
                            label: String(decoding: title.prefix(Int(max(0, n))), as: UTF16.self))
        target.windowsWindow = window; target.windowsPaneIdentity = pane.identity
        target.windowsRequiresForeground = requireForeground
        return target
    }
}

final class WindowsConsoleIO: TerminalIO {
    let bridge: WindowsConsoleReading
    let target: Target
    private(set) var lastFailure: String?
    private let foreground: () -> UInt?
    private let focused: (UInt) throws -> WindowsTerminal.Pane
    private let settle: () -> Void
    init(target: Target, bridge: WindowsConsoleReading? = nil,
         foreground: @escaping () -> UInt? = { GetForegroundWindow().map { UInt(bitPattern: $0) } },
         focused: ((UInt) throws -> WindowsTerminal.Pane)? = nil,
         settle: @escaping () -> Void = { Thread.sleep(forTimeInterval: 0.04) },
         validate: ([WindowsConsoleMember], Agent, () throws -> [WindowsConsoleMember]) throws -> (WindowsTerminal.Identity, UInt64) = {
             try WindowsTerminal.requireWindowsLocal(members: $0, expected: $1, refresh: $2)
         }) throws {
        guard case .windowsConsole(let pid, let start) = target.host else { throw WindowsTerminal.unreadable }
        self.target = target; self.foreground = foreground; self.settle = settle
        if let focused { self.focused = focused }
        else if target.windowsWindow != nil {
            let reader = try WindowsTerminal.FocusReader()
            self.focused = { try reader.focused(window: $0) }
        } else { self.focused = { _ in throw WindowsTerminal.changed } }
        self.bridge = try bridge ?? WindowsConsoleBridge(pid: pid)
        try self.bridge.pin(pid: pid, start: start)
        let members = try self.bridge.read().members
        let (identity, actualStart) = try validate(members, target.agent, self.bridge.members)
        guard identity.pid == pid, actualStart == start else { throw WindowsTerminal.changed }
    }
    private func requireTarget(writing: Bool) throws {
        if let lastFailure { throw SlashCommandError(lastFailure) }
        do {
            if let window = target.windowsWindow {
                if target.windowsRequiresForeground, foreground() != window { throw WindowsTerminal.changed }
                if writing {
                    // The agent echoes a key into the console a few milliseconds before UI Automation shows it (measured on
                    // Windows Terminal 1.24), so a read that falls in between differs. Only text waits for that; a pane change does not.
                    var attempt = 0
                    while true {
                        let console = try bridge.read()
                        let pane = try focused(window)
                        guard pane.identity == target.windowsPaneIdentity else { throw WindowsTerminal.changed }
                        if WindowsTerminalMatching.equal(console: console.text, visible: pane.text) { break }
                        attempt += 1
                        guard attempt < WindowsConsoleIO.textAttempts else { throw WindowsTerminal.changed }
                        settle()
                    }
                    if target.windowsRequiresForeground, foreground() != window { throw WindowsTerminal.changed }
                }
            }
            _ = try bridge.members() // The bridge checks the pinned process handle and membership too.
        } catch {
            lastFailure = String(describing: error); throw error
        }
    }
    func screen() -> [String]? {
        do { try requireTarget(writing: false); return try bridge.read().text.components(separatedBy: "\n") }
        catch { lastFailure = String(describing: error); return nil }
    }
    static let textAttempts = 5
    /// Checks once, then writes the chunk whole. A check between its keys could stop halfway, for example after Claude's
    /// Ctrl+S stash and before the command, and leave a half-typed command in the input box.
    private func write(_ keys: [WindowsConsoleKey]) throws {
        guard !keys.isEmpty else { return }
        try requireTarget(writing: true)
        do { try bridge.write(keys) } catch { lastFailure = String(describing: error); throw error }
    }
    func type(_ text: String) throws { try write(text.utf16.map { .character($0) }) }
    func press(_ key: Key) throws { try write([.key(key)]) }
}
#endif
