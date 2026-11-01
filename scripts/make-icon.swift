// Renders the Tidemark app icon into an .iconset folder: swift make-icon.swift <out.iconset>
import AppKit

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func draw() {
    // Squircle tile (Big Sur grid: 824pt tile centred in 1024).
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    shadow.set()
    rgb(0x0C2340).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: rgb(0x1B3F6E), ending: rgb(0x081A33))!.draw(in: shape, angle: -90)
    shape.addClip()

    // Folders as a treemap.
    let blocks = [NSRect(x: 196, y: 196, width: 300, height: 632),
                  NSRect(x: 524, y: 500, width: 304, height: 328),
                  NSRect(x: 524, y: 196, width: 304, height: 276)]
    let folders = NSBezierPath()
    for b in blocks { folders.append(NSBezierPath(roundedRect: b, xRadius: 40, yRadius: 40)) }
    NSColor.white.withAlphaComponent(0.16).setFill()
    folders.fill()

    // The tide: water risen part-way up, with a wave on top.
    let level: CGFloat = 450, amp: CGFloat = 30, seg: CGFloat = 216
    let crest = NSBezierPath()
    crest.move(to: NSPoint(x: 80, y: level))
    var x: CGFloat = 80, up = true
    while x < 944 {
        let c = level + (up ? amp : -amp) * 1.3
        crest.curve(to: NSPoint(x: x + seg, y: level), controlPoint1: NSPoint(x: x + seg * 0.35, y: c),
                    controlPoint2: NSPoint(x: x + seg * 0.65, y: c))
        x += seg; up.toggle()
    }
    let water = crest.copy() as! NSBezierPath
    water.line(to: NSPoint(x: x, y: 80))
    water.line(to: NSPoint(x: 80, y: 80))
    water.close()
    NSGradient(starting: rgb(0x52E3EA), ending: rgb(0x1170B5))!.draw(in: water, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    water.addClip()
    NSColor.white.withAlphaComponent(0.22).setFill()
    folders.fill()
    NSGraphicsContext.restoreGraphicsState()
    crest.lineWidth = 12
    NSColor.white.withAlphaComponent(0.7).setStroke()
    crest.stroke()

    // The tidemark: the highest the water has reached, read off a gauge.
    let markY: CGFloat = 640
    let mark = NSBezierPath()
    mark.lineWidth = 24
    mark.lineCapStyle = .round
    for i in 0..<7 {   // dashes spanning the treemap
        let x0 = 236 + CGFloat(i) * 88
        mark.move(to: NSPoint(x: x0, y: markY))
        mark.line(to: NSPoint(x: x0 + 52, y: markY))
    }
    let amber = rgb(0xFFB33C)
    amber.setStroke()
    mark.stroke()
    let pointer = NSBezierPath()
    pointer.move(to: NSPoint(x: 100, y: markY + 52))
    pointer.line(to: NSPoint(x: 196, y: markY))
    pointer.line(to: NSPoint(x: 100, y: markY - 52))
    pointer.close()
    amber.setFill()
    pointer.fill()
}

let out = CommandLine.arguments[1]
let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
    ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
]
for (name, px) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
