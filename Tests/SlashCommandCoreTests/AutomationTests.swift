import XCTest
@testable import SlashCommandCore

final class AutomationConsentTests: XCTestCase {
    private let iterm = Detector.itermBundleID

    /// A fake state that answers in order. It records what was asked (`ask`).
    private final class Fake {
        var answers: [AutomationConsent?]
        var asked: [Bool] = []
        /// How long an answer takes to arrive once asked — imitates the time the permission dialog is up.
        var answerDelay: TimeInterval = 0
        /// Called right before the answer to the question is returned.
        var beforeAnswer: () -> Void = {}
        init(_ answers: [AutomationConsent?]) { self.answers = answers }
        func status(_ bundleID: String, _ ask: Bool) -> AutomationConsent? {
            asked.append(ask)
            if ask, answerDelay > 0 { Thread.sleep(forTimeInterval: answerDelay) }
            if ask { beforeAnswer() }
            return answers.removeFirst()
        }
    }

    /// A flag that may be set from another thread.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func raise() { lock.lock(); count += 1; lock.unlock() }
        var raised: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// The order of events that happened on several threads.
    private final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ item: String) { lock.lock(); list.append(item); lock.unlock() }
        var items: [String] { lock.lock(); defer { lock.unlock() }; return list }
    }

    func testClassifiesTheSystemAnswers() {
        XCTAssertEqual(AutomationConsent.classify(noErr), .allowed)
        XCTAssertEqual(AutomationConsent.classify(OSStatus(errAEEventNotPermitted)), .denied)
        XCTAssertEqual(AutomationConsent.classify(OSStatus(procNotFound)), .notRunning)
        XCTAssertEqual(AutomationConsent.classify(-1744), .notAsked)
    }

    func testAllowedGoesOnWithoutAsking() throws {
        let fake = Fake([.allowed])
        var notified = false
        XCTAssertFalse(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", willAsk: { notified = true }, status: fake.status))
        XCTAssertEqual(fake.asked, [false])
        XCTAssertFalse(notified)
    }

    func testNotAskedAsksAndWaitsForTheAnswer() throws {
        let fake = Fake([.notAsked, .allowed])
        var notified = false
        XCTAssertTrue(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", willAsk: { notified = true }, status: fake.status))
        XCTAssertEqual(fake.asked, [false, true])
        XCTAssertTrue(notified)
    }

    func testAlreadyDeniedPointsAtTheSettings() {
        let fake = Fake([.denied])
        XCTAssertThrowsError(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", status: fake.status)) { error in
            let error = error as? SlashCommandError
            XCTAssertEqual(error?.needsAutomation, true)
            XCTAssertTrue(error?.message.contains("iTerm2") == true)
        }
        XCTAssertEqual(fake.asked, [false])
    }

    /// If the user just refused in the dialog, the settings screen is not opened as well (an error with no indication).
    func testDeniedInThePromptDoesNotOpenTheSettings() {
        let fake = Fake([.notAsked, .denied])
        XCTAssertThrowsError(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", status: fake.status)) { error in
            XCTAssertEqual((error as? SlashCommandError)?.needsAutomation, false)
        }
    }

    /// If there is no answer (the target app is stuck) or it could not be asked, do not block — the script decides for itself.
    func testNoAnswerDoesNotBlock() throws {
        let silent = Fake([nil])
        XCTAssertFalse(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", status: silent.status))
        XCTAssertEqual(silent.asked, [false])
        XCTAssertFalse(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", status: Fake([.notAsked, .notAsked]).status))
        XCTAssertFalse(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", status: Fake([.notAsked, nil]).status))
    }

    /// If permission is not confirmed (an answer like «not running»), ask to confirm — if already allowed, it returns immediately without a dialog.
    func testUnconfirmedIsSettledByAsking() throws {
        let fake = Fake([.notRunning, .allowed])
        var notified = false
        var notes: [String] = []
        XCTAssertFalse(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", willAsk: { notified = true }, note: { notes.append($0) }, status: fake.status))
        XCTAssertEqual(fake.asked, [false, true])
        XCTAssertFalse(notified)
        XCTAssertEqual(notes, ["automation iTerm2: not confirmed — asking"])
        XCTAssertThrowsError(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", status: Fake([.notRunning, .denied]).status))
    }

    /// Even if the first check says «not confirmed», a late answer after asking means the permission dialog is up — notify then, and treat the dialog as shown
    /// (Ghostty on a test Mac, 2026-10-13: the dialog appeared but there was no notice).
    func testUnconfirmedTellsOnceTheAnswerIsLate() throws {
        let fake = Fake([.notRunning, .allowed])
        fake.answerDelay = 0.3
        let told = Flag()
        XCTAssertTrue(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", willAsk: told.raise, lateAfter: 0.05, status: fake.status))
        XCTAssertEqual(fake.asked, [false, true])
        XCTAssertEqual(told.raised, 1)
    }

    /// If the answer came right away (no dialog appeared), it does not notify later either.
    func testUnconfirmedStaysQuietWhenTheAnswerIsQuick() throws {
        let fake = Fake([.notRunning, .allowed])
        let told = Flag()
        XCTAssertFalse(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", willAsk: told.raise, lateAfter: 0.05, status: fake.status))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(told.raised, 0)
    }

    /// If «not asked yet», it notifies once before asking — it does not notify again even if the answer is late.
    func testNotAskedTellsExactlyOnce() throws {
        let fake = Fake([.notAsked, .allowed])
        fake.answerDelay = 0.2
        let told = Flag()
        XCTAssertTrue(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", willAsk: told.raise, lateAfter: 0.05, status: fake.status))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(told.raised, 1)
    }

    /// If a late notice has already started, the answer is returned only after it finishes — so the late «please allow» does not cover
    /// the result notification the caller shows next (#35 review: when the answer arrived at that very moment, the notice queued behind the result).
    func testAnswerWaitsForANoticeAlreadyUnderWay() {
        let fake = Fake([.notRunning, .denied])
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let order = Order()
        // The answer to the question arrives «after» the notice has started.
        fake.beforeAnswer = { started.wait() }
        let iterm = self.iterm
        DispatchQueue.global().async {
            _ = try? AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", willAsk: {
                started.signal()
                release.wait()
                order.add("notice")
            }, lateAfter: 0.01, status: fake.status)
            order.add("answered")
            finished.signal()
        }
        // The answer has arrived but the notice has not finished yet — it must not return.
        XCTAssertEqual(finished.wait(timeout: .now() + 0.4), .timedOut)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(order.items, ["notice", "answered"])
    }

    /// When the permission dialog closes the terminal comes back to the front shortly — wait for that for a moment.
    func testGoesOnWhenTheTerminalIsInFrontAgain() throws {
        var answers: [String?] = ["com.apple.UserNotificationCenter", nil, iterm]
        var pauses = 0
        try AutomationConsent.requireFront(bundleID: iterm, appName: "iTerm2", frontmost: { answers.removeFirst() }, pause: { pauses += 1 })
        XCTAssertEqual(pauses, 2)
        XCTAssertTrue(answers.isEmpty)
    }

    /// If the user moved to another app while answering, nothing is sent (neither changing the terminal behind nor retargeting to the app now in front).
    func testStopsWhenAnotherAppStaysInFront() {
        var asked = 0
        XCTAssertThrowsError(try AutomationConsent.requireFront(bundleID: iterm, appName: "iTerm2", tries: 5,
                                                                frontmost: { asked += 1; return Detector.weztermBundleID }, pause: {})) { error in
            let error = error as? SlashCommandError
            XCTAssertEqual(error?.nothingToDo, true)
            XCTAssertTrue(error?.message.contains("iTerm2") == true)
        }
        XCTAssertEqual(asked, 5)
    }

    /// A terminal not driven by AppleScript is neither asked nor read.
    func testOtherTerminalsAreNotChecked() throws {
        let fake = Fake([])
        XCTAssertFalse(try AutomationConsent.ensure(bundleID: Detector.weztermBundleID, appName: "WezTerm", status: fake.status))
        XCTAssertFalse(try AutomationConsent.ensure(bundleID: Detector.orcaBundleID, appName: "Orca", status: fake.status))
        XCTAssertTrue(fake.asked.isEmpty)
    }
}

final class ProcTests: XCTestCase {
    func testReturnsOutputAndStatus() {
        let result = Proc.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        XCTAssertEqual(result.out, "out\n")
        XCTAssertEqual(result.err, "err\n")
        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.ok)
    }

    /// It knows right away when the process finished — when it waited by spinning the run loop, one call took about 65ms (13 s for 200 calls), and missing the finish meant waiting until the timeout.
    func testManyShortRunsFinishPromptly() {
        let start = Date()
        for _ in 0..<200 {
            let result = Proc.run("/usr/bin/true", [], timeout: 5)
            XCTAssertTrue(result.ok)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    /// The same when called from several worker threads at once (the app calls it from a work queue).
    func testConcurrentRunsFinishPromptly() {
        let start = Date()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<25 { XCTAssertTrue(Proc.run("/usr/bin/true", [], timeout: 5).ok) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
    }

    func testTimeoutStopsTheChild() {
        let start = Date()
        let result = Proc.run("/bin/sleep", ["30"], timeout: 0.3)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.ok)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// A child that ignores SIGTERM is killed forcibly — otherwise reading its output would wait forever.
    func testChildIgnoringTerminateIsKilled() {
        let start = Date()
        let result = Proc.run("/usr/bin/perl", ["-e", "$SIG{TERM} = 'IGNORE'; sleep 30"], timeout: 0.3)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testMissingExecutableIsAFailureNotACrash() {
        let result = Proc.run("/nonexistent/slashcommand-test", [])
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, -1)
    }
}
