#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

extension OrcaView {
    // MARK: - Reading through accessibility

    /// Orca's tab strip right now. nil if there is no permission or it cannot be read.
    public static func readStrip() -> Strip? {
        guard GhosttyScreen.trusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Detector.orcaBundleID).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium exposes the web view (DOM) in the tree only when there is an accessibility request.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let windows = ((attribute(element, "AXWindows") as? [AXUIElement]) ?? []).map(Node.init)
        // Put the app element in as "already seen" — under the window the app element sometimes comes out again as a child (see `tabs(from:…)` below).
        let tabs = tabs(from: windows, seen: [Node(element)],
                        label: { (attribute($0.element, "AXTitle") as? String) ?? (attribute($0.element, "AXDescription") as? String) ?? "" },
                        classes: { (attribute($0.element, "AXDOMClassList") as? [String]) ?? [] },
                        children: { ((attribute($0.element, "AXChildren") as? [AXUIElement]) ?? []).map(Node.init) })
        return tabs.flatMap { $0.isEmpty ? nil : Strip(tabs: $0) }
    }

    /// One accessibility element. Whether it is the same element is judged with `CFEqual` (receiving the same element again gives a different object).
    struct Node: Hashable {
        let element: AXUIElement
        init(_ element: AXUIElement) { self.element = element }
        static func == (a: Node, b: Node) -> Bool { CFEqual(a.element, b.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
#endif
