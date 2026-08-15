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
        let repaired = MediaInfoReader.repairSurrogateEscapes(in: raw)
        #expect(String(decoding: repaired, as: UTF8.self) == #"{"value":"Büro"}"#)
    }

    @Test("MacRoman-Steuerbereich und häufiges Latin-1 bleiben unterscheidbar")
    func decodesMacRomanBeforeLatin1() {
        // 0x8A ist in MacRoman „ä“, in Latin-1 dagegen ein Steuerzeichen.
        #expect(MediaInfoReader.decodeLossy(Data([0x8A])) == "ä")
        // 0xFC ist dagegen das häufige Latin-1-„ü“; MacRoman würde daraus
        // ein Cedille-Zeichen machen und darf hier nicht blind gewinnen.
        #expect(MediaInfoReader.decodeLossy(Data([0xFC])) == "ü")
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
}
