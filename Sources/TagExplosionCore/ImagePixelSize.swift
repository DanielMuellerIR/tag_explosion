// Liest Breite und Höhe eines Bildes aus den ersten Bytes — ohne das Bild zu
// dekodieren und ohne CoreGraphics, damit der Core unter Linux baubar bleibt.
// Reicht für die Konsistenzprüfung (sind alle Cover eines Albums gleich groß?)
// und braucht bei JPEG nur die Marker bis zum ersten Frame-Header.
import Foundation

public enum ImagePixelSize {

    /// Breite und Höhe in Pixeln; nil, wenn das Format unbekannt ist oder der
    /// Kopf unvollständig/kaputt ist. Erkannt werden JPEG, PNG, GIF, BMP und
    /// WebP — dieselben Formate wie `Artwork.sniffMimeType`.
    public static func read(from data: Data) -> (width: Int, height: Int)? {
        switch Artwork.sniffMimeType(from: data) {
        case "image/jpeg": return jpeg(data)
        case "image/png": return png(data)
        case "image/gif": return gif(data)
        case "image/bmp": return bmp(data)
        case "image/webp": return webp(data)
        default: return nil
        }
    }

    // Hilfsfunktionen für Byte-Zugriff. Die Daten können mit einem beliebigen
    // Start-Index kommen (Data-Slices), deshalb immer über `startIndex`.
    private static func byte(_ data: Data, _ offset: Int) -> Int? {
        guard offset >= 0, offset < data.count else { return nil }
        return Int(data[data.startIndex + offset])
    }

    private static func u16be(_ data: Data, _ offset: Int) -> Int? {
        guard let high = byte(data, offset), let low = byte(data, offset + 1) else { return nil }
        return high << 8 | low
    }

    private static func u16le(_ data: Data, _ offset: Int) -> Int? {
        guard let low = byte(data, offset), let high = byte(data, offset + 1) else { return nil }
        return high << 8 | low
    }

    private static func u32be(_ data: Data, _ offset: Int) -> Int? {
        guard let high = u16be(data, offset), let low = u16be(data, offset + 2) else { return nil }
        return high << 16 | low
    }

    private static func u32le(_ data: Data, _ offset: Int) -> Int? {
        guard let low = u16le(data, offset), let high = u16le(data, offset + 2) else { return nil }
        return high << 16 | low
    }

    /// 24-Bit Little Endian (WebP VP8X).
    private static func u24le(_ data: Data, _ offset: Int) -> Int? {
        guard let low = u16le(data, offset), let high = byte(data, offset + 2) else { return nil }
        return high << 16 | low
    }

    /// PNG: IHDR ist immer der erste Chunk; Breite ab Byte 16, Höhe ab 20.
    private static func png(_ data: Data) -> (Int, Int)? {
        guard let width = u32be(data, 16), let height = u32be(data, 20),
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// GIF: „Logical Screen" ab Byte 6, zwei Little-Endian-Werte.
    private static func gif(_ data: Data) -> (Int, Int)? {
        guard let width = u16le(data, 6), let height = u16le(data, 8),
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// BMP: BITMAPINFOHEADER ab Byte 14; Breite bei 18, Höhe bei 22 (kann
    /// negativ sein = Zeilen von oben nach unten, deshalb der Betrag).
    private static func bmp(_ data: Data) -> (Int, Int)? {
        guard let width = u32le(data, 18), let rawHeight = u32le(data, 22) else { return nil }
        let height = rawHeight >= 0x8000_0000 ? 0x1_0000_0000 - rawHeight : rawHeight
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// JPEG: Marker-Segmente überspringen, bis ein Start-of-Frame (SOF0–SOF15,
    /// ohne die Nicht-Frame-Marker DHT C4, JPG C8 und DAC CC) erscheint; dort
    /// stehen Höhe (Byte 5–6) und Breite (Byte 7–8) des Segments.
    private static func jpeg(_ data: Data) -> (Int, Int)? {
        var offset = 2 // hinter SOI (FF D8)
        while offset + 4 <= data.count {
            guard byte(data, offset) == 0xFF else { return nil }
            guard let marker = byte(data, offset + 1) else { return nil }
            // Füll-Bytes (FF FF …) überspringen.
            if marker == 0xFF { offset += 1; continue }
            // Marker ohne Länge (RSTn, SOI, TEM) kommen vor dem Frame kaum
            // vor; der Vollständigkeit halber überspringen.
            if (0xD0...0xD7).contains(marker) || marker == 0x01 || marker == 0xD8 {
                offset += 2
                continue
            }
            guard let length = u16be(data, offset + 2), length >= 2 else { return nil }
            let isFrame = (0xC0...0xCF).contains(marker)
                && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if isFrame {
                guard let height = u16be(data, offset + 5), let width = u16be(data, offset + 7),
                      width > 0, height > 0 else { return nil }
                return (width, height)
            }
            offset += 2 + length
        }
        return nil
    }

    /// WebP: RIFF-Container, ab Byte 12 der erste Chunk („VP8 ", „VP8L" oder
    /// „VP8X"), jeder mit eigenem Größenfeld.
    private static func webp(_ data: Data) -> (Int, Int)? {
        guard data.count >= 30 else { return nil }
        let chunk = String(decoding: data[data.startIndex + 12 ..< data.startIndex + 16], as: UTF8.self)
        switch chunk {
        case "VP8X":
            // Erweitertes Format: 24-Bit-Werte minus 1 ab Byte 24 und 27.
            guard let width = u24le(data, 24), let height = u24le(data, 27) else { return nil }
            return (width + 1, height + 1)
        case "VP8 ":
            // Verlustbehaftet: nach dem Frame-Tag (3 Byte) und dem Start-Code
            // (9D 01 2A) folgen Breite und Höhe als 14 Bit, ab Byte 26/28.
            guard byte(data, 23) == 0x9D, byte(data, 24) == 0x01, byte(data, 25) == 0x2A,
                  let width = u16le(data, 26), let height = u16le(data, 28) else { return nil }
            return (width & 0x3FFF, height & 0x3FFF)
        case "VP8L":
            // Verlustfrei: Signatur 2F ab Byte 20, dann 14 Bit Breite-1 und
            // 14 Bit Höhe-1 gepackt in 4 Bytes ab Byte 21.
            guard byte(data, 20) == 0x2F, let bits = u32le(data, 21) else { return nil }
            let width = (bits & 0x3FFF) + 1
            let height = ((bits >> 14) & 0x3FFF) + 1
            return (width, height)
        default:
            return nil
        }
    }
}
