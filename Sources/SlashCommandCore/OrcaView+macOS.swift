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
        var windows = (attribute(element, "AXWindows") as? [AXUIElement]) ?? []
        // On 2026-11-13 (Orca 1.4.257, full screen) `AXWindows` once came back empty while the focused window was there.
        if windows.isEmpty {
            windows = ["AXFocusedWindow", "AXMainWindow"].compactMap { attribute(element, $0) }.map { $0 as! AXUIElement }
        }
        // Put the app element in as "already seen" — under the window the app element sometimes comes out again as a child (see `tabs(from:…)` below).
        let read = strip(from: windows.map(Node.init), seen: [Node(element)],
                         tab: tab(of:),
                         currentWorkspace: { currentWorkspace(domID: attribute($0.element, "AXDOMIdentifier") as? String,
                                                              ariaCurrent: attribute($0.element, "AXARIACurrent") as? String) },
                         children: { children(of: $0.element).map(Node.init) })
        return read.flatMap { $0.tabs.isEmpty ? nil : $0 }
    }

    /// The tab an element is: read from its parts when it has Orca's tab class (any language), otherwise from its English label.
    private static func tab(of node: Node) -> Strip.Tab? {
        let classes = (attribute(node.element, "AXDOMClassList") as? [String]) ?? []
        if !tabClasses.isDisjoint(with: classes) {
            var texts: [String] = []
            var buttonLabels: [String] = []
            for child in children(of: node.element) {
                switch attribute(child, "AXRole") as? String {
                case "AXStaticText": texts.append((attribute(child, "AXValue") as? String) ?? "")
                case "AXButton": buttonLabels.append(label(of: child))
                default: break
                }
            }
            if let tab = tab(classes: classes, texts: texts, buttonLabels: buttonLabels) { return tab }
        }
        return tab(fromLabel: label(of: node.element), classes: classes)
    }

    private static func label(of element: AXUIElement) -> String {
        let title = (attribute(element, "AXTitle") as? String) ?? ""
        return title.isEmpty ? (attribute(element, "AXDescription") as? String) ?? "" : title
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (attribute(element, "AXChildren") as? [AXUIElement]) ?? []
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
