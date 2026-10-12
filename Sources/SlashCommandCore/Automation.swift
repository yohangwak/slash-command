import AppKit

/// macOS 의 «자동화» 허락 — 이 프로세스가 그 앱을 AppleScript 로 다뤄도 되는가.
public enum AutomationConsent: Equatable, Sendable {
    case allowed
    case denied
    /// 아직 물은 적이 없다 — 처음 다룰 때 시스템이 묻는다.
    case notAsked
    case notRunning

    /// AppleScript 로 다루는 터미널들.
    public static let scriptedBundleIDs: Set<String> = [Detector.ghosttyBundleID, Detector.itermBundleID]

    static func classify(_ status: OSStatus) -> AutomationConsent {
        switch status {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .notAsked     // errAEEventWouldRequireUserConsent(-1744) 등
        }
    }

    /// 지금의 허락 상태. `ask` 가 참이면 아직 묻지 않았을 때 시스템이 허용 창을 띄우고 «답할 때까지» 기다린다 —
    /// 주 스레드에서 그렇게 부르지 않는다. 대상 앱이 응답하지 않으면 묻지 않아도 오래 걸릴 수 있다.
    public static func status(bundleID: String, ask: Bool = false) -> AutomationConsent {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return .notRunning }
        return classify(rawStatus(bundleID: bundleID, ask: ask))
    }

    /// 시스템이 준 번호 그대로(0 허용 · -1743 거절 · -1744 아직 묻지 않음 · -600 실행 중 아님).
    public static func rawStatus(bundleID: String, ask: Bool = false) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
    }

    /// 묻지 않고 읽은 결과와, 그렇게 판단한 근거(기록용 — 실행 중인 앱을 못 찾았는지, 시스템이 준 번호가 무엇인지).
    struct Reading: Sendable {
        let consent: AutomationConsent
        let detail: String
    }

    static func read(bundleID: String) -> Reading {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else {
            return Reading(consent: .notRunning, detail: "no running app with that id")
        }
        let raw = rawStatus(bundleID: bundleID)
        return Reading(consent: classify(raw), detail: "status \(raw)")
    }

    /// 묻지 않고 읽되 `seconds` 까지만 기다린다(평소의 답은 몇 ms 다). 대상 앱이 응답하지 않으면 이 확인도 답이 없을 수 있다 —
    /// 그때는 nil(모른다)이고, 부른 쪽은 막지 않고 스크립트의 응답 제한에 맡긴다.
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

    /// 허용 창이 떠 있음을 한 번만 알린다. 닫은 뒤에는 알리지 않는다.
    private final class Notice: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (() -> Void)?
        private var fired = false

        init(_ action: @escaping () -> Void) { self.action = action }

        func fire() {
            lock.lock()
            let run = action
            action = nil
            if run != nil { fired = true }
            lock.unlock()
            run?()
        }

        func fire(after seconds: TimeInterval) {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { self.fire() }
        }

        /// 더는 알리지 않는다. 알렸으면 참.
        func close() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            action = nil
            return fired
        }
    }

    /// 그 터미널을 다루기 전에 허락을 확인하고, 아직 묻지 않았으면 «여기서» 묻고 답을 기다린다.
    ///
    /// 묻지 않은 채 스크립트부터 보내면 시스템이 그때 허용 창을 띄우는데, 스크립트에는 응답 제한(5초)이 있어
    /// 그 안에 누르지 못하면 창이 사라지고 답도 남지 않는다 — 누를 때마다 5초짜리 창이 떴다 사라진다(2026-10-12 집 맥 2 의 iTerm2 실측).
    /// 허용 창을 띄워 허락받았으면 참을 돌려준다(그동안 맨 앞 앱이 바뀌었을 수 있다 — 부른 쪽이 다시 확인한다).
    /// 이미 꺼져 있으면 `needsAutomation` 을 세운 오류를, 방금 창에서 거절했으면 그 표시 없는 오류를 던진다.
    /// `willAsk` 는 허용 창이 뜰 때(또는 떠 있음을 알게 됐을 때) 한 번 불린다 — 다른 스레드에서 불릴 수 있다.
    /// `note` 는 허락이 «확인되지 않았을» 때 무엇을 보았는지 한 줄로 받는다(기록용 — 첫 확인의 근거와 물은 뒤의 번호가 붙는다).
    @discardableResult
    public static func ensure(bundleID: String, appName: String, willAsk: @escaping () -> Void = {}, note: (String) -> Void = { _ in }) throws -> Bool {
        var seen: [String] = []
        return try ensure(bundleID: bundleID, appName: appName, willAsk: willAsk,
                          note: { note(seen.isEmpty ? $0 : "\($0) [\(seen.joined(separator: " · "))]") },
                          status: { id, ask in
            // 물을 때는 «실행 중인가» 를 따로 보지 않는다 — 맨 앞에 있는 터미널이고, 이미 허락돼 있으면 바로 돌아온다.
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

    /// `status(번들 id, 물을지)` 는 답이 없으면 nil 이다. 물은 뒤 `lateAfter` 초가 지나도 답이 없으면 허용 창이 떠 있는 것으로 본다.
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
            // 대상 앱이 답하지 않는다 — 막지 않고 스크립트의 응답 제한에 맡긴다.
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
        // 허락이 확인되지 않았다. 물어서 확인한다 — 창이 뜨면 답할 때까지 기다린다.
        note("automation \(appName): \(first == .notAsked ? "not asked yet" : "not confirmed") — asking")
        // «아직 묻지 않았다» 면 창이 뜰 것을 안다 — 바로 알린다. 그 밖의 답에서는 물어 봐야 안다: 답이 늦으면 창이 떠 있는 것이므로
        // 그때 알린다(2026-10-13 집 맥 2 의 Ghostty: 맨 앞에 있는데 첫 확인이 «확인 안 됨» 이었고, 허용 창은 떴지만 안내가 없었다).
        let notice = Notice(willAsk)
        if first == .notAsked { notice.fire() } else { notice.fire(after: lateAfter) }
        let answer = status(bundleID, true)
        // 창이 떴는지는 «아직 묻지 않았다» 였거나 답이 늦게 온 것으로 안다 — 알린 것과 같다.
        let prompted = notice.close()
        switch answer {
        case .allowed: return prompted
        case .denied: throw SlashCommandError(off)
        // 물을 수 없었거나 모르는 답이다 — 막지 않고 스크립트가 스스로 판가름하게 둔다.
        case .notAsked, .notRunning, nil:
            note("automation \(appName): still not confirmed")
            return false
        }
    }

    /// 지금 맨 앞 앱의 번들 id — 허용 창을 기다린 «뒤» 에 다시 읽을 때 쓴다.
    /// 런루프가 돌지 않는 프로세스(명령줄 도구)에서는 `NSWorkspace` 의 값이 처음 읽은 그대로다(2026-10-12 실측: 앞 앱을 바꿔도
    /// 6초 동안 그대로, 런루프를 잠깐 돌리면 따라온다). 그래서 주 스레드에서는 런루프를 잠깐 돌린 뒤 읽고, 다른 스레드에서는 주 스레드에 묻는다.
    public static func frontBundleID() -> String? {
        if Thread.isMainThread {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        return DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    }

    /// 허용 창이 떠 있는 동안에는 그 창이 맨 앞이고, 그사이 사용자가 다른 앱으로 갔을 수도 있다.
    /// 그 터미널이 다시 맨 앞에 올 때까지 잠깐(기본 2초) 기다리고, 오지 않으면 보내지 않는다 — 지금 맨 앞인 다른 앱으로 대상을 바꾸지도 않는다.
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
