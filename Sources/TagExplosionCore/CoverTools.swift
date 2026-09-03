// Cover-Werkzeuge: Bildanalyse (Maße, Format, Farbraum), Prüfregeln,
// Umwandlung (verkleinern, JPEG/PNG, Metadaten entfernen) und Ordner-Cover
// (folder.jpg & Co.).
//
// Plattformgrenze: Die Analyse von JPEG und PNG läuft über eigenes
// Header-Parsing und damit überall. Andere Formate (GIF, BMP, WebP) und jede
// Umwandlung, die neu kodiert (verkleinern, Format wechseln), brauchen
// ImageIO/CoreGraphics und gibt es deshalb nur auf Apple-Plattformen; unter
// Linux kommt `CoverToolError.conversionUnavailable` statt einer stillen
// Falschmeldung. Das verlustfreie Entfernen von Metadaten (EXIF/XMP/Text-
// Chunks) arbeitet auf Byte-Ebene und läuft ebenfalls überall.
import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

// MARK: - Analyse

/// Prüfregel-Codes. Die Rohwerte sind zugleich die JSON-/CLI-Schreibweise.
public enum CoverIssueCode: String, Sendable, Codable, CaseIterable {
    /// Kürzere Kante unter `CoverTools.minimumEdge` Pixeln.
    case tooSmall = "too-small"
    /// Längere Kante über `CoverTools.maximumEdge` Pixeln.
    case tooLarge = "too-large"
    /// Mehr als `CoverTools.maximumBytes` Bytes.
    case tooManyBytes = "too-many-bytes"
    /// Seitenverhältnis weicht mehr als `CoverTools.squareTolerance` von 1:1 ab.
    case notSquare = "not-square"
    /// Progressives JPEG — manche Player und Autoradios zeigen es nicht an.
    case progressiveJPEG = "progressive-jpeg"
    /// CMYK-JPEG (Druckvorstufe) — viele Player können das nicht dekodieren.
    case cmyk = "cmyk"
    /// Kein bekanntes Bildformat oder Header nicht lesbar.
    case unknownFormat = "unknown-format"
}

/// Ein Prüfhinweis mit Code und englischem Klartext (CLI-Konvention; die App
/// übersetzt anhand des Codes).
public struct CoverIssue: Sendable, Codable, Equatable {
    public var code: CoverIssueCode
    public var message: String

