// Draws the app icon and writes an .iconset directory; build-app.sh turns it into AppIcon.icns.
// Generated rather than committed as a binary so the design lives in reviewable code.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024

    // macOS icon grid: 824pt rounded square centered in 1024.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [
        NSColor(red: 0.20, green: 0.35, blue: 0.95, alpha: 1),
        NSColor(red: 0.45, green: 0.25, blue: 0.85, alpha: 1),
    ])!.draw(in: squircle, angle: -60)

    // Speech bubble.
    NSColor.white.setFill()
    let bubble = NSBezierPath(roundedRect: NSRect(x: 220 * s, y: 330 * s, width: 584 * s, height: 420 * s),
                              xRadius: 120 * s, yRadius: 120 * s)
    bubble.move(to: NSPoint(x: 320 * s, y: 345 * s))
    bubble.line(to: NSPoint(x: 280 * s, y: 230 * s))
    bubble.line(to: NSPoint(x: 430 * s, y: 345 * s))
    bubble.close()
    bubble.fill()

    // Waveform inside the bubble: the transcript.
    NSColor(red: 0.30, green: 0.30, blue: 0.90, alpha: 1).setFill()
    let heights: [CGFloat] = [90, 170, 250, 140, 210, 110]
    for (i, h) in heights.enumerated() {
        let x = (300 + CGFloat(i) * 75) * s
        NSBezierPath(roundedRect: NSRect(x: x, y: (540 - h / 2) * s, width: 40 * s, height: h * s),
                     xRadius: 20 * s, yRadius: 20 * s).fill()
    }

    // Sparkle at the top-right: the assistant's notes.
    NSColor(red: 1.0, green: 0.82, blue: 0.30, alpha: 1).setFill()
    let c = NSPoint(x: 760 * s, y: 760 * s), r = 110 * s, w = 26 * s
    let star = NSBezierPath()
    for k in 0..<8 {
        let a = CGFloat(k) * .pi / 4 + .pi / 2
        let d = k.isMultiple(of: 2) ? r : w
        let p = NSPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d)
        k == 0 ? star.move(to: p) : star.line(to: p)
    }
    star.close()
    star.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for pt in [16, 32, 128, 256, 512] {
    try draw(pt).write(to: out.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try draw(pt * 2).write(to: out.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
