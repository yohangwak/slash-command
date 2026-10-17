#if os(Windows)
import Foundation
import Dispatch
import WinSDK
import SlashCommandCore

// Harden DLL lookup before any application work, including headless commands.
_ = SetDefaultDllDirectories(DWORD(LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_APPLICATION_DIR))

let residentClass = "SlashCommand.Windows.Resident"
let pressMessage = "SlashCommand.Windows.Press.v1".withCString(encodedAs: UTF16.self, RegisterWindowMessageW)
let taskbarCreated = "TaskbarCreated".withCString(encodedAs: UTF16.self, RegisterWindowMessageW)
var resident: Resident?

private let residentProcedure: WNDPROC = { window, message, wParam, lParam in
    if message == pressMessage {
        return resident?.press(Int(wParam)) == true ? 1 : 0
    }
    if message == taskbarCreated { resident?.tray?.restore(taskbarCreated: true); return 0 }
    switch message {
    case UINT(WM_APP + 1): resident?.mailbox.drain(); return 0
    case UINT(WM_APP + 2):
        if [UINT(WM_RBUTTONUP), UINT(WM_LBUTTONUP), UINT(WM_CONTEXTMENU)].contains(UINT(truncatingIfNeeded: lParam)) { resident?.openMenu() }
        return 0
    case UINT(WM_COMMAND): resident?.tray?.action(Int(wParam & 0xFFFF)); return 0
    case UINT(WM_HOTKEY): resident?.press(Int(wParam)); return 0
    case UINT(WM_TIMER): resident?.tick(Int(wParam)); return 0
    case UINT(WM_CLOSE):
        // Let a switch finish restoring defaults before the process exits.
        if resident?.worker.busy == true { resident?.quitting = true }
        else { DestroyWindow(window) }
        return 0
    case UINT(WM_DESTROY): resident?.tray?.remove(); PostQuitMessage(0); return 0
    default: return DefWindowProcW(window, message, wParam, lParam)
    }
}

final class Resident {
    let window: HWND
    let mailbox: Mailbox
    let worker: Worker
    let hud: HUD
    let hotKeys = HotKeys()
    var tray: Tray?
    var watcher: ForegroundWatcher?
    var quitting = false
    private let wake: HANDLE
    private var config: SlashCommandConfig?
    private var configError: String?
    private let refreshQueue = DispatchQueue(label: "slashcommand.windows.refresh")
    private var refreshes = 0
    private var menuLookupPending = false
    private var front = Foreground(window: nil, pid: 0, supported: false)
    private var target: Target?
    private var failures: [Int] = []
    private var warning: String?

