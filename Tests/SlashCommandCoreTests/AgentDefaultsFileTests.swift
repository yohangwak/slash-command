import Foundation
import XCTest
@testable import SlashCommandCore

final class AgentDefaultsFileTests: KoreanMessagesTestCase {
    private func withLinkedFile(_ contents: Data, _ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("settings")
        let link = directory.appendingPathComponent("settings-link")
        try contents.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        try body(link, target)
    }

    private func assertLinkAndPermissions(_ link: URL, _ target: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path, file: file, line: line)
        let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600, file: file, line: line)
    }

    func testCursorOriginalBytesRestorePreservesLinkAndPermissions() throws {
        let original = Data("{\"model\":\"old\",\"theme\":\"dark\"}".utf8)
        try withLinkedFile(Data("{\"model\":\"new\",\"theme\":\"dark\"}".utf8)) { link, target in
            XCTAssertEqual(CursorDefaults(url: link).restore(to: original), .restored)
            try assertLinkAndPermissions(link, target)
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
    }

    func testCursorPartialRestorePreservesLinkPermissionsAndOtherChanges() throws {
        let original = Data("{\"model\":\"old\",\"theme\":\"dark\"}".utf8)
        try withLinkedFile(Data("{\"model\":\"new\",\"theme\":\"light\"}".utf8)) { link, target in
            XCTAssertEqual(CursorDefaults(url: link).restore(to: original), .restored)
            try assertLinkAndPermissions(link, target)
            let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: String]
            XCTAssertEqual(restored, ["model": "old", "theme": "light"])
        }
    }

    func testOtherJSONDefaultsPreserveLinkAndPermissions() throws {
        try withLinkedFile(Data("{\"model\":\"new\"}".utf8)) { link, target in
            XCTAssertEqual(AntigravityDefaults(url: link).restore(to: Data("{\"model\":\"old\"}".utf8)), .restored)
            try assertLinkAndPermissions(link, target)
            XCTAssertEqual(try Data(contentsOf: target), Data("{\"model\":\"old\"}".utf8))
        }
        try withLinkedFile(Data("{\"recent\":[\"new\"]}".utf8)) { link, target in
            XCTAssertEqual(OpenCodeDefaults(url: link).restore(to: Data("{\"recent\":[\"old\"]}".utf8)), .restored)
            try assertLinkAndPermissions(link, target)
            XCTAssertEqual(try Data(contentsOf: target), Data("{\"recent\":[\"old\"]}".utf8))
        }
    }

    func testGrokRestorePreservesLinkPermissionsAndOtherChanges() throws {
        let original = "theme = \"dark\"\n[models]\ndefault = \"old\"\ndefault_reasoning_effort = \"low\"\n"
        let current = "theme = \"light\"\n[models]\ndefault = \"new\"\ndefault_reasoning_effort = \"high\"\n"
        try withLinkedFile(Data(current.utf8)) { link, target in
            XCTAssertEqual(GrokDefaults(url: link).restore(to: original), .restored)
            try assertLinkAndPermissions(link, target)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), original.replacingOccurrences(of: "dark", with: "light"))
        }
    }

    func testInvalidCursorJSONRefusesBeforeSendingAnything() throws {
        try withLinkedFile(Data("not json".utf8)) { link, target in
            let io = FakeCursor(configURL: link)
            let driver = CursorDriver(io: io, sleep: { _ in }, defaults: CursorDefaults(url: link), keepDefaults: true)
            XCTAssertThrowsError(try driver.apply(AgentPreset(model: "Claude Opus 5.5", effort: "high")))
            XCTAssertTrue(io.typed.isEmpty, "No text may be sent when the defaults cannot be parsed")
            XCTAssertTrue(io.presses.isEmpty, "No keys may be sent when the defaults cannot be parsed")
            XCTAssertEqual(try Data(contentsOf: target), Data("not json".utf8))
        }
    }

    func testJSONValidationDoesNotRejectGrokTOML() throws {
        XCTAssertNoThrow(try DefaultsFile.refuseIfUnreadable(.content(Data("[models]\ndefault = \"old\"\n".utf8)), name: "grok"))
        XCTAssertNoThrow(try DefaultsFile.refuseIfUnreadable(.absent, name: "cursor"))
    }
}
