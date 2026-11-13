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
            /// True when a close button inside the tab names its title, as on a terminal tab. A browser tab's close button has no
            /// label and a file tab's says only "Close tab", so this tells a terminal tab from the others on the screen itself.
            public let closeNamesTitle: Bool

            public init(title: String, truncated: Bool, active: Bool, closeNamesTitle: Bool = true) {
                self.title = title
                self.truncated = truncated
                self.active = active
                self.closeNamesTitle = closeNamesTitle
            }
        }

        public let tabs: [Tab]
        /// Worktree ids of the sidebar rows marked as the current page (`aria-current="page"`). One when the sidebar shows the visible
        /// workspace; none when the sidebar is hidden or that row is scrolled out of the list.
        public let currentWorkspaces: [String]

        public init(tabs: [Tab], currentWorkspaces: [String] = []) {
            self.tabs = tabs
            self.currentWorkspaces = currentWorkspaces
        }
    }

    public enum Resolution: Equatable, Sendable {
        /// The strip has zero or more than one active marker.
        case noActiveTab
        case tab(OrcaState.Active)
        /// More than one workspace has the same order of tab titles.
        case ambiguous([String])
        /// No workspace has exactly these tabs (the strip may also hold file, browser or chat tabs, which the terminal list does not have).
        case noMatch
        /// The strip matches the visible workspace's tabs, and the visible tab is not a terminal (a browser or file tab).
        case notATerminal
    }

    /// One tab of a workspace, in strip order, as Orca's session list names it.
    public enum TabKind: Equatable, Sendable {
        case terminal(tabID: String)
        /// A browser, file or chat tab.
        case other
    }

    /// The tabs of a workspace in strip order, from Orca's `session.tabs.list` (measured on Orca 1.4.258, 2026-11-14): one tab group whose
    /// `tabOrder` lists the tab ids; a browser or file tab is listed under its own id, a terminal once per split pane with `parentTabId`
    /// set to the tab id. nil when the answer is not that shape — no tab group or more than one (a split), or an id it does not list —
    /// and then nothing is known about kinds.
    public static func tabKinds(session: [String: Any]) -> [TabKind]? {
        guard let groups = session["tabGroups"] as? [[String: Any]], groups.count == 1,
              (session["tabGroupLayout"] as? [String: Any])?["type"] as? String ?? "leaf" == "leaf",
              let order = groups[0]["tabOrder"] as? [String], !order.isEmpty,
              let tabs = session["tabs"] as? [[String: Any]] else { return nil }
        var kinds: [TabKind] = []
        for id in order {
            if tabs.contains(where: { $0["type"] as? String == "terminal" && $0["parentTabId"] as? String == id }) {
                kinds.append(.terminal(tabID: id))
            } else if let tab = tabs.first(where: { $0["id"] as? String == id }), let type = tab["type"] as? String,
                      !type.isEmpty, type != "terminal" {
                kinds.append(.other)
            } else {
                return nil
            }
        }
        return kinds
    }

    /// Matches the strip of the workspace the sidebar shows against that workspace's tabs in Orca's session list, so a workspace with
    /// browser or file tabs open can be read too. Exact as before: the strip has as many tabs as the list, every terminal is at its place
    /// with its title (the terminal list's), and the list has every terminal the terminal list has. Tabs that are not terminals are counted and must
    /// not look like a terminal tab; their titles are page titles or addresses that the terminal list does not have.
    public static func resolve(strip: Strip, layouts: [[String: Any]], kinds: [TabKind]) -> Resolution {
        let activeIndices = strip.tabs.indices.filter { strip.tabs[$0].active }
        guard activeIndices.count == 1, let activeIndex = activeIndices.first else { return .noActiveTab }
        guard strip.currentWorkspaces.count == 1, let visible = strip.currentWorkspaces.first,
              let layout = layouts.first(where: { $0["worktreeId"] as? String == visible }),
              kinds.count == strip.tabs.count else { return .noMatch }
        let terminals = OrcaState.tabs(in: layout["root"])
        let listed = kinds.compactMap { kind -> String? in if case .terminal(let id) = kind { return id } else { return nil } }
        guard listed.count == terminals.count, Set(listed).count == listed.count else { return .noMatch }
        // The strip and the list are read one after the other, so a tab can move in between (Pullfrog #60). Two checks keep a moved tab
        // from passing for a terminal: each place must look like its kind on the screen (a terminal's close button names its title; a
        // browser tab's names nothing, a file tab's says only "Close tab"), and no other tab in the strip may match a terminal's title.
        // With every terminal's title unique in the strip, a terminal that moved leaves a tab with another title at its place.
        // A file tab whose name is a word of its close button ("tab") looks like a terminal; the second check refuses it when it shares
        // a terminal's title.
        for (index, (kind, shown)) in zip(kinds, strip.tabs).enumerated() {
            guard case .terminal(let id) = kind else {
                guard !shown.closeNamesTitle else { return .noMatch }
                continue
            }
            guard shown.closeNamesTitle, let terminal = terminals.first(where: { $0["tabId"] as? String == id }),
                  case let title = terminal["title"] as? String ?? "", titlesMatch(title, shown),
                  !strip.tabs.indices.contains(where: { $0 != index && titlesMatch(title, strip.tabs[$0]) }) else { return .noMatch }
        }
        guard case .terminal(let id) = kinds[activeIndex] else { return .notATerminal }
        return .tab(OrcaState.Active(worktreeID: visible, tabID: id))
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
        // A title with no letters or digits proves nothing, and an unreadable tab has an empty title: neither matches anything, even another
        // empty or missing title (Pullfrog #57).
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        // Long titles are cut off on screen. If it comes with an ellipsis (`...`) it is enough to match the part before it; and in the 2026-10-07 measurement some titles come with only the leading part, with no ellipsis
        // (a 96-character title came through only up to "...HANDOFF 2026 10 06"). In that case a prefix match is accepted only for 12 or more characters —
        // so that short titles (`initial` vs `initial 2`) do not get mixed up. In any case the tab count and "all" tab titles must match together.
        guard !b.isEmpty, a.hasPrefix(b) else { return false }
        return shown.truncated || b.count >= 12
    }

    /// Matches the tab strip against the layout (`visualLayouts` of `terminal.list`). Both the tab count and the order of titles must be the same.
    /// When the strip names the visible workspace (from the sidebar), only that workspace's layout is compared: titles alone cannot prove
    /// that a workspace is visible — a visible `Terminal 1` + file tab `README.md` also matches a hidden workspace with two terminals of those titles.
    ///
    /// Exact, not "the terminal tabs appear somewhere in the strip": the strip does not say which of its tabs are terminals, so a looser match
    /// lets a hidden workspace with fewer tabs (a lone "Terminal 1") stand in for the visible one, or a file tab with a terminal's title
    /// stand in for that terminal — and a hidden terminal has an input box too. If there is more than one candidate it is "ambiguous".
    public static func resolve(strip: Strip, layouts: [[String: Any]]) -> Resolution {
        let activeIndices = strip.tabs.indices.filter { strip.tabs[$0].active }
        guard activeIndices.count == 1, let activeIndex = activeIndices.first else { return .noActiveTab }
        let visible = strip.currentWorkspaces.count == 1 ? strip.currentWorkspaces.first : nil
        var candidates: [(worktree: String, tabID: String)] = []
        for layout in layouts {
            guard let worktree = layout["worktreeId"] as? String, visible == nil || worktree == visible else { continue }
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
        strip(from: roots, seen: seen, maxDepth: maxDepth, maxNodes: maxNodes,
              tab: { tab(fromLabel: label($0), classes: classes($0)) },
              currentWorkspace: { _ in nil }, children: children)?.tabs
    }

    /// The same walk, also collecting the sidebar rows marked as the current page (`currentWorkspace` returns their worktree id).
    /// `tab` returns the tab an element is, or nil if it is not a tab button.
    static func strip<N: Hashable>(from roots: [N], seen: Set<N> = [], maxDepth: Int = 150, maxNodes: Int = 30_000,
                                   tab: (N) -> Strip.Tab?, currentWorkspace: (N) -> String?,
                                   children: (N) -> [N]) -> Strip? {
        var seen = seen
        var tabs: [Strip.Tab] = []
        var workspaces: [String] = []
        var cut = false
        func visit(_ node: N, depth: Int) {
            guard !cut, seen.insert(node).inserted else { return }
            guard depth <= maxDepth, seen.count <= maxNodes else { cut = true; return }
            if let tab = tab(node) {
                tabs.append(tab)
                return
            }
            if let workspace = currentWorkspace(node) { workspaces.append(workspace) }
            for child in children(node) { visit(child, depth: depth + 1) }
        }
        for root in roots { visit(root, depth: 0) }
        return cut ? nil : Strip(tabs: tabs, currentWorkspaces: workspaces)
    }

    /// A sidebar row's DOM id is `worktree-list-option-<project>:<host>|<worktree id>` (percent-encoded; measured on Orca 1.4.256).
    /// Returns the worktree id when the row is the current page.
    static func currentWorkspace(domID: String?, ariaCurrent: String?) -> String? {
        guard ariaCurrent == "page", let raw = domID, let id = raw.removingPercentEncoding,
              id.hasPrefix("worktree-list-option-"), let bar = id.lastIndex(of: "|") else { return nil }
        let worktree = String(id[id.index(after: bar)...])
        return worktree.isEmpty ? nil : worktree
    }

    /// A tab button of the form `"<state> <title> Close tab <title>"`. The title is the part after "Close tab ".
    /// Only English Orca labels its tabs this way; `tab(classes:texts:buttonLabels:)` reads a tab in any language.
    static func tab(fromLabel label: String, classes: [String]) -> Strip.Tab? {
        guard let range = label.range(of: "Close tab ", options: .backwards) else { return nil }
        let (title, truncated) = withoutEllipsis(String(label[range.upperBound...]))
        return Strip.Tab(title: title, truncated: truncated, active: isActive(classes))
    }

    /// The class names Orca 1.4.256 and later put on every tab button: `bg-tab-active` on the visible tab, `bg-tab-inactive` on the others.
    static let tabClasses: Set<String> = ["bg-tab-active", "bg-tab-inactive"]

    /// A tab button read from its parts, in any interface language.
    ///
    /// Orca 1.4.257 translates its interface, and the close button's label with it, with the title in a different place per language
    /// (measured 2026-11-13 in its catalogs: ko `탭 닫기 <title>`, de `Tab <title> schließen`, ja `タブ <title> を閉じる`, tr `<title> sekmesini kapat`).
    /// So nothing here looks for words. An element is a tab when it has Orca's tab class, and its title is a text of its own that a button
    /// inside it (the close button) also names, as a whole run of words. Orca shows the title without its leading status marks (`✳`, spinners),
    /// which comparison ignores anyway (`normalized`).
    /// - Parameters:
    ///   - texts: the texts directly inside the element (`AXStaticText` values).
    ///   - buttonLabels: the labels of the buttons directly inside it.
    static func tab(classes: [String], texts: [String], buttonLabels: [String]) -> Strip.Tab? {
        guard !tabClasses.isDisjoint(with: classes) else { return nil }
        let labels = buttonLabels.map { " \(normalized($0)) " }
        let named = texts.map(withoutEllipsis).filter { text in
            let words = normalized(text.title)
            return !words.isEmpty && labels.contains { $0.contains(" \(words) ") }
        }
        // A status text could also be named by the button if the title contains it; the title is the longest.
        guard let title = named.max(by: { $0.title.count < $1.title.count }) else { return nil }
        return Strip.Tab(title: title.title, truncated: title.truncated, active: isActive(classes))
    }

    /// The tab an element is, or nil if it is not a tab. An element with Orca's tab class is always a tab: read from its parts, else from
    /// its English label, else as a tab with no title. That tab is counted and matches no terminal, so the strip cannot match without it
    /// (a pinned tab has no close button; a file tab's close button names no title). Leaving it out could let the other tabs match a
    /// workspace and pick a hidden terminal.
    static func tab(classes: [String], texts: [String], buttonLabels: [String], label: String) -> Strip.Tab? {
        guard !tabClasses.isDisjoint(with: classes) else { return tab(fromLabel: label, classes: classes) }
        return tab(classes: classes, texts: texts, buttonLabels: buttonLabels)
            ?? tab(fromLabel: label, classes: classes)
            ?? Strip.Tab(title: "", truncated: false, active: isActive(classes), closeNamesTitle: false)
    }

    private static func isActive(_ classes: [String]) -> Bool {
        classes.contains("text-foreground") || classes.contains("text-tab-active-foreground")
    }

    private static func withoutEllipsis(_ text: String) -> (title: String, truncated: Bool) {
        for ellipsis in ["...", "…"] where text.hasSuffix(ellipsis) {
            return (String(text.dropLast(ellipsis.count)), true)
        }
        return (text, false)
    }

}
