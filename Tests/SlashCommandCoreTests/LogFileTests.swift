import Foundation
import XCTest
@testable import SlashCommandCore

final class LogFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("logfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testWritesOneLineIntoAFolderThatDoesNotExist() throws {
        let url = root.appendingPathComponent("a/b/slashcommand.log")
        LogFile.append("hello\n", to: url)
        XCTAssertEqual(try lines(url), ["hello"])
    }

    func testRotatesToDotOnePastTheLimit() throws {
        let url = root.appendingPathComponent("slashcommand.log")
        LogFile.append("first line here\n", to: url, limit: 10)
        LogFile.append("second\n", to: url, limit: 10)
        let old = url.appendingPathExtension("1")
        XCTAssertEqual(try lines(old), ["first line here"])
        XCTAssertEqual(try lines(url), ["second"])
    }

    #if !os(Windows)
    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testNewFileIs0600AndNewFolderIs0700() throws {
        let url = root.appendingPathComponent("logs/slashcommand.log")
        LogFile.append("x\n", to: url)
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try mode(url.deletingLastPathComponent()), 0o700)
    }

    func testExistingFileWith0644BecomesOwnerOnly() throws {
        let url = root.appendingPathComponent("slashcommand.log")
        try Data("old\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        LogFile.append("new\n", to: url)
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try lines(url), ["old", "new"])
    }

    func testRotatedFileStartsOwnerOnly() throws {
        let url = root.appendingPathComponent("slashcommand.log")
        try Data("old old old old\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        LogFile.append("new\n", to: url, limit: 10)
        XCTAssertEqual(try mode(url), 0o600)
    }
    #endif

    #if !os(Windows)
    /// A folder and a rotated file left by an earlier version are made owner-only too.
    func testExistingFolderAndRotatedFileBecomeOwnerOnly() throws {
        let folder = root.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let url = folder.appendingPathComponent("app.log"), old = url.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.createFile(atPath: old.path, contents: Data("x\n".utf8), attributes: [.posixPermissions: 0o644]))
        LogFile.append("line\n", to: url)
        func mode(_ u: URL) throws -> Int { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber).intValue }
        XCTAssertEqual(try mode(folder), 0o700)
        XCTAssertEqual(try mode(old), 0o600)
        XCTAssertEqual(try mode(url), 0o600)
    }
    #endif
}
