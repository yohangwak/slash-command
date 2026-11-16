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

    /// What the lookup ended with.
    public enum Result: Equatable {
        /// A hotkey would find the visible terminal.
        case found
        /// Refused, with the reader's count-only line and conclusion. `notATerminal` (a browser, file or chat tab in front) means the
        /// reader worked.
        case refused(outcome: String?, diagnostic: String?)
        /// Failed before or after the tab strip without a reader line (Orca's terminal list could not be read, for example).
        case otherFailure

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
            case .otherFailure: return false
            }
        }
    }

    /// `Orca <version> (pid N) check: tabs readable (…)` or `tabs NOT readable (…)`. Counts and fixed words only.
    public static func line(orcaVersion: String?, pid: Int32, result: Result) -> String {
        let detail: String
        switch result {
        case .found: detail = "a hotkey would find the visible terminal"
        case .refused(_, let diagnostic): detail = diagnostic ?? "refused"
        case .otherFailure: detail = "Orca's terminal list could not be read"
        }
        return "Orca \(OrcaView.StripStats.cleanVersion(orcaVersion)) (pid \(pid)) check: tabs \(result.readable ? "readable" : "NOT readable") (\(detail))"
    }
}
