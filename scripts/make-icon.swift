// Renders the FinderPin app icon into an .iconset directory.
// usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func symbol(_ name: String, _ pointSize: CGFloat, _ color: NSColor) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(.init(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGradient(starting: NSColor(calibratedRed: 0.38, green: 0.78, blue: 1.0, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.95, alpha: 1))!.draw(in: path, angle: -90)

    let folder = symbol("folder.fill", s * 0.42, .white)
    let fs = folder.size
    folder.draw(in: NSRect(x: (s - fs.width) / 2, y: (s - fs.height) / 2 - s * 0.04, width: fs.width, height: fs.height))

    let pin = symbol("pin.fill", s * 0.20, NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.25, alpha: 1))
    let ps = pin.size
    pin.draw(in: NSRect(x: s * 0.60, y: s * 0.56, width: ps.width, height: ps.height))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