    public init(code: CoverIssueCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// Ergebnis der Cover-Analyse. Maße sind nil, wenn der Header nicht lesbar war.
public struct CoverAnalysis: Sendable, Codable, Equatable {
    /// MIME-Type nach Magic Bytes, leer = unbekannt.
    public var mimeType: String
    /// Kurzname des Formats ("JPEG", "PNG", "GIF", "BMP", "WebP", "unknown").
    public var format: String
    public var bytes: Int
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// Breite geteilt durch Höhe; nil ohne Maße.
    public var aspectRatio: Double?
    /// Farbmodell ("RGB", "Gray", "CMYK", "Indexed"); nil, wenn unbekannt.
    public var colorModel: String?
    public var hasAlpha: Bool?
    /// Nur bei JPEG gesetzt.
    public var isProgressiveJPEG: Bool?
    public var issues: [CoverIssue]

    public init(mimeType: String, format: String, bytes: Int, pixelWidth: Int?, pixelHeight: Int?,
                colorModel: String?, hasAlpha: Bool?, isProgressiveJPEG: Bool?, issues: [CoverIssue] = []) {
        self.mimeType = mimeType
        self.format = format
        self.bytes = bytes
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        if let pixelWidth, let pixelHeight, pixelHeight > 0 {
            self.aspectRatio = Double(pixelWidth) / Double(pixelHeight)
        } else {
            self.aspectRatio = nil
        }
        self.colorModel = colorModel
        self.hasAlpha = hasAlpha
        self.isProgressiveJPEG = isProgressiveJPEG
        self.issues = issues
    }

    /// Kurzform für Anzeigen: "JPEG · 500×500 px · 48 KB".
    public var summary: String {
        var parts = [format]
        if let pixelWidth, let pixelHeight { parts.append("\(pixelWidth)×\(pixelHeight) px") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        if let colorModel { parts.append(colorModel + (hasAlpha == true ? "+Alpha" : "")) }
        return parts.joined(separator: " · ")
    }
}

/// Fehler der Cover-Werkzeuge. Englische Texte wie bei `TagError`.
public enum CoverToolError: Error, LocalizedError, Sendable, Equatable {
    /// Die Daten sind kein Bild, das die Werkzeuge verstehen.
    case unsupportedImage
    /// Neu kodieren (verkleinern, Format wechseln) geht nur mit ImageIO.
    case conversionUnavailable
    /// ImageIO konnte das Bild nicht dekodieren oder kodieren.
    case conversionFailed(reason: String)
    /// Zieldatei des Ordner-Covers existiert schon (ohne `force`).
    case targetExists(path: String)
    /// Neben der Datei liegt kein folder.jpg/cover.jpg/front.jpg.
    case noFolderCover(directory: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            return "Cover data is not a supported image (JPEG, PNG, GIF, BMP, WebP)"
        case .conversionUnavailable:
            return "Cover conversion is not available on this platform (needs ImageIO)"
        case .conversionFailed(let reason):
            return "Cover conversion failed: \(reason)"
        case .targetExists(let path):
            return "Output file already exists (use --force to replace it): \(path)"
        case .noFolderCover(let directory):
            return "No folder cover (folder/cover/front .jpg/.png) found in: \(directory)"
        }
    }
}

public enum CoverTools {

    /// Verkleinern und Format wechseln brauchen ImageIO (Apple-Plattformen).
    /// Anzeigen, Prüfen, Metadaten entfernen und Ordner-Cover gehen überall.
    public static var isConversionAvailable: Bool {
        #if canImport(ImageIO)
        return true
        #else
        return false
        #endif
    }
    /// Prüfgrenzen. 300 px ist die Untergrenze, ab der Cover in Listen und auf
    /// Geräten nicht mehr verwaschen wirken; 3000 px bzw. 2 MiB sind die
    /// Obergrenzen, über denen manche Player (Autoradios, alte iPods) das Bild
    /// verweigern oder das Laden spürbar bremsen.
    public static let minimumEdge = 300
    public static let maximumEdge = 3000
    public static let maximumBytes = 2 * 1024 * 1024
    /// Erlaubte Abweichung des Seitenverhältnisses von 1:1 (5 %).
    public static let squareTolerance = 0.05

    /// Analysiert Bilddaten und wendet die Prüfregeln an. Wirft nie: Ein
    /// unlesbares Bild ergibt Maße nil und den Hinweis `unknown-format`.
    public static func analyze(_ data: Data) -> CoverAnalysis {
        let mime = Artwork.sniffMimeType(from: data) ?? ""
        var analysis = CoverAnalysis(mimeType: mime, format: formatName(for: mime), bytes: data.count,
                                     pixelWidth: nil, pixelHeight: nil, colorModel: nil,
                                     hasAlpha: nil, isProgressiveJPEG: nil)
        switch mime {
        case "image/jpeg":
            if let header = JPEGHeader.parse(data) {
                analysis = CoverAnalysis(mimeType: mime, format: "JPEG", bytes: data.count,
                                         pixelWidth: header.width, pixelHeight: header.height,
                                         colorModel: header.colorModel, hasAlpha: false,
                                         isProgressiveJPEG: header.isProgressive)
            }
        case "image/png":
            if let header = PNGHeader.parse(data) {
                analysis = CoverAnalysis(mimeType: mime, format: "PNG", bytes: data.count,
                                         pixelWidth: header.width, pixelHeight: header.height,
                                         colorModel: header.colorModel, hasAlpha: header.hasAlpha,
                                         isProgressiveJPEG: nil)
            }
        default:
            #if canImport(ImageIO)
            if !mime.isEmpty, let props = imageIOProperties(data) {
                analysis = CoverAnalysis(mimeType: mime, format: formatName(for: mime), bytes: data.count,
                                         pixelWidth: props.width, pixelHeight: props.height,
                                         colorModel: props.colorModel, hasAlpha: props.hasAlpha,
                                         isProgressiveJPEG: nil)
            }
            #endif
        }
        analysis.issues = issues(for: analysis)
        return analysis
    }

    /// Prüfregeln auf ein Analyseergebnis anwenden (ohne `issues`-Feld).
    public static func issues(for analysis: CoverAnalysis) -> [CoverIssue] {
        guard let width = analysis.pixelWidth, let height = analysis.pixelHeight, width > 0, height > 0 else {
            return [CoverIssue(code: .unknownFormat,
                               message: "Not a readable JPEG/PNG/GIF/BMP/WebP image")]
        }
        var issues: [CoverIssue] = []
        let shortEdge = min(width, height)
        let longEdge = max(width, height)
        if shortEdge < minimumEdge {
            issues.append(CoverIssue(code: .tooSmall,
                                     message: "Image is only \(width)×\(height) px (recommended: at least \(minimumEdge) px)"))
        }
        if longEdge > maximumEdge {
            issues.append(CoverIssue(code: .tooLarge,
                                     message: "Image is \(width)×\(height) px (recommended: at most \(maximumEdge) px)"))
        }
        if analysis.bytes > maximumBytes {
            issues.append(CoverIssue(code: .tooManyBytes,
                                     message: "Image is \(analysis.bytes) bytes (recommended: at most \(maximumBytes) bytes)"))
        }
        let ratio = Double(width) / Double(height)
        if abs(ratio - 1) > squareTolerance {
            issues.append(CoverIssue(code: .notSquare,
                                     message: String(format: "Image is not square (aspect ratio %.2f)", ratio)))
        }
        if analysis.isProgressiveJPEG == true {
            issues.append(CoverIssue(code: .progressiveJPEG,
                                     message: "Progressive JPEG — some players cannot display it"))
        }
        if analysis.colorModel == "CMYK" {
            issues.append(CoverIssue(code: .cmyk,
                                     message: "CMYK color — many players cannot decode it"))
        }
        return issues
    }

    static func formatName(for mimeType: String) -> String {
        switch mimeType {
        case "image/jpeg": return "JPEG"
        case "image/png": return "PNG"
        case "image/gif": return "GIF"
        case "image/bmp": return "BMP"
        case "image/webp": return "WebP"
        default: return "unknown"
        }
    }

    // MARK: - Umwandlung

    /// Zielformat einer Umwandlung.
    public enum OutputFormat: String, Sendable, Codable, CaseIterable {
        case jpeg
        case png

        public var mimeType: String {
            switch self {
            case .jpeg: return "image/jpeg"
            case .png: return "image/png"
            }
        }
    }

    /// Was `convert` tun soll. Alles optional; ohne Auftrag kommt das Bild
    /// unverändert zurück.
    public struct Conversion: Sendable, Equatable {
        /// Längere Kante auf höchstens so viele Pixel verkleinern (Seiten-
        /// verhältnis bleibt). Kleinere Bilder werden nicht vergrößert und —
        /// ohne weiteren Auftrag — auch nicht neu kodiert.
        public var maxPixelSize: Int?
        /// Zielformat. Gesetzt heißt: immer neu kodieren, auch wenn das Bild
        /// schon dieses Format hat (so lässt sich ein JPEG mit `jpegQuality`
        /// nachkomprimieren).
        public var format: OutputFormat?
        /// JPEG-Qualität 0…1 (Voreinstellung 0,85).
        public var jpegQuality: Double
        /// EXIF/XMP/IPTC/Text-Chunks entfernen. Ohne Neukodierung verlustfrei
        /// auf Byte-Ebene; mit Neukodierung ergibt sich das von selbst.
        public var stripMetadata: Bool

        public init(maxPixelSize: Int? = nil, format: OutputFormat? = nil,
                    jpegQuality: Double = 0.85, stripMetadata: Bool = false) {
            self.maxPixelSize = maxPixelSize
            self.format = format
            self.jpegQuality = jpegQuality
            self.stripMetadata = stripMetadata
        }

        public var isNoop: Bool { maxPixelSize == nil && format == nil && !stripMetadata }
    }

    /// Wandelt Bilddaten gemäß `conversion`. Liefert die Eingabe unverändert
    /// zurück, wenn nichts zu tun ist (z.B. Bild schon klein genug).
    public static func convert(_ data: Data, _ conversion: Conversion) throws -> Data {
        let analysis = analyze(data)
        guard let width = analysis.pixelWidth, let height = analysis.pixelHeight, width > 0, height > 0 else {
            throw CoverToolError.unsupportedImage
        }
        let needsShrink = conversion.maxPixelSize.map { max(width, height) > $0 } ?? false
        if conversion.format != nil || needsShrink {
            let target = conversion.format
                ?? (analysis.mimeType == "image/png" ? OutputFormat.png : OutputFormat.jpeg)
            return try reencode(data, maxPixelSize: needsShrink ? conversion.maxPixelSize : nil,
                                format: target, jpegQuality: conversion.jpegQuality)
        }
        if conversion.stripMetadata {
            return try stripMetadata(data)
        }
        return data
    }

    /// Wie `convert(_:_:)`, hält aber Bildtyp und Beschreibung des Artworks
    /// und setzt den MIME-Type auf das neue Format.
    public static func convert(_ artwork: Artwork, _ conversion: Conversion) throws -> Artwork {
        let data = try convert(artwork.data, conversion)
        guard data != artwork.data else { return artwork }
        return Artwork(data: data, mimeType: Artwork.sniffMimeType(from: data) ?? "",
                       pictureType: artwork.pictureType, description: artwork.description)
    }

    /// Entfernt Metadaten verlustfrei: bei JPEG die APP-Segmente mit EXIF,
    /// XMP, IPTC/Photoshop und Kommentare (JFIF-, ICC- und Adobe-Segment
    /// bleiben, sonst stimmen Farben nicht mehr); bei PNG die Text-, Zeit-
    /// und eXIf-Chunks. Andere Formate kommen unverändert zurück.
    public static func stripMetadata(_ data: Data) throws -> Data {
        switch Artwork.sniffMimeType(from: data) {
        case "image/jpeg":
            guard let stripped = JPEGHeader.stripMetadata(data) else { throw CoverToolError.unsupportedImage }
            return stripped
        case "image/png":
            guard let stripped = PNGHeader.stripMetadata(data) else { throw CoverToolError.unsupportedImage }
            return stripped
        case nil:
            throw CoverToolError.unsupportedImage
        default:
            return data
        }
    }

    /// Neu kodieren über ImageIO: dekodieren, ggf. verkleinern, in einen
    /// sRGB-Kontext zeichnen (das wandelt CMYK und flacht Transparenz für JPEG
    /// auf Weiß ab) und als JPEG oder PNG ohne Metadaten ausgeben.
    static func reencode(_ data: Data, maxPixelSize: Int?, format: OutputFormat,
                         jpegQuality: Double) throws -> Data {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CoverToolError.conversionFailed(reason: "image could not be decoded")
        }
        // Das Thumbnail-API skaliert in einem Schritt hochwertig und wendet die
        // EXIF-Ausrichtung an. `MaxPixelSize` ist Pflicht; ohne Verkleinerung
        // nehmen wir die längere Originalkante.
        let analysis = analyze(data)
        let longEdge = max(analysis.pixelWidth ?? 0, analysis.pixelHeight ?? 0)
        let limit = maxPixelSize ?? longEdge
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard limit > 0,
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CoverToolError.conversionFailed(reason: "image could not be decoded")
        }
        let hasAlpha: Bool
        switch decoded.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let keepAlpha = format == .png && hasAlpha
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: decoded.width, height: decoded.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: colorSpace,
                bitmapInfo: (keepAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)
        else {
            throw CoverToolError.conversionFailed(reason: "drawing context could not be created")
        }
        let rect = CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height)
        if !keepAlpha {
            context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1]) ?? CGColor(gray: 1, alpha: 1))
            context.fill(rect)
        }
        context.interpolationQuality = .high
        context.draw(decoded, in: rect)
        guard let image = context.makeImage() else {
            throw CoverToolError.conversionFailed(reason: "image could not be rendered")
        }

        let output = NSMutableData()
        let typeIdentifier = (format == .png ? "public.png" : "public.jpeg") as CFString
        guard let destination = CGImageDestinationCreateWithData(output, typeIdentifier, 1, nil) else {
            throw CoverToolError.conversionFailed(reason: "encoder for \(format.rawValue) not available")
        }
        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(jpegQuality, 0), 1)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CoverToolError.conversionFailed(reason: "encoding failed")
        }
        return output as Data
        #else
        throw CoverToolError.conversionUnavailable
        #endif
    }

    #if canImport(ImageIO)
    /// Maße/Farbmodell für Formate ohne eigenen Header-Parser (GIF, BMP, WebP).
    private static func imageIOProperties(_ data: Data)
        -> (width: Int, height: Int, colorModel: String?, hasAlpha: Bool?)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height, props[kCGImagePropertyColorModel] as? String,
                props[kCGImagePropertyHasAlpha] as? Bool)
    }
    #endif
}

