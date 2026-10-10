// 앱 아이콘을 그려 scripts/AppIcon.icns 로 만든다:  swift scripts/make-icon.swift
// 키 하나에 슬래시 — 키를 누르면 슬래시 명령이 간다. 메뉴 막대 아이콘(StatusIcon.swift)과 같은 그림이다.
// `swift scripts/make-icon.swift --preview 파일.png` 는 1024 크기 한 장만 그 파일로 낸다(icns 는 건드리지 않는다).
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let unit = size / 1024
    let space = CGColorSpaceCreateDeviceRGB()
    func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha).cgColor
    }
    func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x * unit, y: y * unit, width: width * unit, height: height * unit),
               cornerWidth: radius * unit, cornerHeight: radius * unit, transform: nil)
    }
    func fill(_ path: CGPath, from top: CGColor, to bottom: CGColor) {
        let box = path.boundingBoxOfPath
        context.saveGState()
        context.addPath(path)
        context.clip()
        let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
        context.restoreGState()
    }
    func shadowed(_ path: CGPath, offset: CGFloat, blur: CGFloat, alpha: CGFloat, color fillColor: CGColor) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -offset * unit), blur: blur * unit, color: NSColor.black.withAlphaComponent(alpha).cgColor)
        context.addPath(path)
        context.setFillColor(fillColor)
        context.fillPath()
        context.restoreGState()
    }

    // 바탕: 맥 아이콘 격자(1024 중 824, 모서리 반지름 185)
    let plate = rounded(100, 100, 824, 824, 185)
    shadowed(plate, offset: 10, blur: 24, alpha: 0.35, color: color(0.10, 0.11, 0.16))
    fill(plate, from: color(0.17, 0.19, 0.29), to: color(0.07, 0.08, 0.12))

    // 작은 크기(메뉴·목록의 16~32pt)에서는 키의 옆면을 빼고 윗면과 슬래시를 키운다 — 뭉개지지 않게.
    let small = size <= 64
    let face = small ? rounded(212, 212, 600, 600, 120) : rounded(262, 318, 500, 480, 92)
    if !small {
        // 키의 몸통(옆면): 윗면보다 넓고 아래로 길다.
        let body = rounded(222, 232, 580, 600, 124)
        shadowed(body, offset: 18, blur: 36, alpha: 0.55, color: color(0.09, 0.10, 0.15))
        fill(body, from: color(0.15, 0.17, 0.26), to: color(0.10, 0.11, 0.17))
    }
    fill(face, from: color(0.33, 0.36, 0.50), to: color(0.22, 0.24, 0.36))
    context.saveGState()
    context.addPath(face)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    context.setLineWidth((small ? 12 : 5) * unit)
    context.strokePath()
    context.restoreGState()

    // 슬래시
    let center = CGPoint(x: 512 * unit, y: (small ? 512 : 558) * unit)
    let half = CGSize(width: (small ? 92 : 74) * unit, height: (small ? 190 : 156) * unit)
    let line = CGMutablePath()
    line.move(to: CGPoint(x: center.x - half.width, y: center.y - half.height))
    line.addLine(to: CGPoint(x: center.x + half.width, y: center.y + half.height))
    let slash = line.copy(strokingWithWidth: (small ? 104 : 78) * unit, lineCap: .round, lineJoin: .round, miterLimit: 10)
    if !small { shadowed(slash, offset: 6, blur: 14, alpha: 0.35, color: color(0.93, 0.45, 0.25)) }
    fill(slash, from: color(1.00, 0.68, 0.38), to: color(0.93, 0.44, 0.24))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

if let flag = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > flag + 1 {
    let size = CommandLine.arguments.count > flag + 2 ? CGFloat(Int(CommandLine.arguments[flag + 2]) ?? 1024) : 1024
    try draw(size: size).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    exit(0)
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
