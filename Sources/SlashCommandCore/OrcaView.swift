import AppKit
import ApplicationServices
import Foundation

/// Reads the tab that is "currently visible" in Orca's window through accessibility (AX) and matches it against the terminal list.
///
/// Why: the state DB and the "active tab" of `terminal.list` lag the UI by 1.3-2.5 s (measured 2026-10-07, same switch 5 times: DB +1.3-1.7 s).
/// Orca's tab strip (DOM) is in the accessibility tree in order, and only the active tab has the `text-foreground` class — in the same switch it followed within 0.25 s.
/// Matching the order of titles in the tab strip against the layout of `terminal.list` (the order of tab titles per workspace) determines the workspace and tab.
/// `nil` if it cannot be read or is not narrowed to one — the caller falls back to the DB (the old behavior; the latency risk is documented).
public enum OrcaView {
    public struct Strip: Equatable, Sendable {
        /// The titles in the tab strip (from the left). `truncated` is true if a title is cut off.
        public struct Tab: Equatable, Sendable {
            public let title: String
            public let truncated: Bool
            public let active: Bool

            public init(title: String, truncated: Bool, active: Bool) {
                self.title = title
                self.truncated = truncated
                self.active = active
            }
        }

        public let tabs: [Tab]

        public init(tabs: [Tab]) { self.tabs = tabs }
    }

    public enum Resolution: Equatable, Sendable {
        case tab(OrcaState.Active)
        /// More than one workspace has the same order of tab titles.
        case ambiguous([String])
        /// No workspace matches (the tab strip may contain non-terminal tabs).
        case noMatch
    }

    // MARK: - Matching (pure functions)

    /// For comparing titles: lowercase, and anything that is not a letter or digit becomes a single space (AX reads symbols like `-` as a space).
    static func normalized(_ text: String) -> String {
        var out = ""
        var lastSpace = true
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastSpace = false
            } else if !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func titlesMatch(_ listed: String, _ shown: Strip.Tab) -> Bool {
        let a = normalized(listed)
        let b = normalized(shown.title)
        if a == b { return true }
        // Long titles are cut off on screen. If it comes with an ellipsis (`...`) it is enough to match the part before it; and in the 2026-10-07 measurement some titles come with only the leading part, with no ellipsis
        // (a 96-character title came through only up to "...HANDOFF 2026 10 06"). In that case a prefix match is accepted only for 12 or more characters —
        // so that short titles (`initial` vs `initial 2`) do not get mixed up. In any case the tab count and "all" tab titles must match together.
        guard !b.isEmpty, a.hasPrefix(b) else { return false }
        return shown.truncated || b.count >= 12
    }

    /// Matches the tab strip against the layout (`visualLayouts` of `terminal.list`). Both the tab count and the order of titles must be the same.
    /// If there is more than one candidate it is "ambiguous" — do not pick with the late state DB (right after switching workspace the DB holds the old value for 1.3-2.5 s).
    public static func resolve(strip: Strip, layouts: [[String: Any]]) -> Resolution {
        guard !strip.tabs.isEmpty, let activeIndex = strip.tabs.firstIndex(where: \.active),
              strip.tabs.filter(\.active).count == 1 else { return .noMatch }
        var candidates: [(worktree: String, tabID: String)] = []
        for layout in layouts {
            guard let worktree = layout["worktreeId"] as? String else { continue }
            let tabs = OrcaState.tabs(in: layout["root"])
            guard tabs.count == strip.tabs.count else { continue }
            let same = zip(tabs, strip.tabs).allSatisfy { titlesMatch($0.0["title"] as? String ?? "", $0.1) }
            guard same, let tabID = tabs[activeIndex]["tabId"] as? String else { continue }
            candidates.append((worktree, tabID))
        }
        switch candidates.count {
        case 0: return .noMatch
        case 1: return .tab(OrcaState.Active(worktreeID: candidates[0].worktree, tabID: candidates[0].tabID))
        default:
            return .ambiguous(candidates.map(\.worktree))
        }
    }

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

    /// Walks the tree from top to bottom, siblings in turn, and collects tab buttons. Does not look inside a tab button.
    ///
    /// RED: this tree is sometimes "not a tree": under Orca's window the app element comes out again as a child, continuing endlessly
    /// (measured 2026-10-12 on a test Mac: `AXApplication > AXApplication > …`, the stack overflowed at a depth of 65,000 and the program died).
    /// So it does not enter an element it has already seen, and it also sets limits on depth and element count.
    /// If a limit is hit, there may be a tab it did not see, so the answer is "unknown" (nil) — a tab is not picked from a partially read tab strip.
    static func tabs<N: Hashable>(from roots: [N], seen: Set<N> = [], maxDepth: Int = 150, maxNodes: Int = 30_000,
                                  label: (N) -> String, classes: (N) -> [String], children: (N) -> [N]) -> [Strip.Tab]? {
        var seen = seen
        var tabs: [Strip.Tab] = []
        var cut = false
        func visit(_ node: N, depth: Int) {
            guard !cut, seen.insert(node).inserted else { return }
            guard depth <= maxDepth, seen.count <= maxNodes else { cut = true; return }
            if let tab = tab(fromLabel: label(node), classes: classes(node)) {
                tabs.append(tab)
                return
            }
            for child in children(node) { visit(child, depth: depth + 1) }
        }
        for root in roots { visit(root, depth: 0) }
        return cut ? nil : tabs
    }

    /// A tab button of the form `"<state> <title> Close tab <title>"`. The title is the part after "Close tab ".
    static func tab(fromLabel label: String, classes: [String]) -> Strip.Tab? {
        guard let range = label.range(of: "Close tab ", options: .backwards) else { return nil }
        var title = String(label[range.upperBound...])
        var truncated = false
        for ellipsis in ["...", "…"] where title.hasSuffix(ellipsis) {
            title = String(title.dropLast(ellipsis.count))
            truncated = true
        }
        // Only the active tab has the class `text-foreground` (exactly). The rest have `text-muted-foreground` and `hover:text-foreground`.
        return Strip.Tab(title: title, truncated: truncated, active: classes.contains("text-foreground"))
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
