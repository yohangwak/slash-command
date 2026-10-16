#if os(Windows)
import Foundation
import WinSDK

private func hudFont(scale: Double) -> HFONT? {
    CreateFontW(-Int32(17 * scale), 0, 0, 0, FW_SEMIBOLD, 0, 0, 0,
                DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH), nil)
}
private let hudProcedure: WNDPROC = { window, message, wParam, lParam in
    switch message {
    case UINT(WM_MOUSEACTIVATE): return LRESULT(MA_NOACTIVATE)
    case UINT(WM_NCHITTEST): return LRESULT(HTTRANSPARENT)
    case UINT(WM_TIMER): resident?.hud.timer(Int(wParam)); return 0
    case UINT(WM_PAINT):
        var paint = PAINTSTRUCT()
        let dc = BeginPaint(window, &paint)
        var rect = RECT(); GetClientRect(window, &rect)
        let brush = CreateSolidBrush(0x00282020)
        FillRect(dc, &rect, brush); DeleteObject(brush)
        SetBkMode(dc, TRANSPARENT); SetTextColor(dc, 0x00FFFFFF)
        let scale = resident?.hud.scale ?? 1
        let font = hudFont(scale: scale)
        let old = SelectObject(dc, font)
        let padding = Int32(18 * scale)
        rect.left += padding; rect.right -= padding; rect.top += padding; rect.bottom -= padding
        let text = resident?.hud.text ?? ""
        text.withCString(encodedAs: UTF16.self) { _ = DrawTextW(dc, $0, -1, &rect, UINT(DT_CENTER | DT_WORDBREAK | DT_NOPREFIX | DT_END_ELLIPSIS)) }
        SelectObject(dc, old); DeleteObject(font)
        EndPaint(window, &paint)
        return 0
    default: return DefWindowProcW(window, message, wParam, lParam)
    }
}

final class HUD {
    let window: HWND
    private(set) var text = ""
    private(set) var scale: Double = 1
    private var fadeStarted: UInt64 = 0
    private var fadeDue: UInt64?
    init?() {
        let made: HWND? = "SlashCommand.HUD".withCString(encodedAs: UTF16.self) { name in
            var cls = WNDCLASSW()
            cls.lpfnWndProc = hudProcedure
            cls.hInstance = GetModuleHandleW(nil)
            cls.lpszClassName = name
            guard RegisterClassW(&cls) != 0 else { return nil }
            return CreateWindowExW(DWORD(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT),
                                   name, nil, DWORD(WS_POPUP), 0, 0, 1, 1, nil, nil, cls.hInstance, nil)
        }
        guard let made else { return nil }
        window = made
    }
    /// nil stays visible until the next notice. The fast timer exists only during the fade.
    func show(_ text: String, foreground: Foreground, seconds: TimeInterval? = 1.6) {
        KillTimer(window, 1); KillTimer(window, 2); fadeStarted = 0; fadeDue = nil
        self.text = text
        scale = Double(max(96, GetDpiForWindow(foreground.window))) / 96
        var monitor = MONITORINFO()
        monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        guard GetMonitorInfoW(MonitorFromWindow(foreground.window, DWORD(MONITOR_DEFAULTTONEAREST)), &monitor) else { return }
        let work = monitor.rcWork
        let padding = Int32(18 * scale)
        let width = min(Int32(420 * scale), work.right - work.left)
        var measured = RECT(left: 0, top: 0, right: max(1, width - 2 * padding), bottom: 0)
        let dc = GetDC(window), font = hudFont(scale: scale)
        let old = SelectObject(dc, font)
        text.withCString(encodedAs: UTF16.self) { _ = DrawTextW(dc, $0, -1, &measured, UINT(DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX)) }
        SelectObject(dc, old); DeleteObject(font); ReleaseDC(window, dc)
        let maxHeight = min(Int32(480 * scale), (work.bottom - work.top) / 2)
        let height = min(maxHeight, max(Int32(60 * scale), measured.bottom + 2 * padding))
        SetLayeredWindowAttributes(window, 0, 245, DWORD(LWA_ALPHA))
        SetWindowPos(window, HWND(bitPattern: -1), work.left + (work.right - work.left - width) / 2,
                     max(work.top, work.bottom - height - Int32(90 * scale)), width, height, UINT(SWP_NOACTIVATE))
        InvalidateRect(window, nil, true)
        ShowWindow(window, SW_SHOWNOACTIVATE)
        if let seconds {
            let milliseconds = UINT(max(1, seconds * 1000))
            fadeDue = GetTickCount64() + UInt64(milliseconds)
            if SetTimer(window, 1, milliseconds, nil) == 0 { Log.write("HUD hide timer creation failed") }
        }
    }
    func timer(_ id: Int) {
        if id == 1 {
            // KillTimer does not remove already queued messages from a previous notice.
            guard let fadeDue, GetTickCount64() >= fadeDue else { return }
            self.fadeDue = nil
            KillTimer(window, 1); fadeStarted = GetTickCount64()
            SetTimer(window, 2, 50, nil)
        } else if id == 2, fadeStarted != 0 {
            let elapsed = GetTickCount64() - fadeStarted
            if elapsed >= 250 {
                KillTimer(window, 2); ShowWindow(window, SW_HIDE); fadeStarted = 0
            } else { SetLayeredWindowAttributes(window, 0, BYTE((250 - elapsed) * 245 / 250), DWORD(LWA_ALPHA)) }
        }
    }
    deinit { KillTimer(window, 1); KillTimer(window, 2); DestroyWindow(window) }
}
#endif
