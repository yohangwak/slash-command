import Foundation

/// The app's check after each Orca start (macOS): a minute after Orca takes the request to make its tabs readable, the tab strip is
/// read once, silently, and the result goes to the log as counts only; if it is not readable, once more two minutes later.
/// An Orca update this reader cannot follow then shows up in the log at the first Orca start after it, on every Mac, instead of at a
/// refused hotkey.
public enum OrcaSelfCheck {
    /// After Orca took the request: its page took 12 to 46 seconds to appear (Orca 1.4.259, measured 2026-11-15).
    public static let firstDelay: TimeInterval = 60
    /// The one more read when the first found no strip.
    public static let secondDelay: TimeInterval = 120

    /// `Orca <version> (pid N) check: tabs readable (<counts>)`, or `tabs NOT readable`. Counts only (`OrcaView.StripStats.summary`).
    public static func line(orcaVersion: String?, pid: Int32, readable: Bool, stats: OrcaView.StripStats) -> String {
        "Orca \(OrcaView.StripStats.cleanVersion(orcaVersion)) (pid \(pid)) check: tabs \(readable ? "readable" : "NOT readable") (\(stats.summary))"
    }
}
