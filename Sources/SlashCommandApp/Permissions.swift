import AppKit
import ApplicationServices
import SlashCommandCore
import SwiftUI

/// macOS 권한의 상태를 읽고, 그 권한을 켜는 «바로 그» 시스템 설정 화면을 연다.
///
/// 사용자가 시스템 설정에서 길을 찾게 하지 않는다 — 2026-10-08 요한님: «셋팅에서 뭔가 켜야 한다면 그 메뉴로 바로 갈 수 있도록
/// 우리 앱에 버튼 같은 게 있어야 하는 거 아니야?». 시스템 설정에는 «Accessibility» 가 둘이라(사이드바의 장애 접근성 기능 화면과
/// Privacy & Security 안의 앱 권한 목록) 말로 안내하면 엉뚱한 화면에 간다.
enum Permissions {
    /// 시스템 설정 → Privacy & Security → Accessibility(앱 권한 목록).
    static let accessibilityPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    /// 시스템 설정 → Privacy & Security → Automation.
    static let automationPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    static var accessibility: Bool { GhosttyScreen.trusted() }

    /// 그 권한 목록 화면을 연다. 먼저 시스템에 한 번 물어 둔다 — 그래야 Slash Command 가 목록에 «이미 들어 있고» 스위치만 켜면 된다.
    static func openAccessibility() {
        _ = GhosttyScreen.trusted(prompt: true)
        NSWorkspace.shared.open(accessibilityPane)
    }

    static func openAutomation() {
        NSWorkspace.shared.open(automationPane)
    }

    enum Automation: Equatable {
        case allowed
        case denied
        /// 아직 물은 적이 없다 — 처음 쓸 때 시스템이 묻는다.
        case notAsked
        case notRunning
    }

    /// Slash Command 가 그 앱을 AppleScript 로 다뤄도 되는가. 묻는 창은 띄우지 않는다.
    /// 대상 앱이 응답하지 않으면 오래 걸릴 수 있으므로 주 스레드 밖에서 부른다.
    static func automation(bundleID: String) -> Automation {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return .notRunning }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .notAsked     // errAEEventWouldRequireUserConsent(-1744) 등
        }
    }

    /// AppleScript 로 다루는 터미널들(이름, 번들 id).
    static let automatedTerminals: [(name: String, bundleID: String)] = [("Ghostty", Detector.ghosttyBundleID), ("iTerm2", Detector.itermBundleID)]

    /// 그 가운데 이 맥에 깔려 있는 것 — 쓰지 않는 터미널의 권한은 보여 주지 않는다.
    static var installedAutomatedTerminals: [(name: String, bundleID: String)] {
        automatedTerminals.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }
}

/// 편집 화면 맨 위의 「권한」 칸이 보는 상태. 창이 떠 있는 동안 1초마다 다시 읽어 — 설정에서 켜고 돌아오면 바로 ✓ 로 바뀐다.
final class PermissionsModel: ObservableObject {
    @Published var accessibility = Permissions.accessibility
    @Published var automation: [String: Permissions.Automation] = [:]

    private var timer: Timer?
    private let queue = DispatchQueue(label: "slashcommand.permissions")
    /// 앞의 확인이 아직 끝나지 않았으면 새로 넣지 않는다 — 대상 앱이 응답하지 않으면 확인이 오래 걸리고, 그동안 1초마다 쌓인다.
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

/// 「권한」 칸: 권한마다 상태와 «그 설정 화면을 여는» 버튼. 켜져 있으면 한 줄, 손댈 것이 있으면 무엇을 하면 되는지 적는다.
struct PermissionsSection: View {
    @ObservedObject var model: PermissionsModel

    var body: some View {
        Section {
            row(title: loc("Accessibility"),
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
            Button(loc("Open Settings…"), action: action)
        }
    }
}
