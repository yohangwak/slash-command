import XCTest
@testable import SlashCommandCore

final class ModelListsTests: XCTestCase {
    /// Lines shaped like `cursor-agent models` (2026.11.22, measured 2026-11-28): effort and Fast variants of one model, two spaces, a zero-width tail, a tag.
    static let cursor = """
    Available models

    auto - Auto (default)
    grok-4.7-high - Grok 4.7  High
    grok-4.7-high-fast - Grok 4.7  High Fast\u{200B}\u{200B}
    claude-opus-5-5-medium - Claude Opus 5.5 1M
    claude-opus-5-5-high - Claude Opus 5.5 1M High
    claude-fable-5-2-high - Claude Fable 5.2 1M (NO ZDR)
    claude-opus-5-thinking-high - Claude Opus 5 1M Thinking
    composer-2.5 - Composer 2.5
    """

    /// Lines shaped like `agy models` (1.5.18, measured 2026-11-28).
    static let agy = """
    Fetching available models...
    gemini-4-neon-high\tGemini 4 Neon (High)
    gemini-4-neon-low\tGemini 4 Neon (Low)
    gemini-3.8-flash-high\tGemini 3.8 Flash (High)
    gemini-pro-orchestrator-neon\tOrchestrator (Neon)
    gemini-pro-orchestrator\tOrchestrator (Carbon)
    claude-opus-5-5-high\tClaude Opus 5.5 (High)
    """

    func testNamesAreEachModelOnceInListedOrder() {
        XCTAssertEqual(ModelLists.names(agent: .cursor, listing: Self.cursor),
                       ["Auto", "Grok 4.7", "Claude Opus 5.5", "Claude Fable 5.2", "Claude Opus 5", "Composer 2.5"])
        XCTAssertEqual(ModelLists.names(agent: .antigravity, listing: Self.agy),
                       ["Gemini 4 Neon", "Gemini 3.8 Flash", "Orchestrator (Neon)", "Orchestrator (Carbon)", "Claude Opus 5.5"])
        XCTAssertEqual(ModelLists.names(agent: .codex, listing: Self.cursor), [], "Only Cursor Agent and Antigravity")
    }

    func testEveryNameResolvesToAnIdWithTheSameListing() throws {
        for (agent, listing) in [(Agent.cursor, Self.cursor), (.antigravity, Self.agy)] {
            for name in ModelLists.names(agent: agent, listing: listing) where !["Auto", "Composer 2.5"].contains(name) {
                XCTAssertNoThrow(try Launch.resolve(agent: agent, preset: AgentPreset(model: name, effort: "high"), listing: listing), "\(agent) \(name)")
            }
        }
    }

    func testOrchestratorRowsResolveToTheirOwnIds() throws {
        XCTAssertEqual(try Launch.resolve(agent: .antigravity, preset: AgentPreset(model: "Orchestrator (Carbon)", effort: "high"), listing: Self.agy).model,
                       "gemini-pro-orchestrator")
        XCTAssertEqual(try Launch.resolve(agent: .antigravity, preset: AgentPreset(model: "Orchestrator (Neon)", effort: "high"), listing: Self.agy).model,
                       "gemini-pro-orchestrator-neon")
        XCTAssertEqual(try Launch.resolve(agent: .antigravity, preset: AgentPreset(model: "Gemini 4 Neon", effort: "low"), listing: Self.agy).model,
                       "gemini-4-neon-low", "An effort bracket is still split off")
        let spaced = "example-extra-high\tExample (Extra High)\nexample-low\tExample (Low)\n"
        XCTAssertEqual(try Launch.resolve(agent: .antigravity, preset: AgentPreset(model: "Example", effort: "extra high"), listing: spaced).model,
                       "example-extra-high", "`Extra High` is an effort level too")
        XCTAssertEqual(ModelLists.names(agent: .antigravity, listing: spaced), ["Example"])
    }

