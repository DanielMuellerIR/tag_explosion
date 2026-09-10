// Blockierende Arbeit gehört nicht auf den Swift-Executor: Dessen Breite ist
// die Kernzahl, und ein wartender Leser rechnet nicht, belegt aber trotzdem
// einen Thread. Der Test beweist genau das — er verlangt mehr gleichzeitige
// Leser, als die Maschine Kerne hat.
import Foundation
import TagExplosionCore
import Testing

@Suite("BlockingWork")
struct BlockingWorkTests {

    @Test("Ergebnis und Fehler kommen unverändert zurück")
    func passesResultAndError() async throws {
        let value = try await BlockingWork.run { 21 * 2 }
        #expect(value == 42)
        do {
            _ = try await BlockingWork.run { throw TagError.cannotOpen(path: "/kein/pfad") }
            Issue.record("Fehler wurde verschluckt")
        } catch {
            #expect(error as? TagError == TagError.cannotOpen(path: "/kein/pfad"))
        }
    }

    /// Alle Leser müssen gleichzeitig laufen, sonst erreicht keiner die
    /// Sammelstelle. Auf dem Executor wäre bei `Kerne + 4` Lesern Schluss.
    @Test("Mehr gleichzeitige blockierende Leser als Kerne")
    func runsMoreConcurrentReadersThanCores() async throws {
        let count = ProcessInfo.processInfo.activeProcessorCount + 4
        let barrier = ArrivalBarrier(expected: count)
        let reached = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<count {
                group.addTask { try await BlockingWork.run { barrier.arriveAndWait(timeout: 10) } }
            }
            var reached = 0
            for try await arrived in group where arrived { reached += 1 }
            return reached
        }
        #expect(reached == count)
    }
}

/// Sammelstelle: Erst wenn alle erwarteten Aufrufe angekommen sind, kommt
/// irgendeiner weiter. Läuft die Arbeit nacheinander, läuft die Frist ab.
private final class ArrivalBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let expected: Int
    private var arrived = 0

    init(expected: Int) { self.expected = expected }

    /// false = Frist abgelaufen, es waren nie alle gleichzeitig da.
    func arriveAndWait(timeout: TimeInterval) -> Bool {
        lock.lock()
        arrived += 1
        let complete = arrived == expected
        lock.unlock()
        if complete { for _ in 0..<expected { gate.signal() } }
        return gate.wait(timeout: .now() + timeout) == .success
    }
}
