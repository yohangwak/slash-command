import XCTest
@testable import SlashCommandCore

final class SettingsNamesTests: XCTestCase {
    func testMissingBundleOrKeyGivesNothing() {
        XCTAssertNil(SettingsNames.system(key: "ACCESSIBILITY", bundlePath: "/nonexistent/Nothing.appex"))
        XCTAssertNil(SettingsNames.system(key: "SLASHCOMMAND_NO_SUCH_KEY"))
    }

    /// 이 macOS 의 시스템 설정이 그 목록을 부르는 이름을 읽는다(macOS 27: «Device Control and Data Access», 그 전: «Accessibility»).
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
