import Foundation
#if !os(Linux)
import Observation
#endif
import TagExplosionCore

public struct LibraryCheckRequest: Equatable, Sendable {
    public init(items: [LibraryCheck.Item], checkNames: Bool, pattern: String) {
        self.items = items; self.checkNames = checkNames; self.pattern = pattern
    }
    public var items: [LibraryCheck.Item]
    public var checkNames: Bool
    public var pattern: String
}

/// Nur aktuelle Ergebnisse gelangen in die Anzeige. Die Engine erhält
/// unveränderliche Werte; sie greift niemals auf FileEntry oder die UI zu.
#if !os(Linux)
@Observable
#endif
@MainActor
public final class LibraryCheckState {
    public init() {}
    public private(set) var report: LibraryCheck.Report?
    public private(set) var error: String?
    public private(set) var isChecking = false
    private var revision = 0
    private var task: Task<Void, Never>?

    @discardableResult
    public func submit(_ request: LibraryCheckRequest, delay: Duration = .milliseconds(250),
                evaluate: @escaping @Sendable ([LibraryCheck.Item], FilenamePattern?) async -> LibraryCheck.Report = { items, pattern in
                    await Task.detached(priority: .userInitiated) { LibraryCheck.run(items, pattern: pattern) }.value
                }) -> Task<Void, Never> {
        task?.cancel()
        revision += 1
        let current = revision
        report = nil
        error = nil
        isChecking = false
        let pattern: FilenamePattern?
        do { pattern = request.checkNames ? try FilenamePattern(request.pattern) : nil }
        catch {
            self.error = error.localizedDescription
            return Task {}
        }
        isChecking = true
        let work = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            let result = await evaluate(request.items, pattern)
            guard !Task.isCancelled, current == revision else { return }
            report = result
            isChecking = false
        }
        task = work
        return work
    }

    public func cancel() {
        task?.cancel()
        revision += 1
        isChecking = false
    }
}
