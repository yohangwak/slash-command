#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

extension OrcaView {
    // MARK: - Reading through accessibility

    /// What a read of Orca's tab strip found.
    public enum StripReading {
        /// The strip of the window.
        case read(Strip)
        /// Orca has a window but has not put its page in the accessibility tree yet: Chromium builds it some time after a reader first
        /// asks. Measured 2026-11-15 on a Mac with Orca 1.4.259: the window alone (12–13 elements, no page) for 12 to 46 seconds after
        /// the first request — however long Orca had been running — then the full page (about 220 elements). With 1.4.258 it took
        /// one to two seconds. `prepare(pid:)` asks early so a hotkey press does not land in that gap.
        case pageNotReady
        /// No permission, no Orca, no window, or a page without a tab strip this reader knows.
        case unreadable
    }

    /// Orca's tab strip right now.
    ///
    /// Chromium builds Orca's page for accessibility only once a reader asks (`AXManualAccessibility`), and the reads that follow get
    /// the window without its page for a while (see `StripReading.pageNotReady`). A read that finds no tab strip is repeated for a short
    /// while, which covers the one to two seconds Orca 1.4.258 takes.
    public static func readStrip() -> StripReading {
        guard GhosttyScreen.trusted() else { return .unreadable }
        return reading(times: 8, every: 0.15) { readStripOnce() }
    }

    /// Reads with `retrying`; when no read finds a strip, the last read says whether the page was missing from a window that is there.
    static func reading(times: Int, every: TimeInterval, wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                        _ read: () -> (strip: Strip?, windowWithoutPage: Bool)) -> StripReading {
        var windowWithoutPage = false
        let strip = retrying(times: times, every: every, wait: wait) { () -> Strip? in
            let once = read()
            windowWithoutPage = once.windowWithoutPage
            return once.strip
        }
        if let strip { return .read(strip) }
        return windowWithoutPage ? .pageNotReady : .unreadable
    }

    /// Asks Orca to build its page for accessibility, and reads nothing. The app calls it when Orca comes to the front, so the page
    /// is there by the time a hotkey is pressed (see `StripReading.pageNotReady`). Asking again once it is built changes nothing.
    /// Returns whether Orca took the request: while it is still starting it refuses (measured 2026-11-15, Orca 1.4.259: refused
    /// with `kAXErrorCannotComplete` 0.3 seconds after launch, and the page was still missing 50 seconds later; taken at 3 and at
    /// 6 seconds, and the page was there 50 seconds later).
    public static func prepare(pid: pid_t) -> Bool {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 2)
        return AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
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

    /// One read. `windowWithoutPage`: no strip was found, and Orca has a window with no web page (`AXWebArea`) in it. While Orca is
    /// still building its page the window holds only Electron's frame — a few groups and the window buttons (measured 2026-11-15).
    private static func readStripOnce() -> (strip: Strip?, windowWithoutPage: Bool) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Detector.orcaBundleID).first else { return (nil, false) }
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
        if let read, !read.tabs.isEmpty { return (read, false) }
        return (nil, !windows.isEmpty && !hasWebArea(under: windows))
    }

    /// Whether a web page is among the first elements under the windows (it sits about seven levels down in Orca 1.4.259).
    private static func hasWebArea(under windows: [AXUIElement]) -> Bool {
        var level = windows, looked = 0
        for _ in 0..<12 where !level.isEmpty {
            var next: [AXUIElement] = []
            for element in level {
                looked += 1
                if looked > 400 { return true }  // a large tree is not a page still being built
                if attribute(element, "AXRole") as? String == "AXWebArea" { return true }
                next += children(of: element)
            }
            level = next
        }
        return false
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
