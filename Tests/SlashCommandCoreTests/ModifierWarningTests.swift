import XCTest
@testable import SlashCommandCore

final class ModifierWarningTests: KoreanMessagesTestCase {
    private func decode(_ modifiers: [String]) throws -> SlashCommandConfig {
        let data = try JSONSerialization.data(withJSONObject: ["modifiers": modifiers, "slots": []])
        return try JSONDecoder().decode(SlashCommandConfig.self, from: data)
    }

    func testUnknownModifiersWarnAboutTheActualFallback() throws {
        let config = try decode(["hyper", "meta"])
        XCTAssertEqual(config.modifiers, SlashCommandConfig.defaultModifiers)
        XCTAssertEqual(config.ignoredModifiers, ["hyper", "meta"])
        XCTAssertEqual(config.modifierWarning, loc("The modifier keys in the presets file were not recognized (%@), so %@ is used. Use control, option, shift or command.", "hyper, meta", "⌥⇧"))
    }

    func testRecognizedModifiersDoNotWarn() throws {
        let config = try decode(["option", "shift"])
        XCTAssertEqual(config.modifiers, ["option", "shift"])
        XCTAssertTrue(config.ignoredModifiers.isEmpty)
        XCTAssertNil(config.modifierWarning)
    }

    func testPartlyFilteredModifiersRetainTheOriginalNames() throws {
        let config = try decode(["hyper", "option"])
        XCTAssertEqual(config.modifiers, ["option"])
        XCTAssertEqual(config.ignoredModifiers, ["hyper"], "option was recognized, so it is not named as unrecognized")
        XCTAssertEqual(config.modifierWarning, loc("The modifier keys in the presets file were not recognized (%@), so %@ is used. Use control, option, shift or command.", "hyper", "⌥"))
    }

    func testUnusableModifiersWarnEvenForAnEmptyArray() throws {
        for names in [["shift"], []] as [[String]] {
            let config = try decode(names)
            XCTAssertEqual(config.modifiers, SlashCommandConfig.defaultModifiers)
            XCTAssertTrue(config.ignoredModifiers.isEmpty, "shift is a recognized name; the problem is that it cannot be used alone")
            XCTAssertEqual(config.modifierWarning, loc("The modifier keys in the presets file cannot be used on their own, so %@ is used. Include control, option or command.", "⌥⇧"))
        }
    }

    func testReorderingRecognizedModifiersDoesNotWarn() throws {
        XCTAssertNil(try decode(["shift", "option"]).modifierWarning)
    }

    func testWarningStateDoesNotMakeAnUneditedDraftDirty() throws {
        // The settings window builds its draft with the public initializer and compares it with the loaded file.
        for names in [["hyper", "meta"], ["shift"]] as [[String]] {
            let loaded = try decode(names)
            let draft = SlashCommandConfig(version: loaded.version, keepDefaults: loaded.keepDefaults, acceptSwitchPrompt: loaded.acceptSwitchPrompt,
                                           effortKeys: loaded.effortKeys, modifiers: loaded.modifiers, slots: loaded.slots)
            XCTAssertEqual(draft, loaded)
        }
        XCTAssertNotEqual(try decode(["option", "shift"]), try decode(["control", "shift"]))
    }

    func testWarningDoesNotAddStoredKeys() throws {
        let config = try decode(["hyper", "meta"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "keepDefaults", "acceptSwitchPrompt", "effortKeys", "modifiers", "slots"])
    }

    func testTenSlotsCannotOverwriteAnExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigStore(url: root.appendingPathComponent("presets.json"))
        try store.save(.starter)
        let before = try Data(contentsOf: store.url)
        let oversized = SlashCommandConfig(slots: Array(repeating: Slot(), count: 10))
        XCTAssertThrowsError(try store.save(oversized)) {
            XCTAssertEqual(String(describing: $0), loc("At most %@ presets are allowed (there are %@): %@", 9, 10, store.url.path))
        }
        XCTAssertEqual(try Data(contentsOf: store.url), before)
    }

    func testTenSlotsDoNotCreateADirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigStore(url: root.appendingPathComponent("presets.json"))
        XCTAssertThrowsError(try store.save(SlashCommandConfig(slots: Array(repeating: Slot(), count: 10))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testNineSlotsCanStillBeSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigStore(url: root.appendingPathComponent("presets.json"))
        let config = SlashCommandConfig(slots: Array(repeating: Slot(), count: 9))
        try store.save(config)
        XCTAssertEqual(try store.load(), config)
    }

    func testWindowsPrioritizesTheFileWarningAndKeepsPlatformWarnings() throws {
        // The file warning names the keys Windows actually registers, not Mac symbols.
        XCTAssertEqual(WindowsAppModel.modifierWarning(for: try decode(["hyper", "meta"])),
                       loc("The modifier keys in the presets file were not recognized (%@), so %@ is used. Use control, option, shift or command.", "hyper, meta", "Alt+Shift"))
        XCTAssertEqual(WindowsAppModel.modifierWarning(for: try decode(["shift"])),
                       loc("The modifier keys in the presets file cannot be used on their own, so %@ is used. Include control, option or command.", "Alt+Shift"))
        XCTAssertEqual(WindowsAppModel.modifierWarning(for: try decode(["hyper", "control", "shift"])),
                       loc("The modifier keys in the presets file were not recognized (%@), so %@ is used. Use control, option, shift or command.", "hyper", "Ctrl+Shift"))
        XCTAssertNil(WindowsAppModel.modifierWarning(for: try decode(["option", "shift"])))
        XCTAssertEqual(WindowsAppModel.modifierWarning(for: try decode(["command"])), loc("Command is unavailable on Windows. Using Alt+Shift."))
    }

    func testShortNamesAreReadAsTheSameKeys() throws {
        let config = try decode(["Ctrl", "alt", "cmd"])
        XCTAssertEqual(config.modifiers, ["control", "option", "command"])
        XCTAssertNil(config.modifierWarning)
        XCTAssertEqual(try decode(["opt", "shift"]).modifiers, ["option", "shift"])
        XCTAssertEqual(WindowsAppModel.modifiers(try decode(["alt", "shift"]).modifiers), WindowsAppModel.modifiers(["option", "shift"]))
        // Saving writes the long names.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        XCTAssertEqual(object["modifiers"] as? [String], ["control", "option", "command"])
    }
}
