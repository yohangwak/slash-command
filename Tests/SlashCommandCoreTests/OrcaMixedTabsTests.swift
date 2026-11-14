import XCTest
@testable import SlashCommandCore

/// Workspaces with browser or file tabs open: Orca's `session.tabs.list` says which strip positions are terminals (Orca 1.4.258, 2026-11-14).
final class OrcaMixedTabsTests: XCTestCase {
    private let worktree = "465122ea-b2af::/Users/yohan/orca/workspaces/Hyva_K-MYTHIC/preorder"
    private let terminalTitle = "<pasted_content id=\"a17e\"> K-Mythic · PREORDER ALERTS A new set. A heads-up when preorders op..."

    /// The shape measured for that workspace: a terminal tab and a browser tab in one tab group.
    private func session(order: [String] = ["term-1", "browser-1"], extraTabs: [[String: Any]] = [],
                         groups: Int = 1, layout: String = "leaf") -> [String: Any] {
        var tabs: [[String: Any]] = [
            ["type": "terminal", "id": "term-1::leaf-a", "parentTabId": "term-1", "leafId": "leaf-a", "title": "✅ preorder"],
            ["type": "browser", "id": "browser-1", "title": "Login - Brevo", "url": "https://login.brevo.com/"],
        ]
        tabs += extraTabs
        let group: [String: Any] = ["id": "g1", "activeTabId": order.first ?? "", "tabOrder": order]
        return ["tabGroups": Array(repeating: group, count: groups), "tabGroupLayout": ["type": layout, "groupId": "g1"], "tabs": tabs,
                "activeGroupId": "g1", "worktree": worktree]
    }

    /// The session list read, for a shape that must be understood.
    private func listed(_ session: [String: Any]) -> OrcaView.SessionTabs {
        OrcaView.sessionTabs(session: session)!
    }

    private func layouts(_ titles: [(String, String)]) -> [[String: Any]] {
        [["worktreeId": worktree, "root": ["tabs": titles.map { ["tabId": $0.0, "title": $0.1] }]],
         ["worktreeId": "other", "root": ["tabs": [["tabId": "o-1", "title": terminalTitle]]]]]
    }

    /// A terminal tab on screen (its close button names its title) and a browser tab (its close button names nothing).
    private enum Shown { case terminal(String, active: Bool), other(String, active: Bool) }

    private func strip(_ tabs: [Shown], current: [String]? = nil, groups: [OrcaView.Strip.Group] = []) -> OrcaView.Strip {
        .init(tabs: tabs.map {
            switch $0 {
            case .terminal(let title, let active): return .init(title: title, truncated: false, active: active)
            case .other(let title, let active): return .init(title: title, truncated: false, active: active, closeNamesTitle: false)
            }
        }, currentWorkspaces: current ?? [worktree], groups: groups)
    }

    /// Group frames on screen: their tab counts, and which one shows focus.
    private func frames(_ counts: [Int], focused: Int?) -> [OrcaView.Strip.Group] {
        counts.enumerated().map { item in .init(tabs: item.element, focused: focused.map { item.offset == $0 }) }
    }

    private func one(_ kinds: [OrcaView.TabKind], active: Int = 0) -> OrcaView.SessionTabs {
        .init(groups: [.init(kinds: kinds, active: active)], focused: 0)
    }

    func testReadsKindsInStripOrder() {
        XCTAssertEqual(OrcaView.sessionTabs(session: session()), one([.terminal(tabID: "term-1"), .other]))
        XCTAssertEqual(OrcaView.sessionTabs(session: session(order: ["browser-1", "term-1"])), one([.other, .terminal(tabID: "term-1")]))
        // A split terminal tab is listed once per pane; it is still one tab in the strip.
        let split = session(extraTabs: [["type": "terminal", "id": "term-1::leaf-b", "parentTabId": "term-1"]])
        XCTAssertEqual(OrcaView.sessionTabs(session: split), one([.terminal(tabID: "term-1"), .other]))
        // An id its tabs do not describe (a chat tab) is counted as a tab that is not a terminal.
        XCTAssertEqual(OrcaView.sessionTabs(session: session(order: ["term-1", "browser-1", "chat"])), one([.terminal(tabID: "term-1"), .other, .unlisted]))
        // Without a layout, one group is still understood.
        var bare = session(); bare["tabGroupLayout"] = nil
        XCTAssertEqual(OrcaView.sessionTabs(session: bare), one([.terminal(tabID: "term-1"), .other]))
    }

