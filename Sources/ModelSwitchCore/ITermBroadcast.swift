import AppKit
import ApplicationServices
import Foundation

/// iTerm2 의 «입력 방송»(Broadcast Input) 상태.
///
/// 켜져 있으면 AppleScript `write text` 도 다른 칸(·다른 탭)에 같이 들어간다 — 2026-10-07 맥북 실측: 「모든 탭의 모든 칸에 입력 보내기」를
/// 켠 두 칸 창에서 한 칸에 `write text` 를 했더니 다른 칸에도 같은 글이 도착했다. 다른 칸은 입력창이 보이는지 확인한 적이 없으므로
/// 방송 중에는 보내지 않는다. 상태는 iTerm2 의 Shell ▸ Broadcast Input 메뉴 체크 표시를 접근성(AX)으로 읽는다(손쉬운 사용 권한 필요).
public enum ITermBroadcast {
    public enum State: Equatable, Sendable {
        case off
        case on(String)
        /// 읽지 못했다 — 방송이 꺼져 있다고 말할 수 없으므로 보내지 않는다.
        case unknown(String)

        public var allowsSending: Bool { self == .off }
    }

    struct MenuItem: Equatable {
        let title: String
        let marked: Bool
    }

    /// 메뉴 항목들로 상태를 가른다. 「현재 세션에만 입력」이 체크돼 있어야 꺼진 것이다.
    static func classify(_ items: [MenuItem]) -> State {
        guard !items.isEmpty else { return .unknown("Broadcast Input 메뉴를 찾지 못했습니다") }
        if let active = items.first(where: { $0.marked && $0.title.localizedCaseInsensitiveContains("All Panes") }) {
            return .on(active.title)
        }
        if items.contains(where: { $0.marked && $0.title.localizedCaseInsensitiveContains("Current Session Only") }) {
            return .off
        }
        // 체크된 항목이 없거나 모르는 항목이 체크됐다 — 형식이 달라졌을 수 있다.
        return .unknown("Broadcast Input 체크 상태를 알 수 없습니다")
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, state: State)?

    /// 한 번의 전환에서 입력을 여러 번 보내므로 1초 동안은 같은 답을 쓴다(메뉴를 읽는 데 수십 ms 가 든다).
    public static func state() -> State {
        lock.lock(); defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(cached.at) < 1 { return cached.state }
        let fresh = read()
        cached = (Date(), fresh)
        return fresh
    }

    private static func read() -> State {
        guard GhosttyScreen.trusted() else { return .unknown("손쉬운 사용 권한이 없어 iTerm2 의 입력 방송 상태를 읽지 못했습니다") }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Detector.itermBundleID).first else {
            return .unknown("iTerm2 가 실행 중이 아닙니다")
        }
        return classify(menuItems(pid: app.processIdentifier))
    }

    /// 사람이 보는 한 줄(`doctor`·시험용).
    public static func dump() -> [String] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Detector.itermBundleID).first else { return ["iTerm2 not running"] }
        return ["trusted=\(GhosttyScreen.trusted())"] + menuItems(pid: app.processIdentifier).map { "[\($0.marked ? "x" : " ")] \($0.title)" }
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