// MARK: - Header-Parser (plattformneutral)

/// JPEG-Segmente lesen: Maße, Komponentenzahl und Progressiv-Flag aus dem
/// SOF-Marker; Metadaten-Segmente entfernen.
enum JPEGHeader {
    struct Info: Equatable {
        var width: Int
        var height: Int
        var components: Int
        var isProgressive: Bool

        var colorModel: String {
            switch components {
            case 1: return "Gray"
            case 4: return "CMYK"
            default: return "RGB"
            }
        }
    }

    /// Durchläuft die Segmente bis zum ersten SOF (Start of Frame). SOF0/1
    /// sind Baseline/Extended, SOF2 ist progressiv (ebenso 6, 10, 14).
    static func parse(_ data: Data) -> Info? {
        var info: Info?
        walkSegments(data) { marker, payload in
            let sofMarkers: Set<UInt8> = [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                                          0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]
            guard sofMarkers.contains(marker), payload.count >= 6 else { return true }
            let bytes = [UInt8](payload)
            info = Info(width: Int(bytes[3]) << 8 | Int(bytes[4]),
                        height: Int(bytes[1]) << 8 | Int(bytes[2]),
                        components: Int(bytes[5]),
                        isProgressive: [0xC2, 0xC6, 0xCA, 0xCE].contains(marker))
            return false
        }
        return info
    }

