import AppKit
import ApplicationServices
import SlashCommandCore
import SwiftUI

/// Reads the state of macOS permissions and opens the exact System Settings pane that turns each one on.
///
/// Users should not have to find their way around System Settings: when something must be turned on there, the app has a button that goes straight to that pane (decided 2026-10-08).
/// System Settings has two "Accessibility" entries (the accessibility features pane in the sidebar and
/// the app permission list inside Privacy & Security), so describing it in words sends people to the wrong one.
enum Permissions {
    /// System Settings → Privacy & Security → Accessibility (the app permission list).
    static let accessibilityPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    /// System Settings → Privacy & Security → Automation.
    static let automationPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    static var accessibility: Bool { GhosttyScreen.trusted() }

    /// Opens that permission list. It asks the system once first, so Slash Command is already in the list and only the switch needs turning on.
    static func openAccessibility() {
        _ = GhosttyScreen.trusted(prompt: true)
        NSWorkspace.shared.open(accessibilityPane)
    }

    static func openAutomation() {
        NSWorkspace.shared.open(automationPane)
    }

    typealias Automation = AutomationConsent

    /// Whether Slash Command may control that app with AppleScript. It does not show the prompt.
    /// Call it off the main thread: it can take a long time if the target app does not respond.
    static func automation(bundleID: String) -> Automation { AutomationConsent.status(bundleID: bundleID) }

    /// Terminals controlled with AppleScript (name, bundle id).
    static let automatedTerminals: [(name: String, bundleID: String)] = [("Ghostty", Detector.ghosttyBundleID), ("iTerm2", Detector.itermBundleID)]

    /// Those installed on this Mac. Permissions of terminals that are not used are not shown.
    static var installedAutomatedTerminals: [(name: String, bundleID: String)] {
        automatedTerminals.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }
}

/// The state the "Permissions" row at the top of the edit window shows. It is re-read every second while the window is open, so it flips to ✓ as soon as the user turns it on in Settings and comes back.
final class PermissionsModel: ObservableObject {
    @Published var accessibility = Permissions.accessibility
    @Published var automation: [String: Permissions.Automation] = [:]

    private var timer: Timer?
    private let queue = DispatchQueue(label: "slashcommand.permissions")
    /// Do not start a new check while the previous one is unfinished: if the target app does not respond, a check takes a long time and they would pile up every second.
    private var checking = false

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let trusted = Permissions.accessibility
        if trusted != accessibility { accessibility = trusted }
        guard !checking else { return }
        checking = true
        queue.async { [weak self] in
            var found: [String: Permissions.Automation] = [:]
            for terminal in Permissions.automatedTerminals { found[terminal.bundleID] = Permissions.automation(bundleID: terminal.bundleID) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                if self.automation != found { self.automation = found }
            }
        }
    }
}

/// The "Permissions" row: for each permission, its state and a button that opens that settings pane. One line when it is on; when something needs doing, it says what to do.
struct PermissionsSection: View {
    @ObservedObject var model: PermissionsModel

    var body: some View {
        Section {
            row(title: SettingsNames.accessibility,
                state: model.accessibility ? .ok : .problem,
                status: model.accessibility ? loc("On") : loc("Off"),
                detail: model.accessibility
                    ? loc("Used to read the Ghostty screen, to follow tab changes in Orca, and to check that iTerm2 Broadcast Input is off.")
                    : loc("Needed to read the Ghostty screen and to check that iTerm2 Broadcast Input is off; in Orca it keeps up with the tab you just switched to. Turn on Slash Command in the list that opens (use + if it is not listed)."),
                action: Permissions.openAccessibility)
            ForEach(Permissions.installedAutomatedTerminals, id: \.bundleID) { terminal in
                let state = model.automation[terminal.bundleID] ?? .notAsked
                row(title: loc("Automation → %@", terminal.name),
                    state: state == .allowed ? .ok : (state == .denied ? .problem : .unknown),
                    status: status(state),
                    detail: detail(state, terminal: terminal.name),
                    action: Permissions.openAutomation)
            }
        } header: {
            Text(loc("Permissions"))
        }
    }

    private enum RowState { case ok, problem, unknown }

    private func status(_ state: Permissions.Automation) -> String {
        switch state {
        case .allowed: return loc("On")
        case .denied: return loc("Off")
        case .notAsked: return loc("Not asked yet")
        case .notRunning: return loc("Not running")
        }
    }

    private func detail(_ state: Permissions.Automation, terminal: String) -> String {
        switch state {
        case .allowed: return loc("Used to type the switch commands into %@.", terminal)
        case .denied: return loc("Slash Command cannot type into %@. Turn on %@ under Slash Command in the list that opens.", terminal, terminal)
        case .notAsked: return loc("macOS asks once, the first time you press a shortcut in %@.", terminal)
        case .notRunning: return loc("%@ is not running, so this cannot be checked now.", terminal)
        }
    }

    private func row(title: String, state: RowState, status: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: state == .ok ? "checkmark.circle.fill" : (state == .problem ? "exclamationmark.triangle.fill" : "questionmark.circle"))
                .foregroundStyle(state == .ok ? Color.green : (state == .problem ? Color.orange : Color.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    Text(status).foregroundStyle(.secondary)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(loc("Open System Settings…"), action: action)
        }
    }
}
