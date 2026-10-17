#if os(Windows)
import WinSDK
import SlashCommandCore

struct Foreground {
    let window: HWND?
    let pid: DWORD
    let supported: Bool
    var keepsSnapshot: Bool = false
    var app: String = "orca"

    /// Only window metadata; safe on the UI thread. Process-image I/O is in capture().
    static func identity() -> (HWND?, DWORD) {
        let window = GetForegroundWindow()
        var pid: DWORD = 0
        if let window { GetWindowThreadProcessId(window, &pid) }
        return (window, pid)
    }
    static func capture(window: HWND?, pid: DWORD) -> Foreground {
        var name = [WCHAR](repeating: 0, count: 256)
        let count = GetClassNameW(window, &name, Int32(name.count))
        var image = [WCHAR](repeating: 0, count: 32768)
        var length = DWORD(image.count)
        var path = ""
        if let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) {
            if QueryFullProcessImageNameW(process, 0, &image, &length) {
                path = String(decoding: image.prefix(Int(length)), as: UTF16.self)
            }
            CloseHandle(process)
        }
        return Foreground(window: window, pid: pid, supported: pid != 0 && WindowsAppModel.supports(image: path),
                          keepsSnapshot: WindowsAppModel.keepsSnapshot(pid: pid, ownPID: GetCurrentProcessId(), image: path,
                              windowClass: String(decoding: name.prefix(Int(max(0, count))), as: UTF16.self)),
                          app: WindowsAppModel.app(image: path) ?? "")
    }
}

final class ForegroundWatcher {
    private var hook: HWINEVENTHOOK?
    init() {
        hook = SetWinEventHook(DWORD(EVENT_SYSTEM_FOREGROUND), DWORD(EVENT_SYSTEM_FOREGROUND), nil,
                              { _, _, _, _, _, _, _ in resident?.refreshForeground(retry: true) }, 0, 0, DWORD(WINEVENT_OUTOFCONTEXT))
    }
    var installed: Bool { hook != nil }
    deinit { if let hook { UnhookWinEvent(hook) } }
}
#endif
