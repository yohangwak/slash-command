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

    /// Orca 1.4.258 with tabs split into two groups, as measured on 2026-11-14: each group's frame holds its tabs, and the focused
    /// group's frame has `border-b-accent`.
    func testReadsGroupFramesAndWhichOneShowsFocus() {
        enum Part { case frame(focused: Bool), tab(active: Bool, String), other }
        let parts: [Int: Part] = [
            1: .frame(focused: false), 2: .other, 3: .tab(active: true, "one"), 4: .tab(active: false, "two"),
            6: .frame(focused: true), 7: .tab(active: true, "three"), 9: .tab(active: false, "loose"),
        ]
        let children = [0: [1, 6, 9], 1: [2], 2: [3, 4], 6: [7]]
        func classes(_ node: Int) -> [String] {
            guard case .frame(let focused) = parts[node] else { return [] }
            let base = "group/tab-group relative flex flex-col flex-1 min-w-0 min-h-0 overflow-hidden border-b border-border".split(separator: " ").map(String.init)
            return focused ? base + ["border-b-accent"] : base
        }
        let strip = OrcaView.strip(from: [0], tab: { node in
            guard case .tab(let active, let title) = parts[node] else { return nil }
            return OrcaView.Strip.Tab(title: title, truncated: false, active: active)
        }, currentWorkspace: { _ in nil }, group: { OrcaView.groupMark(classes: classes($0)) }, children: { children[$0] ?? [] })
        XCTAssertEqual(strip?.tabs.map(\.title), ["one", "two", "three", "loose"])
        XCTAssertEqual(strip?.groups, [.init(tabs: 2, focused: false), .init(tabs: 1, focused: true)])
        XCTAssertEqual(strip?.ungroupedTabs, 1)
        XCTAssertNil(OrcaView.groupMark(classes: ["border-b-accent"]), "Not a frame")
        XCTAssertNil(OrcaView.groupMark(classes: ["bg-tab-active"]))
        XCTAssertEqual(OrcaView.groupMark(classes: ["group/tab-group", "relative"]), .frame(focused: false, canShowFocus: false))
        XCTAssertEqual(OrcaView.groupMark(classes: ["group/tab-group", "border-b", "border-b-accent"]), .frame(focused: true, canShowFocus: true))
    }

    /// Measured 2026-11-14: the upper of two stacked groups has no `border-b`, so it never shows the mark. With it focused, no frame is
    /// marked and it is the only frame that cannot be; with two such frames nothing is known.
    func testAFrameThatCannotShowFocusIsFocusedWhenNoneIsMarked() {
        func frames(_ classes: [[String]]) -> [OrcaView.Strip.Group]? {
            var children: [Int: [Int]] = [0: []]
            var cls: [Int: [String]] = [:]
            for (i, c) in classes.enumerated() {
                let frame = 10 + i, tab = 100 + i
                children[0]!.append(frame); children[frame] = [tab]; cls[frame] = ["group/tab-group"] + c
            }
            return OrcaView.strip(from: [0], tab: { $0 >= 100 ? .init(title: "t\($0)", truncated: false, active: true) : nil },
                                  currentWorkspace: { _ in nil }, group: { OrcaView.groupMark(classes: cls[$0] ?? []) },
                                  children: { children[$0] ?? [] })?.groups
        }
        let upper: [String] = ["border-border"], lower = ["border-b", "border-border"], marked = ["border-b", "border-border", "border-b-accent"]
        XCTAssertEqual(frames([upper, lower, lower])?.map(\.focused), [true, false, false])
        XCTAssertEqual(frames([upper, marked, lower])?.map(\.focused), [false, true, false])
        XCTAssertEqual(frames([upper, upper, lower])?.map(\.focused), [nil, nil, nil], "Two frames that cannot show it")
        XCTAssertEqual(frames([lower, lower])?.map(\.focused), [nil, nil], "No mark and every frame could show it")
        XCTAssertEqual(frames([marked, marked])?.map(\.focused), [nil, nil], "Two marks")
    }

    func testNoTabsIsAnEmptyListNotUnknown() {
        var tree = Tree()
        tree.children = [0: [1, 2]]
        XCTAssertEqual(tree.tabs(from: [0])?.count, 0)
    }

    #if os(macOS)
    /// The read that first asks Chromium for Orca's page gets none (measured 2026-11-14): a read that finds no strip is repeated briefly.
    func testAReadThatFindsNoStripIsRepeatedBriefly() {
        var calls = 0, waited: [TimeInterval] = []
        let found: Int? = OrcaView.retrying(times: 8, every: 0.15, wait: { waited.append($0) }) { calls += 1; return calls == 4 ? 42 : nil }
        XCTAssertEqual(found, 42)
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(waited, [0.15, 0.15, 0.15])
        calls = 0; waited = []
        let none: Int? = OrcaView.retrying(times: 8, every: 0.15, wait: { waited.append($0) }) { calls += 1; return nil }
        XCTAssertNil(none)
        XCTAssertEqual(calls, 9, "The first read and eight more")
        XCTAssertEqual(waited.reduce(0, +), 1.2, accuracy: 0.001)
        calls = 0
        XCTAssertEqual(OrcaView.retrying(times: 8, every: 0.15, wait: { _ in XCTFail("No wait when the first read finds it") }) { calls += 1; return 7 }, 7)
    }
    #endif
}
