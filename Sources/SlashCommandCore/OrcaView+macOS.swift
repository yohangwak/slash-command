#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

extension OrcaView {
    // MARK: - Reading through accessibility

    /// Orca's tab strip right now. nil if there is no permission or it cannot be read.
    ///
    /// Chromium builds Orca's page for accessibility only once a reader asks (`AXManualAccessibility`), and the read that asks first
    /// gets the window without its page (measured 2026-11-14 on a Mac, Orca 1.4.258: 12–13 elements, then the full 215 one to two seconds
    /// later, read through a new application element each time). So a read that finds no tab strip is repeated for a short while.
    public static func readStrip() -> Strip? {
        guard GhosttyScreen.trusted() else { return nil }
        return retrying(times: 8, every: 0.15) { readStripOnce() }
    }

    /// Calls `read` until it returns a value, at most `times` more times after the first, waiting `every` seconds in between.
    static func retrying<T>(times: Int, every: TimeInterval, wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                            _ read: () -> T?) -> T? {
        if let value = read() { return value }
        for _ in 0..<max(0, times) {
            wait(every)
            if let value = read() { return value }
        }
        return nil
    }

    private static func readStripOnce() -> Strip? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Detector.orcaBundleID).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium exposes the web view (DOM) in the tree only when there is an accessibility request.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var windows = (attribute(element, "AXWindows") as? [AXUIElement]) ?? []
        // On 2026-11-13 (Orca 1.4.257, full screen) `AXWindows` once came back empty while the focused window was there.
        if windows.isEmpty {
            windows = ["AXFocusedWindow", "AXMainWindow"].compactMap { attribute(element, $0) }.map { $0 as! AXUIElement }
        }
        // Put the app element in as "already seen" — under the window the app element sometimes comes out again as a child (see `tabs(from:…)` below).
        // The walk asks `tab`, then (for an element that is not a tab) `group`, about the same element: read its classes once.
        var last: (node: Node, classes: [String])?
        func classes(of node: Node) -> [String] {
            if let last, last.node == node { return last.classes }
            let read = (attribute(node.element, "AXDOMClassList") as? [String]) ?? []
            last = (node, read)
            return read
        }
        let read = strip(from: windows.map(Node.init), seen: [Node(element)],
                         tab: { tab(of: $0, classes: classes(of: $0)) },
                         currentWorkspace: { currentWorkspace(domID: attribute($0.element, "AXDOMIdentifier") as? String,
                                                              ariaCurrent: attribute($0.element, "AXARIACurrent") as? String) },
                         group: { groupMark(classes: classes(of: $0)) },
                         children: { children(of: $0.element).map(Node.init) })
        return read.flatMap { $0.tabs.isEmpty ? nil : $0 }
    }

    /// The tab an element is (see `tab(classes:texts:buttonLabels:label:)`). Its parts are read only when it has Orca's tab class.
    private static func tab(of node: Node, classes: [String]) -> Strip.Tab? {
        var texts: [String] = []
        var buttonLabels: [String] = []
        if !tabClasses.isDisjoint(with: classes) {
            for child in children(of: node.element) {
                switch attribute(child, "AXRole") as? String {
                case "AXStaticText": texts.append((attribute(child, "AXValue") as? String) ?? "")
                case "AXButton": buttonLabels.append(label(of: child))
                default: break
                }
            }
        }
        return tab(classes: classes, texts: texts, buttonLabels: buttonLabels, label: label(of: node.element))
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
