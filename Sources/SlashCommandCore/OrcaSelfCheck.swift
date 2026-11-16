import Foundation

/// The app's check after each Orca start (macOS): a minute after Orca takes the request to make its tabs readable, the hotkey's own
/// lookup (`Detector.orcaActive` for that Orca process) runs once, silently — no keys, nothing sent — and the result goes to the log
/// as counts only; if a hotkey would be refused, once more two minutes later. An Orca update this reader cannot follow then shows up
/// in the log at the first Orca start after it, on every Mac, instead of at a refused hotkey.
public enum OrcaSelfCheck {
    /// After Orca took the request: its page took 12 to 46 seconds to appear (Orca 1.4.259, measured 2026-11-15).
    public static let firstDelay: TimeInterval = 60
    /// The one more read when the first would have refused a hotkey.
    public static let secondDelay: TimeInterval = 120
    /// While the display is asleep or the screen locked, how often to look again. Orca leaves its page out of the accessibility tree
    /// then (measured 2026-11-15 and 11-16: the window answers with the application itself and no page), so a read would report a
    /// broken reader that is not broken.
    public static let screenPoll: TimeInterval = 30

    /// Run the check only when the screen was usable at this look and at the one before (not in the moment it wakes).
    public static func screenAllows(awakeNow: Bool, awakeBefore: Bool) -> Bool { awakeNow && awakeBefore }

    /// What the lookup ended with.
    public enum Result: Equatable {
        /// A hotkey would find the visible terminal.
        case found
        /// Refused, with the reader's count-only line and conclusion. `notATerminal` (a browser, file or chat tab in front) means the
        /// reader worked.
        case refused(outcome: String?, diagnostic: String?)
        /// Failed before or after the tab strip without a reader line (Orca's terminal list could not be read, for example).
        case otherFailure
        /// Not run: Orca's runtime, which answers the terminal and session lists, belongs to another Orca process (Pullfrog #64), so
        /// that process's lists would be judged against this one's screen.
        case otherRuntime

        /// Not run yet: Orca's runtime information could not be read (not written yet, say). Tried again like a failure.
        case runtimeUnknown

        /// nil when the runtime is this Orca process; `.runtimeUnknown` when it cannot be read; `.otherRuntime` when it is another.
        public static func runtime(_ runtimePID: Int32?, checking pid: Int32) -> Result? {
            guard let runtimePID else { return .runtimeUnknown }
            return runtimePID == pid ? nil : .otherRuntime
        }

        public init(error: Error?) {
            guard let error else { self = .found; return }
            if let refusal = error as? SlashCommandError, refusal.diagnostic != nil {
                self = .refused(outcome: refusal.diagnosticOutcome, diagnostic: refusal.diagnostic)
            } else {
                self = .otherFailure
            }
        }

        /// Whether a hotkey pressed in a terminal would work: the lookup found the terminal, or the reader worked and a tab that is not
        /// a terminal is in front.
        public var readable: Bool {
            switch self {
            case .found: return true
            case .refused(let outcome, _): return outcome == "notATerminal"
            case .otherFailure, .otherRuntime, .runtimeUnknown: return false
            }
        }

        /// Whether a second look two minutes later could change the answer.
        public var worthRetrying: Bool { !readable && self != .otherRuntime }
    }

    /// `Orca <version> (pid N) check: tabs readable (…)` or `tabs NOT readable (…)`. Counts and fixed words only.
    public static func line(orcaVersion: String?, pid: Int32, result: Result) -> String {
        let detail: String
        switch result {
        case .found: detail = "a hotkey would find the visible terminal"
        case .refused(_, let diagnostic): detail = diagnostic ?? "refused"
        case .otherFailure: detail = "Orca's terminal list could not be read"
        case .runtimeUnknown: detail = "Orca's runtime information could not be read"
        case .otherRuntime:
            return "Orca \(OrcaView.StripStats.cleanVersion(orcaVersion)) (pid \(pid)) check: skipped (Orca's runtime is another Orca process)"
        }
        return "Orca \(OrcaView.StripStats.cleanVersion(orcaVersion)) (pid \(pid)) check: tabs \(result.readable ? "readable" : "NOT readable") (\(detail))"
    }
}
