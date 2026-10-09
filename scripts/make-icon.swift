// 앱 아이콘을 그려 scripts/AppIcon.icns 로 만든다:  swift scripts/make-icon.swift
// 두 줄의 스위치 — 위는 오른쪽, 아래는 왼쪽으로 넘어가 있다(모델과 effort 를 바꾼다).
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let unit = size / 1024

    // 바탕: 맥 아이콘 격자(1024 중 824, 모서리 반지름 185)
    let plate = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let shape = CGPath(roundedRect: plate, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 24 * unit, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(shape)
    context.setFillColor(NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.16, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.29, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.12, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: plate.midX, y: plate.maxY), end: CGPoint(x: plate.midX, y: plate.minY), options: [])
    context.restoreGState()

    // 스위치 두 줄
    func toggle(centerY: CGFloat, on: Bool, color: NSColor) {
        let track = CGRect(x: 262 * unit, y: (centerY - 105) * unit, width: 500 * unit, height: 210 * unit)
        let trackPath = CGPath(roundedRect: track, cornerWidth: 105 * unit, cornerHeight: 105 * unit, transform: nil)
        context.addPath(trackPath)
        context.setFillColor((on ? color.withAlphaComponent(0.95) : NSColor.white.withAlphaComponent(0.14)).cgColor)
        context.fillPath()
        let knobX = on ? track.maxX - 105 * unit : track.minX + 105 * unit
        let knob = CGRect(x: knobX - 82 * unit, y: (centerY - 82) * unit, width: 164 * unit, height: 164 * unit)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -4 * unit), blur: 10 * unit, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setFillColor((on ? NSColor.white : NSColor(calibratedWhite: 0.82, alpha: 1)).cgColor)
        context.fillEllipse(in: knob)
        context.restoreGState()
    }
    toggle(centerY: 652, on: true, color: NSColor(calibratedRed: 0.93, green: 0.52, blue: 0.30, alpha: 1))
    toggle(centerY: 372, on: false, color: .white)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("SlashCommand-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let data = draw(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent(name))
}
let output = root.appendingPathComponent("AppIcon.icns")
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", "-o", output.path, iconset.path]
try tool.run()
tool.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(tool.terminationStatus == 0 ? "만듦: \(output.path)" : "iconutil 실패")
exit(tool.terminationStatus)
