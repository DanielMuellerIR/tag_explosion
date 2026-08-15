// Generiert das App-Icon (AppIcon.icns) programmatisch — kein Designer nötig,
// reproduzierbar. Stil: Big-Sur-Squircle, warmer Verlauf, Tag-Symbol mit
// "Explosions"-Funken.
// Aufruf: swift scripts/make-icon.swift <ausgabe-verzeichnis>
import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Resources"

/// Zeichnet das Icon in gegebener Größe.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let s = size / 1024.0 // Skalierungsfaktor relativ zur Referenzgröße

    // Squircle mit Standard-Rand (Big-Sur-Icons füllen ~824/1024)
    let margin = 100 * s
    let rect = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)

    // Hintergrund-Verlauf: dunkles Violett → glühendes Orange (Explosion)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.09, blue: 0.30, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.15, blue: 0.35, alpha: 1),
        NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.15, alpha: 1),
    ])!
    gradient.draw(in: squircle, angle: -60)

    // Funken/Strahlen hinter dem Tag
    NSColor(calibratedWhite: 1.0, alpha: 0.25).setStroke()
    let center = NSPoint(x: size * 0.5, y: size * 0.52)
    for i in 0..<12 {
        let angle = CGFloat(i) * .pi / 6 + 0.26
        let inner = 300 * s, outer = (i % 2 == 0 ? 400 : 360) * s
        let path = NSBezierPath()
        path.lineWidth = 14 * s
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
        path.line(to: NSPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        path.stroke()
    }

    // Tag-Symbol (SF Symbol), leicht rotiert, weiß mit Schatten
    if let symbol = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: 430 * s, weight: .medium)
        let tag = symbol.withSymbolConfiguration(config)!
        let tinted = NSImage(size: tag.size)
        tinted.lockFocus()
        NSColor.white.set()
        let r = NSRect(origin: .zero, size: tag.size)
        tag.draw(in: r)
        r.fill(using: .sourceAtop)
        tinted.unlockFocus()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 30 * s
        shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
        shadow.set()

        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: -18)
        transform.concat()
        tinted.draw(at: NSPoint(x: -tinted.size.width / 2, y: -tinted.size.height / 2),
                    from: .zero, operation: .sourceOver, fraction: 1.0)
    }
    return image
}

func writePNG(_ image: NSImage, to url: URL, pixels: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// iconset mit allen Größen erzeugen, dann iconutil
let fm = FileManager.default
let temporaryRoot = fm.temporaryDirectory.appendingPathComponent(
    "tag-explosion-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = temporaryRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
do {
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("Tempordner nicht anlegbar: \(error)\n".utf8))
    exit(1)
}
defer { try? fm.removeItem(at: temporaryRoot) }

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                   ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512),
                   ("icon_512x512@2x", 1024)] {
    writePNG(drawIcon(size: CGFloat(px)), to: iconset.appendingPathComponent("\(name).png"), pixels: px)
}

do {
    try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("Ausgabeordner nicht anlegbar: \(error)\n".utf8))
    exit(1)
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "\(outDir)/AppIcon.icns"]
do {
    try task.run()
} catch {
    FileHandle.standardError.write(Data("iconutil konnte nicht starten: \(error)\n".utf8))
    exit(1)
}
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(
        Data("iconutil endete mit Status \(task.terminationStatus)\n".utf8))
    exit(1)
}
print("OK \(outDir)/AppIcon.icns")
