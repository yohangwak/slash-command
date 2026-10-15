import AppKit
import ApplicationServices

/// Ghostty exposes the terminal screen text as an accessibility (AX) text area. Reading it needs the Accessibility permission.
public enum GhosttyScreen {
    public static func trusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// The time (0.5 s) during which Ghostty returns the screen text without rebuilding it, plus some margin.
    public static let cacheMs = 520

    private static let clock = NSLock()
    nonisolated(unsafe) private static var lastFetch: DispatchTime?

    /// Waits until `cacheMs` has passed since our last read, so that reading now gives a fresh screen.
    /// If this process has never read yet, it cannot know whether someone just read, so it waits the full time once.
    public static func waitUntilFresh() {
        clock.lock()
        let last = lastFetch
        clock.unlock()
        var wait = Double(cacheMs) / 1000
        if let last {
            let since = Double(DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000_000
            wait -= since
        } else {
            // Read once to set Ghostty's cache time to now, then wait that long.
            _ = lines()
        }
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    }

    /// The lines of the focused terminal's screen. nil if there is no permission or it was not found.
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