    func testCRLFListingsAreReadLineByLine() {
        XCTAssertEqual(ModelLists.names(agent: .cursor, listing: Self.cursor.replacingOccurrences(of: "\n", with: "\r\n")),
                       ModelLists.names(agent: .cursor, listing: Self.cursor))
        XCTAssertEqual(ModelLists.names(agent: .antigravity, listing: Self.agy.replacingOccurrences(of: "\n", with: "\r\n")),
                       ModelLists.names(agent: .antigravity, listing: Self.agy))
    }

    func testTheListNeverTakesThePresetsFilePath() throws {
        let presets = URL(fileURLWithPath: "/tmp/x/model-lists.json")
        XCTAssertEqual(ModelLists.url(besides: presets).path, "/tmp/x/model-lists.json.model-lists.json")
        XCTAssertEqual(ModelLists.url(besides: URL(fileURLWithPath: "/tmp/x/Model-Lists.json")).path, "/tmp/x/Model-Lists.json.model-lists.json",
                       "Same file on a volume that ignores case")
        XCTAssertEqual(ModelLists.url(besides: URL(fileURLWithPath: "/tmp/x/presets.json")).path, "/tmp/x/model-lists.json")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-list-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let other = Data(#"{"version":1,"slots":[]}"#.utf8)
        try other.write(to: url)
        XCTAssertThrowsError(try ModelLists.save([.cursor: .names(["Grok 4.7"])], to: url))
        XCTAssertEqual(try Data(contentsOf: url), other, "Another file at that path is left alone")
        let lookalike = Data(#"{"version":1,"slots":[],"lists":{}}"#.utf8)
        try lookalike.write(to: url)
        XCTAssertEqual(ModelLists.load(from: url), [:])
        XCTAssertThrowsError(try ModelLists.save([.cursor: .names(["Grok 4.7"])], to: url), "A presets file with a 'lists' key is still not ours")
        XCTAssertEqual(try Data(contentsOf: url), lookalike)
    }

    func testAskRunsOnlyTheListCommandAndReportsEachAgent() {
        var ran: [[String]] = []
        let outcomes = ModelLists.ask(locate: { $0 == "cursor-agent" ? "/x/cursor-agent" : nil }, run: { exe, args in
            ran.append([exe] + args)
            return ProcResult(status: 0, out: Self.cursor, err: "", timedOut: false)
        })
        XCTAssertEqual(ran, [["/x/cursor-agent", "models"]])
        XCTAssertEqual(outcomes[.cursor], .names(ModelLists.names(agent: .cursor, listing: Self.cursor)))
        XCTAssertEqual(outcomes[.antigravity], .notInstalled)
    }

    func testAFailedCommandSaysWhyAndNamesNothing() {
        let signedOut = ModelLists.ask([.antigravity], locate: { _ in "/x/agy" }, run: { _, _ in
            ProcResult(status: 1, out: "", err: "\nPlease sign in first.\n", timedOut: false)
        })
        XCTAssertEqual(signedOut[.antigravity], .failed("Please sign in first."))
        let slow = ModelLists.ask([.cursor], locate: { _ in "/x/c" }, run: { _, _ in ProcResult(status: -1, out: "", err: "", timedOut: true) })
        XCTAssertEqual(slow[.cursor], .failed(loc("timed out")))
        let empty = ModelLists.ask([.cursor], locate: { _ in "/x/c" }, run: { _, _ in ProcResult(status: 0, out: "Available models\n", err: "", timedOut: false) })
        XCTAssertEqual(empty[.cursor], .failed("Available models"), "A list without one model row is not saved as an empty menu")
    }

    func testSaveKeepsTheOldListOfAnAgentThatFailed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("model-lists-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ModelLists.load(from: url), [:], "No file: the built-in lists are used")
        try ModelLists.save([.cursor: .names(["Grok 4.7"]), .antigravity: .names(["Gemini 4 Neon"])], to: url)
        try ModelLists.save([.cursor: .failed("timed out"), .antigravity: .names(["Gemini 4 Argon", "Gemini 4 Neon"])], to: url)
        XCTAssertEqual(ModelLists.load(from: url), [.cursor: ["Grok 4.7"], .antigravity: ["Gemini 4 Argon", "Gemini 4 Neon"]])
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(ModelLists.load(from: url), [:], "An unreadable file falls back to the built-in lists")
    }
}
