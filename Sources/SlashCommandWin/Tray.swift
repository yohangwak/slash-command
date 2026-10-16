#if os(Windows)
import Foundation
import WinSDK
import SlashCommandCore

func executablePath() -> String {
    var buffer = [WCHAR](repeating: 0, count: 32768)
    let count = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
    return String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
}

enum LoginItem {
    static let key = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    static let name = "Slash Command"
    static var command: String { "\"\(executablePath())\"" }
    static var enabled: Bool {
        var handle: HKEY?
        guard key.withCString(encodedAs: UTF16.self, { RegOpenKeyExW(HKEY_CURRENT_USER, $0, 0, REGSAM(KEY_QUERY_VALUE), &handle) }) == ERROR_SUCCESS else { return false }
        defer { RegCloseKey(handle) }
        var bytes: DWORD = 65536, kind: DWORD = 0
        var value = [WCHAR](repeating: 0, count: 32768)
        let status = name.withCString(encodedAs: UTF16.self) { name in
            value.withUnsafeMutableBytes { RegQueryValueExW(handle, name, nil, &kind, $0.baseAddress?.assumingMemoryBound(to: BYTE.self), &bytes) }
        }
        guard status == ERROR_SUCCESS, kind == REG_SZ, bytes >= 2 else { return false }
        return String(decoding: value.prefix(Int(bytes / 2) - 1), as: UTF16.self) == command
    }
    static func set(_ enabled: Bool) -> Bool {
        var handle: HKEY?
        guard key.withCString(encodedAs: UTF16.self, { RegCreateKeyExW(HKEY_CURRENT_USER, $0, 0, nil, 0, REGSAM(KEY_SET_VALUE), nil, &handle, nil) }) == ERROR_SUCCESS else { return false }
        defer { RegCloseKey(handle) }
        let status = name.withCString(encodedAs: UTF16.self) { name in
            if !enabled { return RegDeleteValueW(handle, name) }
            let value = Array(command.utf16) + [0]
            return value.withUnsafeBytes { RegSetValueExW(handle, name, 0, DWORD(REG_SZ), $0.baseAddress?.assumingMemoryBound(to: BYTE.self), DWORD($0.count)) }
        }
        return status == ERROR_SUCCESS || (!enabled && status == ERROR_FILE_NOT_FOUND)
    }
}

final class Tray {
    private var icon = NOTIFYICONDATAW()
    private var loadedIcon: HICON?
    let window: HWND
    private(set) var added = false
    init(window: HWND) {
        self.window = window
        let path = URL(fileURLWithPath: executablePath()).deletingLastPathComponent().appendingPathComponent("AppIcon.ico").path
        loadedIcon = path.withCString(encodedAs: UTF16.self) { name in
            LoadImageW(nil, name, UINT(IMAGE_ICON), 0, 0, UINT(LR_LOADFROMFILE | LR_DEFAULTSIZE)).map { $0.assumingMemoryBound(to: HICON__.self) }
        }
        icon.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        icon.hWnd = window; icon.uID = 1
        icon.uFlags = UINT(NIF_ICON | NIF_MESSAGE | NIF_TIP)
        icon.uCallbackMessage = UINT(WM_APP + 2)
        icon.hIcon = loadedIcon ?? LoadIconW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
        withUnsafeMutableBytes(of: &icon.szTip) { bytes in
            let text = Array(loc("Slash Command").utf16) + [0]
            bytes.copyBytes(from: text.withUnsafeBytes { Array($0) })
        }
        restore()
    }
    func restore(taskbarCreated: Bool = false) {
        if taskbarCreated { added = false }
        guard !added else { return }
        added = Shell_NotifyIconW(DWORD(NIM_ADD), &icon)
        if !added { Log.write("tray NIM_ADD failed: \(GetLastError()); retrying in 5 seconds") }
        resident?.scheduleTrayRetry(needed: !added)
    }
    func remove() {
        if added { Shell_NotifyIconW(DWORD(NIM_DELETE), &icon); added = false }
    }
    func show(lines: [String]) {
        guard let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }
        for (index, line) in lines.enumerated() {
            let action = index >= lines.count - 4
            let id = action ? UINT_PTR(201 + index - (lines.count - 4)) : 0
            let checked = id == 203 && LoginItem.enabled
            let flags = UINT(MF_STRING) | (action ? 0 : UINT(MF_GRAYED)) | (checked ? UINT(MF_CHECKED) : 0)
            line.withCString(encodedAs: UTF16.self) { _ = AppendMenuW(menu, flags, id, $0) }
        }
        var point = POINT(); GetCursorPos(&point)
        SetForegroundWindow(window)
        _ = TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), point.x, point.y, 0, window, nil)
        PostMessageW(window, UINT(WM_NULL), 0, 0)
    }
    func action(_ selected: Int) {
        switch selected {
        case 201: open(ConfigStore.defaultURL.path)
        case 202:
            if let folder = Log.folder {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                open(folder.path)
            }
        case 203:
            if !LoginItem.set(!LoginItem.enabled) { resident?.notice(loc("Could not change Open at login.")) }
        case 204: PostMessageW(window, UINT(WM_CLOSE), 0, 0)
        default: break
        }
    }
    private func open(_ path: String) {
        let result = "open".withCString(encodedAs: UTF16.self) { verb in
            path.withCString(encodedAs: UTF16.self) { ShellExecuteW(window, verb, $0, nil, nil, SW_SHOWNORMAL) }
        }
        if Int(bitPattern: result) <= 32 { resident?.notice(loc("Could not open the file or folder.")) }
    }
    deinit {
        if let loadedIcon { DestroyIcon(loadedIcon) }
    }
}
#endif
