import AppKit

/// Menu bar icon: a slash on a key (the same picture as the app icon `scripts/make-icon.swift`).
/// It is a template image, so it follows the menu bar's brightness (light, dark, highlighted) and is redrawn at the screen scale each time it is drawn.
enum StatusIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image() -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Slash Command"
        return image
    }

    /// Drawn on an 18pt grid. For a `rect` of another size it is scaled proportionally.
    static func draw(in rect: NSRect) {
        let unit = rect.width / size.width
        NSColor.black.setStroke()
        let key = NSBezierPath(roundedRect: rect.insetBy(dx: 1.75 * unit, dy: 1.75 * unit), xRadius: 4.25 * unit, yRadius: 4.25 * unit)
        key.lineWidth = 1.5 * unit
        key.stroke()
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: rect.minX + 7.1 * unit, y: rect.minY + 5.3 * unit))
        slash.line(to: NSPoint(x: rect.minX + 10.9 * unit, y: rect.minY + 12.7 * unit))
        slash.lineWidth = 1.9 * unit
        slash.lineCapStyle = .round
        slash.stroke()
    }
}