    func testKindsAreUnknownWhenTheListIsNotUnderstood() {
        XCTAssertNil(OrcaView.sessionTabs(session: session(order: [])), "No order")
        XCTAssertNil(OrcaView.sessionTabs(session: session(order: ["term-1", "term-1"])), "An id twice")
        XCTAssertNil(OrcaView.sessionTabs(session: session(groups: 0)), "No tab group (measured: a remote workspace with only a file tab)")
        XCTAssertNil(OrcaView.sessionTabs(session: session(groups: 2)), "Two groups with one id")
        XCTAssertNil(OrcaView.sessionTabs(session: session(layout: "split")), "A split without its halves")
        XCTAssertNil(OrcaView.sessionTabs(session: [:]))
        var noActive = session(); noActive["tabGroups"] = [["id": "g1", "activeTabId": NSNull(), "tabOrder": ["term-1", "browser-1"]]]
        XCTAssertNil(OrcaView.sessionTabs(session: noActive), "A group without an active tab")
        var noFocus = session(); noFocus["activeGroupId"] = "gone"
        XCTAssertNil(OrcaView.sessionTabs(session: noFocus), "A focused group it does not list")
        var otherTop = session(); otherTop["activeTabId"] = "browser-1"
        XCTAssertNil(OrcaView.sessionTabs(session: otherTop), "The workspace's active tab is not the focused group's")
        var topTerminal = session(); topTerminal["activeTabId"] = "term-1::leaf-a"
        XCTAssertNotNil(OrcaView.sessionTabs(session: topTerminal), "Positive control: a terminal is named tabId::leafId")
        var oddTerminal = session(extraTabs: [["type": "terminal", "id": "term-9"]]); oddTerminal["tabGroups"] = [["id": "g1", "activeTabId": "term-1", "tabOrder": ["term-1", "browser-1", "term-9"]]]
        XCTAssertNil(OrcaView.sessionTabs(session: oddTerminal), "A terminal listed under its own id")
    }

    /// The case reported on 2026-11-13: the terminal is visible next to a browser tab whose close button names nothing (its title is unread).
    func testATerminalNextToABrowserTabResolves() {
        let kinds = listed(session())
        let shown = strip([.terminal(terminalTitle, active: true), .other("", active: false)])
        XCTAssertEqual(OrcaView.resolve(strip: shown, layouts: layouts([("term-1", terminalTitle)]), session: kinds),
                       .tab(.init(worktreeID: worktree, tabID: "term-1")))
        // Without the session list the same strip is refused, as before.
        XCTAssertEqual(OrcaView.resolve(strip: shown, layouts: layouts([("term-1", terminalTitle)])), .noMatch)
    }

