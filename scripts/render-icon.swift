import AppKit

// Nisla: a dark capsule with diagonally staggered activity cards on a warm tile.
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func surface(_ path: NSBezierPath, top: UInt32, bottom: UInt32, shadowColor: NSColor, blur: CGFloat, drop: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = shadowColor
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: -drop)
    shadow.set()
    color(bottom).setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(top), ending: color(bottom))!.draw(in: path, angle: -90)
}
func activityCard(_ rect: NSRect, top: UInt32, bottom: UInt32, angle: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: rect.midX, yBy: rect.midY)
    transform.rotate(byDegrees: angle)
    transform.concat()
    let card = NSBezierPath(roundedRect: NSRect(x: -rect.width / 2, y: -rect.height / 2,
        width: rect.width, height: rect.height), xRadius: 48, yRadius: 48)
    surface(card, top: top, bottom: bottom,
        shadowColor: .black.withAlphaComponent(0.14), blur: 18, drop: 8)
    NSColor.white.withAlphaComponent(0.28).setStroke()
    card.lineWidth = 2; card.stroke()
    NSGraphicsContext.restoreGraphicsState()
}
func draw() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
    surface(tile, top: 0xFAF8F2, bottom: 0xEAE7DF,
        shadowColor: .black.withAlphaComponent(0.18), blur: 22, drop: 10)
    NSColor.white.withAlphaComponent(0.8).setStroke()
    tile.lineWidth = 3; tile.stroke()

    activityCard(NSRect(x: 250, y: 548, width: 200, height: 200),
        top: 0xB9B2FF, bottom: 0x8982DB, angle: 9)
    activityCard(NSRect(x: 576, y: 276, width: 200, height: 200),
        top: 0xFFC49B, bottom: 0xEE9C79, angle: -9)

    let capsule = NSBezierPath(roundedRect: NSRect(x: 212, y: 402, width: 600, height: 220), xRadius: 110, yRadius: 110)
    surface(capsule, top: 0x303135, bottom: 0x101114,
        shadowColor: .black.withAlphaComponent(0.23), blur: 30, drop: 20)
    NSGraphicsContext.saveGraphicsState()
    capsule.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.10), ending: .clear)!
        .draw(fromCenter: NSPoint(x: 330, y: 650), radius: 0,
            toCenter: NSPoint(x: 330, y: 650), radius: 440, options: [])
    NSGradient(starting: color(0xAAB8C4).withAlphaComponent(0.13), ending: .clear)!
        .draw(fromCenter: NSPoint(x: 655, y: 375), radius: 0,
            toCenter: NSPoint(x: 655, y: 375), radius: 190, options: [])
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.12).setStroke()
    capsule.lineWidth = 2; capsule.stroke()
}
for (name, pixels) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
    (transform as NSAffineTransform).concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
}
// Store PNG-backed ICNS representations directly; no external image converter.
if CommandLine.arguments.count > 2 {
    func integer(_ value: Int) -> Data {
        var big = UInt32(value).bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }
    var chunks = Data()
    for (type, name) in [("icp4", "icon_16x16"), ("icp5", "icon_32x32"), ("icp6", "icon_32x32@2x"), ("ic07", "icon_128x128"), ("ic08", "icon_256x256"), ("ic09", "icon_512x512"), ("ic10", "icon_512x512@2x"), ("ic11", "icon_16x16@2x"), ("ic12", "icon_32x32@2x"), ("ic13", "icon_128x128@2x"), ("ic14", "icon_256x256@2x")] {
        let png = try Data(contentsOf: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
        chunks.append(Data(type.utf8)); chunks.append(integer(png.count + 8)); chunks.append(png)
    }
    var container = Data("icns".utf8)
    container.append(integer(chunks.count + 8)); container.append(chunks)
    try container.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
}
