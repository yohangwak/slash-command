import AppKit
import ApplicationServices
import ModelSwitchCore
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

    /// 그 권한 목록 화면을 연다. 먼저 시스템에 한 번 물어 둔다 — 그래야 ModelSwitch 가 목록에 «이미 들어 있고» 스위치만 켜면 된다.
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

    /// ModelSwitch 가 그 앱을 AppleScript 로 다뤄도 되는가. 묻는 창은 띄우지 않는다.
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
    static let automatedTerminals: [(name: String, bundleID: String)] = [("Ghostty", Detector.ghosttyBundleID)]
}

/// 편집 화면 맨 위의 「권한」 상자가 보는 상태. 창이 떠 있는 동안 1초마다 다시 읽어 — 설정에서 켜고 돌아오면 바로 ✓ 로 바뀐다.
final class PermissionsModel: ObservableObject {
    @Published var accessibility = Permissions.accessibility
    @Published var automation: [String: Permissions.Automation] = [:]

    private var timer: Timer?
    private let queue = DispatchQueue(label: "modelswitch.permissions")

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
        queue.async { [weak self] in
            var found: [String: Permissions.Automation] = [:]
            for terminal in Permissions.automatedTerminals { found[terminal.bundleID] = Permissions.automation(bundleID: terminal.bundleID) }
            DispatchQueue.main.async { if self?.automation != found { self?.automation = found } }
        }
    }
}

/// 「권한」 상자: 권한마다 상태와 «그 설정 화면을 여는» 버튼.
struct PermissionsBox: View {
    @ObservedObject var model: PermissionsModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                row(title: "손쉬운 사용 (Accessibility)",
                    ok: model.accessibility,
                    status: model.accessibility ? "켜짐" : "꺼짐",
                    detail: "Ghostty 화면 읽기에 꼭 필요하고, Orca 에서는 탭을 옮긴 직후에도 지금 보이는 탭을 정확히 알게 해 줍니다. 열리는 목록에서 ModelSwitch 의 스위치를 켜 주세요(목록에 없으면 아래 + 로 추가).",
                    button: model.accessibility ? "설정 보기" : "설정 열기…",
                    action: Permissions.openAccessibility)
                ForEach(Permissions.automatedTerminals, id: \.bundleID) { terminal in
                    let state = model.automation[terminal.bundleID] ?? .notAsked
                    row(title: "자동화 (Automation) → \(terminal.name)",
                        ok: state == .allowed,
                        status: label(state),
                        detail: "\(terminal.name) 터미널에 전환 명령을 입력하는 데 씁니다. 열리는 목록의 ModelSwitch 아래에서 \(terminal.name) 를 켜 주세요. 처음 단축키를 누를 때 시스템이 한 번 묻습니다.",
                        button: state == .allowed ? "설정 보기" : "설정 열기…",
                        action: Permissions.openAutomation,
                        neutral: state == .notRunning || state == .notAsked)
                }
            }
            .padding(4)
        } label: {
            Text("권한").font(.headline)
        }
    }

    private func label(_ state: Permissions.Automation) -> String {
        switch state {
        case .allowed: return "켜짐"
        case .denied: return "꺼짐"
        case .notAsked: return "아직 묻지 않음"
        case .notRunning: return "앱이 꺼져 있어 확인 못 함"
        }
    }

    private func row(title: String, ok: Bool, status: String, detail: String, button: String, action: @escaping () -> Void,
                     neutral: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : (neutral ? "questionmark.circle" : "exclamationmark.triangle.fill"))
                .foregroundStyle(ok ? Color.green : (neutral ? Color.secondary : Color.orange))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    Text(status).foregroundStyle(.secondary)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(button, action: action)
        }
    }
}
