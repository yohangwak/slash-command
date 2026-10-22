#if os(macOS)
import XCTest
@testable import SlashCommandCore

final class ITermWideWrapTests: XCTestCase {
    func testWideCharactersWasteTheLastColumnBeforeWrapping() {
        XCTAssertEqual(ITermIO.visibleLines(from: "2\n3\n한한한\n", ambiguousIsDoubleWidth: false), [])
        XCTAssertEqual(ITermIO.visibleLines(from: "3\n3\n한한한\n", ambiguousIsDoubleWidth: false), ["한한한"])
    }

    func testScrollbackAboveWideWrappedLineIsExcluded() {
        XCTAssertEqual(ITermIO.visibleLines(from: "3\n3\n이전줄\n한한한\n", ambiguousIsDoubleWidth: false), ["한한한"])
    }

    func testExactlyFullASCIIStaysOnOneRow() {
        let line = String(repeating: "x", count: 80)
        XCTAssertEqual(ITermIO.visibleLines(from: "1\n80\n\(line)\n", ambiguousIsDoubleWidth: true), [line])
    }
}
#endif
