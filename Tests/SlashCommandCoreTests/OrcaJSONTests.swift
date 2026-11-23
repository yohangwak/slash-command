import XCTest
@testable import SlashCommandCore

/// Orca cuts each terminal preview to 300 UTF-16 code units, which can leave half of an emoji in the JSON (2026-11-24).
final class OrcaJSONTests: XCTestCase {
    private func parse(_ text: String) -> [String: Any]? { OrcaJSON.object(text) }

    func testPlainJSONParsesAsBefore() {
        XCTAssertEqual(parse(#"{"ok":true,"result":{"preview":"abc"}}"#)?["ok"] as? Bool, true)
    }

    func testLoneLowSurrogateAtTheStartOfACutPreviewIsReplaced() throws {
        // What `JSON.stringify("🔴abc".slice(1))` writes: the low half of U+1F534 alone.
        let json = try XCTUnwrap(parse(#"{"ok":true,"result":{"preview":"\udd34abc"}}"#))
        XCTAssertEqual((json["result"] as? [String: Any])?["preview"] as? String, "\u{FFFD}abc")
    }

    func testLoneHighSurrogateIsReplaced() throws {
        let json = try XCTUnwrap(parse(#"{"a":"x\ud83d","b":"\uD83D y"}"#))
        XCTAssertEqual(json["a"] as? String, "x\u{FFFD}")
        XCTAssertEqual(json["b"] as? String, "\u{FFFD} y")
    }

    func testAHighSurrogateFollowedByAnotherHighOneIsReplacedAndTheValidPairAfterItKept() throws {
        let json = try XCTUnwrap(parse(#"{"a":"\ud83d🔴"}"#))
        XCTAssertEqual(json["a"] as? String, "\u{FFFD}🔴")
    }

    func testAValidPairIsLeftAlone() throws {
        let json = try XCTUnwrap(parse(#"{"a":"🔴 é"}"#))
        XCTAssertEqual(json["a"] as? String, "🔴 é")
    }

    func testAnEscapedBackslashBeforeULooksLikeAnEscapeButIsNot() throws {
        // `\\ud83d` is a backslash followed by the letters "ud83d", not an escape; next to a real lone half, only the half changes.
        let json = try XCTUnwrap(parse(#"{"a":"\\ud83d \udd34"}"#))
        XCTAssertEqual(json["a"] as? String, "\\ud83d \u{FFFD}")
    }

    func testBrokenJSONStillFails() {
        XCTAssertNil(parse(#"{"ok":true,"result":{"terminals":["#))
        XCTAssertNil(parse(#"{"a":"\udd34"#))
    }

    func testNothingToReplaceReturnsNil() {
        XCTAssertNil(OrcaJSON.replacingLoneSurrogateEscapes(Data(#"{"a":"🔴 \\u \n"}"#.utf8)))
    }

    func testSocketFrameWithAHalfEmojiIsAnAnswer() {
        let line = Data(#"{"id":"r1","ok":true,"result":{"terminals":[{"preview":"\udd34 done"}]}}"#.utf8)
        guard case .done(.success(let result)) = OrcaRuntime.frame(line, expectingID: "r1", runtimeID: nil) else {
            return XCTFail("a preview cut inside an emoji must not make the whole answer unreadable")
        }
        XCTAssertEqual(((result["terminals"] as? [[String: Any]])?.first)?["preview"] as? String, "\u{FFFD} done")
    }

    func testAnUnparseableAnswerFromACommandThatSucceededIsNotQuotedAsTheReason() {
        let result = ProcResult(status: 0, out: #"{"id":"r1","ok":true,"result":{"terminals":["#, err: "", timedOut: false)
        XCTAssertEqual(OrcaIO.errorSummary(result), loc("Could not parse the Orca app's response"))
    }

    func testAFailedCommandStillShowsWhatItSaid() {
        let result = ProcResult(status: 1, out: "", err: "orca: not running", timedOut: false)
        XCTAssertEqual(OrcaIO.errorSummary(result), "orca: not running")
    }
}
