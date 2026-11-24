import XCTest
@testable import SlashCommandCore

/// A workspace in a paired Orca environment runs on another computer; an SSH workspace's terminals run on another computer too.
final class OrcaPairedEnvironmentTests: XCTestCase {
    override func setUp() { super.setUp(); L10n.use(language: "en", directory: nil) }

    /// Sidebar row ids as Orca 1.4.273 writes them (2026-11-25): `encodeURIComponent("<section>:<host>|<worktree id>")`.
    private func rowID(host: String, worktree: String = "b6c8991d-5796-43de-b9c6-f055abb535be::C:/Users/someone/orca/workspaces/office/fbm") -> String {
        let key = "project:github:someone/office-manager:\(host)|\(worktree)"
        return "worktree-list-option-" + key.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()")))!
    }

    func testReadsTheHostOfASidebarRow() {
        XCTAssertEqual(OrcaView.currentWorkspaceHost(domID: rowID(host: "local")), "local")
        XCTAssertEqual(OrcaView.currentWorkspaceHost(domID: rowID(host: "runtime:2bbe00c4-0821-4c70-ae16-2392ed6f00e6")),
                       "runtime:2bbe00c4-0821-4c70-ae16-2392ed6f00e6")
        // Orca encodes the host's own characters, so an SSH target with `:` or `|` in it is one part after one decoding.
        XCTAssertEqual(OrcaView.currentWorkspaceHost(domID: rowID(host: "ssh:" + "box:22|x".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)),
                       "ssh:box%3A22%7Cx")
        // The measured row from `testReadsTheCurrentWorkspaceFromTheSidebarRowID`, unchanged.
        let measured = "worktree-list-option-project%3Agithub%3Ayohangwak%2Fslash-command%3Alocal%7Cc9b0a209-f6ff-4d61-907b-8f16e5fb51a4%3A%3A%2FUsers%2Fyohan%2FRepos%2Fyohangwak%2Fmodelswitch"
        XCTAssertEqual(OrcaView.currentWorkspaceHost(domID: measured), "local")
    }

    func testAnUnknownRowShapeNamesNoHost() {
        XCTAssertNil(OrcaView.currentWorkspaceHost(domID: nil))
        XCTAssertNil(OrcaView.currentWorkspaceHost(domID: "worktree-list-option-project%3Agithub%3Ayohangwak%2Fslash-command"), "A project header")
        XCTAssertNil(OrcaView.currentWorkspaceHost(domID: rowID(host: "wsl:Ubuntu")), "A host kind this reader does not know")
        XCTAssertNil(OrcaView.currentWorkspaceHost(domID: rowID(host: "runtime:")), "No environment id")
        XCTAssertNil(OrcaView.currentWorkspaceHost(domID: "something-else-runtime%3Aabc%7Cw"))
        // An unknown shape is never another computer, so it keeps today's path (the strip still has to match the lists).
        XCTAssertFalse(OrcaView.isPairedEnvironment(host: nil))
        XCTAssertFalse(OrcaView.isPairedEnvironment(host: "local"))
        XCTAssertFalse(OrcaView.isPairedEnvironment(host: "ssh:box"))
        XCTAssertTrue(OrcaView.isPairedEnvironment(host: "runtime:2bbe00c4-0821-4c70-ae16-2392ed6f00e6"))
    }

    func testTheWalkKeepsEachCurrentRowsHost() {
        // 0 → rows 1 (current, paired environment), 2 (not current, local), 3 (current, unknown shape)
        let ids: [Int: String] = [1: rowID(host: "runtime:env"), 2: rowID(host: "local"), 3: "worktree-list-option-x%7Cw"]
        let current: Set<Int> = [1, 3]
        let strip = OrcaView.strip(from: [0], tab: { _ in nil },
                                   currentWorkspace: { current.contains($0) ? OrcaView.currentWorkspace(domID: ids[$0], ariaCurrent: "page") : nil },
                                   currentHost: { OrcaView.currentWorkspaceHost(domID: ids[$0]) },
                                   children: { $0 == 0 ? [1, 2, 3] : [] })
        XCTAssertEqual(strip?.currentWorkspaces.count, 2)
        XCTAssertEqual(strip?.currentHosts, ["runtime:env", nil])
        // A strip built without hosts has one unknown host per row.
        XCTAssertEqual(OrcaView.Strip(tabs: [], currentWorkspaces: ["a", "b"]).currentHosts, [nil, nil])
    }