    /// Baut die Datei ohne die Metadaten-Segmente neu auf. Behalten werden
    /// APP0 (JFIF), APP2 (ICC-Profil, sonst falsche Farben) und APP14 (Adobe,
    /// nötig zum Dekodieren von CMYK/YCCK). Alles ab SOS (Bilddaten) wird
    /// unverändert übernommen. nil, wenn die Struktur nicht lesbar ist.
    static func stripMetadata(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var output = Data([0xFF, 0xD8])
        var index = 2
        let keep: Set<UInt8> = [0xE0, 0xE2, 0xEE]
        while index + 4 <= bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let marker = bytes[index + 1]
            if marker == 0xFF { index += 1; continue } // Füllbytes
            if marker == 0xD9 || marker == 0xDA {
                // EOI oder SOS: Rest (Bilddaten) unverändert anhängen.
                output.append(contentsOf: bytes[index...])
                return output
            }
            let standalone: Set<UInt8> = [0x01, 0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8]
            if standalone.contains(marker) {
                output.append(contentsOf: bytes[index..<index + 2])
                index += 2
                continue
            }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2, index + 2 + length <= bytes.count else { return nil }
            let isMetadata = (0xE1...0xEF).contains(marker) && !keep.contains(marker) || marker == 0xFE
            if !isMetadata {
                output.append(contentsOf: bytes[index..<index + 2 + length])
            }
            index += 2 + length
        }
        return nil
    }

    /// Ruft `visit(marker, payload)` je Segment bis SOS auf; `false` bricht ab.
    private static func walkSegments(_ data: Data, visit: (UInt8, Data) -> Bool) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return }
        var index = 2
        while index + 4 <= bytes.count {
            guard bytes[index] == 0xFF else { return }
            let marker = bytes[index + 1]
            if marker == 0xFF { index += 1; continue }
            if marker == 0xD9 || marker == 0xDA { return }
            let standalone: Set<UInt8> = [0x01, 0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8]
            if standalone.contains(marker) { index += 2; continue }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2, index + 2 + length <= bytes.count else { return }
            let payload = data.subdata(in: (index + 4)..<(index + 2 + length))
            if !visit(marker, payload) { return }
            index += 2 + length
        }
    }
}

