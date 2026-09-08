// Gemeinsame Byte-Dekodierung für JSON, Klartext und Werkzeugfehler.
import Foundation

enum ExternalToolText {
    /// Bytes tolerant dekodieren: UTF-8 strikt; scheitert das, werden gültige
    /// UTF-8-Sequenzen ERHALTEN und nur die tatsächlich ungültigen Bytes in
    /// einer Ein-Byte-Kodierung gedeutet. Ein komplett umgeschalteter Bericht
    /// würde sonst wegen eines einzigen fremd kodierten Feldes auch korrekte
    /// UTF-8-Tags (etwa Emoji, deren Fortsetzungsbytes zufällig im C1-Bereich
    /// liegen) verstümmeln. mediainfo gibt rohe Tag-Bytes ungeprüft weiter;
    /// ID3v1/v2.3-Tags sind oft in einer Ein-Byte-Kodierung geschrieben und
    /// würden als UTF-8 gelesen zu Ersatzzeichen zerfallen.
    ///
    /// Entschieden wird je TEXTFELD, nicht je ungültigem Byte-Lauf: Ein Feld
    /// enthält seine fremden Bytes oft getrennt durch ASCII
    /// („Bäckereistraße" = 0x8A … 0xA7), und eine Entscheidung pro Lauf mischte
    /// darin zwei Kodierungen (Review-Fund 2026-08-18).
    ///
    /// Zur Wahl stehen MacRoman und Windows-1252. Windows-1252 statt reinem
    /// Latin-1, weil es in ID3v2.3 die real verbreitete Kodierung ist und
    /// 0x80–0x9F mit sichtbaren Zeichen belegt (Gedankenstrich, typografischer
    /// Apostroph, Auslassungspunkte) — für Bytes ab 0xA0 sind beide gleich.
    /// Gewählt wird nicht mehr allein am Vorkommen eines C1-Bytes, sondern über
    /// eine Plausibilitätswertung des ganzen Feldes: Ein C1-Byte neben einem
    /// Umlaut zog sonst ALLE Nicht-ASCII-Zeichen des Feldes auf MacRoman
    /// (Review-Fund 2026-08-20).
    /// Dekodiert JSON-Ausgabe externer Werkzeuge. Nur dieser Weg repariert die
    /// von MediaInfo erzeugten Lone-Surrogate-Escapes.
    static func decodeLossyJSON(_ data: Data) -> String {
        decodeLossy(data, repairingSurrogateEscapes: true)
    }

    /// Dekodiert Klartext oder stderr wortgetreu. Eine Ausgabe kann mit `[` oder
    /// `{` beginnen, ohne JSON zu sein; der Aufrufer kennt den Ausgabetyp.
    static func decodeLossyPlainText(_ data: Data) -> String {
        decodeLossy(data, repairingSurrogateEscapes: false)
    }

