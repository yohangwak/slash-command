import AppKit
import ApplicationServices

/// Ghostty 는 터미널 화면 글자를 접근성(AX) 텍스트 영역으로 내준다. 읽으려면 「손쉬운 사용」 권한이 필요하다.
public enum GhosttyScreen {
    public static func trusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Ghostty 가 화면 글자를 다시 만들지 않고 돌려주는 시간(0.5초)에 여유를 더한 값.
    public static let cacheMs = 520

    private static let clock = NSLock()
    nonisolated(unsafe) private static var lastFetch: DispatchTime?

    /// 지금 읽으면 새 화면이 나오도록, 우리가 마지막으로 읽은 뒤 `cacheMs` 가 지날 때까지 기다린다.
    /// 이 프로세스가 아직 읽은 적이 없으면 누가 방금 읽었는지 알 수 없으므로 한 번은 다 기다린다.
    public static func waitUntilFresh() {
        clock.lock()
        let last = lastFetch
        clock.unlock()
        var wait = Double(cacheMs) / 1000
        if let last {
            let since = Double(DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000_000
            wait -= since
        } else {
            // 한 번 읽어 Ghostty 의 보관 시각을 지금으로 맞춰 놓고 그만큼 기다린다.
            _ = lines()
        }
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    }

    /// 포커스가 있는 터미널의 화면 줄들. 권한이 없거나 못 찾으면 nil.
    public static func lines() -> [String]? {
        clock.lock()
        lastFetch = .now()
        clock.unlock()
        return fetch()
    }

    private static func fetch() -> [String]? {
        guard trusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Detector.ghosttyBundleID).first else {
            return nil
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 2)

        var area = (attribute(element, kAXFocusedUIElementAttribute) as! AXUIElement?).flatMap { isTextArea($0) ? $0 : nil }
        if area == nil, let window = attribute(element, kAXFocusedWindowAttribute) {
            let areas = textAreas(in: window as! AXUIElement, depth: 0)
            area = areas.first { (attribute($0, kAXFocusedAttribute) as? Bool) == true } ?? areas.first
        }
        guard let area, let text = attribute(area, kAXValueAttribute) as? String else { return nil }
        return text.components(separatedBy: "\n")
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func isTextArea(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXRoleAttribute) as? String) == (kAXTextAreaRole as String)
    }

    private static func textAreas(in element: AXUIElement, depth: Int) -> [AXUIElement] {
        if isTextArea(element) { return [element] }
        guard depth < 12, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return children.flatMap { textAreas(in: $0, depth: depth + 1) }
    }
}
