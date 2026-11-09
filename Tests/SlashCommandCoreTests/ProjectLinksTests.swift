import XCTest
@testable import SlashCommandCore

final class ProjectLinksTests: XCTestCase {
    func testBugReportFillsTheFormFieldsByID() {
        let url = ProjectLinks.bugReport(appVersion: "0.2.5", system: "macOS 26.1.0", agents: "Claude Code 2.1.319 · Codex 0.162.0")
        XCTAssertEqual(url.absoluteString,
                       "https://github.com/yohangwak/slash-command/issues/new?template=bug_report.yml&version=0.2.5"
                       + "&macos=macOS%2026.1.0&agent=Claude%20Code%202.1.319%20%C2%B7%20Codex%200.162.0")
    }

    func testEmptyValuesAreLeftOut() {
        let url = ProjectLinks.bugReport(appVersion: "0.2.5", system: "Windows 10.0.26100", agents: "")
        XCTAssertEqual(url.query, "template=bug_report.yml&version=0.2.5&macos=Windows%2010.0.26100")
    }

    /// `+` would read as a space, and `&`, `=`, `#` would cut the query, so every reserved character is encoded.
    func testReservedCharactersCannotChangeTheQuery() {
        XCTAssertEqual(ProjectLinks.encode("1.0+build&x=y#z"), "1.0%2Bbuild%26x%3Dy%23z")
        XCTAssertEqual(ProjectLinks.encode("2026.10.01-14929f9_~"), "2026.10.01-14929f9_~")
    }

    func testAgentSummaryKeepsTheAgentOrderAndSkipsMissingOnes() {
        XCTAssertEqual(ProjectLinks.agentSummary([.codex: "0.162.0", .claude: "2.1.319"]), "Claude Code 2.1.319 · Codex 0.162.0")
        XCTAssertEqual(ProjectLinks.agentSummary([:]), "")
    }

    func testSystemDescriptionNamesTheSystemAndAThreePartVersion() {
        let text = ProjectLinks.systemDescription
        #if os(Windows)
        XCTAssertTrue(text.hasPrefix("Windows "), text)
        #else
        XCTAssertTrue(text.hasPrefix("macOS "), text)
        #endif
        XCTAssertEqual(text.split(separator: " ").last?.split(separator: ".").count, 3, text)
    }

    func testAppVersionIsTheBundleVersion() throws {
        let data = try Data(contentsOf: L10nTests.root.appendingPathComponent("scripts/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(ProjectLinks.appVersion, plist?["CFBundleShortVersionString"] as? String)
    }

    /// The query names must stay the ids in the issue form, or GitHub silently leaves the fields empty.
    func testIssueFormHasTheFieldsTheLinkFills() throws {
        let form = try String(contentsOf: L10nTests.root.appendingPathComponent(".github/ISSUE_TEMPLATE/bug_report.yml"), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n") // a Windows checkout has CRLF line ends
        for id in ["version", "macos", "agent"] {
            XCTAssertTrue(form.contains("id: \(id)\n"), id)
        }
    }

    func testLinksStayOnTheProjectRepository() {
        XCTAssertEqual(ProjectLinks.discussions.absoluteString, "https://github.com/yohangwak/slash-command/discussions")
        XCTAssertEqual(ProjectLinks.releases.absoluteString, "https://github.com/yohangwak/slash-command/releases")
    }
}
