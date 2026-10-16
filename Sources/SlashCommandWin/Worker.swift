#if os(Windows)
import Foundation
import Dispatch
import WinSDK
import SlashCommandCore

/// Win32 owns the main message loop; DispatchQueue.main is deliberately not used.
final class Mailbox {
    private let lock = NSLock()
    private var jobs: [() -> Void] = []
    let window: HWND
    init(window: HWND) { self.window = window }
    func post(_ job: @escaping () -> Void) {
        lock.lock(); jobs.append(job); lock.unlock()
        PostMessageW(window, UINT(WM_APP + 1), 0, 0)
    }
    func drain() {
        lock.lock(); let batch = jobs; jobs = []; lock.unlock()
        batch.forEach { $0() }
    }
}

final class Worker {
    let queue = DispatchQueue(label: "slashcommand.windows.switch")
    private(set) var busy = false // main thread only
    private var nudgedTabLag = false // serial worker queue only
    private let mailbox: Mailbox
    init(mailbox: Mailbox) { self.mailbox = mailbox }

    func press(_ id: Int, foreground: Foreground, completion: @escaping (WindowsAppModel.Notice) -> Void) {
        busy = true // Resident checks the registered key, foreground and busy state first.
        let label = WindowsAppModel.actionLabel(id)
        Log.write(WindowsAppModel.hotkeyLine(id))
        queue.async {
            let trace = Trace()
            var target: Target?
            do {
                let config = try ConfigStore().load()
                var switcher = Switcher(config: config)
                switcher.trace = trace
                switcher.onAwaitingUser = { model in
                    Log.write("awaiting confirmation \(label): \(model)")
                    let targetDetail = target.map { "\n" + WindowsAppModel.targetLine($0) } ?? ""
                    self.mailbox.post { completion(.init(loc("Press Enter to confirm") + targetDetail + "\n" + loc("Claude Code is asking whether to switch to %@ (it re-reads the conversation).", model), kind: .awaiting)) }
                }
                let found = try Detector.target(app: "orca", frontPID: foreground.pid)
                target = found
                trace.mark("find target")
                let result = try id <= 9 ? switcher.apply(slot: id, to: found, deferFinalCheck: true)
                    : switcher.stepEffort(up: id == WindowsAppModel.effortUp, on: found)
                Log.write(WindowsAppModel.appliedLine(id: id, result: result))
                let notice = WindowsAppModel.hud(result: result, tabLagNote: !self.nudgedTabLag)
                self.nudgedTabLag = true
                self.mailbox.post { completion(notice) }
                if let before = result.pendingRestore, let late = switcher.verifyRestore(before) {
                    Log.write("⚠️ \(late)")
                    self.mailbox.post { completion(.init(result.summary + "\n" + WindowsAppModel.targetLine(found) + "\n⚠️ " + late, kind: .multiline)) }
                }
            } catch {
                Log.write("\(WindowsAppModel.errorPrefix(error)) \(label): \(error)")
                var detail = target.map { "\n" + WindowsAppModel.targetLine($0) } ?? ""
                if target != nil && !self.nudgedTabLag {
                    self.nudgedTabLag = true
                    detail += "\n" + loc("Right after switching Orca tabs, wait 2.5 seconds before pressing a shortcut; the visible tab is read from Orca’s delayed state file.")
                }
                let notice: WindowsAppModel.Notice
                if let error = error as? SlashCommandError, error.awaitingUser {
                    notice = .init(loc("Press Enter to confirm") + detail + "\n\(error)", kind: .awaitingError)
                } else if let error = error as? SlashCommandError, error.nothingToDo {
                    notice = .init("\(error)" + detail, kind: .unchanged)
                } else {
                    notice = .init(loc("Not switched") + detail + "\n\(error)", kind: .error)
                }
                self.mailbox.post { completion(notice) }
            }
            Log.write("timing \(label): \(trace.report)")
            self.mailbox.post { self.busy = false }
        }
    }
}
#endif