/// PNG-Chunks lesen: Maße und Farbtyp aus IHDR, Transparenz aus Farbtyp oder
/// tRNS-Chunk; Text-/Zeit-/eXIf-Chunks entfernen.
enum PNGHeader {
    struct Info: Equatable {
        var width: Int
        var height: Int
        var colorType: Int
        var hasTransparencyChunk: Bool

        var hasAlpha: Bool { colorType == 4 || colorType == 6 || hasTransparencyChunk }

        var colorModel: String {
            switch colorType {
            case 0, 4: return "Gray"
            case 3: return "Indexed"
            default: return "RGB"
            }
        }
    }

    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func parse(_ data: Data) -> Info? {
        var info: Info?
        walkChunks(data) { type, payload in
            if type == "IHDR", payload.count >= 13 {
                let b = [UInt8](payload)
                info = Info(width: Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3]),
                            height: Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7]),
                            colorType: Int(b[9]), hasTransparencyChunk: false)
            } else if type == "tRNS" {
                info?.hasTransparencyChunk = true
            }
            // Ab den Bilddaten kommt nichts mehr, was uns interessiert.
            return type != "IDAT"
        }
        return info
    }

    /// Baut die Datei ohne Metadaten-Chunks neu auf (tEXt, zTXt, iTXt, eXIf,
    /// tIME). Alle anderen Chunks bleiben byteidentisch, die CRCs mit ihnen.
    static func stripMetadata(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Array(bytes[0..<8]) == signature else { return nil }
        var output = Data(bytes[0..<8])
        var index = 8
        let drop: Set<String> = ["tEXt", "zTXt", "iTXt", "eXIf", "tIME"]
        while index + 12 <= bytes.count {
            let length = Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16
                | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let type = String(decoding: bytes[(index + 4)..<(index + 8)], as: UTF8.self)
            let end = index + 12 + length
            guard end <= bytes.count else { return nil }
            if !drop.contains(type) {
                output.append(contentsOf: bytes[index..<end])
            }
            index = end
            if type == "IEND" { break }
        }
        return index >= 8 ? output : nil
    }

    private static func walkChunks(_ data: Data, visit: (String, Data) -> Bool) {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Array(bytes[0..<8]) == signature else { return }
        var index = 8
        while index + 12 <= bytes.count {
            let length = Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16
                | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let type = String(decoding: bytes[(index + 4)..<(index + 8)], as: UTF8.self)
            let end = index + 12 + length
            guard end <= bytes.count else { return }
            let payload = data.subdata(in: (index + 8)..<(index + 8 + length))
            if !visit(type, payload) { return }
            index = end
        }
    }
}

