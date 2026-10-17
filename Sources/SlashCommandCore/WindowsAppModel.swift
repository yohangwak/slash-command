import Foundation

/// Windows presentation decisions, kept independent of WinSDK for portable tests.
public enum WindowsAppModel {
    public enum RefreshReason { case foregroundChanged, menu, tick }

    /// A WezTerm lookup launches CLI children; idle ticks must remain in-process.
    public static func looksUpTarget(app: String, reason: RefreshReason) -> Bool {
        switch app {
        case "orca": return true
        case "wezterm", "windowsterminal": return reason != .tick
        default: return false
        }
    }

    public static let version = "0.2.0" // scripts/Info.plist
    public static let effortUp = 101
    public static let effortDown = 102

    public struct Modifiers: Equatable {
        public let flags: UInt32
        public let warning: String?
    }

    public static func modifiers(_ names: [String]) -> Modifiers {
        if names.contains("command") {
            return Modifiers(flags: 0x4005, warning: loc("Command is unavailable on Windows. Using Alt+Shift."))
        }
        guard names.contains("control") || names.contains("option") else {
            return Modifiers(flags: 0x4005, warning: loc("Shortcuts need Control or Alt. Using Alt+Shift."))
        }
        let bits: [String: UInt32] = ["option": 1, "control": 2, "shift": 4]
        return Modifiers(flags: Set(names).compactMap { bits[$0] }.reduce(0x4000, |), warning: nil)
    }

    public static func scanCode(for id: Int) -> UInt32? {
        if (1...9).contains(id) { return UInt32(id + 1) }
        if id == effortUp { return 0x0D }
        if id == effortDown { return 0x0C }
        return nil
    }

    public static func supports(image: String) -> Bool {
        app(image: image) != nil
    }

    public static func app(image: String) -> String? {
        switch image.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last?.lowercased() {
        case "orca.exe": return "orca"
        case "wezterm-gui.exe": return "wezterm"
        case "windowsterminal.exe": return "windowsterminal"
        default: return nil
        }
    }

    public static func keyName(_ id: Int) -> String {
        id == effortUp ? "=" : id == effortDown ? "-" : String(id)
    }

    public static func pressID(_ value: String) -> Int? {
        if value == "up" { return effortUp }
        if value == "down" { return effortDown }
        guard let id = Int(value), String(id) == value, (1...9).contains(id) else { return nil }
        return id
    }

    /// Shell tray activation and our own no-activate UI must not replace the terminal snapshot.
    public static func keepsSnapshot(pid: UInt32, ownPID: UInt32, image: String, windowClass: String) -> Bool {
        if pid != 0 && pid == ownPID { return true }
        let name = image.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last?.lowercased()
        // Windows 11 opens hidden tray icons in TopLevelWindowForOverflowXamlIsland (measured 2026-10-16, build 26200).
        return name == "explorer.exe" && ["Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland"].contains(windowClass)
    }

    public enum NoticeKind { case result, error, awaiting, awaitingError, unchanged, multiline }
    public static func seconds(_ kind: NoticeKind) -> TimeInterval? {
        switch kind {
        case .result: return 1.6
        case .error: return 5
        case .awaiting: return nil
        case .awaitingError: return 6
        case .unchanged: return 2.5
        case .multiline: return 4
        }
    }
    public struct Notice {
        public let text: String
        public let seconds: TimeInterval?
        public init(_ text: String, kind: NoticeKind = .result) {
            self.text = text; seconds = WindowsAppModel.seconds(kind)
        }
    }
    public static func targetLine(_ target: Target) -> String {
        "\(target.agent.displayName) · \(target.host.appName) · \(displayLabel(target.label))"
    }

    /// Agents put status symbols at the start of the tab title (Claude Code: `✳`, spinner frames in the Braille block).
    /// The notice's font has no glyph for most of them, so they are dropped for display only.
    public static func displayLabel(_ label: String) -> String {
        let trimmed = label.drop(while: { character in
            character.unicodeScalars.allSatisfy { scalar in
                scalar.properties.generalCategory == .otherSymbol || (0x2800...0x28FF).contains(scalar.value)
                    || scalar.properties.isWhitespace || scalar.value == 0xFE0F
            }
        })
        return trimmed.isEmpty ? label : String(trimmed)
    }
    public static func hud(result: SwitchResult, tabLagNote: Bool = false) -> Notice {
        var lines = [targetLine(result.target)]
        if !result.slotName.isEmpty { lines.append(result.slotName) }
        if let warning = result.warning { lines.append("⚠️ " + warning) }
        if tabLagNote, case .orca = result.target.host { lines.append(loc("Right after switching Orca tabs, wait 2.5 seconds before pressing a shortcut; the visible tab is read from Orca’s delayed state file.")) }
        return Notice(([result.summary] + lines).joined(separator: "\n"), kind: lines.count > 2 ? .multiline : .result)
    }
    public static func actionLabel(_ id: Int) -> String {
        id <= 9 ? "preset \(id)" : id == effortUp ? "effort up" : "effort down"
    }
    public static func hotkeyLine(_ id: Int) -> String {
        "hotkey " + (id <= 9 ? String(id) : actionLabel(id))
    }
    public static func refusal(id: Int, supported: Bool, busy: Bool, registered: [Int]) -> String? {
        if !supported { return "no supported terminal in front" }
        if busy { return "still switching" }
        if !registered.contains(id) { return "key not registered" }
        return nil
    }
    public static func appliedLine(id: Int, result: SwitchResult) -> String {
        "applied \(actionLabel(id)): \(result.summary)\(result.confirmed ? "" : " (no confirmation text)") → \(result.target.agent.rawValue)@\(result.target.host.appName)\(result.warning.map { " ⚠️ " + $0 } ?? "")"
    }
    public static func hotkeysLine(previous: [Int], registered: [Int]) -> String? {
        guard previous != registered else { return nil }
        return registered.isEmpty ? "hotkeys off" : "hotkeys on \(registered.map(keyName).joined(separator: ", "))"
    }
    public static func errorPrefix(_ error: Error) -> String {
        if let error = error as? SlashCommandError {
            if error.awaitingUser { return "awaiting confirmation" }
            if error.nothingToDo { return "unchanged" }
        }
        return "failed"
    }
    public static func logLine(_ message: String, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter(); formatter.timeZone = timeZone
        return "\(formatter.string(from: date)) \(message)\n"
    }

    public static func menu(config: SlashCommandConfig?, supported: Bool, agent: Agent?, terminal: String? = nil,
                            failures: [Int] = [], warning: String? = nil, appName: String = "Orca") -> [String] {
        let status = supported ? "\(appName) · \(agent?.displayName ?? loc("Checking…"))\(terminal.map { " · " + displayLabel($0) } ?? "")"
            : loc("No supported terminal in front")
        var lines = [status]
        if let config {
            for number in 1...9 {
                let title = number <= config.slots.count ? config.slots[number - 1].menuTitle(for: agent) : nil
                lines.append("\(number)  \(title ?? loc("Not set"))")
            }
        } else {
            lines.append(loc("The presets file could not be read — choose Open presets file to fix it."))
        }
        if let warning { lines.append(warning) }
        if !failures.isEmpty {
            lines.append(loc("Another app is using these shortcut keys: %@", failures.map(keyName).joined(separator: ", ")))
        }
        lines += [loc("Open presets file"), loc("Open log folder"), loc("Open at login"), loc("Quit Slash Command")]
        return lines
    }
}
