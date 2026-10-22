import Foundation
import XCTest
@testable import SlashCommandCore

final class PresetControlCharacterTests: KoreanMessagesTestCase {
    private func switcher(_ preset: AgentPreset, agent: Agent, io: FakeClaude = FakeClaude()) -> Switcher {
        var slot = Slot()
        slot.presets[agent] = preset
        let defaults = FileManager.default.temporaryDirectory.appendingPathComponent("preset-control-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: defaults) }
        return Switcher(config: SlashCommandConfig(slots: [slot]), claudeDefaults: ClaudeDefaults(url: defaults),
                        codexModels: { CodexModels(models: []) }, makeIO: { _ in io }, sleep: { _ in })
    }

    private func expectedError(_ agent: Agent) -> String {
        loc("Not switched: preset %@ for %@ contains a control character. Fix it in Settings or the presets file.", 1, agent.displayName)
    }

    func testClaudeModelCarriageReturnStopsBeforeAnyKeyIsSent() {
        let io = FakeClaude()
        let switcher = switcher(AgentPreset(model: "opus\r/exit", effort: "high"), agent: .claude, io: io)
        let target = Target(host: .orca(handle: "test"), agent: .claude, label: "test")

        XCTAssertThrowsError(try switcher.apply(slot: 1, to: target)) {
            XCTAssertEqual(($0 as? SlashCommandError)?.message, self.expectedError(.claude))
        }
        XCTAssertEqual(io.sent, [])
    }

    func testCodexEffortEscapeStopsBeforeAnyKeyIsSent() {
        let io = FakeClaude()
        let switcher = switcher(AgentPreset(model: "gpt-6.1-sol", effort: "high\u{1b}"), agent: .codex, io: io)
        let target = Target(host: .orca(handle: "test"), agent: .codex, label: "test")

        XCTAssertThrowsError(try switcher.apply(slot: 1, to: target)) {
            XCTAssertEqual(($0 as? SlashCommandError)?.message, self.expectedError(.codex))
        }
        XCTAssertEqual(io.sent, [])
    }

    func testLaunchPresetLookupRejectsEveryASCIIControlInEitherField() {
        // `slashcommand run` reads through preset(slot:agent:) before building launch arguments.
        for value in Array(UInt32(0)...UInt32(31)) + [UInt32(127)] {
            let control = String(UnicodeScalar(value)!)
            for preset in [AgentPreset(model: "opus" + control, effort: "high"),
                           AgentPreset(model: "opus", effort: "high" + control)] {
                XCTAssertThrowsError(try switcher(preset, agent: .claude).preset(slot: 1, agent: .claude)) {
                    XCTAssertEqual(($0 as? SlashCommandError)?.message, self.expectedError(.claude))
                }
            }
        }
    }

    func testPrintableAndUnicodePresetValuesRemainAvailable() throws {
        let preset = AgentPreset(model: "provider/모델 α ~", effort: "custom effort")
        XCTAssertEqual(try switcher(preset, agent: .claude).preset(slot: 1, agent: .claude), preset)
    }
}
