// Baut AppIcon.icns aus einem Quellbild (z.B. KI-generiert), das eine
// Icon-Kachel auf weissem Grund enthaelt:
//   1. Kachel per Bounding-Box-Erkennung ausschneiden (weisser Rand weg),
//   2. FULL-BLEED auf die komplette 1024er-Flaeche skalieren (kein HIG-Rand —
//      bewusste Gestaltungsentscheidung fuer ein maximal grosses Dock-Icon),
//   3. mit macOS-Squircle-Maske runden, alle Groessen + iconutil -> .icns.
// Aufruf: swift scripts/icon-from-image.swift <quelle.png> <ausgabe-verzeichnis>
import AppKit
import Foundation

guard CommandLine.arguments.count >= 3 else {
    print("Aufruf: icon-from-image.swift <quelle.png> <ausgabe-verzeichnis>")
    exit(2)
}
let sourcePath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

guard let source = NSImage(contentsOfFile: sourcePath),
      var cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { print("Quelle nicht lesbar: \(sourcePath)"); exit(1) }

// ---- 1) Bounding Box des Nicht-Weiss-Inhalts finden -------------------------

func contentBounds(of image: CGImage) -> CGRect {
    let w = image.width, h = image.height
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    // "Inhalt" = deutlich nicht-weiss (Schwelle 240 lässt den weichen
    // Schlagschatten der KI-Bilder draussen, nimmt aber die Kachel selbst mit).
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            if buffer[i] < 240 || buffer[i + 1] < 240 || buffer[i + 2] < 240 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    guard maxX > minX, maxY > minY else { return CGRect(x: 0, y: 0, width: w, height: h) }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

var box = contentBounds(of: cg)
// Quadratisch um den Mittelpunkt machen (Kachel ist quadratisch; Schatten o.ae.
// kann die Box leicht verzerren) und ~1,5 % einruecken, damit keine weichen
// weissen Antialias-Raender mitkommen.
let side = min(box.width, box.height)
let inset = side * 0.015
let square = CGRect(x: box.midX - side / 2 + inset, y: box.midY - side / 2 + inset,
                    width: side - 2 * inset, height: side - 2 * inset)
guard let cropped = cg.cropping(to: square) else { print("Zuschnitt fehlgeschlagen"); exit(1) }
cg = cropped
print("Kachel erkannt: \(Int(box.width))x\(Int(box.height)) px -> Zuschnitt \(cg.width)x\(cg.height)")

// ---- 2+3) Full-Bleed-Squircle in allen Groessen rendern ---------------------

func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    // macOS-Eckradius skaliert vom Standard-Squircle (185/824-Kachel) auf
    // die volle Flaeche: 185 * 1024/824 ≈ 230.
    let radius = size * 230.0 / 1024.0
    let clip = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                            xRadius: radius, yRadius: radius)
    clip.setClip()
    // Minimal ueberzeichnen (Bleed), damit an den Kanten nichts Weisses durchblitzt.
    let bleed = size * 0.004
    NSGraphicsContext.current?.cgContext.interpolationQuality = .high
    NSGraphicsContext.current?.cgContext.draw(
        cg, in: CGRect(x: -bleed, y: -bleed, width: size + 2 * bleed, height: size + 2 * bleed))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

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
    let rep = renderIcon(pixels: px)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent("\(name).png"))
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
