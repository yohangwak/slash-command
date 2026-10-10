import AppKit
import ServiceManagement
import SlashCommandCore

// `SlashCommand --login-item on|off|status` — 로그인할 때 실행을 명령줄에서 켜고 끈다(설정 창의 같은 항목과 같다).
// 로그인 항목은 앱 자신만 등록할 수 있어서 명령줄 도구가 아니라 여기서 받는다.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--login-item") {
    do {
        switch arguments.dropFirst(flag + 1).first {
        case "on": try LoginItem.set(true)
        case "off": try LoginItem.set(false)
        case "status", nil: break
        default:
            FileHandle.standardError.write(Data("SlashCommand --login-item on|off|status\n".utf8))
            exit(2)
        }
    } catch {
        FileHandle.standardError.write(Data((loc("Could not change the login item: %@", error.localizedDescription) + "\n").utf8))
        exit(1)
    }
    print(SMAppService.mainApp.status == .enabled ? "on" : "off")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// `SlashCommand --snapshot 파일.png [--dark] [--height N] [--collapsed]` — 개발용. 설정 창을 띄우지 않고 그림 파일로 낸다.
if let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 1 {
    let height = arguments.firstIndex(of: "--height").flatMap { arguments.count > $0 + 1 ? Double(arguments[$0 + 1]) : nil } ?? 900
    let done = SettingsSnapshot.write(to: URL(fileURLWithPath: arguments[flag + 1]), height: height,
                                      dark: arguments.contains("--dark"), expandFirst: !arguments.contains("--collapsed"))
    exit(done ? 0 : 1)
}

let delegate = AppDelegate()

// `SlashCommand --menu-text [번들 id]` — 개발용. 지금 맨 앞 앱(또는 적어 준 앱)을 두고 메뉴를 만들어 그 줄들을 글로 찍는다(아무것도 보내지 않는다).
if let flag = arguments.firstIndex(of: "--menu-text") {
    let bundleID = arguments.count > flag + 1 ? arguments[flag + 1] : nil
    print(delegate.menuText(asIfFront: bundleID))
    exit(0)
}

app.delegate = delegate
app.run()