    /// Orca's state database names the active workspace's host (Windows reads the visible workspace from it).
    func testTheStateDatabaseRefusesAPairedEnvironmentsWorkspace() throws {
        XCTAssertThrowsError(try OrcaState.active(queryOutput: #"{"worktree":"r::C:/w","tab":"t","host":"runtime:2bbe00c4"}"#)) {
            XCTAssertEqual(String(describing: $0), Detector.pairedEnvironmentRefusal)
        }
        XCTAssertEqual(try OrcaState.active(queryOutput: #"{"worktree":"r::/w","tab":"t","host":"local"}"#), .init(worktreeID: "r::/w", tabID: "t"))
        XCTAssertEqual(try OrcaState.active(queryOutput: #"{"worktree":"r::/w","tab":"t","host":null}"#), .init(worktreeID: "r::/w", tabID: "t"),
                       "An Orca that does not save the host")
        XCTAssertThrowsError(try OrcaState.active(queryOutput: #"{"worktree":null,"tab":"t","host":"local"}"#))
    }

    private func payload(host: Any?) -> [String: Any] {
        var terminal: [String: Any] = ["handle": "term_1", "title": "Claude Code", "agentIdentity": "grok"]
        if let host { terminal["executionHostId"] = host }
        let pane: [String: Any] = ["type": "terminal", "handle": "term_1", "leafId": "leaf", "active": true]
        let tab: [String: Any] = ["tabId": "tab", "title": "Claude Code", "activeLeafId": "leaf", "panes": [pane]]
        return ["terminals": [terminal],
                "visualLayouts": [["worktreeId": "w", "worktreePath": "/w", "root": ["tabs": [tab]]]]]
    }

    func testAnSSHTerminalsDefaultsAreNotThisComputers() throws {
        let active = OrcaState.Active(worktreeID: "w", tabID: "tab")
        XCTAssertTrue(try OrcaState.target(in: payload(host: "local"), active: active).defaultsAreLocal)
        XCTAssertTrue(try OrcaState.target(in: payload(host: nil), active: active).defaultsAreLocal, "An Orca that does not list the host")
        XCTAssertFalse(try OrcaState.target(in: payload(host: "ssh:box"), active: active).defaultsAreLocal)
        XCTAssertFalse(try OrcaState.target(in: payload(host: "runtime:env"), active: active).defaultsAreLocal)
    }

    private final class NoIO: TerminalIO {
        var keys: [Key] = []
        var typed: [String] = []
        func type(_ text: String) throws { typed.append(text) }
        func press(_ key: Key) throws { keys.append(key) }
        func screen() -> [String]? { nil }
    }

    func testAnAgentThatSavesDefaultsIsNotSwitchedOnAnSSHTerminalWhileDefaultsAreKept() throws {
        let active = OrcaState.Active(worktreeID: "w", tabID: "tab")
        for agent in [Agent.grok, .cursor, .antigravity, .opencode] {
            let io = NoIO()
            let switcher = Switcher(config: .starter, makeIO: { _ in io })
            var target = try OrcaState.target(in: payload(host: "ssh:box"), active: active, processAgent: { _ in agent })
            XCTAssertEqual(target.agent, agent)
            XCTAssertThrowsError(try switcher.stepEffort(up: true, on: target)) {
                XCTAssertTrue(String(describing: $0).contains("this Orca terminal runs on another computer"), "\(agent): \($0)")
            }
            XCTAssertTrue(io.keys.isEmpty && io.typed.isEmpty)
            // Positive control: the same terminal on this computer gets past that check (and stops at the unreadable screen).
            target.defaultsAreLocal = true
            XCTAssertThrowsError(try switcher.stepEffort(up: true, on: target)) {
                XCTAssertFalse(String(describing: $0).contains("runs on another computer"), "\(agent): \($0)")
            }
        }
    }
}
