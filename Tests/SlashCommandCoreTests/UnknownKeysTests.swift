import XCTest
@testable import SlashCommandCore

/// 나중 판이 프리셋 파일에 쓴 키를, 이 판이 읽고 저장해도 잃지 않는다.
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
        XCTAssertEqual((slots[0]["gemini"] as? [String: Any])?["model"] as? String, "g-3", "모르는 에이전트의 프리셋")
        XCTAssertEqual((slots[0]["claude"] as? [String: Any])?["fast"] as? Bool, true, "프리셋 안의 모르는 키")
        XCTAssertEqual(slots[1]["pinned"] as? Int, 7)
        // 아는 키는 한 번씩만, 이 판의 값으로.
        XCTAssertEqual(written["version"] as? Int, 3)
        XCTAssertEqual((slots[0]["claude"] as? [String: Any])?["model"] as? String, "opus")
    }

    func testUnknownKeysTravelWithTheirSlot() throws {
        var config = try JSONDecoder().decode(SlashCommandConfig.self, from: Data(newer.utf8))
        // 첫 프리셋을 지우면 그 프리셋의 모르는 키도 같이 사라지고, 남은 프리셋의 것은 제자리에 있다(순서로 붙이지 않는다).
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
        XCTAssertEqual(try store.load(), config, "다시 읽어도 같다")
    }

    func testAFileWithoutUnknownKeysIsWrittenAsBefore() throws {
        let config = SlashCommandConfig.starter
        let written = try object(JSONEncoder().encode(config))
        XCTAssertEqual(Set(written.keys), ["version", "keepDefaults", "acceptSwitchPrompt", "effortKeys", "modifiers", "slots"])
        let slots = try XCTUnwrap(written["slots"] as? [[String: Any]])
        XCTAssertEqual(Set(slots[0].keys), ["claude", "codex"])
        XCTAssertEqual(Set((slots[0]["claude"] as? [String: Any] ?? [:]).keys), ["model", "effort"])
    }
}