    private static func decodeLossy(
        _ data: Data,
        repairingSurrogateEscapes: Bool
    ) -> String {
        // Lone-Surrogates sind eine Besonderheit von MediaInfos JSON-Ausgabe.
        // In Klartext von MediaInfo, Calibre oder stderr ist `\udcfc` dagegen
        // wörtlicher Text und darf nicht zum Rohbyte 0xFC werden.
        let repaired = repairingSurrogateEscapes
            ? repairSurrogateEscapes(in: data)
            : data
        if let s = String(data: repaired, encoding: .utf8) { return s }

        // In Läufe aus gültigen UTF-8-Sequenzen und ungültigen Bytes zerlegen.
        let bytes = [UInt8](repaired)
        var runs: [(valid: Bool, range: Range<Int>)] = []
        var index = 0
        while index < bytes.count {
            let length = utf8SequenceLength(bytes, at: index)
            let valid = length != nil
            let next = index + (length ?? 1)
            if let last = runs.last, last.valid == valid {
                runs[runs.count - 1].range = last.range.lowerBound..<next
            } else {
                runs.append((valid, index..<next))
            }
            index = next
        }

        // Jeden Lauf seinem Textfeld zuordnen und dabei gleich merken, welche
        // Felder überhaupt fremde Bytes enthalten — beides in EINEM Durchlauf,
        // die Feldnummer steht ja schon fest, wenn der Lauf zugeordnet wird.
        //
        // Feldgrenze ist immer der Zeilenumbruch (Klartextausgaben von
        // mediainfo und Calibre); bei JSON zusätzlich das Anführungszeichen.
        // Nur bei JSON: In einer Klartextzeile steht das Anführungszeichen
        // mitten im Wert („Der \"Bär\" aus der Straße") und hätte das Feld
        // fälschlich geteilt (Review-Fund 2026-08-20). Beide Grenzzeichen sind
        // ASCII und können deshalb nie innerhalb eines ungültigen Laufs liegen:
        // Ein Byte unter 0x80 ist immer eine gültige UTF-8-Sequenz für sich.
        let quotesSeparateFields = repairingSurrogateEscapes
        var fieldOfRun = [Int](repeating: 0, count: runs.count)
        var foreignRunsByField: [Int: [Int]] = [:]
        var field = 0
        var backslashes = 0
        for (position, run) in runs.enumerated() {
            fieldOfRun[position] = field
            guard run.valid else {
                foreignRunsByField[field, default: []].append(position)
                backslashes = 0
                continue
            }
            for index in run.range {
                let byte = bytes[index]
                if byte == 0x0A || byte == 0x0D {
                    field += 1
                } else if byte == 0x22, quotesSeparateFields, backslashes % 2 == 0 {
                    // Ein maskiertes \" gehört zum Wert und trennt nicht.
                    field += 1
                }
                backslashes = byte == 0x5C ? backslashes + 1 : 0
            }
        }

        // Je Feld nur seine fremden Läufe bewerten. Eine erneute Suche im
        // ganzen Bericht pro Feld würde quadratisch mit der Feldzahl wachsen.
        var encodingOfField: [Int: SingleByteEncoding] = [:]
        for (field, positions) in foreignRunsByField {
            encodingOfField[field] = betterEncoding(
                runs: runs, positions: positions, bytes: bytes)
        }

        var out = ""
        for (position, run) in runs.enumerated() {
            if run.valid {
                out += String(decoding: bytes[run.range], as: UTF8.self)
            } else {
                let encoding = encodingOfField[fieldOfRun[position]] ?? .windows1252
                out += decode(bytes[run.range], as: encoding)
            }
        }
        return out
    }

    /// Die beiden Ein-Byte-Kodierungen, zwischen denen entschieden wird.
    enum SingleByteEncoding { case macRoman, windows1252 }

    /// Windows-1252 belegt 0x80–0x9F abweichend von Latin-1; ab 0xA0 sind
    /// beide identisch. Die Tabelle steht hier ausgeschrieben, weil
    /// `String.Encoding.windowsCP1252` nicht auf jeder Plattform verfügbar ist
    /// und der Core Linux-portabel bleiben soll. nil = in Windows-1252 nicht
    /// belegt; dort bleibt das Latin-1-Steuerzeichen stehen.
    private static let windows1252C1: [Character?] = [
        "€", nil, "‚", "ƒ", "„", "…", "†", "‡", "ˆ", "‰", "Š", "‹", "Œ", nil, "Ž", nil,
        nil, "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "•", "–", "—", "˜", "™",
        "š", "›", "œ", nil, "ž", "Ÿ"
    ]

    private static func decode(_ slice: ArraySlice<UInt8>,
                               as encoding: SingleByteEncoding) -> String {
        switch encoding {
        case .macRoman:
            // MacRoman bildet jedes Byte ab; der Rückfall auf lossy UTF-8 ist
            // reine Vorsicht.
            return String.decoded(Data(slice), as: .macOSRoman)
                ?? String(decoding: slice, as: UTF8.self)
        case .windows1252:
            var out = ""
            for byte in slice {
                if (0x80...0x9F).contains(byte), let mapped = windows1252C1[Int(byte) - 0x80] {
                    out.append(mapped)
                } else {
                    // Latin-1: Byte-Wert = Unicode-Codepoint.
                    out.append(Character(UnicodeScalar(byte)))
                }
            }
            return out
        }
    }

