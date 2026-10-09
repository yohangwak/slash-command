import AppKit
import ApplicationServices
import Foundation
import SlashCommandCore

/// Orca 에서 «지금 보이는 터미널» 을 알려 주는 신호들이 UI 보다 얼마나 늦는지 재는 시험 도구(아무것도 보내지 않는다).
/// 사람이 Orca 에서 탭·워크스페이스를 몇 번 옮기는 동안 돌려 두면, 신호가 바뀐 시각을 같은 시계로 찍는다.
///   - 클릭: 마우스 왼쪽 버튼이 눌린 시각(권한 필요 없음)
///   - AX: Orca 의 «포커스된 요소» 와 그 부모 사슬이 바뀐 시각
///   - DB: 상태 DB 의 활성 워크스페이스·탭이 바뀐 시각
///   - 목록: 소켓 `terminal.list` 의 워크스페이스별 활성 탭이 바뀐 시각
enum OrcaProbe {
    static func run(seconds: Double) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Detector.orcaBundleID }) else {
            print("Orca 가 실행 중이 아닙니다"); return
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let start = Date()
        func stamp() -> String { String(format: "+%6.3fs", Date().timeIntervalSince(start)) }
        print("\(Int(seconds))초 동안 기록합니다. 지금 Orca 로 가서 탭·워크스페이스를 몇 번 옮겨 주세요(클릭으로도, 단축키로도).")

        var lastChain = "", lastDB = "", lastList = ""
        var lastClick = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        var lastTick = Date.distantPast
        while Date().timeIntervalSince(start) < seconds {
            let click = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
            if click < lastClick { print("\(stamp()) 클릭   (앞 앱: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))") }
            lastClick = click

            let chain = focusChain(element)
            if chain != lastChain { print("\(stamp()) AX     \(chain.isEmpty ? "(포커스 없음)" : chain)"); lastChain = chain }

            if Date().timeIntervalSince(lastTick) > 0.3 {
                lastTick = Date()
                let db = (try? OrcaState.active()).map { "\($0.worktreeID.suffix(28)) tab=\($0.tabID.prefix(8))" } ?? "(읽지 못함)"
                if db != lastDB { print("\(stamp()) DB     \(db)"); lastDB = db }
                let list = activeTabs()
                if list != lastList { print("\(stamp()) 목록   \(list)"); lastList = list }
            }
            usleep(20_000)
        }
        print("끝")
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// 포커스된 요소에서 위로 올라가며 역할·DOM id·클래스·제목을 짧게 적은 한 줄.
    static func focusChain(_ app: AXUIElement) -> String {
        guard let focused = attribute(app, "AXFocusedUIElement") else { return "" }
        var parts: [String] = []
        var current: AXUIElement? = (focused as! AXUIElement)
        var depth = 0
        while let element = current, depth < 8 {
            let role = (attribute(element, "AXRole") as? String ?? "?").replacingOccurrences(of: "AX", with: "")
            let id = attribute(element, "AXDOMIdentifier") as? String ?? ""
            let cls = (attribute(element, "AXDOMClassList") as? [String])?.prefix(2).joined(separator: ".") ?? ""
            let title = (attribute(element, "AXTitle") as? String ?? attribute(element, "AXDescription") as? String ?? "").prefix(24)
            parts.append([role, id.isEmpty ? nil : "#\(id)", cls.isEmpty ? nil : ".\(cls)", title.isEmpty ? nil : "\"\(title)\""].compactMap { $0 }.joined())
            current = attribute(element, "AXParent") as! AXUIElement?
            depth += 1
        }
        return parts.joined(separator: " < ")
    }

    /// terminal.list 에서 «DB 가 말하는 활성 워크스페이스» 의 탭마다 활성 분할(leaf)을 모은다.
    /// 목록이 따로 «지금 보이는 탭» 을 주는지, 분할 포커스는 DB 보다 빨리 바뀌는지를 본다.
    static func activeTabs() -> String {
        guard case .success(let payload) = OrcaRuntime.call("terminal.list", ["includeVisualLayouts": true]) else { return "(읽지 못함)" }
        let layouts = payload["visualLayouts"] as? [[String: Any]] ?? []
        var found: [String] = []
        for layout in layouts {
            var keys = layout.keys.filter { $0.lowercased().contains("active") }.sorted().map { "\($0)=\("\(layout[$0] ?? "")".prefix(8))" }
            var stack: [Any] = [layout["root"] as Any]
            while let node = stack.popLast() {
                if let array = node as? [Any] { stack.append(contentsOf: array); continue }
                guard let dict = node as? [String: Any] else { continue }
                if let tabs = dict["tabs"] as? [[String: Any]] {
                    for tab in tabs {
                        let id = "\(tab["tabId"] ?? "")".prefix(6)
                        let leaf = "\(tab["activeLeafId"] ?? "-")".prefix(6)
                        keys.append("\(id):\(leaf)")
                    }
                }
                for (key, value) in dict where key != "tabs" { stack.append(value) }
                for key in dict.keys.filter({ $0.lowercased().contains("active") && $0 != "activeLeafId" }).sorted() { keys.append("\(key)=\("\(dict[key] ?? "")".prefix(8))") }
            }
            found.append("\("\(layout["worktreeId"] ?? "")".suffix(12)){\(keys.sorted().joined(separator: ","))}")
        }
        return found.sorted().joined(separator: " ")
    }
}
