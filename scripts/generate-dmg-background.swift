import AppKit

// Erzeugt das DMG-Hintergrundbild als reproduzierbaren 2×-Master (1200 × 840 px)
// für die 600 × 420 Punkte große Finder-Inhaltsfläche. build.sh skaliert daraus
// die 1x-/2x-Varianten und kombiniert sie zu einem HiDPI-TIFF. Der Finder legt
// App- und Programme-Icon später genau über die beiden gestrichelten Kreise
// (Icon-Positionen im AppleScript von build.sh müssen dazu passen).
//
// Aufruf: swift scripts/generate-dmg-background.swift <ausgabe.png>

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Aufruf: swift generate-dmg-background.swift <ausgabe.png>\n".utf8))
    exit(2)
}
let outputPath = CommandLine.arguments[1]

let size = NSSize(width: 1200, height: 840)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(1) }
bitmap.size = size

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

// Zeichnet Text horizontal zentriert; y zählt von unten (AppKit-Ursprung).
func centeredText(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let measured = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (size.width - measured.width) / 2, y: y),
              withAttributes: attributes)
}

guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
let context = graphicsContext.cgContext

// Heller, leicht warmer Verlauf — neutral genug für Light- und Dark-Finder.
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0xFCFAF5).cgColor, color(0xF4EFE4).cgColor] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(gradient,
                           start: CGPoint(x: 600, y: 840),
                           end: CGPoint(x: 600, y: 0),
                           options: [])

let ink = color(0x2B2822)          // Titel
let muted = color(0x746F63)        // Untertitel und Hinweiszeile
let accent = color(0xE8641E)       // Orange wie die Explosion im App-Icon
let dashed = color(0xB8B1A0)       // gestrichelte Icon-Platzhalter

centeredText("Tag Explosion", y: 686,
             font: .systemFont(ofSize: 64, weight: .semibold), color: ink)
centeredText("Medien-Metadaten anzeigen und bearbeiten", y: 618,
             font: .systemFont(ofSize: 26, weight: .regular), color: muted)

// Kurzer Akzentstrich unter dem Untertitel.
context.setStrokeColor(accent.cgColor)
context.setLineWidth(7)
context.setLineCap(.round)
context.move(to: CGPoint(x: 543, y: 581))
context.addLine(to: CGPoint(x: 657, y: 581))
context.strokePath()

// Gestrichelte Kreise als Slots für App-Icon (links) und Programme-Ordner (rechts).
context.setStrokeColor(dashed.cgColor)
context.setLineWidth(4)
context.setLineDash(phase: 0, lengths: [19, 17])
for centerX in [300.0, 900.0] {
    context.strokeEllipse(in: CGRect(x: centerX - 128, y: 128, width: 256, height: 256))
}
context.setLineDash(phase: 0, lengths: [])

// Pfeil von der App zum Programme-Ordner.
context.setFillColor(accent.cgColor)
context.fill(CGRect(x: 476, y: 250, width: 207, height: 12))
context.beginPath()
context.move(to: CGPoint(x: 718, y: 256))
context.addLine(to: CGPoint(x: 680, y: 279))
context.addLine(to: CGPoint(x: 680, y: 233))
context.closePath()
context.fillPath()

centeredText("Zum Installieren in den Programme-Ordner ziehen · Drag to Applications to install",
             y: 36, font: .systemFont(ofSize: 20, weight: .regular), color: muted)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
