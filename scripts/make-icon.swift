// Renders Resources/AppIcon.icns ("Midnight"): a near-black squircle with a pixel-art notch whose
// "working" dots glow in T3 Code's indigo.
// Run: swift scripts/make-icon.swift [repo root]   (needs iconutil, ships with macOS)
// Also writes docs/icon.png (1024px) for the README and site.
import AppKit

func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

let indigo = color(0x6B83FF)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Body: macOS icon grid keeps ~10% margin. T3's dark-mode near-black, a touch lighter at the top.
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    squircle.addClip()
    NSGradient(colors: [color(0x1A1F2E), color(0x050608)])!.draw(in: squircle, angle: -90)

    // Everything else sits on a 16×16 pixel grid; rows count down from the top.
    let grid = 16, cell = body.width / CGFloat(grid)
    func pixel(_ x: Int, _ y: Int, _ c: NSColor) {
        c.setFill()
        NSRect(x: body.minX + CGFloat(x) * cell, y: body.maxY - CGFloat(y + 1) * cell,
               width: cell + 0.5, height: cell + 0.5).fill()
    }

    // Indigo glow behind the notch.
    let center = NSPoint(x: body.midX, y: body.maxY - 2.5 * cell)
    NSGradient(colors: [indigo.withAlphaComponent(0.30), indigo.withAlphaComponent(0)])!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: body.width * 0.42, options: [])

    // The notch: stepped like pixel art, wider at the top edge.
    let rows = [(2, 13), (3, 12), (3, 12), (3, 12), (4, 11)]
    for (y, span) in rows.enumerated() { for x in span.0...span.1 { pixel(x, y, .black) } }

    // The working dots, mid-sweep.
    pixel(5, 2, indigo.withAlphaComponent(0.45))
    pixel(7, 2, indigo)
    pixel(8, 2, indigo)
    pixel(10, 2, indigo.withAlphaComponent(0.7))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try render(1024).write(to: root.appendingPathComponent("docs/icon.png"))
guard p.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed (status \(p.terminationStatus))\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote \(out.path) and docs/icon.png")
