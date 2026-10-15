import XCTest
@testable import SlashCommandCore

final class SettingsNamesTests: XCTestCase {
    func testMissingBundleOrKeyGivesNothing() {
        XCTAssertNil(SettingsNames.system(key: "ACCESSIBILITY", bundlePath: "/nonexistent/Nothing.appex"))
        XCTAssertNil(SettingsNames.system(key: "SLASHCOMMAND_NO_SUCH_KEY"))
    }

    /// Reads the name this macOS's System Settings uses for that list (macOS 27: "Device Control and Data Access"; earlier: "Accessibility").
    func testReadsTheNameThisSystemUses() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: SettingsNames.privacyExtension), "no Privacy & Security extension on this system")
        let name = try XCTUnwrap(SettingsNames.system(key: "ACCESSIBILITY"))
        print("this system calls the list: \(name)")
        XCTAssertFalse(name.isEmpty)
        XCTAssertNotEqual(name, "ACCESSIBILITY")
    }

    func testFallsBackToOurOwnWord() {
        XCTAssertFalse(SettingsNames.accessibility.isEmpty)
    }
}
