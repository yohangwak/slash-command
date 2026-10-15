import AppKit
import SlashCommandCore
import SwiftUI

/// For development: writes the contents of the settings window to an image file without showing it on screen.
/// It is for checking layout and translations (such as `SLASHCOMMAND_LANG=ja`) by eye without the Screen Recording permission. It saves nothing else.
enum SettingsSnapshot {
    static func write(to url: URL, height: Double, dark: Bool, expandFirst: Bool) -> Bool {
        let model = SettingsModel(store: ConfigStore(), onSaved: {})
        model.expanded = expandFirst ? Set(model.slots.prefix(1).map(\.id)) : []
        let permissions = PermissionsModel()
        permissions.refresh()
        // In the real app the system flips the layout for right-to-left languages. Here we match it by hand.
        let direction: LayoutDirection = Locale.Language(identifier: L10n.language).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
        let view = SettingsView(model: model, permissions: permissions).environment(\.layoutDirection, direction)
        let hosting = NSHostingView(rootView: view)
        let frame = NSRect(x: -30_000, y: -30_000, width: 620, height: height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        // Wait briefly for the Automation permission check and SwiftUI's first layout to finish.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        hosting.layoutSubtreeIfNeeded()
        guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
