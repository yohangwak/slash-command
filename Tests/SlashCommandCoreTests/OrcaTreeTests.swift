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

    /// Orca 1.4.259 shows its window without the page for 12 to 46 seconds after the first request (measured 2026-11-15): that is
    /// told apart from a strip this reader cannot find, so the message says to wait instead of blaming an Orca update.
    func testAWindowWithoutItsPageIsNotReadyRatherThanUnreadable() {
        let strip = OrcaView.Strip(tabs: [.init(title: "zsh", truncated: false, active: true)])
        /// `true`: a window without its page; `false`: no window (nothing looked up).
        func stats(_ windowWithoutPage: Bool) -> OrcaView.StripStats {
            var stats = OrcaView.StripStats()
            if windowWithoutPage { stats.windows = 1; stats.elements = 13; stats.webPage = false }
            return stats
        }
        func reading(_ reads: [(OrcaView.Strip?, Bool)]) -> (reading: OrcaView.StripReading, stats: OrcaView.StripStats) {
            var left = reads[...]
            return OrcaView.reading(times: reads.count - 1, every: 0.15, wait: { _ in }) {
                let next = left.popFirst()!
                return (next.0, next.0.map { OrcaView.StripStats(strip: $0, windows: 1, elements: 220) } ?? stats(next.1))
            }
        }
        guard case .pageNotReady = reading(Array(repeating: (nil, true), count: 9)).reading else { return XCTFail("Window, never a page") }
        guard case .unreadable = reading(Array(repeating: (nil, false), count: 9)).reading else { return XCTFail("A page without a known strip, or no window") }
        guard case .unreadable = reading([(nil, true), (nil, false)]).reading else { return XCTFail("The last read decides") }
        let came = reading([(nil, true), (nil, true), (strip, false)])
        guard case .read(let found) = came.reading else { return XCTFail("The page came in time") }
        XCTAssertEqual(found.tabs.map(\.title), ["zsh"])
        XCTAssertEqual(came.stats.elements, 220, "The counts are those of the read that found the strip")
        XCTAssertEqual(reading(Array(repeating: (nil, true), count: 3)).stats.elements, 13)
    }
    #endif

    /// The log line for a refused read and for the check after Orca starts: counts only. A strip whose titles and worktree id would
    /// be in the log if anything but counts were used must not leak them.
    func testTheDiagnosticHoldsCountsAndNoScreenText() {
        let strip = OrcaView.Strip(tabs: [.init(title: "secret-project — claude", truncated: false, active: true),
                                          .init(title: "billing.csv", truncated: false, active: false, closeNamesTitle: false),
                                          .init(title: "zsh ~/private", truncated: true, active: true)],
                                   currentWorkspaces: ["repo-123::/Users/someone/private-repo"],
                                   groups: [.init(tabs: 2, focused: true), .init(tabs: 1, focused: false)])
        var stats = OrcaView.StripStats(strip: strip, windows: 1, elements: 231)
        XCTAssertEqual(stats.summary, "windows 1 · elements 231 · web page yes · cut no · tabs 3 · active 2 · groups 2 · sidebar current 1")
        let line = OrcaView.StripStats.diagnostic(orcaVersion: "1.4.259", outcome: "noActiveTab, with session list", stats: stats)
        XCTAssertEqual(line, "Orca 1.4.259 · noActiveTab, with session list · windows 1 · elements 231 · web page yes · cut no · tabs 3 · active 2 · groups 2 · sidebar current 1")
        let check = OrcaSelfCheck.line(orcaVersion: "1.4.259", pid: 9132, result: .refused(outcome: "noActiveTab, with session list", diagnostic: line))
        XCTAssertEqual(check, "Orca 1.4.259 (pid 9132) check: tabs NOT readable (Orca 1.4.259 · noActiveTab, with session list · windows 1 · elements 231 · web page yes · cut no · tabs 3 · active 2 · groups 2 · sidebar current 1)")
        for text in [line, check] {
            for leak in ["secret", "claude", "billing", "csv", "zsh", "private", "repo-123", "/Users", "someone"] {
                XCTAssertFalse(text.contains(leak), "\(leak) in \(text)")
            }
        }
        // A window without its page, before anything is found.
        stats = OrcaView.StripStats()
        stats.windows = 1; stats.elements = 13; stats.webPage = false
        XCTAssertTrue(stats.windowWithoutPage)
        XCTAssertEqual(OrcaView.StripStats.diagnostic(orcaVersion: nil, outcome: "pageNotReady", stats: stats),
                       "Orca ? · pageNotReady · windows 1 · elements 13 · web page no · cut no · tabs 0 · active 0 · groups 0 · sidebar current 0")
        XCTAssertTrue(OrcaView.StripStats().summary.contains("web page unknown"), "Not looked up is not «no»")
        XCTAssertFalse(OrcaView.StripStats().windowWithoutPage, "No window is not a window without its page")
    }

    /// The check after an Orca start runs the hotkey's lookup: a strip that is found but would be refused is not «readable» (Pullfrog
    /// #64 — an Orca that renamed the active mark gives tabs and no active one); a non-terminal tab in front means the reader works.
    func testTheCheckAfterAnOrcaStartJudgesByTheHotkeysLookup() {
        XCTAssertEqual(OrcaSelfCheck.Result(error: nil), .found)
        XCTAssertTrue(OrcaSelfCheck.Result.found.readable)
        XCTAssertEqual(OrcaSelfCheck.line(orcaVersion: "1.4.259", pid: 9, result: .found),
                       "Orca 1.4.259 (pid 9) check: tabs readable (a hotkey would find the visible terminal)")
        let renamed = SlashCommandError("Not sent").diagnosing("Orca 1.4.260 · noActiveTab, no session list · tabs 3 · active 0", outcome: "noActiveTab, no session list")
        let partial = OrcaSelfCheck.Result(error: renamed)
        XCTAssertFalse(partial.readable, "Tabs found, but a hotkey would be refused")
        XCTAssertTrue(OrcaSelfCheck.line(orcaVersion: "1.4.260", pid: 9, result: partial).contains("check: tabs NOT readable (Orca 1.4.260 · noActiveTab"))
        let browser = SlashCommandError("The frontmost Orca tab is not a terminal.").diagnosing("Orca 1.4.259 · notATerminal · tabs 2", outcome: "notATerminal")
        XCTAssertTrue(OrcaSelfCheck.Result(error: browser).readable)
        let other = OrcaSelfCheck.Result(error: SlashCommandError("Orca's terminal list: timeout"))
        XCTAssertEqual(other, .otherFailure)
        XCTAssertFalse(other.readable)
        XCTAssertFalse(OrcaSelfCheck.line(orcaVersion: "1.4.259", pid: 9, result: other).contains("timeout"), "No message text in the line")
    }

    /// Only the characters a version has reach the log from Orca's Info.plist.
    func testTheOrcaVersionIsCutToVersionCharacters() {
        XCTAssertEqual(OrcaView.StripStats.cleanVersion("1.4.259"), "1.4.259")
        XCTAssertEqual(OrcaView.StripStats.cleanVersion("1.5.0-beta.2+build7"), "1.5.0-beta.2+build7")
        XCTAssertEqual(OrcaView.StripStats.cleanVersion("1.4 /x\n\"y\""), "1.4xy", "No spaces, slashes, line breaks or quotes")
        XCTAssertEqual(OrcaView.StripStats.cleanVersion(nil), "?")
        XCTAssertEqual(OrcaView.StripStats.cleanVersion(" \n"), "?")
        XCTAssertEqual(OrcaView.StripStats.cleanVersion(String(repeating: "9", count: 80)).count, 32)
    }

    /// The error a refused read throws carries the line; equality is still the message's (the line is for the log).
    func testARefusalCarriesItsDiagnostic() {
        let plain = SlashCommandError("Not sent")
        let carried = plain.diagnosing("Orca 1.4.259 · unreadable · windows 0")
        XCTAssertNil(plain.diagnostic)
        XCTAssertEqual(carried.diagnostic, "Orca 1.4.259 · unreadable · windows 0")
        XCTAssertEqual(carried.message, "Not sent")
        XCTAssertEqual(carried.logDescription, "Not sent", "The log's failure line stays the message; the diagnostic is its own line")
    }
}
