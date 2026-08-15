// Regressionen des gemeinsamen Cover-Drops. NSItemProvider liefert seine
// Daten asynchron; der Test wartet auf einem Hintergrund-Thread, damit die
// MainActor-Zustellung des Produktionscodes nicht blockiert wird.
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TagExplosionApp

@Suite("CoverDrop")
struct CoverDropTests {
    private final class Receiver: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var received: Data?

        func accept(_ data: Data) {
            lock.withLock { received = data }
            semaphore.signal()
        }

        func wait() async -> Data? {
            await Task.detached { [self] in waitSynchronously() }.value
        }

        /// Die blockierenden APIs stehen absichtlich in einer synchronen
        /// Hilfsfunktion; aufgerufen wird sie ausschließlich vom detached Task.
        private func waitSynchronously() -> Data? {
            guard semaphore.wait(timeout: .now() + 2) == .success else { return nil }
            return lock.withLock { received }
        }
    }

    private func provider(data: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.image.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    @Test("Ungültiger erster Provider verdeckt ein folgendes gültiges Bild nicht")
    func skipsInvalidProvider() async {
        let invalid = provider(data: Data("kein Bild".utf8))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A,
                        0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        let valid = provider(data: png)
        let receiver = Receiver()

        #expect(CoverDrop.load([invalid, valid]) { receiver.accept($0) })
        #expect(await receiver.wait() == png)
    }

    @Test("Nicht erlaubtes Bildformat verdeckt einen folgenden passenden Provider nicht")
    func skipsProviderWithDisallowedMimeType() async {
        let gif = provider(data: Data([0x47, 0x49, 0x46, 0x38,
                                       0x39, 0x61, 0, 0, 0, 0, 0, 0]))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A,
                        0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        let receiver = Receiver()

        #expect(CoverDrop.load(
            [gif, provider(data: png)],
            acceptedMimeTypes: ["image/jpeg", "image/png"]
        ) { receiver.accept($0) })
        #expect(await receiver.wait() == png)
    }

    @Test("Cover-Export beschriftet BMP und unbekannte Daten ehrlich")
    func exportFileExtensionsMatchMimeType() {
        #expect(CoverExport.fileExtension(for: "image/jpeg") == "jpg")
        #expect(CoverExport.fileExtension(for: "image/png") == "png")
        #expect(CoverExport.fileExtension(for: "image/gif") == "gif")
        #expect(CoverExport.fileExtension(for: "image/webp") == "webp")
        #expect(CoverExport.fileExtension(for: "image/bmp") == "bmp")
        #expect(CoverExport.fileExtension(for: "application/octet-stream") == "bin")
    }
}