// MARK: - Ordner-Cover

/// Cover-Dateien neben den Mediendateien (`folder.jpg` & Co.).
public enum FolderCover {
    /// Prioritätsliste (Groß-/Kleinschreibung egal): Windows/Explorer-Name
    /// zuerst, dann die verbreiteten Alternativen; JPEG vor PNG.
    public static let candidateNames = [
        "folder.jpg", "folder.jpeg", "folder.png",
        "cover.jpg", "cover.jpeg", "cover.png",
        "front.jpg", "front.jpeg", "front.png",
    ]

    /// Findet die höchstpriorisierte Cover-Datei im Verzeichnis. Auf
    /// Dateisystemen mit Groß-/Kleinschreibung können mehrere Schreibweisen
    /// desselben Namens nebeneinander liegen; dann gewinnt die alphabetisch
    /// erste (deterministisch, damit CLI und App dasselbe wählen).
    public static func find(in directory: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        var byLowercase: [String: [String]] = [:]
        for name in names { byLowercase[name.lowercased(), default: []].append(name) }
        for candidate in candidateNames {
            if let matches = byLowercase[candidate], let first = matches.sorted().first {
                return directory.appendingPathComponent(first)
            }
        }
        return nil
    }

    /// Lädt das Ordner-Cover als Artwork; nil, wenn keins da ist. Wirft
    /// `unsupportedImage`, wenn die Datei kein erkennbares Bild ist.
    public static func load(in directory: URL) throws -> Artwork? {
        guard let url = find(in: directory) else { return nil }
        let data = try Data(contentsOf: url)
        guard Artwork.sniffMimeType(from: data) != nil else { throw CoverToolError.unsupportedImage }
        return Artwork(data: data, mimeType: Artwork.sniffMimeType(from: data) ?? "",
                       pictureType: "Front Cover")
    }

