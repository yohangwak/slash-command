import XCTest
@testable import SlashCommandCore

/// The part that walks the accessibility tree. The real Orca tree can run endlessly, with the app element reappearing as a child under the window (2026-10-12 test Mac).
final class OrcaTreeTests: XCTestCase {
    /// A fake tree keyed by number: child lists and text.
    private struct Tree {
        var children: [Int: [Int]] = [:]
        var labels: [Int: String] = [:]
        var active: Set<Int> = []
        var visited: [Int] = []

        mutating func tabs(from roots: [Int], seen: Set<Int> = [], maxDepth: Int = 150, maxNodes: Int = 30_000) -> [OrcaView.Strip.Tab]? {
            var order: [Int] = []
            let result = OrcaView.tabs(from: roots, seen: seen, maxDepth: maxDepth, maxNodes: maxNodes,
                                       label: { order.append($0); return self.labels[$0] ?? "" },
                                       classes: { self.active.contains($0) ? ["text-foreground"] : ["text-muted-foreground"] },
                                       children: { self.children[$0] ?? [] })
            visited = order
            return result
        }
    }

    private func tab(_ title: String) -> String { "idle \(title) Close tab \(title)" }

    func testCollectsTabsInDocumentOrderAndDoesNotLookInsideATab() {
        var tree = Tree()
        tree.children = [0: [1, 2], 1: [3, 4], 2: [5], 3: [9]]
        tree.labels = [3: tab("one"), 4: tab("two"), 5: tab("three"), 9: tab("inside")]
        tree.active = [4]
        let tabs = tree.tabs(from: [0])
        XCTAssertEqual(tabs?.map(\.title), ["one", "two", "three"])
        XCTAssertEqual(tabs?.map(\.active), [false, true, false])
        XCTAssertFalse(tree.visited.contains(9))
    }

    /// A cycle where the app element reappears under the window and leads back to the window — it must terminate, and each tab is counted once.
    func testACycleThroughTheApplicationEnds() {
        var tree = Tree()
        // 0 = app, 1 = window. The window's children include the app again, and the app's child is the window.
        tree.children = [0: [1], 1: [2, 0], 2: [3]]
        tree.labels = [3: tab("only")]
        XCTAssertEqual(tree.tabs(from: [1], seen: [0])?.map(\.title), ["only"])
        // It ends even if the app element is not put in beforehand.
        XCTAssertEqual(tree.tabs(from: [1])?.map(\.title), ["only"])
    }

    func testAnElementThatIsItsOwnChildEnds() {
        var tree = Tree()
        tree.children = [1: [1, 2]]
        tree.labels = [2: tab("only")]
        XCTAssertEqual(tree.tabs(from: [1])?.map(\.title), ["only"])
    }

    /// If the limit is hit there may be tabs not seen — do not return a partial read as the answer.
    func testTooDeepOrTooLargeIsUnknown() {
        var chain = Tree()
        for depth in 0..<400 { chain.children[depth] = [depth + 1] }
        chain.labels = [400: tab("far")]
        XCTAssertNil(chain.tabs(from: [0]))
        XCTAssertEqual(chain.tabs(from: [0], maxDepth: 500)?.map(\.title), ["far"])

        var wide = Tree()
        wide.children = [0: Array(1...50)]
        wide.labels = [50: tab("last")]
        XCTAssertNil(wide.tabs(from: [0], maxNodes: 20))
        XCTAssertEqual(wide.tabs(from: [0], maxNodes: 60)?.map(\.title), ["last"])
    }

