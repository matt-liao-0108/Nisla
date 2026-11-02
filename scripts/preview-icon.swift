import AppKit

func color(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
}
func gradient(_ path: NSBezierPath, _ colors: [UInt32], angle: CGFloat = -65) {
    NSGradient(colors: colors.map(color))!.draw(in: path, angle: angle)
}
func castShadow(_ path: NSBezierPath, tint: NSColor, blur: CGFloat, offset: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = tint
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: offset)
    shadow.set()
    tint.setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
}
func draw() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
    castShadow(tile, tint: NSColor.black.withAlphaComponent(0.16), blur: 23, offset: -10)
    gradient(tile, [0xFFFEFC, 0xEFEDE9], angle: -90)
    NSColor.white.setStroke(); tile.lineWidth = 3; tile.stroke()

    // One sculptural panel, rather than a device or a collection of hanging cards.
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: 512, yBy: 524)
    transform.rotate(byDegrees: 10)
    transform.concat()
    let body = NSBezierPath(roundedRect: NSRect(x: -215, y: -204, width: 430, height: 408), xRadius: 100, yRadius: 100)
    castShadow(body, tint: color(0x6E3759).withAlphaComponent(0.26), blur: 38, offset: -24)
    gradient(body, [0xFFD0A1, 0xFF947F, 0xBA73BB])
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    NSGradient(starting: .white.withAlphaComponent(0.65), ending: .clear)!
        .draw(fromCenter: NSPoint(x: -160, y: 175), radius: 0, toCenter: NSPoint(x: -160, y: 175), radius: 480, options: [])
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.75).setStroke()
    body.lineWidth = 4; body.stroke()

    // A recessed notch carved into the upper edge is the only interior detail.
    let notch = NSBezierPath()
    notch.move(to: NSPoint(x: -91, y: 205))
    notch.line(to: NSPoint(x: 91, y: 205))
    notch.line(to: NSPoint(x: 91, y: 154))
    notch.curve(to: NSPoint(x: 59, y: 122), controlPoint1: NSPoint(x: 91, y: 133), controlPoint2: NSPoint(x: 80, y: 122))
    notch.line(to: NSPoint(x: -59, y: 122))
    notch.curve(to: NSPoint(x: -91, y: 154), controlPoint1: NSPoint(x: -80, y: 122), controlPoint2: NSPoint(x: -91, y: 133))
    notch.close()
    gradient(notch, [0x38343C, 0x211E27], angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [128, 256, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(size) / 1024); scale.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent("Island-\(size).png"))
}