    /// Dateiname, unter dem `artwork` als Ordner-Cover landet: `folder.` plus
    /// Endung nach Magic Bytes (jpg, png, gif, webp, bmp). nil bei unbekannten
    /// Daten — eine `.jpg`-Endung auf Nicht-JPEG wäre eine Lüge.
    public static func exportFileName(for artwork: Artwork) -> String? {
        switch artwork.resolvedMimeType {
        case "image/jpeg": return "folder.jpg"
        case "image/png": return "folder.png"
        case "image/gif": return "folder.gif"
        case "image/webp": return "folder.webp"
        case "image/bmp": return "folder.bmp"
        default: return nil
        }
    }

    /// Schreibt das eingebettete Cover als `folder.<ext>` ins Verzeichnis.
    /// Ohne `force` bleibt eine vorhandene Datei stehen (`targetExists`); das
    /// exklusive Anlegen (`link`) schließt auch das Rennen zwischen Prüfung
    /// und Anlegen. Mit `force` läuft der Austausch wie jeder Schreibweg:
    /// Papierkorb-Sicherung, Geschwisterkopie, Prüfung, atomarer Tausch.
    /// Auch eine NEUE Datei entsteht erst als geprüfte Geschwister-Temp-Datei
    /// — ein Abbruch mittendrin hinterlässt so nie ein halbes `folder.jpg`,
    /// das später als vorhandenes Cover gälte.
    @discardableResult
    public static func export(_ artwork: Artwork, to directory: URL, force: Bool = false) throws -> URL {
        guard let name = exportFileName(for: artwork) else { throw CoverToolError.unsupportedImage }
        let target = directory.appendingPathComponent(name)
        let fileManager = FileManager.default
        let expected = artwork.resolvedMimeType
        let mutate: (URL) throws -> Void = { temp in try artwork.data.write(to: temp) }
        // Magic-Byte-Prüfung: Die geschriebene Datei muss das Bild sein, das
        // der Dateiname verspricht.
        let validate: (URL) throws -> Void = { temp in
            guard Artwork.sniffMimeType(from: try Data(contentsOf: temp)) == expected else {
                throw TagError.saveFailed(path: target.path)
            }
        }
        if force, fileManager.fileExists(atPath: target.path) {
            try TrashBackup.shared.backUp(target)
            try AtomicFileRewrite.run(url: target, mutate: mutate, validate: validate)
            return target
        }
        do {
            try AtomicFileRewrite.create(url: target, replacingOriginal: true, beforeReplace: {},
                                         mutate: mutate, validate: validate)
        } catch TagError.fileChangedOnDisk {
            throw CoverToolError.targetExists(path: target.path)
        }
        return target
    }
}
