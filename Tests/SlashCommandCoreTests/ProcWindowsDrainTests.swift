#if os(Windows)
import XCTest
@testable import SlashCommandCore

final class ProcWindowsDrainTests: XCTestCase {
    /// A grandchild (ping, about thirty seconds) keeps inheriting the stdout and stderr pipes after the child has exited.
    /// The timeout is generous because PowerShell can take several seconds to start on a busy runner; waiting for the grandchild would take thirty.
    func testExitedChildDoesNotWaitForGrandchildPipeEOF() throws {
        let powershell = try XCTUnwrap(Proc.locate("powershell"))
        let script = "Start-Process ping.exe -ArgumentList '-n','31','127.0.0.1' -NoNewWindow; [Console]::Out.WriteLine('started')"
        let started = Date()
        let result = Proc.run(powershell, ["-NoProfile", "-Command", script], timeout: 20)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        XCTAssertTrue(result.out.contains("started"), result.out)
        XCTAssertFalse(result.timedOut)
    }
}
#endif
