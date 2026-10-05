import AppKit
import ApplicationServices

/// Ghostty 는 터미널 화면 글자를 접근성(AX) 텍스트 영역으로 내준다. 읽으려면 「손쉬운 사용」 권한이 필요하다.
public enum GhosttyScreen {
    public static func trusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 포커스가 있는 터미널의 화면 줄들. 권한이 없거나 못 찾으면 nil.
    public static func lines() -> [String]? {
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