    func testTheBrowserTabInFrontIsNotATerminal() {
        var browserInFront = session()
        browserInFront["tabGroups"] = [["id": "g1", "activeTabId": "browser-1", "tabOrder": ["term-1", "browser-1"]]]
        let kinds = listed(browserInFront)
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal(terminalTitle, active: false), .other("Login - Brevo", active: true)]), layouts: layouts([("term-1", terminalTitle)]), session: kinds),
                       .notATerminal)
    }

    func testStaysExact() {
        let kinds = listed(session())
        let layout = layouts([("term-1", terminalTitle)])
        // A tab more or fewer on screen than the list has.
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal(terminalTitle, active: true)]), layouts: layout, session: kinds), .noMatch)
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal(terminalTitle, active: true), .other("", active: false), .other("x", active: false)]), layouts: layout, session: kinds), .noMatch)
        // The terminal's place shows another title (the list is out of date, or the order differs).
        XCTAssertEqual(OrcaView.resolve(strip: strip([.other("Login - Brevo", active: true), .terminal(terminalTitle, active: false)]), layouts: layout, session: kinds), .noMatch)
        // An unreadable tab at a terminal's place never matches.
        XCTAssertEqual(OrcaView.resolve(strip: strip([.other("", active: true), .other("", active: false)]), layouts: layout, session: kinds), .noMatch)
        // The terminal list has a terminal the session list does not (or the other way round).
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal(terminalTitle, active: true), .other("", active: false)]),
                                        layouts: layouts([("term-1", terminalTitle), ("term-2", "Terminal 2")]), session: kinds), .noMatch)
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal(terminalTitle, active: true), .other("", active: false)]), layouts: layouts([("term-9", terminalTitle)]), session: kinds), .noMatch)
        // Only the workspace the sidebar shows is compared; without it nothing is matched.
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal(terminalTitle, active: true), .other("", active: false)], current: ["other"]), layouts: layout, session: kinds), .noMatch)
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal(terminalTitle, active: true), .other("", active: false)], current: []), layouts: layout, session: kinds), .noMatch)
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal(terminalTitle, active: false), .other("", active: false)]), layouts: layout, session: kinds), .noActiveTab)
    }

    func testTwoTerminalsAroundABrowserTab() {
        let session: [String: Any] = [
            "tabGroups": [["id": "g", "activeTabId": "t2", "tabOrder": ["t1", "b", "t2"]]], "tabGroupLayout": ["type": "leaf", "groupId": "g"], "activeGroupId": "g",
            "tabs": [["type": "terminal", "id": "t1::a", "parentTabId": "t1"], ["type": "browser", "id": "b"],
                     ["type": "terminal", "id": "t2::a", "parentTabId": "t2"]],
        ]
        let kinds = listed(session)
        let layout = layouts([("t1", "Terminal 1"), ("t2", "Terminal 2")])
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal("Terminal 1", active: false), .other("", active: false), .terminal("Terminal 2", active: true)]), layouts: layout, session: kinds),
                       .tab(.init(worktreeID: worktree, tabID: "t2")))
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal("Terminal 2", active: false), .other("", active: false), .terminal("Terminal 1", active: true)]), layouts: layout, session: kinds),
                       .noMatch, "Swapped titles")
    }

    /// Pullfrog #60: the strip and the list are read one after the other. If a browser tab with the terminal's title moves to the
    /// terminal's place in between and is in front, the title alone would pass; its shape on the screen does not.
    func testABrowserTabWithTheTerminalsTitleAtTheTerminalsPlaceIsRefused() {
        let kinds = listed(session())          // the list still says: terminal, then browser
        let layout = layouts([("term-1", terminalTitle)])
        let moved = strip([.other(terminalTitle, active: true), .terminal(terminalTitle, active: false)])
        XCTAssertEqual(OrcaView.resolve(strip: moved, layouts: layout, session: kinds), .noMatch)
        // …and a terminal-shaped tab where the list has a browser tab is refused too.
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal(terminalTitle, active: true), .terminal("Login - Brevo", active: false)]),
                                        layouts: layout, session: kinds), .noMatch)
        // Positive control: each tab's shape at its place resolves.
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal(terminalTitle, active: true), .other("Login - Brevo", active: false)]),
                                        layouts: layout, session: kinds), .tab(.init(worktreeID: worktree, tabID: "term-1")))
    }

    /// Pullfrog #60: a file named `tab` has a close button "Close tab" that names it, so it looks like a terminal. If it shares a
    /// terminal's title and the two swap places between the two reads, the title must not be enough.
    func testAFileThatLooksLikeATerminalAtItsPlaceIsRefused() {
        let session: [String: Any] = [
            "tabGroups": [["id": "g", "activeTabId": "t1", "tabOrder": ["t1", "f"]]], "tabGroupLayout": ["type": "leaf", "groupId": "g"], "activeGroupId": "g",
            "tabs": [["type": "terminal", "id": "t1::a", "parentTabId": "t1"], ["type": "file", "id": "f"]],
        ]
        let kinds = listed(session)
        let layout = layouts([("t1", "tab")])
        let file = OrcaView.tab(classes: ["bg-tab-active", "text-tab-active-foreground"], texts: ["tab"], buttonLabels: ["Close tab"], label: "")!
        XCTAssertTrue(file.closeNamesTitle, "The file tab looks like a terminal")
        // Swapped between the reads: the file is in front at the terminal's place, the terminal at the file's.
        let swapped = OrcaView.Strip(tabs: [file, .init(title: "tab", truncated: false, active: false, closeNamesTitle: true)], currentWorkspaces: [worktree])
        XCTAssertEqual(OrcaView.resolve(strip: swapped, layouts: layout, session: kinds), .noMatch)
        // Any other tab sharing the terminal's title refuses, even in the right order.
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal("tab", active: true), .other("tab", active: false)]), layouts: layout, session: kinds), .noMatch)
        // Positive control: a distinct title resolves.
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal("tab", active: true), .other("README.md", active: false)]), layouts: layout, session: kinds),
                       .tab(.init(worktreeID: worktree, tabID: "t1")))
    }

    // MARK: Tabs split into groups side by side (Orca marks the active tab of every group; one strip per group, `first` before `second`)

    private let t1: [String: Any] = ["type": "terminal", "id": "t1::a", "parentTabId": "t1"]
    private let t2: [String: Any] = ["type": "terminal", "id": "t2::a", "parentTabId": "t2"]
    private let t3: [String: Any] = ["type": "terminal", "id": "t3::a", "parentTabId": "t3"]
    private let b: [String: Any] = ["type": "browser", "id": "b", "title": "Docs"]

    /// Groups as Orca lists them (not in drawing order) and the layout that orders them.
    private func split(_ groups: [(id: String, order: [String], active: String)], layout: [String: Any], focused: String,
                       tabs: [[String: Any]]? = nil) -> [String: Any] {
        ["tabGroups": groups.map { ["id": $0.id, "activeTabId": $0.active, "tabOrder": $0.order] },
         "tabGroupLayout": layout, "activeGroupId": focused, "tabs": tabs ?? [t1, t2, t3, b], "worktree": worktree]
    }

    private func leaf(_ id: String) -> [String: Any] { ["type": "leaf", "groupId": id] }
    private func pair(_ first: [String: Any], _ second: [String: Any], _ direction: String = "horizontal") -> [String: Any] {
        ["type": "split", "direction": direction, "first": first, "second": second]
    }

    private var threeTerminals: [[String: Any]] { layouts([("t1", "Terminal 1"), ("t2", "Terminal 2"), ("t3", "Terminal 3")]) }

    /// The likely shape behind 2026-11-13 23:30 («could not tell which Orca tab»): two groups, so two active marks.
    func testTwoGroupsSideBySideResolveToTheFocusedGroup() {
        let tabs: [Shown] = [.terminal("Terminal 1", active: true), .other("Docs", active: false), .terminal("Terminal 2", active: true), .terminal("Terminal 3", active: false)]
        let rightFocused = strip(tabs, groups: frames([2, 2], focused: 1))
        XCTAssertEqual(OrcaView.resolve(strip: rightFocused, layouts: threeTerminals), .noActiveTab, "Without the session list: two marks")
        // Listed second-group-first; the layout says which strip is drawn first.
        let groups = [(id: "g2", order: ["t2", "t3"], active: "t2"), (id: "g1", order: ["t1", "b"], active: "t1")]
        let right = OrcaView.sessionTabs(session: split(groups, layout: pair(leaf("g1"), leaf("g2")), focused: "g2"))!
        XCTAssertEqual(OrcaView.resolve(strip: rightFocused, layouts: threeTerminals, session: right), .tab(.init(worktreeID: worktree, tabID: "t2")))
        let left = OrcaView.sessionTabs(session: split(groups, layout: pair(leaf("g1"), leaf("g2")), focused: "g1"))!
        let leftFocused = strip(tabs, groups: frames([2, 2], focused: 0))
        XCTAssertEqual(OrcaView.resolve(strip: leftFocused, layouts: threeTerminals, session: left), .tab(.init(worktreeID: worktree, tabID: "t1")))
        // Pullfrog #61: the list names one group, the screen shows the other focused (the list is a moment behind) — refused.
        XCTAssertEqual(OrcaView.resolve(strip: rightFocused, layouts: threeTerminals, session: left), .noMatch)
        XCTAssertEqual(OrcaView.resolve(strip: leftFocused, layouts: threeTerminals, session: right), .noMatch)
        // Focus not readable on screen (no frames, no mark, two marks) — refused.
        XCTAssertEqual(OrcaView.resolve(strip: strip(tabs), layouts: threeTerminals, session: right), .noMatch)
        XCTAssertEqual(OrcaView.resolve(strip: strip(tabs, groups: [.init(tabs: 2, focused: false), .init(tabs: 2, focused: nil)]), layouts: threeTerminals, session: right), .noMatch)
        XCTAssertEqual(OrcaView.resolve(strip: strip(tabs, groups: frames([2, 2], focused: nil)), layouts: threeTerminals, session: right), .noMatch)
        XCTAssertEqual(OrcaView.resolve(strip: strip(tabs, groups: [.init(tabs: 2, focused: true), .init(tabs: 2, focused: true)]), layouts: threeTerminals, session: right), .noMatch)
        // Frames that split the tabs differently from the list — refused.
        XCTAssertEqual(OrcaView.resolve(strip: strip(tabs, groups: frames([1, 3], focused: 1)), layouts: threeTerminals, session: right), .noMatch)
        // An empty frame (a group drawn without tabs) is ignored.
        XCTAssertEqual(OrcaView.resolve(strip: strip(tabs, groups: [.init(tabs: 0, focused: nil)] + frames([2, 2], focused: 1)), layouts: threeTerminals, session: right),
                       .tab(.init(worktreeID: worktree, tabID: "t2")))
        // The layout drawn the other way round does not line up with this strip.
        let flipped = OrcaView.sessionTabs(session: split(groups, layout: pair(leaf("g2"), leaf("g1")), focused: "g2"))!
        XCTAssertEqual(OrcaView.resolve(strip: strip(tabs, groups: frames([2, 2], focused: 0)), layouts: threeTerminals, session: flipped), .noMatch)
    }

    func testNestedSplitsAreDrawnFirstToSecond() {
        let groups = [(id: "g1", order: ["t1"], active: "t1"), (id: "g2", order: ["t2"], active: "t2"), (id: "g3", order: ["t3", "b"], active: "t3")]
        let session = split(groups, layout: pair(leaf("g3"), pair(leaf("g1"), leaf("g2")), "vertical"), focused: "g1")
        let tabs = OrcaView.sessionTabs(session: session)!
        XCTAssertEqual(tabs.groups.map(\.kinds.count), [2, 1, 1])
        XCTAssertEqual(tabs.focused, 1)
        let shown = strip([.terminal("Terminal 3", active: true), .other("Docs", active: false), .terminal("Terminal 1", active: true), .terminal("Terminal 2", active: true)],
                          groups: frames([2, 1, 1], focused: 1))
        XCTAssertEqual(OrcaView.resolve(strip: shown, layouts: threeTerminals, session: tabs), .tab(.init(worktreeID: worktree, tabID: "t1")))
    }

    func testALayoutThatDoesNotNameEachGroupOnceIsNotUnderstood() {
        let groups = [(id: "g1", order: ["t1"], active: "t1"), (id: "g2", order: ["t2"], active: "t2")]
        XCTAssertNil(OrcaView.sessionTabs(session: split(groups, layout: pair(leaf("g1"), leaf("g1")), focused: "g1")), "A group twice")
        XCTAssertNil(OrcaView.sessionTabs(session: split(groups, layout: leaf("g1"), focused: "g1")), "A group missing")
        XCTAssertNil(OrcaView.sessionTabs(session: split(groups, layout: pair(leaf("g1"), leaf("g9")), focused: "g1")), "A group it does not list")
        XCTAssertNil(OrcaView.sessionTabs(session: split(groups, layout: ["type": "split", "first": leaf("g1")], focused: "g1")), "A half missing")
        var noLayout = split(groups, layout: [:], focused: "g1"); noLayout["tabGroupLayout"] = nil
        XCTAssertNil(OrcaView.sessionTabs(session: noLayout), "Two groups and no layout")
    }

    /// Every group's active mark must be where the list has it: a tab chosen between the two reads moves a mark and is refused.
    func testActiveMarksMustBeWhereTheListHasThem() {
        let groups = [(id: "g1", order: ["t1", "b"], active: "t1"), (id: "g2", order: ["t2", "t3"], active: "t2")]
        let tabs = OrcaView.sessionTabs(session: split(groups, layout: pair(leaf("g1"), leaf("g2")), focused: "g2"))!
        let moved = strip([.terminal("Terminal 1", active: true), .other("Docs", active: false), .terminal("Terminal 2", active: false), .terminal("Terminal 3", active: true)], groups: frames([2, 2], focused: 1))
        XCTAssertEqual(OrcaView.resolve(strip: moved, layouts: threeTerminals, session: tabs), .noMatch, "Another tab chosen in the focused group")
        let otherGroup = strip([.terminal("Terminal 1", active: false), .other("Docs", active: true), .terminal("Terminal 2", active: true), .terminal("Terminal 3", active: false)], groups: frames([2, 2], focused: 1))
        XCTAssertEqual(OrcaView.resolve(strip: otherGroup, layouts: threeTerminals, session: tabs), .noMatch, "Another tab chosen in the other group")
        let oneMark = strip([.terminal("Terminal 1", active: false), .other("Docs", active: false), .terminal("Terminal 2", active: true), .terminal("Terminal 3", active: false)], groups: frames([2, 2], focused: 1))
        XCTAssertEqual(OrcaView.resolve(strip: oneMark, layouts: threeTerminals, session: tabs), .noMatch, "A group without its mark")
        let none = strip([.terminal("Terminal 1", active: false), .other("Docs", active: false), .terminal("Terminal 2", active: false), .terminal("Terminal 3", active: false)])
        XCTAssertEqual(OrcaView.resolve(strip: none, layouts: threeTerminals, session: tabs), .noActiveTab)
    }

    func testTheFocusedGroupShowingABrowserTabIsNotATerminal() {
        let groups = [(id: "g1", order: ["t1", "b"], active: "b"), (id: "g2", order: ["t2", "t3"], active: "t2")]
        let tabs = OrcaView.sessionTabs(session: split(groups, layout: pair(leaf("g1"), leaf("g2")), focused: "g1"))!
        let shown = strip([.terminal("Terminal 1", active: false), .other("Docs", active: true), .terminal("Terminal 2", active: true), .terminal("Terminal 3", active: false)],
                          groups: frames([2, 2], focused: 0))
        XCTAssertEqual(OrcaView.resolve(strip: shown, layouts: threeTerminals, session: tabs), .notATerminal)
    }

    /// Two terminals with the same title next to a browser tab: the list may lag the screen, so a swap between them would be unseen.
    func testTerminalsSharingATitleAreRefused() {
        let session: [String: Any] = [
            "tabGroups": [["id": "g", "activeTabId": "t2", "tabOrder": ["t1", "b", "t2"]]], "tabGroupLayout": leaf("g"), "activeGroupId": "g",
            "tabs": [t1, b, t2], "worktree": worktree,
        ]
        let tabs = OrcaView.sessionTabs(session: session)!
        let same = layouts([("t1", "claude"), ("t2", "claude")])
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal("claude", active: false), .other("Docs", active: false), .terminal("claude", active: true)]), layouts: same, session: tabs),
                       .noMatch)
        // Positive control: distinct titles resolve.
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal("claude", active: false), .other("Docs", active: false), .terminal("codex", active: true)]),
                                        layouts: layouts([("t1", "claude"), ("t2", "codex")]), session: tabs), .tab(.init(worktreeID: worktree, tabID: "t2")))
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal("claude", active: true), .other("Docs", active: false), .terminal("claude", active: false)]), layouts: same, session: tabs),
                       .noMatch)
    }

    /// A chat tab is in the tab order but not among the listed tabs; it looks like a terminal on screen and is never one.
    func testAChatTabIsCountedAndNeverChosen() {
        let session: [String: Any] = [
            "tabGroups": [["id": "g", "activeTabId": "t1", "tabOrder": ["chat", "t1"]]], "tabGroupLayout": leaf("g"), "activeGroupId": "g",
            "tabs": [t1], "worktree": worktree,
        ]
        let layout = layouts([("t1", "Terminal 1")])
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal("Ask", active: false), .terminal("Terminal 1", active: true)]), layouts: layout, session: listed(session)),
                       .tab(.init(worktreeID: worktree, tabID: "t1")))
        var chatInFront = session; chatInFront["tabGroups"] = [["id": "g", "activeTabId": "chat", "tabOrder": ["chat", "t1"]]]
        XCTAssertEqual(OrcaView.resolve(strip: strip([.terminal("Ask", active: true), .terminal("Terminal 1", active: false)]), layouts: layout, session: listed(chatInFront)),
                       .notATerminal)
    }

    /// Pullfrog #61: a chat tab and a terminal with the same title, swapped and chosen between the two reads.
    func testAChatTabSharingATerminalsTitleIsRefused() {
        let session: [String: Any] = [
            "tabGroups": [["id": "g", "activeTabId": "t1", "tabOrder": ["t1", "chat"]]], "tabGroupLayout": leaf("g"), "activeGroupId": "g",
            "tabs": [t1], "worktree": worktree,
        ]
        let seen = strip([.terminal("Ask", active: true), .terminal("Ask", active: false)])   // the chat in front, then the terminal
        XCTAssertEqual(OrcaView.resolve(strip: seen, layouts: layouts([("t1", "Ask")]), session: listed(session)), .noMatch)
    }

    /// A file tab's close button says only "Close tab" in Orca's language: it is read as a tab that is not a terminal.
    func testAFileTabNextToATerminal() {
        let session: [String: Any] = [
            "tabGroups": [["id": "g", "activeTabId": "t1", "tabOrder": ["t1", "editor:x"]]], "tabGroupLayout": leaf("g"), "activeGroupId": "g",
            "activeTabId": "t1::a", "tabs": [t1, ["type": "file", "id": "editor:x", "title": "README.md"]], "worktree": worktree,
        ]
        let file = OrcaView.tab(classes: ["bg-tab-inactive", "text-tab-inactive-foreground"], texts: ["README.md"], buttonLabels: ["탭 닫기"], label: "")!
        XCTAssertFalse(file.closeNamesTitle)
        let terminal = OrcaView.tab(classes: ["bg-tab-active", "text-tab-active-foreground"], texts: ["Terminal 1"], buttonLabels: ["탭 닫기 Terminal 1"], label: "")!
        let shown = OrcaView.Strip(tabs: [terminal, file], currentWorkspaces: [worktree])
        XCTAssertEqual(OrcaView.resolve(strip: shown, layouts: layouts([("t1", "Terminal 1")]), session: listed(session)),
                       .tab(.init(worktreeID: worktree, tabID: "t1")))
    }
}