    /// Wählt die Kodierung, unter der die fremden Bytes eines Feldes im
    /// Zusammenhang plausibler aussehen. Bewertet wird jedes aus einem fremden
    /// Byte entstandene Zeichen: Ein Buchstabe wiegt schwerer als ein Symbol,
    /// und ein Großbuchstabe mitten in einem klein geschriebenen Wort
    /// („BŠckerei") ist ein starkes Gegenargument. Bei Gleichstand entscheidet
    /// wie bisher das C1-Byte für MacRoman — dort fehlt schlicht der
    /// Zusammenhang (etwa ein Feld aus einem einzigen Byte).
    private static func betterEncoding(runs: [(valid: Bool, range: Range<Int>)],
                                       positions: [Int],
                                       bytes: [UInt8]) -> SingleByteEncoding {
        var macRomanScore = 0
        var windowsScore = 0
        var hasC1 = false
        for position in positions {
            let run = runs[position]
            if bytes[run.range].contains(where: { (0x80...0x9F).contains($0) }) { hasC1 = true }
            let before = precedingCharacter(runs: runs, position: position, bytes: bytes)
            macRomanScore += score(decode(bytes[run.range], as: .macRoman), before: before)
            windowsScore += score(decode(bytes[run.range], as: .windows1252), before: before)
        }
        if macRomanScore != windowsScore {
            return macRomanScore > windowsScore ? .macRoman : .windows1252
        }
        return hasC1 ? .macRoman : .windows1252
    }

