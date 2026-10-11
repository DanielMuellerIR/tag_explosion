import Foundation

/// Fremdbestände direkt als ID3v2.4 erzeugen, unabhängig von den Produkt-Schreibern.
public enum ID3TestFixtures {
    public static func installLegacyDetails(at url: URL, overlappingChapters: Bool = true,
                                            emptySyncedLyrics: Bool = true) throws {
        var audio = try Data(contentsOf: url)
        if audio.starts(with: Data("ID3".utf8)), audio.count >= 10 {
            let size = audio[6..<10].reduce(0) { ($0 << 7) | Int($1) }
            audio.removeFirst(10 + size)
        }
        var frames = Data()
        if overlappingChapters {
            for (index, start) in [0, 500].enumerated() {
                var chapter = Data("chapter\(index)\0".utf8)
                chapter += uint32(start) + uint32(start + 1000)
                chapter += Data(repeating: 0xFF, count: 8)
                chapter += frame("TIT2", Data([3]) + Data("Kapitel \(index)".utf8))
                frames += frame("CHAP", chapter)
            }
        }
        if emptySyncedLyrics {
            // UTF-8, Sprache eng, Millisekunden, Lyrics, leere Beschreibung, keine Zeilen.
            frames += frame("SYLT", Data([3]) + Data("eng".utf8) + Data([2, 1, 0]))
        }
        try (Data("ID3".utf8) + Data([4, 0, 0]) + syncsafe(frames.count) + frames + audio).write(to: url)
    }

    private static func frame(_ id: String, _ body: Data) -> Data {
        Data(id.utf8) + syncsafe(body.count) + Data([0, 0]) + body
    }

    private static func syncsafe(_ value: Int) -> Data {
        Data([21, 14, 7, 0].map { UInt8((value >> $0) & 0x7F) })
    }

    private static func uint32(_ value: Int) -> Data {
        Data([24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) })
    }
}
