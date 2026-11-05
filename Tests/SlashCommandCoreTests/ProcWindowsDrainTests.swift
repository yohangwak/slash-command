#if os(Windows)
import XCTest
@testable import SlashCommandCore

final class ProcWindowsDrainTests: XCTestCase {
    /// A grandchild (ping, about nine seconds) keeps inheriting the stdout and stderr pipes after the child has exited.
    func testExitedChildDoesNotWaitForGrandchildPipeEOF() throws {
        let powershell = try XCTUnwrap(Proc.locate("powershell"))
        let script = "Start-Process ping.exe -ArgumentList '-n','10','127.0.0.1' -NoNewWindow; [Console]::Out.WriteLine('started')"
        let started = Date()
        let result = Proc.run(powershell, ["-NoProfile", "-Command", script], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        XCTAssertTrue(result.out.contains("started"), result.out)
        XCTAssertFalse(result.timedOut)
    }
}
#endif
