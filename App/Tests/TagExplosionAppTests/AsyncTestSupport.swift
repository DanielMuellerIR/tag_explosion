import Observation

struct TestSignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func signal() {
        continuation.yield(())
        continuation.finish()
    }

    func wait(for event: String, until deadline: ContinuousClock.Instant = .now + .seconds(10)) async throws {
        let timeout = Task {
            try await ContinuousClock().sleep(until: deadline)
            continuation.finish()
        }
        defer { timeout.cancel() }
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() != nil else {
            try Task.checkCancellation()
            throw TestWaitTimeout(event: event)
        }
    }
}

struct TestWaitTimeout: Error {
    let event: String
}

@MainActor
func waitForObservation(_ event: String, until condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while true {
        let changed = TestSignal()
        if withObservationTracking(condition, onChange: changed.signal) { return }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw TestWaitTimeout(event: event) }
        try await changed.wait(for: event, until: deadline)
    }
}

actor TestGate {
    let started = TestSignal()
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func pause() async {
        started.signal()
        guard !released else { return }
        // Der alte Auftrag soll auch nach seinem Abbruch erst nach Freigabe enden.
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
