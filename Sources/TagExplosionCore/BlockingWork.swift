import Foundation

/// Blockierende Arbeit außerhalb des Swift-Executors ausführen.
///
/// Der Executor hat nur so viele Threads, wie die Maschine Kerne hat. Ein
/// Aufruf, der auf ein externes Werkzeug (mediainfo, exiftool) oder eine
/// blockierende Bibliothek (TagLib) wartet, belegt einen davon vollständig,
/// ohne dabei zu rechnen. Mehrere solche Leser drücken sich deshalb
/// gegenseitig: Ein angekündigter Fächer von acht Lesern läuft auf einer
/// Maschine mit zwei Kernen nur zweifach, und alle übrige Aufgabenarbeit
/// reiht sich dahinter ein. GCD legt für blockierende Arbeit dagegen
/// zusätzliche Threads an.
///
/// Gemessen mit 64 blockierenden Lesern auf 18 Kernen: 1,23 s über den
/// Executor gegen 0,31 s über eine GCD-Queue.
public enum BlockingWork {

    /// Führt `operation` auf einer GCD-Queue aus und wartet darauf. Der
    /// wartende Task ist dabei angehalten und belegt keinen Executor-Thread.
    public static func run<T: Sendable>(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }
}