    /// Orca 1.4.257 in Korean, as measured: the tab button's parts are its children, and the walk does not go on into them.
    func testCollectsLocalizedTabsFromTheirParts() {
        enum Part { case group, tab(active: Bool), text(String), button(String) }
        let parts: [Int: Part] = [0: .group, 1: .tab(active: false), 2: .text("weekly-review"), 3: .button("탭 닫기 weekly-review"),
                                  4: .tab(active: true), 5: .text("social-2"), 6: .button("탭 닫기 social-2")]
        let children = [0: [1, 4], 1: [2, 3], 4: [5, 6]]
        var visited: [Int] = []
        let strip = OrcaView.strip(from: [0], tab: { node in
            visited.append(node)
            guard case .tab(let active) = parts[node] else { return nil }
            var texts: [String] = [], labels: [String] = []
            for child in children[node] ?? [] {
                if case .text(let text) = parts[child] { texts.append(text) }
                if case .button(let label) = parts[child] { labels.append(label) }
            }
            return OrcaView.tab(classes: [active ? "bg-tab-active" : "bg-tab-inactive", active ? "text-tab-active-foreground" : "text-tab-inactive-foreground"],
                                texts: texts, buttonLabels: labels)
        }, currentWorkspace: { _ in nil }, children: { children[$0] ?? [] })
        XCTAssertEqual(strip?.tabs, [.init(title: "weekly-review", truncated: false, active: false), .init(title: "social-2", truncated: false, active: true)])
        XCTAssertEqual(visited, [0, 1, 4])
    }

    /// Orca 1.4.258 with tabs split into two groups: each group's frame holds its tab actions, then its tabs; the unfocused group's
    /// actions carry `opacity-50`.
    func testReadsGroupFramesAndWhichOneShowsFocus() {
        enum Part { case frame, actions([String]), tab(active: Bool, String), other }
        let parts: [Int: Part] = [
            1: .frame, 2: .other, 3: .tab(active: true, "one"), 4: .tab(active: false, "two"),
            5: .actions(["ml-1.5", "flex", "shrink-0", "items-center", "gap-0.5", "transition-opacity", "duration-150", "opacity-50", "hover:opacity-100", "focus-within:opacity-100"]),
            6: .frame, 7: .tab(active: true, "three"),
            8: .actions(["ml-1.5", "flex", "shrink-0", "items-center", "gap-0.5", "transition-opacity", "duration-150"]),
            9: .tab(active: false, "loose"),
        ]
        let children = [0: [1, 6, 9], 1: [2, 5], 2: [3, 4], 6: [7, 8]]
        func classes(_ node: Int) -> [String] {
            switch parts[node] {
            case .frame: return ["group/tab-group", "relative", "flex", "flex-col"]
            case .actions(let classes): return classes
            default: return []
            }
        }
        let strip = OrcaView.strip(from: [0], tab: { node in
            guard case .tab(let active, let title) = parts[node] else { return nil }
            return OrcaView.Strip.Tab(title: title, truncated: false, active: active)
        }, currentWorkspace: { _ in nil }, group: { OrcaView.groupMark(classes: classes($0)) }, children: { children[$0] ?? [] })
        XCTAssertEqual(strip?.tabs.map(\.title), ["one", "two", "three", "loose"])
        XCTAssertEqual(strip?.groups, [.init(tabs: 2, focused: false), .init(tabs: 1, focused: true)])
        XCTAssertEqual(strip?.ungroupedTabs, 1)
        XCTAssertNil(OrcaView.groupMark(classes: ["ml-1.5", "flex"]), "Not the tab actions")
        XCTAssertNil(OrcaView.groupMark(classes: ["bg-tab-active"]))
    }

    /// A frame with no actions, or with two, does not say whether it has focus.
    func testAFrameWithoutExactlyOneMarkHasUnknownFocus() {
        let marks: [Int: OrcaView.GroupMark] = [1: .frame, 2: .actions(focused: true), 3: .actions(focused: false), 4: .frame]
        let children = [0: [1, 4], 1: [2, 3, 5], 4: [6]]
        let strip = OrcaView.strip(from: [0], tab: { [5, 6].contains($0) ? .init(title: "t\($0)", truncated: false, active: true) : nil },
                                   currentWorkspace: { _ in nil }, group: { marks[$0] }, children: { children[$0] ?? [] })
        XCTAssertEqual(strip?.groups, [.init(tabs: 1, focused: nil), .init(tabs: 1, focused: nil)])
    }

    func testNoTabsIsAnEmptyListNotUnknown() {
        var tree = Tree()
        tree.children = [0: [1, 2]]
        XCTAssertEqual(tree.tabs(from: [0])?.count, 0)
    }
}
