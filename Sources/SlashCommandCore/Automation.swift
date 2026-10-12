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

    /// 묻지 않고 읽되 `seconds` 까지만 기다린다(평소의 답은 몇 ms 다). 대상 앱이 응답하지 않으면 이 확인도 답이 없을 수 있다 —
    /// 그때는 nil(모른다)이고, 부른 쪽은 막지 않고 스크립트의 응답 제한에 맡긴다.
    static func bounded(bundleID: String, seconds: TimeInterval = 2) -> AutomationConsent? {
        final class Answer: @unchecked Sendable { var value: AutomationConsent? }
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            answer.value = status(bundleID: bundleID)
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success ? answer.value : nil
    }

    /// 그 터미널을 다루기 전에 허락을 확인하고, 아직 묻지 않았으면 «여기서» 묻고 답을 기다린다.
    ///
    /// 묻지 않은 채 스크립트부터 보내면 시스템이 그때 허용 창을 띄우는데, 스크립트에는 응답 제한(5초)이 있어
    /// 그 안에 누르지 못하면 창이 사라지고 답도 남지 않는다 — 누를 때마다 5초짜리 창이 떴다 사라진다(2026-10-12 집 맥 2 의 iTerm2 실측).
    /// 허용 창을 띄워 허락받았으면 참을 돌려준다(그동안 맨 앞 앱이 바뀌었을 수 있다 — 부른 쪽이 다시 확인한다).
    /// 이미 꺼져 있으면 `needsAutomation` 을 세운 오류를, 방금 창에서 거절했으면 그 표시 없는 오류를 던진다.
    /// `note` 는 허락이 «확인되지 않았을» 때 무엇을 보았는지 한 줄로 받는다(기록용).
    @discardableResult
    public static func ensure(bundleID: String, appName: String, willAsk: () -> Void = {}, note: (String) -> Void = { _ in }) throws -> Bool {
        // 물을 때는 «실행 중인가» 를 따로 보지 않는다 — 맨 앞에 있는 터미널이고, 이미 허락돼 있으면 바로 돌아온다.
        try ensure(bundleID: bundleID, appName: appName, willAsk: willAsk, note: note,
                   status: { $1 ? classify(rawStatus(bundleID: $0, ask: true)) : bounded(bundleID: $0) })
    }

    /// `status(번들 id, 물을지)` 는 답이 없으면 nil 이다.
    static func ensure(bundleID: String, appName: String, willAsk: () -> Void = {}, note: (String) -> Void = { _ in },
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
        if first == .notAsked { willAsk() }
        let began = Date()
        let answer = status(bundleID, true)
        // 창이 떴는지는 «아직 묻지 않았다» 였거나 답이 늦게 온 것으로 안다.
        let prompted = first == .notAsked || Date().timeIntervalSince(began) > 1
        switch answer {
        case .allowed: return prompted
        case .denied: throw SlashCommandError(off)
        // 물을 수 없었거나 모르는 답이다 — 막지 않고 스크립트가 스스로 판가름하게 둔다.
        case .notAsked, .notRunning, nil:
            note("automation \(appName): still not confirmed")
            return false
        }
    }
}
