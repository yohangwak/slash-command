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

    func testNoTabsIsAnEmptyListNotUnknown() {
        var tree = Tree()
        tree.children = [0: [1, 2]]
        XCTAssertEqual(tree.tabs(from: [0])?.count, 0)
    }
}
