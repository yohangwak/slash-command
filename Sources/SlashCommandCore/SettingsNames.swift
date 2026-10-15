import Foundation

/// Refers to System Settings screens by "the name this macOS uses".
///
/// The app permission list "Accessibility" is called "Device Control and Data Access" by macOS 27
/// (confirmed 2026-10-12 on two Macs running macOS 27.0.1); guiding with the old name does not match the title of the pane that opens.
/// So the name is read straight from System Settings' translation table, and if it cannot be read, our own translation of "Accessibility" is used.
public enum SettingsNames {
    /// The name of that app permission list in System Settings → Privacy & Security.
    public static let accessibility: String = system(key: "ACCESSIBILITY") ?? loc("Accessibility")

    static let privacyExtension = "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex"

    /// The text for that key in the System Settings "Privacy & Security" translation table. nil if there is none.
    static func system(key: String, bundlePath: String = privacyExtension) -> String? {
        guard let bundle = Bundle(path: bundlePath) else { return nil }
        let missing = "\u{1}"
        let value = bundle.localizedString(forKey: key, value: missing, table: "Localizable")
        return value == missing || value.isEmpty || value == key ? nil : value
    }
}
