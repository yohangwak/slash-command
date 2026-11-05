import XCTest
@testable import SlashCommandCore

/// Keys that a later version wrote to the presets file are not lost when this version reads and saves it.
final class UnknownKeysTests: XCTestCase {
    private let newer = """
    {
      "version": 3,
      "theme": {"accent": "blue", "sizes": [1, 2.5, null, true]},
      "slots": [
        {"name": "a", "claude": {"model": "opus", "effort": "high", "fast": true}, "gemini": {"model": "g-3", "effort": "low"}, "note": "keep me"},
        {"codex": {"model": "gpt-6.1-sol", "effort": "high"}, "pinned": 7}
      ]
    }
    """

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testReadsAndWritesBackKeysItDoesNotKnow() throws {
        let config = try JSONDecoder().decode(SlashCommandConfig.self, from: Data(newer.utf8))
        XCTAssertEqual(config.version, 3)
        XCTAssertEqual(config.slots[0].claude?.model, "opus")
        let written = try object(JSONEncoder().encode(config))
        let theme = try XCTUnwrap(written["theme"] as? [String: Any])
        XCTAssertEqual(theme["accent"] as? String, "blue")
        let sizes = try XCTUnwrap(theme["sizes"] as? [Any])
        XCTAssertEqual(sizes.count, 4)
        XCTAssertEqual(sizes[0] as? Int, 1)
        XCTAssertEqual(sizes[1] as? Double, 2.5)
        XCTAssertTrue(sizes[2] is NSNull)
        XCTAssertEqual(sizes[3] as? Bool, true)
        let slots = try XCTUnwrap(written["slots"] as? [[String: Any]])
        XCTAssertEqual(slots[0]["note"] as? String, "keep me")
        XCTAssertEqual((slots[0]["gemini"] as? [String: Any])?["model"] as? String, "g-3", "Preset of an unknown agent")
        XCTAssertEqual((slots[0]["claude"] as? [String: Any])?["fast"] as? Bool, true, "Unknown key inside a preset")
        XCTAssertEqual(slots[1]["pinned"] as? Int, 7)
        // Known keys appear only once, with this version's values.
        XCTAssertEqual(written["version"] as? Int, 3)
        XCTAssertEqual((slots[0]["claude"] as? [String: Any])?["model"] as? String, "opus")
    }

    func testUnknownKeysTravelWithTheirSlot() throws {
        var config = try JSONDecoder().decode(SlashCommandConfig.self, from: Data(newer.utf8))
        // Deleting the first preset also drops that preset's unknown keys, and those of the remaining presets stay in place (they are not matched up by order).
        config.slots.removeFirst()
        config.slots[0].codex?.effort = "low"
        let slots = try XCTUnwrap(try object(JSONEncoder().encode(config))["slots"] as? [[String: Any]])
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0]["pinned"] as? Int, 7)
        XCTAssertNil(slots[0]["note"])
        XCTAssertEqual((slots[0]["codex"] as? [String: Any])?["effort"] as? String, "low")
    }

    func testStoreKeepsThemAcrossLoadAndSave() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("slashcommand-\(UUID().uuidString)/presets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(newer.utf8).write(to: url)
        let store = ConfigStore(url: url)
        var config = try store.load()
        config.keepDefaults = false
        try store.save(config)
        let saved = try object(Data(contentsOf: url))
        XCTAssertEqual(saved["keepDefaults"] as? Bool, false)
        XCTAssertNotNil(saved["theme"])
        XCTAssertEqual(try store.load(), config, "Same after reading again")
    }

    /// PR #28 review: an unsigned integer beyond `Int64` is not read as a floating-point number and written back as a different value.
    func testUnsignedIntegersBeyondInt64AreKeptExactly() throws {
        struct Future: Decodable { let futureID: UInt64; let negative: Int64; let ratio: Double }
        let json = #"{"slots":[],"futureID":18446744073709551615,"negative":-9223372036854775808,"ratio":0.1}"#
        var config = try JSONDecoder().decode(SlashCommandConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.extra["futureID"], .unsigned(UInt64.max))
        config.keepDefaults = false   // Change and save an unrelated setting
        let saved = try JSONDecoder().decode(Future.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(saved.futureID, UInt64.max)
        XCTAssertEqual(saved.negative, Int64.min)
        XCTAssertEqual(saved.ratio, 0.1)
    }

    func testAFileWithoutUnknownKeysIsWrittenAsBefore() throws {
        let config = SlashCommandConfig.starter
        let written = try object(JSONEncoder().encode(config))
        XCTAssertEqual(Set(written.keys), ["version", "keepDefaults", "acceptSwitchPrompt", "effortKeys", "modifiers", "slots"])
        let slots = try XCTUnwrap(written["slots"] as? [[String: Any]])
        XCTAssertEqual(Set(slots[0].keys), ["claude", "codex"])
        XCTAssertEqual(Set((slots[0]["claude"] as? [String: Any] ?? [:]).keys), ["model", "effort"])
    }

    private func decode(_ json: String) throws -> SlashCommandConfig {
        try JSONDecoder().decode(SlashCommandConfig.self, from: Data(json.utf8))
    }

    func testTypoedKeysAreNamedWithTheirPath() throws {
        let config = try decode(#"{"acceptSwitchPromt": false, "slots": [{"claud": {"model": "opus", "effort": "high"}}]}"#)
        XCTAssertEqual(config.unknownKeys, ["acceptSwitchPromt", "slots[1].claud"])
        XCTAssertEqual(config.unknownKeyWarning, loc("This version does not use these keys in the presets file (they are kept): %@", "acceptSwitchPromt, slots[1].claud"))
        XCTAssertTrue(config.acceptSwitchPrompt, "The typo leaves the default in place; the warning is how it gets noticed")
    }

    func testTypoInsideAPresetIsNamedWithSlotAndAgent() throws {
        let config = try decode(#"{"slots": [{"claude": {"model": "opus", "effort": "high"}}, {"name": "b", "codex": {"model": "m", "effort": "low", "efort": "x"}}]}"#)
        XCTAssertEqual(config.unknownKeys, ["slots[2].codex.efort"])
    }

    func testAFileWithOnlyKnownKeysHasNoWarning() throws {
        let config = try decode(#"{"slots": [{"name": "a", "claude": {"model": "opus", "effort": "high"}, "codex": {"model": "m", "effort": "low"}}]}"#)
        XCTAssertEqual(config.unknownKeys, [])
        XCTAssertNil(config.unknownKeyWarning)
        XCTAssertNil(SlashCommandConfig.starter.unknownKeyWarning)
    }

    func testKeysAreListedTopLevelFirstThenBySlot() throws {
        let config = try decode(newer)
        XCTAssertEqual(config.unknownKeys, ["theme", "slots[1].gemini", "slots[1].note", "slots[1].claude.fast", "slots[2].pinned"])
    }

    func testReportingDoesNotChangeWhatIsKeptOrCompared() throws {
        let config = try decode(newer)
        var plain = config
        plain.extra = [:]
        XCTAssertNotEqual(config, plain, "Unknown keys are still part of the file's content")
        XCTAssertNotNil(try object(JSONEncoder().encode(config))["theme"], "Still written back")
    }
}
