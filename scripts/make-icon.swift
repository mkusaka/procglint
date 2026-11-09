// Renders Config/AppIcon.icns. Run: swift scripts/make-icon.swift (needs iconutil).
import AppKit

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: x * s, y: y * s)
    }

    // macOS icon grid: 824pt body inside a 1024 canvas.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.13, blue: 0.22, alpha: 1),
               ending: NSColor(srgbRed: 0.03, green: 0.04, blue: 0.08, alpha: 1))!.draw(in: shape, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSColor(white: 1, alpha: 0.06).setStroke()
    for y in stride(from: 300.0, through: 750, by: 150) {
        let grid = NSBezierPath()
        grid.move(to: p(100, y)); grid.line(to: p(924, y))
        grid.lineWidth = 4 * s
        grid.stroke()
    }

    let points = [p(170, 360), p(290, 400), p(380, 330), p(470, 470), p(560, 420), p(650, 690), p(740, 520), p(854, 580)]
    let line = NSBezierPath()
    line.move(to: points[0])
    points.dropFirst().forEach { line.line(to: $0) }
    let area = NSBezierPath()
    area.append(line)
    area.line(to: p(854, 100)); area.line(to: p(170, 100)); area.close()
    NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.85, blue: 0.75, alpha: 0.35),
               ending: NSColor(srgbRed: 0.20, green: 0.85, blue: 0.75, alpha: 0))!.draw(in: area, angle: -90)
    line.lineWidth = 34 * s
    line.lineJoinStyle = .round
    line.lineCapStyle = .round
    NSColor(srgbRed: 0.35, green: 0.95, blue: 0.80, alpha: 1).setStroke()
    line.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // The glint: a four-point sparkle on the peak.
    let c = points[5]
    let star = NSBezierPath()
    let r = 120 * s, w = 22 * s
    star.move(to: NSPoint(x: c.x, y: c.y + r))
    star.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + w, y: c.y + w), controlPoint2: NSPoint(x: c.x + w, y: c.y + w))
    star.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + w, y: c.y - w), controlPoint2: NSPoint(x: c.x + w, y: c.y - w))
    star.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - w, y: c.y - w), controlPoint2: NSPoint(x: c.x - w, y: c.y - w))
    star.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - w, y: c.y + w), controlPoint2: NSPoint(x: c.x - w, y: c.y + w))
    let glow = NSShadow()
    glow.shadowColor = NSColor(srgbRed: 1, green: 0.95, blue: 0.7, alpha: 0.9)
    glow.shadowBlurRadius = 40 * s
    glow.set()
    NSColor(srgbRed: 1, green: 0.97, blue: 0.85, alpha: 1).setFill()
    star.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Config/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
exit(task.terminationStatus)
