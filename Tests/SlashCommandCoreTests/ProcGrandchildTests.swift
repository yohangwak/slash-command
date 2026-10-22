// Runs /bin/sh and perl, which a Windows runner does not have.
#if !os(Windows)
import XCTest
@testable import SlashCommandCore

final class ProcGrandchildTests: XCTestCase {
    func testExitedChildDoesNotWaitForGrandchildPipeEOF() {
        let started = Date()
        let result = Proc.run("/bin/sh", ["-c", "sleep 15 & echo started"], timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        XCTAssertTrue(result.out.contains("started"))
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testTimedOutChildDoesNotWaitForGrandchildPipeEOF() {
        let started = Date()
        let result = Proc.run("/bin/sh", ["-c", "sleep 15 & echo started; exec /bin/sleep 15"], timeout: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        XCTAssertTrue(result.out.contains("started"))
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.ok)
    }

    func testBothStreamsDrainWithoutTruncatingFastChildOutput() {
        let result = Proc.run("/usr/bin/perl", ["-e", "print STDOUT 'x' x 131072; print STDERR 'y' x 131072;"])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.out, String(repeating: "x", count: 131072))
        XCTAssertEqual(result.err, String(repeating: "y", count: 131072))
    }
}
#endif
