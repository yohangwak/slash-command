import AppKit
import ServiceManagement

// `SlashCommand --login-item on|off|status` — 로그인할 때 실행을 명령줄에서 켜고 끈다(메뉴의 같은 항목과 같다).
// 로그인 항목은 앱 자신만 등록할 수 있어서 명령줄 도구가 아니라 여기서 받는다.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--login-item") {
    let service = SMAppService.mainApp
    do {
        switch arguments.dropFirst(flag + 1).first {
        case "on": if service.status != .enabled { try service.register() }
        case "off": if service.status == .enabled { try service.unregister() }
        case "status", nil: break
        default:
            FileHandle.standardError.write(Data("SlashCommand --login-item on|off|status\n".utf8))
            exit(2)
        }
    } catch {
        FileHandle.standardError.write(Data("로그인 항목을 바꾸지 못했습니다: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    print(service.status == .enabled ? "on" : "off")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
