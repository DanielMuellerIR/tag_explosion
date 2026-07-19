// Ein externer Prozess muss stdout und stderr parallel leeren. Sonst kann ein
// einzelner voller Pipe-Puffer den Kindprozess und damit den Testlauf festhalten.
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("MediaInfoReader Prozess")
struct MediaInfoReaderProcessTests {

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
