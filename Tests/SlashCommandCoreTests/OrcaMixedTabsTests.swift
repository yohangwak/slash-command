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
                "worktree": worktree]
    }

    private func layouts(_ titles: [(String, String)]) -> [[String: Any]] {
        [["worktreeId": worktree, "root": ["tabs": titles.map { ["tabId": $0.0, "title": $0.1] }]],
         ["worktreeId": "other", "root": ["tabs": [["tabId": "o-1", "title": terminalTitle]]]]]
    }

    private func strip(_ tabs: [(String, Bool)], current: [String]? = nil) -> OrcaView.Strip {
        .init(tabs: tabs.map { .init(title: $0.0, truncated: false, active: $0.1) }, currentWorkspaces: current ?? [worktree])
    }

    func testReadsKindsInStripOrder() {
        XCTAssertEqual(OrcaView.tabKinds(session: session()), [.terminal(tabID: "term-1"), .other])
        XCTAssertEqual(OrcaView.tabKinds(session: session(order: ["browser-1", "term-1"])), [.other, .terminal(tabID: "term-1")])
        // A split terminal tab is listed once per pane; it is still one tab in the strip.
        let split = session(extraTabs: [["type": "terminal", "id": "term-1::leaf-b", "parentTabId": "term-1"]])
        XCTAssertEqual(OrcaView.tabKinds(session: split), [.terminal(tabID: "term-1"), .other])
    }

    func testKindsAreUnknownWhenTheListIsNotUnderstood() {
        XCTAssertNil(OrcaView.tabKinds(session: session(order: ["term-1", "browser-1", "gone"])), "An id it does not list")
        XCTAssertNil(OrcaView.tabKinds(session: session(order: [])), "No order")
        XCTAssertNil(OrcaView.tabKinds(session: session(groups: 0)), "No tab group (measured: a workspace with a file tab)")
        XCTAssertNil(OrcaView.tabKinds(session: session(groups: 2)), "Two tab groups side by side")
        XCTAssertNil(OrcaView.tabKinds(session: session(layout: "split")), "A split layout")
        XCTAssertNil(OrcaView.tabKinds(session: [:]))
    }

    /// The case reported on 2026-11-13: the terminal is visible next to a browser tab whose close button names nothing (its title is unread).
    func testATerminalNextToABrowserTabResolves() {
        let kinds = OrcaView.tabKinds(session: session())!
        let shown = strip([(terminalTitle, true), ("", false)])
        XCTAssertEqual(OrcaView.resolve(strip: shown, layouts: layouts([("term-1", terminalTitle)]), kinds: kinds),
                       .tab(.init(worktreeID: worktree, tabID: "term-1")))
        // Without the session list the same strip is refused, as before.
        XCTAssertEqual(OrcaView.resolve(strip: shown, layouts: layouts([("term-1", terminalTitle)])), .noMatch)
    }

    func testTheBrowserTabInFrontIsNotATerminal() {
        let kinds = OrcaView.tabKinds(session: session())!
        XCTAssertEqual(OrcaView.resolve(strip: strip([(terminalTitle, false), ("Login - Brevo", true)]), layouts: layouts([("term-1", terminalTitle)]), kinds: kinds),
                       .notATerminal)
    }

    func testStaysExact() {
        let kinds = OrcaView.tabKinds(session: session())!
        let layout = layouts([("term-1", terminalTitle)])
        // A tab more or fewer on screen than the list has.
        XCTAssertEqual(OrcaView.resolve(strip: strip([(terminalTitle, true)]), layouts: layout, kinds: kinds), .noMatch)
        XCTAssertEqual(OrcaView.resolve(strip: strip([(terminalTitle, true), ("", false), ("x", false)]), layouts: layout, kinds: kinds), .noMatch)
        // The terminal's place shows another title (the list is out of date, or the order differs).
        XCTAssertEqual(OrcaView.resolve(strip: strip([("Login - Brevo", true), (terminalTitle, false)]), layouts: layout, kinds: kinds), .noMatch)
        // An unreadable tab at a terminal's place never matches.
        XCTAssertEqual(OrcaView.resolve(strip: strip([("", true), ("", false)]), layouts: layout, kinds: kinds), .noMatch)
        // The terminal list has a terminal the session list does not (or the other way round).
        XCTAssertEqual(OrcaView.resolve(strip: strip([(terminalTitle, true), ("", false)]),
                                        layouts: layouts([("term-1", terminalTitle), ("term-2", "Terminal 2")]), kinds: kinds), .noMatch)
        XCTAssertEqual(OrcaView.resolve(strip: strip([(terminalTitle, true), ("", false)]), layouts: layouts([("term-9", terminalTitle)]), kinds: kinds), .noMatch)
        // Only the workspace the sidebar shows is compared; without it nothing is matched.
        XCTAssertEqual(OrcaView.resolve(strip: strip([(terminalTitle, true), ("", false)], current: ["other"]), layouts: layout, kinds: kinds), .noMatch)
        XCTAssertEqual(OrcaView.resolve(strip: strip([(terminalTitle, true), ("", false)], current: []), layouts: layout, kinds: kinds), .noMatch)
        XCTAssertEqual(OrcaView.resolve(strip: strip([(terminalTitle, false), ("", false)]), layouts: layout, kinds: kinds), .noActiveTab)
    }

    func testTwoTerminalsAroundABrowserTab() {
        let session: [String: Any] = [
            "tabGroups": [["id": "g", "tabOrder": ["t1", "b", "t2"]]], "tabGroupLayout": ["type": "leaf"],
            "tabs": [["type": "terminal", "id": "t1::a", "parentTabId": "t1"], ["type": "browser", "id": "b"],
                     ["type": "terminal", "id": "t2::a", "parentTabId": "t2"]],
        ]
        let kinds = OrcaView.tabKinds(session: session)!
        let layout = layouts([("t1", "Terminal 1"), ("t2", "Terminal 2")])
        XCTAssertEqual(OrcaView.resolve(strip: strip([("Terminal 1", false), ("", false), ("Terminal 2", true)]), layouts: layout, kinds: kinds),
                       .tab(.init(worktreeID: worktree, tabID: "t2")))
        XCTAssertEqual(OrcaView.resolve(strip: strip([("Terminal 2", false), ("", false), ("Terminal 1", true)]), layouts: layout, kinds: kinds),
                       .noMatch, "Swapped titles")
    }
}
