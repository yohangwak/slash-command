import AppKit

/// 메뉴 막대 아이콘 — 키 하나에 슬래시(앱 아이콘 `scripts/make-icon.swift` 와 같은 그림).
/// 템플릿 이미지라 메뉴 막대의 밝기(밝음·어두움·강조)를 따라가고, 그릴 때마다 화면 배율에 맞춰 다시 그린다.
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

    /// 18pt 격자 기준으로 그린다. 다른 크기의 `rect` 에는 비율대로 늘어난다.
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