    init?(window: HWND, wake: HANDLE) {
        guard let hud = HUD() else { return nil }
        self.window = window; self.wake = wake; self.hud = hud
        mailbox = Mailbox(window: window)
        worker = Worker(mailbox: mailbox)
    }
    func start() -> Bool {
        tray = Tray(window: window)
        scheduleTrayRetry(needed: tray?.added != true)
        watcher = ForegroundWatcher()
        guard watcher?.installed == true else { Log.write("foreground hook installation failed"); return false }
        guard SetTimer(window, 1, 1000, nil) != 0 else { Log.write("periodic timer creation failed"); return false }
        refreshForeground(retry: true)
        return true
    }
    func scheduleTrayRetry(needed: Bool) {
        if needed { SetTimer(window, 3, 5000, nil) } else { KillTimer(window, 3) }
    }
    func refreshForeground(retry: Bool = false, reason: WindowsAppModel.RefreshReason = .foregroundChanged) {
        let (observedWindow, pid) = Foreground.identity()
        // Do not leave global keys active while asynchronous process checks run.
        if pid != front.pid || !front.supported { hotKeys.unregister(window: self.window) }
        guard retry || refreshes == 0 else { return }
        refreshes += 1
        let canLookup = !worker.busy
        refreshQueue.async {
            let captured = Foreground.capture(window: observedWindow, pid: pid)
            let loaded = Result { try ConfigStore().load() }
            let lookupTarget = canLookup && WindowsAppModel.looksUpTarget(app: captured.app, reason: reason)
            let found = captured.supported && lookupTarget ? try? Detector.target(app: captured.app, frontPID: captured.pid, frontWindow: captured.window.map { UInt(bitPattern: $0) }) : nil
            self.mailbox.post {
                self.refreshes -= 1
                let (currentWindow, currentPID) = Foreground.identity()
                let stillFront = currentWindow == captured.window && currentPID == captured.pid
                switch loaded {
                case .success(let config): self.config = config; self.configError = nil
                case .failure(let error):
                    let text = String(describing: error)
                    if text != self.configError { Log.write("presets unreadable: \(text)") }
                    self.configError = text; self.config = nil
                }
                if stillFront { self.hotKeys.update(window: self.window, foreground: captured, config: self.config, retry: retry) }
                if !captured.keepsSnapshot {
                    if found != nil || captured.pid != self.front.pid || !captured.supported || (lookupTarget && stillFront) { self.target = found }
                    if stillFront {
                        self.failures = self.hotKeys.failed; self.warning = self.hotKeys.warning
                    } else if captured.pid != self.front.pid {
                        self.failures = []; self.warning = self.config.flatMap { WindowsAppModel.modifiers($0.modifiers).warning }
                    }
                    self.front = captured
                }
            }
        }
    }
    func notice(_ text: String, foreground: Foreground? = nil, seconds: TimeInterval? = 5) {
        hud.show(text, foreground: foreground ?? front, seconds: seconds)
    }
    @discardableResult func press(_ id: Int) -> Bool {
        let (window, pid) = Foreground.identity()
        let supported = front.supported && window == front.window && pid == front.pid
        if let reason = WindowsAppModel.refusal(id: id, supported: supported, busy: worker.busy, registered: hotKeys.registered) {
            Log.write("ignored \(WindowsAppModel.actionLabel(id)): \(reason)")
            if worker.busy { notice(loc("Still switching") + "\n" + loc("Press again when it is done."), seconds: 1.6) }
            return false
        }
        let captured = front
        worker.press(id, foreground: captured) { [weak self] notice in
            self?.notice(notice.text, foreground: captured, seconds: notice.seconds)
        }
        return true
    }
    func openMenu() {
        // A second click while the lookup runs would queue a second menu.
        guard !menuLookupPending else { return }
        let captured = front
        // The tray owns foreground now; resolve the cached terminal's pinned GUI, for display only.
        if ["wezterm", "windowsterminal"].contains(captured.app), !worker.busy,
           WindowsAppModel.looksUpTarget(app: captured.app, reason: .menu) {
            menuLookupPending = true
            refreshQueue.async {
                let found = try? Detector.windowsMenuTarget(app: captured.app, frontPID: captured.pid, frontWindow: captured.window.map { UInt(bitPattern: $0) })
                self.mailbox.post {
                    self.menuLookupPending = false
                    if self.front.pid == captured.pid && self.front.app == captured.app { self.target = found }
                    self.showMenu()
                }
            }
        } else { showMenu() }
    }
    private func showMenu() {
        // Foreground events already cached the terminal before Explorer/our tray took focus.
        tray?.show(lines: WindowsAppModel.menu(config: config, supported: front.supported, agent: target?.agent,
                                              terminal: target?.label, failures: failures, warning: warning,
                                              appName: front.app == "windowsterminal" ? "Windows Terminal" : front.app == "wezterm" ? "WezTerm" : "Orca"))
    }
    func tick(_ id: Int) {
        if id == 3 { tray?.restore(); return }
        if quitting && !worker.busy { DestroyWindow(window); return }
        let wakeUp = WaitForSingleObject(wake, 0) == WAIT_OBJECT_0
        refreshForeground(retry: wakeUp, reason: .tick)
    }
    func stop() {
        KillTimer(window, 1); KillTimer(window, 3)
        hotKeys.unregister(window: window)
        watcher = nil; tray = nil
    }
}

func die(_ text: String) -> Never {
    Log.write("fatal: " + text)
    if let resident, IsWindow(resident.window) { DestroyWindow(resident.window) }
    Log.flush()
    FileHandle.standardError.write(Data((text + "\n").utf8)); exit(1)
}

