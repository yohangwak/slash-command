import Foundation

/// Reads the visible tab in Orca through accessibility (AX) and matches it against the terminal list.
/// The tab strip supplies the active marker and the order of visible titles. The terminal list supplies the workspace and terminal tab IDs.
/// Orca 1.4.256 no longer writes the visible tab to its state database when you switch (measured 2026-11-11), so on a Mac this is the only source.
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
        /// The strip has zero or more than one active marker.
        case noActiveTab
        case tab(OrcaState.Active)
        /// More than one workspace has the same order of tab titles.
        case ambiguous([String])
        /// No workspace has exactly these tabs (the strip may also hold file, browser or chat tabs, which the terminal list does not have).
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
    ///
    /// Exact, not "the terminal tabs appear somewhere in the strip": the strip does not say which of its tabs are terminals, so a looser match
    /// lets a hidden workspace with fewer tabs (a lone "Terminal 1") stand in for the visible one, or a file tab with a terminal's title
    /// stand in for that terminal — and a hidden terminal has an input box too. If there is more than one candidate it is "ambiguous".
    public static func resolve(strip: Strip, layouts: [[String: Any]]) -> Resolution {
        let activeIndices = strip.tabs.indices.filter { strip.tabs[$0].active }
        guard activeIndices.count == 1, let activeIndex = activeIndices.first else { return .noActiveTab }
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
        default: return .ambiguous(candidates.map(\.worktree))
        }
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
        let active = classes.contains("text-foreground") || classes.contains("text-tab-active-foreground")
        return Strip.Tab(title: title, truncated: truncated, active: active)
    }

}
