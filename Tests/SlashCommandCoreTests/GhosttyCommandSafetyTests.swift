import Foundation
import XCTest
@testable import SlashCommandCore

final class GhosttyCommandSafetyTests: KoreanMessagesTestCase {
    private let target = Target(host: .ghostty(terminalID: "T"), agent: .claude, label: "test")

    private func settingsFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-command-\(UUID().uuidString).json")
        try Data("{\"model\":\"opus\"}".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAnotherSessionsStampCannotSendEffortIntoASwitchDialog() throws {
        let settings = try settingsFile()
        let claude = FakeClaude()
        claude.settings = settings
        claude.asksBeforeSwitching = true
        var clock = 0
        var touched = false
        let io = LaggingIO(base: claude, lagMs: 500)
        io.now = { clock }
        let switcher = Switcher(
            config: SlashCommandConfig(acceptSwitchPrompt: false, slots: [Slot(claude: AgentPreset(model: "sonnet", effort: "medium"))]),
            claudeDefaults: ClaudeDefaults(url: settings), codexModels: { CodexModels(models: []) },
            makeIO: { _ in io }, sleep: { ms in
                clock += ms
                if !touched, claude.stage == .confirm {
                    touched = true
                    try? Data("{\"model\":\"fable\"}".utf8).write(to: settings)
                    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000_000)], ofItemAtPath: settings.path)
                }
            })

        XCTAssertThrowsError(try switcher.apply(slot: 1, to: target))
        XCTAssertTrue(touched)
        XCTAssertEqual(claude.stage, .confirm)
        XCTAssertFalse(claude.sent.contains { $0.contains("/effort") }, "Never send the second command into the confirmation dialog")
    }

    func testNormalCommandsSucceedWithTheRestoredDraft() throws {
        let settings = try settingsFile()
        let claude = FakeClaude()
        claude.settings = settings
        claude.draft = "unfinished draft"
        var clock = 0
        let io = LaggingIO(base: claude, lagMs: 500)
        io.now = { clock }
        let switcher = Switcher(
            config: SlashCommandConfig(slots: [Slot(claude: AgentPreset(model: "sonnet", effort: "medium"))]),
            claudeDefaults: ClaudeDefaults(url: settings), codexModels: { CodexModels(models: []) },
            makeIO: { _ in io }, sleep: { clock += $0 })

        let result = try switcher.apply(slot: 1, to: target)
        XCTAssertEqual(result.summary, "Sonnet 5.5 · medium")
        XCTAssertEqual(claude.sent, ["\u{13}/model sonnet\r", "\u{13}/effort medium\r"])
        XCTAssertEqual(claude.draft, "unfinished draft")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{\"model\":\"opus\"}")
    }
}