/// Swift's CRT stdout may be unopened for a GUI executable; use the attached/inherited Win32 handle.
func output(_ text: String) {
    let handle = GetStdHandle(DWORD(STD_OUTPUT_HANDLE))
    var written: DWORD = 0
    if GetFileType(handle) == FILE_TYPE_CHAR {
        let units = Array((text + "\n").utf16)
        units.withUnsafeBufferPointer { _ = WriteConsoleW(handle, $0.baseAddress, DWORD($0.count), &written, nil) }
    } else {
        let bytes = Array((text + "\n").utf8)
        bytes.withUnsafeBytes { _ = WriteFile(handle, $0.baseAddress, DWORD($0.count), &written, nil) }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
// GUI-subsystem launches create no console. Explicit command modes reuse the caller's console.
if !args.isEmpty { _ = AttachConsole(DWORD(bitPattern: -1)) }
if args == ["--version"] { output(WindowsAppModel.version); exit(0) }
if args == ["--menu-text"] || args == ["--menu-text", "--as-if", "orca"] || args == ["--menu-text", "--as-if", "wezterm"] || args == ["--menu-text", "--as-if", "windowsterminal"] {
    let config = try? ConfigStore().load()
    let supported = args.count == 3
    output(WindowsAppModel.menu(config: config, supported: supported, agent: nil,
                               warning: config.flatMap { WindowsAppModel.modifiers($0.modifiers).warning },
                               appName: args.last == "windowsterminal" ? "Windows Terminal" : args.last == "wezterm" ? "WezTerm" : "Orca").joined(separator: "\n"))
    exit(0)
}
if args.first == "--press" {
    guard args.count == 2, let id = WindowsAppModel.pressID(args[1]) else { die(loc("Use --press with 1–9, up, or down.")) }
    let window = residentClass.withCString(encodedAs: UTF16.self) { FindWindowW($0, nil) }
    guard let window else { die(loc("Slash Command is not running.")) }
    var accepted: DWORD_PTR = 0
    guard SendMessageTimeoutW(window, pressMessage, WPARAM(id), 0, UINT(SMTO_ABORTIFHUNG | SMTO_BLOCK), 2000, &accepted) != 0,
          accepted == 1 else { die(loc("The shortcut is not available right now.")) }
    exit(0)
}
if !args.isEmpty { die(loc("Unknown argument.")) }


let mutexResult = "Local\\SlashCommand.Windows".withCString(encodedAs: UTF16.self) { name in
    let handle = CreateMutexW(nil, false, name)
    let error = GetLastError() // Must precede Swift closure cleanup/allocation.
    return (handle, error)
}
let (mutex, mutexError) = mutexResult
guard let mutex else { die(loc("Could not start Slash Command.")) }
let wake = "Local\\SlashCommand.Windows.Wake".withCString(encodedAs: UTF16.self) { CreateEventW(nil, false, false, $0) }
guard let wake else { CloseHandle(mutex); die(loc("Could not start Slash Command.")) }
if mutexError == ERROR_ALREADY_EXISTS {
    guard SetEvent(wake) else { die(loc("Could not start Slash Command.")) }
    Log.write("second launch: handed off to resident"); Log.flush()
    CloseHandle(wake); CloseHandle(mutex); exit(0)
}
// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4.
_ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))
let window: HWND? = residentClass.withCString(encodedAs: UTF16.self) { name in
    var cls = WNDCLASSW()
    cls.lpfnWndProc = residentProcedure; cls.hInstance = GetModuleHandleW(nil); cls.lpszClassName = name
    guard RegisterClassW(&cls) != 0 else { return nil }
    // A hidden top-level window receives TaskbarCreated broadcasts and IPC; no visible main window.
    return CreateWindowExW(DWORD(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE), name, nil, DWORD(WS_POPUP),
                           0, 0, 0, 0, nil, nil, cls.hInstance, nil)
}
guard let window, let app = Resident(window: window, wake: wake) else { die(loc("Could not start Slash Command.")) }
resident = app
guard app.start() else { die(loc("Could not start Slash Command.")) }
Log.write("started \(WindowsAppModel.version)")
// WinSDK imports GetMessageW as Bool, which loses its documented -1 error.
typealias RawGetMessage = @convention(c) (UnsafeMutablePointer<MSG>?, HWND?, UINT, UINT) -> Int32
let user32 = "user32.dll".withCString(encodedAs: UTF16.self, GetModuleHandleW)
guard let address = GetProcAddress(user32, "GetMessageW") else { die(loc("Could not start Slash Command.")) }
let getMessage = unsafeBitCast(address, to: RawGetMessage.self)
var message = MSG()
var loopResult: Int32 = 0
while true {
    loopResult = getMessage(&message, nil, 0, 0)
    if loopResult <= 0 { break }
    TranslateMessage(&message); DispatchMessageW(&message)
}
if loopResult == -1 {
    Log.write("fatal: GetMessageW failed: \(GetLastError())")
    DestroyWindow(window)
}
app.stop(); resident = nil
Log.flush()
CloseHandle(wake); CloseHandle(mutex)
exit(loopResult == -1 ? 1 : 0)
#endif
