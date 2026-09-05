import Foundation

/// Begrenzt abgeschlossene Berichte und teilt identische laufende Leseaufträge.
/// Ein Aufrufer darf abbrechen, ohne anderen Abonnenten den Prozess zu nehmen.
public actor MediaInfoCache {
    public static let shared = MediaInfoCache()
    public typealias Reader = @Sendable (URL, MediaInfoReader.Output, ExternalToolRunner.Cancellation) throws -> MediaInfoReport
    private struct Key: Equatable {
        let url: URL
        let stamp: FileStamp?
        let output: MediaInfoReader.Output
    }
    private struct Cached {
        let key: Key
        let report: MediaInfoReport
        let bytes: Int
    }
    private struct Pending {
        let id: UUID
        let key: Key
        let cancellation: ExternalToolRunner.Cancellation
        var subscribers: [UUID: CheckedContinuation<MediaInfoReport, Error>]
    }
    private let capacity: Int
    private let byteLimit: Int
    private let reader: Reader
    private var cached: [Cached] = []
    private var pending: [Pending] = []
    // Diagnosewert für gesteuerte Nebenläufigkeitstests ohne Timing-Annahmen.
    var subscriberCount: Int { pending.reduce(0) { $0 + $1.subscribers.count } }

    public init(capacity: Int = 8, byteLimit: Int = 8 * 1024 * 1024,
                reader: @escaping Reader = { url, output, cancellation in
                    try MediaInfoReader.read(url: url, output: output, cancellation: cancellation)
                }) {
        self.capacity = max(0, capacity)
        self.byteLimit = max(0, byteLimit)
        self.reader = reader
    }

    public func read(url: URL, output: MediaInfoReader.Output = .both) async throws -> MediaInfoReport {
        try Task.checkCancellation()
        let url = MediaFormats.canonicalFileURL(url)
        let key = Key(url: url, stamp: FileStamp.current(of: url), output: output)
        if let index = cached.firstIndex(where: { $0.key == key }) {
            let hit = cached.remove(at: index)
            cached.append(hit)
            return hit.report
        }
        cached.removeAll { $0.key.url == url && $0.key.stamp != key.stamp }
        let subscriber = UUID()
        let report: MediaInfoReport = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let index = pending.firstIndex(where: { $0.key == key }) {
                    pending[index].subscribers[subscriber] = continuation
                } else {
                    let cancellation = ExternalToolRunner.Cancellation()
                    let id = UUID()
                    pending.append(Pending(id: id, key: key, cancellation: cancellation,
                                           subscribers: [subscriber: continuation]))
                    let reader = self.reader
                    Task.detached(priority: .userInitiated) {
                        let result = Result {
                            let report = try reader(url, output, cancellation)
                            try FileStamp.requireUnchanged(key.stamp, at: url)
                            try cancellation.check()
                            return report
                        }
                        await self.complete(id, key: key, result: result)
                    }
                }
            }
        } onCancel: {
            Task { await self.release(subscriber: subscriber) }
        }
        try Task.checkCancellation()
        return report
    }

    private func release(subscriber: UUID) {
        guard let index = pending.firstIndex(where: { $0.subscribers[subscriber] != nil }) else { return }
        let continuation = pending[index].subscribers.removeValue(forKey: subscriber)
        continuation?.resume(throwing: CancellationError())
        if pending[index].subscribers.isEmpty {
            pending[index].cancellation.cancel()
            pending.remove(at: index)
        }
    }

    private func complete(_ id: UUID, key: Key, result: Result<MediaInfoReport, Error>) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        for continuation in request.subscribers.values { continuation.resume(with: result) }
        guard case .success(let report) = result else { return }
        // Ohne lesbaren Stempel ist keine verlässliche Wiederverwendung möglich.
        guard key.stamp != nil, FileStamp.current(of: key.url) == key.stamp else { return }
        let bytes = report.text.utf8.count + report.tracks.reduce(0) { total, track in
            total + track.type.utf8.count + track.fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        }
        guard capacity > 0, bytes <= byteLimit else { return }
        cached.removeAll { $0.key == key }
        cached.append(Cached(key: key, report: report, bytes: bytes))
        while cached.count > capacity || cached.reduce(0, { $0 + $1.bytes }) > byteLimit {
            cached.removeFirst()
        }
    }
}
