import XCTest
@testable import SlashCommandCore

final class AutomationConsentTests: XCTestCase {
    private let iterm = Detector.itermBundleID

    /// 순서대로 답하는 가짜 상태. 무엇을 물었는지(`ask`) 적어 둔다.
    private final class Fake {
        var answers: [AutomationConsent?]
        var asked: [Bool] = []
        /// 물었을 때 답이 오기까지 걸리는 시간 — 허용 창이 떠 있는 동안을 흉내 낸다.
        var answerDelay: TimeInterval = 0
        init(_ answers: [AutomationConsent?]) { self.answers = answers }
        func status(_ bundleID: String, _ ask: Bool) -> AutomationConsent? {
            asked.append(ask)
            if ask, answerDelay > 0 { Thread.sleep(forTimeInterval: answerDelay) }
            return answers.removeFirst()
        }
    }

    /// 다른 스레드에서 불려도 되는 표시.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func raise() { lock.lock(); count += 1; lock.unlock() }
        var raised: Int { lock.lock(); defer { lock.unlock() }; return count }
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

    /// 방금 창에서 거절했다면 설정 화면까지 열지는 않는다(표시 없는 오류).
    func testDeniedInThePromptDoesNotOpenTheSettings() {
        let fake = Fake([.notAsked, .denied])
        XCTAssertThrowsError(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", status: fake.status)) { error in
            XCTAssertEqual((error as? SlashCommandError)?.needsAutomation, false)
        }
    }

    /// 답이 없거나(대상 앱이 멈췄다) 물을 수 없었으면 막지 않는다 — 스크립트가 스스로 판가름한다.
    func testNoAnswerDoesNotBlock() throws {
        let silent = Fake([nil])
        XCTAssertFalse(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", status: silent.status))
        XCTAssertEqual(silent.asked, [false])
        XCTAssertFalse(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", status: Fake([.notAsked, .notAsked]).status))
        XCTAssertFalse(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", status: Fake([.notAsked, nil]).status))
    }

    /// 허락이 확인되지 않으면(«실행 중이 아니다» 같은 답) 물어서 확인한다 — 이미 허락돼 있으면 창 없이 바로 돌아온다.
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

    /// 첫 확인이 «확인 안 됨» 이어도 물은 뒤 답이 늦으면 허용 창이 떠 있는 것이다 — 그때 알리고, 창을 띄운 것으로 친다
    /// (2026-10-13 집 맥 2 의 Ghostty: 창은 떴는데 안내가 없었다).
    func testUnconfirmedTellsOnceTheAnswerIsLate() throws {
        let fake = Fake([.notRunning, .allowed])
        fake.answerDelay = 0.3
        let told = Flag()
        XCTAssertTrue(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", willAsk: told.raise, lateAfter: 0.05, status: fake.status))
        XCTAssertEqual(fake.asked, [false, true])
        XCTAssertEqual(told.raised, 1)
    }

    /// 답이 바로 왔으면(창이 뜨지 않았다) 나중에도 알리지 않는다.
    func testUnconfirmedStaysQuietWhenTheAnswerIsQuick() throws {
        let fake = Fake([.notRunning, .allowed])
        let told = Flag()
        XCTAssertFalse(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", willAsk: told.raise, lateAfter: 0.05, status: fake.status))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(told.raised, 0)
    }

    /// «아직 묻지 않았다» 면 묻기 전에 한 번만 알린다 — 답이 늦어도 다시 알리지 않는다.
    func testNotAskedTellsExactlyOnce() throws {
        let fake = Fake([.notAsked, .allowed])
        fake.answerDelay = 0.2
        let told = Flag()
        XCTAssertTrue(try AutomationConsent.ensure(bundleID: iterm, appName: "iTerm2", willAsk: told.raise, lateAfter: 0.05, status: fake.status))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(told.raised, 1)
    }

    /// 허용 창이 닫히면 터미널이 곧 다시 맨 앞에 온다 — 그때까지 잠깐 기다린다.
    func testGoesOnWhenTheTerminalIsInFrontAgain() throws {
        var answers: [String?] = ["com.apple.UserNotificationCenter", nil, iterm]
        var pauses = 0
        try AutomationConsent.requireFront(bundleID: iterm, appName: "iTerm2", frontmost: { answers.removeFirst() }, pause: { pauses += 1 })
        XCTAssertEqual(pauses, 2)
        XCTAssertTrue(answers.isEmpty)
    }

    /// 답하는 사이 다른 앱으로 갔으면 보내지 않는다(뒤에 있는 터미널을 바꾸지도, 지금 맨 앞 앱으로 대상을 바꾸지도 않는다).
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

    /// AppleScript 로 다루지 않는 터미널은 묻지도 읽지도 않는다.
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

    /// 끝난 것을 바로 안다 — 런루프를 돌며 기다리던 때는 호출 하나가 약 65ms 였고(200번에 13초), 끝난 것을 놓치면 제한 시간까지 기다렸다.
    func testManyShortRunsFinishPromptly() {
        let start = Date()
        for _ in 0..<200 {
            let result = Proc.run("/usr/bin/true", [], timeout: 5)
            XCTAssertTrue(result.ok)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    /// 작업 스레드 여럿에서 한꺼번에 불러도 같다(앱은 작업 큐에서 부른다).
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

    /// SIGTERM 을 무시하는 자식은 강제로 끝낸다 — 끝나지 않으면 출력 읽기가 영영 기다린다.
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
