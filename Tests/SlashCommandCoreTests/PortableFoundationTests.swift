import XCTest
@testable import SlashCommandCore

final class PortableFoundationTests: XCTestCase {
    func testJSONDeepEquality() throws {
        func json(_ text: String) throws -> Any {
            try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        }
        let pairs = [
            (#"{"array":["text",1,true,null,{"nested":2}],"empty":{}}"#,
             #"{"empty":{},"array":["text",1.0,true,null,{"nested":2.0}]}"#, true),
            (#"[1,2]"#, #"[2,1]"#, false),
            (#"{"a":null}"#, #"{}"#, false),
            (#"{"a":1}"#, #"{"b":1}"#, false),
            (#""1""#, #"1"#, false),
            (#"true"#, #"1"#, true),
            (#"false"#, #"0"#, true),
            (#"true"#, #"false"#, false),
            (#"null"#, #"null"#, true),
            (#"null"#, #"false"#, false),
            (#"[]"#, #"{}"#, false),
        ]
        for (left, right, expected) in pairs {
            let a = try json(left), b = try json(right)
            XCTAssertEqual(DefaultsFile.jsonEqual(a, b), expected, "\(left) vs \(right)")
            #if os(macOS)
            XCTAssertEqual(DefaultsFile.jsonEqual(a, b), (a as AnyObject).isEqual(b))
            #endif
        }
    }

    func testStringsParserHandlesCommentsEscapesAndRejectsIncompleteTables() {
        let text = #"/* heading */ "a" = "line\nquote\"slash\\"; // trailing comment"#
        XCTAssertEqual(StringsTable.parse(text), ["a": "line\nquote\"slash\\"])
        XCTAssertEqual(StringsTable.parse(#""unicode" = "\U0041\UD83D\UDE00";"#), ["unicode": "A😀"])
        XCTAssertEqual(StringsTable.parse("/* empty */"), [:])
        XCTAssertNil(StringsTable.parse(#""a" = "value""#))
        XCTAssertNil(StringsTable.parse(#""a" = "unterminated;"#))
        XCTAssertNil(StringsTable.parse("/* unterminated"))
    }

    #if os(macOS)
    func testPortableStringsParserMatchesFoundationForEveryTranslation() throws {
        let languages = L10n.available(in: L10nTests.resources)
        XCTAssertEqual(languages.count, 9)
        for language in languages {
            let url = L10nTests.resources.appendingPathComponent("\(language).lproj/Localizable.strings")
            let foundation = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], language)
            let portable = try XCTUnwrap(StringsTable.parse(try String(contentsOf: url, encoding: .utf8)), language)
            XCTAssertEqual(portable, foundation, language)
        }
    }
    #endif

    #if os(Windows)
    func testLocateWindowsExecutablesAndShims() throws {
        let command = try XCTUnwrap(Proc.locate("cmd"), "Search the semicolon-separated Windows PATH")
        XCTAssertEqual(URL(fileURLWithPath: command).lastPathComponent.lowercased(), "cmd.exe")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for ext in ["exe", "cmd", "bat"] {
            let name = "slashcommand-test-\(ext)"
            let file = directory.appendingPathComponent("\(name).\(ext)")
            try Data().write(to: file)
            XCTAssertEqual(Proc.locate(name, extra: [directory.path]), file.path)
            XCTAssertEqual(Proc.locate("\(name).\(ext)", extra: [directory.path]), file.path)
        }
        // An extensionless shell script next to the .cmd shim (npm, Electron apps) is not what cmd.exe would run.
        try Data("#!/bin/sh".utf8).write(to: directory.appendingPathComponent("slashcommand-shim"))
        let shim = directory.appendingPathComponent("slashcommand-shim.cmd")
        try Data().write(to: shim)
        XCTAssertEqual(Proc.locate("slashcommand-shim", extra: [directory.path]), shim.path)
        XCTAssertNil(Proc.locate("slashcommand-only-script", extra: [directory.path]))
        try Data("#!/bin/sh".utf8).write(to: directory.appendingPathComponent("slashcommand-only-script"))
        XCTAssertNil(Proc.locate("slashcommand-only-script", extra: [directory.path]), "A bare file without a PATHEXT extension is not runnable")
        let folder = directory.appendingPathComponent("folder.exe")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNil(Proc.locate("folder", extra: [directory.path]))
    }
    #endif
}