    /// Bewertung einer Kandidaten-Dekodierung im Zusammenhang des Zeichens,
    /// das links davor steht.
    private static func score(_ text: String, before: Character?) -> Int {
        var total = 0
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let left = index == 0 ? before : characters[index - 1]
            if character.isLetter {
                total += 2
                // Ein Großbuchstabe MITTEN im Wort („BŠckerei") kommt in echten
                // Tags praktisch nicht vor; am Wortanfang („Ärger") dagegen
                // ständig. Entscheidend ist deshalb allein, ob links ein
                // Buchstabe steht.
                if character.isUppercase, left?.isLetter ?? false { total -= 3 }
            } else if let scalar = character.unicodeScalars.first,
                      scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) {
                // Steuerzeichen sind in einem Textfeld immer falsch.
                total -= 2
            }
        }
        return total
    }

    /// Letztes Zeichen vor dem Lauf, sofern es aus gültigem UTF-8 stammt.
    private static func precedingCharacter(runs: [(valid: Bool, range: Range<Int>)],
                                           position: Int, bytes: [UInt8]) -> Character? {
        guard position > 0, runs[position - 1].valid else { return nil }
        return String(decoding: bytes[runs[position - 1].range], as: UTF8.self).last
    }


    /// Länge der gültigen UTF-8-Sequenz an `index`, sonst nil. Prüft
    /// Fortsetzungsbytes, Überlang-Kodierungen, Surrogate und die
    /// Unicode-Obergrenze — nur echte Sequenzen zählen als gültig.
    private static func utf8SequenceLength(_ bytes: [UInt8], at index: Int) -> Int? {
        let first = bytes[index]
        if first < 0x80 { return 1 }
        let length: Int
        let minScalar: UInt32
        switch first {
        case 0xC2...0xDF: length = 2; minScalar = 0x80
        case 0xE0...0xEF: length = 3; minScalar = 0x800
        case 0xF0...0xF4: length = 4; minScalar = 0x10000
        default: return nil
        }
        guard index + length <= bytes.count else { return nil }
        var scalar = UInt32(first) & (0xFF >> UInt32(length + 1))
        for offset in 1..<length {
            let byte = bytes[index + offset]
            guard (0x80...0xBF).contains(byte) else { return nil }
            scalar = (scalar << 6) | UInt32(byte & 0x3F)
        }
        guard scalar >= minScalar, scalar <= 0x10FFFF,
              !(0xD800...0xDFFF).contains(scalar) else { return nil }
        return length
    }

    /// mediainfo kodiert nicht-UTF-8-Bytes in JSON als Lone-Surrogates
    /// ("\udcfc" für Byte 0xFC, à la Python surrogateescape). JSON-Parser
    /// lehnen das ab bzw. verlieren die Information — deshalb stellen wir das
    /// ROHE Originalbyte wieder her. Es bleibt dadurch bis zur
    /// Kodierungsentscheidung in `decodeLossyJSON` erhalten und wird dort wie
    /// jedes andere ungültige Byte als MacRoman/Latin1 gedeutet ("\udc8a" ist
    /// MacRomans "ä" und würde als vorschnelles Latin1 zum Steuerzeichen
    /// U+008A).
    static func repairSurrogateEscapes(in data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = Data(capacity: bytes.count)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "\\") else {
                out.append(bytes[i])
                i += 1
                continue
            }
            // Backslash-Lauf am Stück betrachten: In JSON ist jedes PAAR ein
            // literaler Backslash und leitet nichts ein. `\\udcfc` meint den
            // Text „udcfc" und wurde vorher fälschlich zum Rohbyte umgebaut
            // (Review-Fund 2026-08-17).
            var run = 0
            while i + run < bytes.count, bytes[i + run] == UInt8(ascii: "\\") { run += 1 }
            let literals = run - (run % 2)
            out.append(contentsOf: repeatElement(UInt8(ascii: "\\"), count: literals))
            i += literals
            guard run % 2 == 1 else { continue }

            // Ab hier steht ein einzelner Backslash, der wirklich eine
            // Escape-Folge einleitet.
            guard let value = unicodeEscapeValue(bytes, at: i) else {
                out.append(bytes[i])
                i += 1
                continue
            }
            if (0xD800...0xDBFF).contains(value) {
                // Hohes Surrogat. Folgt unmittelbar ein niedriges, ist das ein
                // GÜLTIGES Paar (etwa `\ud83d\udcfc`) und beschreibt ein
                // echtes Zeichen jenseits der BMP — beide Hälften bleiben
                // unangetastet. Vorher wurde die zweite Hälfte zum Rohbyte
                // umgebaut und das Zeichen zerstört.
                if let low = unicodeEscapeValue(bytes, at: i + 6),
                   (0xDC00...0xDFFF).contains(low) {
                    out.append(contentsOf: bytes[i..<(i + 12)])
                    i += 12
                    continue
                }
                out.append(contentsOf: bytes[i..<(i + 6)])
                i += 6
                continue
            }
            // Nur die von mediainfo erzeugten Byte-Fluchten DC80–DCFF werden zum
            // Rohbyte zurückgebaut — und nur, wenn sie allein stehen.
            if (0xDC80...0xDCFF).contains(value) {
                out.append(UInt8(value & 0xFF))
                i += 6
                continue
            }
            out.append(contentsOf: bytes[i..<(i + 6)])
            i += 6
        }
        return out
    }

    /// Wert der `\uXXXX`-Folge, die an `index` beginnt — sonst nil.
    /// JSON kennt nur das kleine `u`; die Hexziffern dürfen beide Schreibweisen
    /// haben.
    private static func unicodeEscapeValue(_ bytes: [UInt8], at index: Int) -> UInt16? {
        guard index >= 0, index + 6 <= bytes.count,
              bytes[index] == UInt8(ascii: "\\"),
              bytes[index + 1] == UInt8(ascii: "u") else { return nil }
        var value: UInt16 = 0
        for offset in 2..<6 {
            guard let digit = hexDigitValue(bytes[index + offset]) else { return nil }
            value = value << 4 | UInt16(digit)
        }
        return value
    }

    private static func hexDigitValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }


}
