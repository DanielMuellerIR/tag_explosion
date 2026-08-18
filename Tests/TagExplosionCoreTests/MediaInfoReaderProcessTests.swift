// Ein externer Prozess muss stdout und stderr parallel leeren. Sonst kann ein
// einzelner voller Pipe-Puffer den Kindprozess und damit den Testlauf festhalten.
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("MediaInfoReader Prozess")
struct MediaInfoReaderProcessTests {

    @Test("Jeder Track behält seine eigene Feldreihenfolge")
    func preservesOrderPerTrack() throws {
        let json = #"""
        {
          "media": {
            "track": [
              {"@type":"General", "First":"1", "Second":"2"},
              {"@type":"Audio", "Second":"3", "First":"4",
               "extra":{"Zeta":"z", "Alpha":"a"}}
            ]
          }
        }
        """#

        let tracks = try MediaInfoReader.parseTracks(jsonData: Data(json.utf8))

        #expect(tracks.count == 2)
        #expect(tracks[0].fields.map(\.key) == ["First", "Second"])
        #expect(tracks[1].fields.map(\.key) == [
            "Second", "First", "extra.Zeta", "extra.Alpha",
        ])
    }

    @Test("Unlesbares MediaInfo-JSON wird nicht als leerer Erfolg gemeldet")
    func invalidJSONThrows() {
        #expect(throws: (any Error).self) {
            _ = try MediaInfoReader.parseTracks(jsonData: Data("kein JSON".utf8))
        }
        #expect(throws: (any Error).self) {
            _ = try MediaInfoReader.parseTracks(jsonData: Data(#"{"media":{}}"#.utf8))
        }
    }

    @Test("Surrogate-Escapes werden unabhängig von der Hex-Schreibweise repariert")
    func repairsUppercaseSurrogateEscape() {
        let raw = Data(#"{"value":"B\uDCFCro"}"#.utf8)
        // Die Reparatur stellt das ROHE Byte wieder her (0xFC); erst die
        // Kodierungsentscheidung in decodeLossy deutet es (hier: Latin1 „ü“).
        let expected = Data(#"{"value":"B"#.utf8) + Data([0xFC]) + Data(#"ro"}"#.utf8)
        #expect(MediaInfoReader.repairSurrogateEscapes(in: raw) == expected)
        #expect(MediaInfoReader.decodeLossy(raw) == #"{"value":"Büro"}"#)
    }

    @Test("Surrogate-Escape eines MacRoman-Bytes erreicht den MacRoman-Fallback")
    func surrogateEscapeKeepsMacRomanSignal() {
        // \udc8a steht für das Rohbyte 0x8A — MacRomans „ä“. Würde die
        // Reparatur es vorschnell als Latin1 deuten, entstünde das
        // Steuerzeichen U+008A statt des Umlauts.
        let raw = Data(#"{"value":"B\udc8ackerei"}"#.utf8)
        #expect(MediaInfoReader.decodeLossy(raw) == #"{"value":"Bäckerei"}"#)
    }

    @Test("MacRoman-Steuerbereich und häufiges Latin-1 bleiben unterscheidbar")
    func decodesMacRomanBeforeLatin1() {
        // 0x8A ist in MacRoman „ä“, in Latin-1 dagegen ein Steuerzeichen.
        #expect(MediaInfoReader.decodeLossy(Data([0x8A])) == "ä")
        // 0xFC ist dagegen das häufige Latin-1-„ü“; MacRoman würde daraus
        // ein Cedille-Zeichen machen und darf hier nicht blind gewinnen.
        #expect(MediaInfoReader.decodeLossy(Data([0xFC])) == "ü")
    }

    @Test("Gültiges UTF-8 bleibt trotz einzelner fremd kodierter Bytes erhalten")
    func keepsValidUTF8NextToForeignBytes() {
        // Die Fortsetzungsbytes von „😀“ (F0 9F 98 80) liegen teils im
        // C1-Bereich. Ein einzelnes Latin1-Byte daneben darf den Bericht
        // nicht komplett auf MacRoman umschalten und das Emoji zerlegen.
        let raw = Data("Titel 😀 ".utf8) + Data([0xE4]) + Data(" Ende".utf8)
        #expect(MediaInfoReader.decodeLossy(raw) == "Titel 😀 ä Ende")
        // Und umgekehrt: Ein echtes MacRoman-Signal (C1-Byte 0x8A unter den
        // UNGÜLTIGEN Bytes) gewinnt weiterhin, ohne das Emoji anzutasten.
        let macRoman = Data("Titel 😀 ".utf8) + Data([0x8A]) + Data(" Ende".utf8)
        #expect(MediaInfoReader.decodeLossy(macRoman) == "Titel 😀 ä Ende")
    }

    // Swift Testing akzeptiert Zeitgrenzen bewusst nur in Minuten. Eine Minute
    // ist hier ein harter Hänger-Schutz; der lokale Hilfsprozess braucht sonst
    // nur Millisekunden.
    @Test("Große stdout- und stderr-Pipes enden mit vollständigem Fehlertext", .timeLimit(.minutes(1)))
    func drainsBothPipesBeforeReportingFailure() throws {
        // 256 KiB je Stream liegen deutlich über den üblichen Pipe-Puffern.
        let repetitions = 256
        let stdoutChunk = String(repeating: "O", count: 1024)
        let stderrChunk = String(repeating: "E", count: 1024)
        let script = """
        i=0
        while [ "$i" -lt \(repetitions) ]; do
          printf '%s' '\(stdoutChunk)'
          printf '%s' '\(stderrChunk)' >&2
          i=$((i + 1))
        done
        exit 23
        """

        do {
            _ = try MediaInfoReader.run(
                "/bin/sh",
                ["-c", script],
                // Der Prozess-Timeout beendet einen echten Pipe-Hänger auch,
                // wenn die Swift-Testing-Zeitgrenze den blockierten Aufruf
                // selbst nicht unterbrechen kann.
                processTimeout: 5
            )
            Issue.record("Der Hilfsprozess muss mit Exit 23 fehlschlagen")
        } catch MediaInfoReader.ProcessTimeoutError.exceeded {
            Issue.record("Der Hilfsprozess überschritt den Prozess-Timeout")
        } catch let error as TagError {
            guard case .toolFailed(let name, let exitCode, let stderr) = error else {
                Issue.record("Unerwarteter TagError: \(error)")
                return
            }
            #expect(name == "sh")
            #expect(exitCode == 23)
            #expect(stderr == String(repeating: stderrChunk, count: repetitions))
        }
    }

    // MARK: - Review-Fund 2026-08-17

    @Test("MacRoman und Latin-1 duerfen im selben Bericht nebeneinander stehen")
    func decidesEncodingPerInvalidRun() {
        // Ein einziges C1-Byte irgendwo im Bericht zog vorher ALLE unguel­tigen
        // Laeufe auf MacRoman: Ein Feld mit 0x8A (MacRoman „ae") verfaelschte
        // damit ein anderes Feld mit 0xFC (Latin-1 „ue").
        var raw = Data(#"{"a":"B"#.utf8)
        raw.append(0x8A)                      // MacRoman „ä"
        raw.append(contentsOf: Data(#"ckerei","b":"T"#.utf8))
        raw.append(0xFC)                      // Latin-1 „ü"
        raw.append(contentsOf: Data(#"r"}"#.utf8))

        let decoded = MediaInfoReader.decodeLossy(raw)

        #expect(decoded.contains("Bäckerei"))
        #expect(decoded.contains("Tür"))
    }

    @Test("Ein gueltiges Surrogatpaar bleibt unangetastet")
    func keepsValidSurrogatePairs() {
        // `\ud83d\udcfc` ist ein echtes Zeichen jenseits der BMP. Die zweite
        // Haelfte wurde vorher zum Rohbyte 0xFC umgebaut und das JSON damit
        // zerstoert.
        let raw = Data(#"{"v":"\ud83d\udcfc"}"#.utf8)
        let repaired = MediaInfoReader.repairSurrogateEscapes(in: raw)
        #expect(repaired == raw)
        // Und das Ergebnis bleibt gueltiges JSON mit dem richtigen Zeichen.
        struct Wrapper: Decodable { let v: String }
        let decoded = try? JSONDecoder().decode(Wrapper.self, from: repaired)
        #expect(decoded?.v == "📼")
    }

    @Test("Ein doppelter Backslash leitet keine Escape-Folge ein")
    func keepsLiteralBackslashEscapes() {
        // `\\udcfc` meint in JSON den Text „udcfc" hinter einem literalen
        // Backslash — kein Escape. Vorher wurde daraus ein Rohbyte.
        let raw = Data(##"{"v":"\\udcfc"}"##.utf8)
        #expect(MediaInfoReader.repairSurrogateEscapes(in: raw) == raw)
    }

    @Test("Ein einzelnes Byte-Escape wird weiterhin zum Rohbyte")
    func stillRepairsLoneByteEscapes() {
        let raw = Data(#"{"v":"T\udcfcr"}"#.utf8)
        var erwartet = Data(#"{"v":"T"#.utf8)
        erwartet.append(0xFC)
        erwartet.append(contentsOf: Data(#"r"}"#.utf8))
        #expect(MediaInfoReader.repairSurrogateEscapes(in: raw) == erwartet)
    }

    // MARK: - Review-Fund 2026-08-18

    @Test("Ein MacRoman-Feld bleibt trotz Nicht-C1-Bytes vollstaendig MacRoman")
    func decidesEncodingPerField() {
        // „Bäckereistraße" in MacRoman: das ä ist 0x8A (C1-Bereich, eindeutiges
        // MacRoman-Signal), das ß dagegen 0xA7 — dazwischen liegt gültiges
        // ASCII. Die Entscheidung je ungültigem LAUF nahm für den zweiten Lauf
        // mangels C1-Byte Latin-1 an und machte aus dem ß ein „§".
        var raw = Data(#"{"a":"B"#.utf8)
        raw.append(0x8A)                      // MacRoman „ä"
        raw.append(contentsOf: Data("ckereistra".utf8))
        raw.append(0xA7)                      // MacRoman „ß", in Latin-1 „§"
        raw.append(contentsOf: Data(#"e","b":"T"#.utf8))
        raw.append(0xFC)                      // Latin-1 „ü" im NACHBARFELD
        raw.append(contentsOf: Data(#"r"}"#.utf8))

        let decoded = MediaInfoReader.decodeLossy(raw)

        #expect(decoded.contains("Bäckereistraße"))
        // Das Nachbarfeld bleibt davon unberührt — sonst wäre nur der alte
        // Fehler „ein C1-Byte schaltet den ganzen Bericht um" zurück.
        #expect(decoded.contains("Tür"))
    }

    @Test("Zeilen einer Klartextausgabe entscheiden getrennt")
    func decidesEncodingPerLineInPlainText() {
        // Calibre und mediainfo geben auch reinen Text aus; dort ist die Zeile
        // die Feldgrenze.
        var raw = Data("Titel: B".utf8)
        raw.append(0x8A)                      // MacRoman „ä"
        raw.append(contentsOf: Data("r\nAutor: T".utf8))
        raw.append(0xFC)                      // Latin-1 „ü"
        raw.append(contentsOf: Data("r".utf8))

        let decoded = MediaInfoReader.decodeLossy(raw)

        #expect(decoded.contains("Bär"))
        #expect(decoded.contains("Tür"))
    }
}
