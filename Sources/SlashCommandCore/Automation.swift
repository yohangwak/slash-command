#if os(macOS)
import AppKit

/// macOS "Automation" permission — may this process drive that app with AppleScript?
public enum AutomationConsent: Equatable, Sendable {
    case allowed
    case denied
    /// Never asked yet — the system asks the first time the app is driven.
    case notAsked
    case notRunning

    /// Terminals driven with AppleScript.
    public static let scriptedBundleIDs: Set<String> = [Detector.ghosttyBundleID, Detector.itermBundleID]

    static func classify(_ status: OSStatus) -> AutomationConsent {
        switch status {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .notAsked     // errAEEventWouldRequireUserConsent (-1744), etc.
        }
    }

    /// The current permission state. When `ask` is true and the user has not been asked yet, the system shows the permission dialog and waits "until it is answered" —
    /// do not call it that way on the main thread. If the target app does not respond, it can take a long time even without asking.
    public static func status(bundleID: String, ask: Bool = false) -> AutomationConsent {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return .notRunning }
        return classify(rawStatus(bundleID: bundleID, ask: ask))
    }

    /// The number exactly as the system gave it (0 allowed, -1743 denied, -1744 not asked yet, -600 not running).
    public static func rawStatus(bundleID: String, ask: Bool = false) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
    }

    /// The result read without asking, and the number the system gave (for logging).
    struct Reading: Sendable {
        let consent: AutomationConsent
        let detail: String
    }

    /// Asks the system directly — does not pre-filter with "is it running" via `NSRunningApplication`. For an app that launched "after" our app started,
    /// that list is sometimes not visible from another thread, and the frontmost terminal was read as "not running" (2026-10-13, Ghostty on a test Mac,
    /// 2 times out of 2 — log `first check: no running app with that id`). If it really is not running, the system returns -600.
    static func read(bundleID: String) -> Reading {
        let raw = rawStatus(bundleID: bundleID)
        return Reading(consent: classify(raw), detail: "status \(raw)")
    }

    /// Reads without asking, but waits only up to `seconds` (the usual answer takes a few ms). If the target app does not respond, this check can also go unanswered —
    /// then nil (unknown), and the caller does not block and leaves it to the script's response limit.
    static func bounded(bundleID: String, seconds: TimeInterval = 2) -> Reading? {
        final class Answer: @unchecked Sendable { var value: Reading? }
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            answer.value = read(bundleID: bundleID)
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success ? answer.value : nil
    }

    /// Announces once that the permission dialog is showing. Does not announce after it is closed.
    ///
    /// The announcement is called while holding the lock — if an announcement has already started, `close()` waits until it finishes. Otherwise, when the answer arrives
    /// at that very moment, the caller's result notification would queue first and the belated "please allow" notice would overwrite it (#35 review).
    /// So the announcement (`willAsk`) must finish quickly and must not call `ensure` again.
    private final class Notice: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (() -> Void)?
        private var fired = false

        init(_ action: @escaping () -> Void) { self.action = action }

        func fire() {
            lock.lock()
            defer { lock.unlock() }
            guard let run = action else { return }
            action = nil
            fired = true
            run()
        }

        func fire(after seconds: TimeInterval) {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { self.fire() }
        }

        /// No more announcements (an announcement already started returns after it finishes). True if one was announced.
        func close() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            action = nil
            return fired
        }
    }

    /// Checks the permission before driving that terminal, and if the user has not been asked yet, asks "here" and waits for the answer.
    ///
    /// If a script were sent without asking, the system would show the permission dialog at that moment, but scripts have a response limit (5 s),
    /// and if the user cannot click in time, the dialog disappears and no answer is recorded — a 5-second dialog appears and vanishes on every press (measured 2026-10-12, iTerm2 on a test Mac).
    /// Returns true if the dialog was shown and the permission granted (the frontmost app may have changed meanwhile — the caller checks again).
    /// If it is already off, throws an error with `needsAutomation` set; if the user just denied it in the dialog, an error without that mark.
    /// `willAsk` is called once when the dialog appears (or when we learn it is showing) — it may be called from another thread and must finish quickly
    /// (the answer is not returned until it finishes).
    /// `note` receives, in one line, what was seen when the permission was "not confirmed" (for logging — carries the basis of the first check and the number after asking).
    @discardableResult
    public static func ensure(bundleID: String, appName: String, willAsk: @escaping () -> Void = {}, note: (String) -> Void = { _ in }) throws -> Bool {
        var seen: [String] = []
        return try ensure(bundleID: bundleID, appName: appName, willAsk: willAsk,
                          note: { note(seen.isEmpty ? $0 : "\($0) [\(seen.joined(separator: " · "))]") },
                          status: { id, ask in
            // When asking, "is it running" is not checked separately — it is the frontmost terminal, and if already permitted this returns immediately.
            if ask {
                let raw = rawStatus(bundleID: id, ask: true)
                seen.append("asked: status \(raw)")
                return classify(raw)
            }
            let reading = bounded(bundleID: id)
            seen.append("first check: \(reading?.detail ?? "no answer")")
            return reading?.consent
        })
    }

    /// `status(bundle id, whether to ask)` returns nil when there is no answer. If there is still no answer `lateAfter` seconds after asking, the permission dialog is assumed to be showing.
    static func ensure(bundleID: String, appName: String, willAsk: @escaping () -> Void = {}, note: (String) -> Void = { _ in },
                       lateAfter: TimeInterval = 1,
                       status: (_ bundleID: String, _ ask: Bool) -> AutomationConsent?) throws -> Bool {
        guard scriptedBundleIDs.contains(bundleID) else { return false }
        let off = loc("Not sent: Automation for %@ is turned off. Turn it on in System Settings → Privacy & Security → Automation, then press again.", appName)
        let first = status(bundleID, false)
        switch first {
        case .allowed:
            return false
        case nil:
            // The target app does not answer — do not block; leave it to the script's response limit.
            note("automation \(appName): no answer")
            return false
        case .denied:
            note("automation \(appName): denied")
            var error = SlashCommandError(off)
            error.needsAutomation = true
            throw error
        case .notAsked, .notRunning:
            break
        }
        // The permission is not confirmed. Ask to confirm — if the dialog appears, wait for the answer.
        note("automation \(appName): \(first == .notAsked ? "not asked yet" : "not confirmed") — asking")
        // If "not asked yet", we know the dialog will appear — announce right away. For any other answer we only know by asking: if the answer is late, the dialog is showing, so
        // announce then (2026-10-13, Ghostty on a test Mac: it was frontmost, the first check said "not confirmed", and the dialog appeared but there was no notice).
        let notice = Notice(willAsk)
        if first == .notAsked { notice.fire() } else { notice.fire(after: lateAfter) }
        let answer = status(bundleID, true)
        // That the dialog appeared is known from "not asked yet" or from a late answer — same as having announced.
        let prompted = notice.close()
        switch answer {
        case .allowed: return prompted
        case .denied: throw SlashCommandError(off)
        // Could not ask, or an unknown answer — do not block; let the script decide for itself.
        case .notAsked, .notRunning, nil:
            note("automation \(appName): still not confirmed")
            return false
        }
    }

    /// Bundle id of the current frontmost app — used to read again "after" waiting for the permission dialog.
    /// In a process whose run loop is not running (a command-line tool), `NSWorkspace` keeps returning the value first read (measured 2026-10-12: after switching the front app it
    /// stayed the same for 6 s, and followed once the run loop was briefly run). So on the main thread it runs the run loop briefly and then reads; on other threads it asks the main thread.
    public static func frontBundleID() -> String? {
        if Thread.isMainThread {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        return DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    }

    /// While the permission dialog is showing, that dialog is frontmost, and the user may have gone to another app meanwhile.
    /// Waits briefly (2 s by default) for that terminal to be frontmost again, and if it does not, nothing is sent — nor is the target switched to whatever other app is frontmost now.
    public static func requireFront(bundleID: String, appName: String, tries: Int = 20,
                                    frontmost: () -> String? = AutomationConsent.frontBundleID,
                                    pause: () -> Void = { usleep(100_000) }) throws {
        for _ in 0..<tries {
            if frontmost() == bundleID { return }
            pause()
        }
        var error = SlashCommandError(loc("%@ is allowed now. Try again.", appName))
        error.nothingToDo = true
        throw error
    }
}
#endif
