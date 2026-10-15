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

    func testNoTabsIsAnEmptyListNotUnknown() {
        var tree = Tree()
        tree.children = [0: [1, 2]]
        XCTAssertEqual(tree.tabs(from: [0])?.count, 0)
    }
}
