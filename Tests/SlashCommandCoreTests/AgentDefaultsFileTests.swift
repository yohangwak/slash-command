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
        // Windows reports the link target with backslashes and the URL path with slashes.
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path).replacingOccurrences(of: "\\", with: "/")
        XCTAssertEqual(destination, target.path.replacingOccurrences(of: "\\", with: "/"), file: file, line: line)
        let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600, file: file, line: line)
    }

    func testRestoreOfOriginallyAbsentFilePreservesDanglingLink() throws {
        for grok in [false, true] {
            try withLinkedFile(Data()) { link, target in
                try FileManager.default.removeItem(at: target)
                let snapshot = DefaultsFile.snapshot(link)
                XCTAssertEqual(snapshot, .absent)
                if grok {
                    try Data("[models]\ndefault = \"new\"\n".utf8).write(to: target)
                    XCTAssertEqual(GrokDefaults(url: link).restore(to: snapshot), .restored)
                } else {
                    try Data(#"{"model":"new"}"#.utf8).write(to: target)
                    XCTAssertEqual(CursorDefaults(url: link).restore(to: snapshot), .restored)
                }
                XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            }
        }
    }

    func testRestoringModelKeepsUnrelatedChangeFromBooleanToNumber() throws {
        let before = "{\n  \"model\": \"old\",\n  \"other\": [true]\n}"
        let after = before.replacingOccurrences(of: "true", with: "1").replacingOccurrences(of: "old", with: "new")
        for claude in [false, true] {
            try withLinkedFile(Data(after.utf8)) { link, target in
                let snapshot = DefaultsSnapshot.content(Data(before.utf8))
                if claude {
                    XCTAssertEqual(ClaudeDefaults(url: link).restore(to: snapshot), .restored)
                } else {
                    XCTAssertEqual(CursorDefaults(url: link).restore(to: snapshot), .restored)
                }
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: target))
                let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                XCTAssertEqual(String(decoding: canonical, as: UTF8.self), #"{"model":"old","other":[1]}"#)
            }
        }
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
