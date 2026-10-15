import AppKit
import ServiceManagement
import SlashCommandCore

// `SlashCommand --login-item on|off|status`: turns launch at login on or off from the command line (same as the same item in the settings window).
// Only the app itself can register a login item, so it is handled here rather than by the command-line tool.
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

// `SlashCommand --automation-status <bundle id>`: for development. Prints the system's answer, as the raw number, to whether this app may control that app with AppleScript (no prompt is shown).
// The permission follows the "app that launched" the process: calling it directly from a terminal gives the terminal's answer. The app's own answer is seen with
// `open -n -W -a "Slash Command" --stdout <file> --args --automation-status <bundle id>`.
if let flag = arguments.firstIndex(of: "--automation-status"), arguments.count > flag + 1 {
    let bundleID = arguments[flag + 1]
    print("\(bundleID): \(AutomationConsent.rawStatus(bundleID: bundleID)) (\(AutomationConsent.status(bundleID: bundleID)))")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// `SlashCommand --snapshot file.png [--dark] [--height N] [--collapsed]`: for development. Writes the settings window to an image file without showing it.
if let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 1 {
    let height = arguments.firstIndex(of: "--height").flatMap { arguments.count > $0 + 1 ? Double(arguments[$0 + 1]) : nil } ?? 900
    let done = SettingsSnapshot.write(to: URL(fileURLWithPath: arguments[flag + 1]), height: height,
                                      dark: arguments.contains("--dark"), expandFirst: !arguments.contains("--collapsed"))
    exit(done ? 0 : 1)
}

let delegate = AppDelegate()

// `SlashCommand --menu-text [bundle id]`: for development. Builds the menu for the frontmost app (or the given one) and prints its lines as text (nothing is sent).
if let flag = arguments.firstIndex(of: "--menu-text") {
    let bundleID = arguments.count > flag + 1 ? arguments[flag + 1] : nil
    print(delegate.menuText(asIfFront: bundleID))
    exit(0)
}

app.delegate = delegate
app.run()
