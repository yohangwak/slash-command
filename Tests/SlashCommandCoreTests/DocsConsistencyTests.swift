import XCTest
import Foundation
@testable import SlashCommandCore

/// Keeps the docs that are easy to forget in step with the original or with the code:
/// the four README translations against `README.md`, and the "Versions" table in `docs/agents.md` against `AgentVersions.tested`.
final class DocsConsistencyTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func read(_ relativePath: String) throws -> [String] {
        let url = relativePath.split(separator: "/").reduce(Self.root) { $0.appendingPathComponent(String($1)) }
        let text = try String(contentsOf: url, encoding: .utf8)
        // Accept CRLF checkouts (Windows CI).
        return text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    // MARK: - README translations

    private struct Shape: Equatable {
        var headings = 0
        var fences = 0
        var links: Set<String> = []
    }

    private static let linkPattern = try! NSRegularExpression(pattern: #"\]\(([^)\s]+)"#)

    /// Counts `#` heading lines outside code fences, the fence lines themselves, and the set of link targets.
    /// The language switcher links (`README*.md`) are not counted, because each file leaves out its own.
    private func shape(of lines: [String]) -> Shape {
        var shape = Shape()
        var inFence = false
        for line in lines {
            if line.hasPrefix("```") {
                shape.fences += 1
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if line.hasPrefix("#") { shape.headings += 1 }
            let range = NSRange(line.startIndex..., in: line)
            for match in Self.linkPattern.matches(in: line, range: range) {
                guard let r = Range(match.range(at: 1), in: line) else { continue }
                let target = String(line[r])
                if target.hasPrefix("README") && target.hasSuffix(".md") { continue }
                shape.links.insert(target)
            }
        }
        return shape
    }

    func testReadmeTranslationsHaveTheSameStructureAsTheOriginal() throws {
        let original = shape(of: try read("README.md"))
        XCTAssertGreaterThan(original.headings, 0, "README.md: no headings found, the parser is not seeing the file")
        XCTAssertFalse(original.links.isEmpty, "README.md: no links found, the parser is not seeing the file")
        for language in ["es", "ja", "ko", "zh-CN"] {
            let name = "README.\(language).md"
            let translated = shape(of: try read(name))
            XCTAssertEqual(translated.headings, original.headings, "\(name): heading lines \(translated.headings), README.md has \(original.headings)")
            XCTAssertEqual(translated.fences, original.fences, "\(name): code fence lines \(translated.fences), README.md has \(original.fences)")
            let missing = original.links.subtracting(translated.links).sorted()
            let extra = translated.links.subtracting(original.links).sorted()
            XCTAssertTrue(missing.isEmpty && extra.isEmpty, "\(name): links missing from the translation: \(missing); links not in README.md: \(extra)")
        }
    }

    // MARK: - docs/agents.md versions table

    private static let agentNames: [String: Agent] = [
        "Claude Code": .claude,
        "Codex": .codex,
        "Grok": .grok,
        "Cursor Agent": .cursor,
        "Antigravity": .antigravity,
        "OpenCode": .opencode,
    ]

    /// `2.1.283, 2.1.288` becomes two versions. `2026.10.01 (14929f9, e373342)` becomes `2026.10.01-14929f9` and `2026.10.01-e373342`.
    private func versions(fromCell cell: String) -> Set<String> {
        let cell = cell.trimmingCharacters(in: .whitespaces)
        if let open = cell.firstIndex(of: "("), cell.hasSuffix(")") {
            let base = cell[..<open].trimmingCharacters(in: .whitespaces)
            let inner = cell[cell.index(after: open)..<cell.index(before: cell.endIndex)]
            return Set(inner.split(separator: ",").map { "\(base)-\($0.trimmingCharacters(in: .whitespaces))" })
        }
        return Set(cell.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    func testAgentsDocVersionTableMatchesTestedVersions() throws {
        let lines = try read("docs/agents.md")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Versions" }) else {
            return XCTFail("docs/agents.md: no `## Versions` section")
        }
        var documented: [Agent: Set<String>] = [:]
        for line in lines[(start + 1)...] {
            if line.hasPrefix("## ") { break }
            guard line.hasPrefix("|") else { continue }
            let cells = line.split(separator: "|", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 2, cells[0] != "Agent", !cells[0].hasPrefix("---") else { continue }
            guard let agent = Self.agentNames[cells[0]] else {
                XCTFail("docs/agents.md: table row for an agent this test does not know: \(cells[0])")
                continue
            }
            documented[agent] = versions(fromCell: cells[1])
        }
        XCTAssertFalse(documented.isEmpty, "docs/agents.md: the Versions table has no rows")
        for agent in Agent.allCases {
            let doc = documented[agent] ?? []
            let code = AgentVersions.tested[agent] ?? []
            XCTAssertEqual(doc, code, "docs/agents.md vs AgentVersions.tested for \(agent.rawValue): only in the doc \(doc.subtracting(code).sorted()); only in the code \(code.subtracting(doc).sorted())")
        }
    }
}
