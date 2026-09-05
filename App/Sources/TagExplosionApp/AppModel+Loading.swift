// Laden, Reihenfolge, Reservierungen und Fortschritt eines Fensters.
import Foundation
import Observation
import TagExplosionCore

@Observable
@MainActor
final class FileLoadingState {
    var operationCount = 0
    var generation = 0
    var completed = 0
    var total = 0
    var urls: Set<URL> = []
}

extension AppModel {
    /// Laufende Leser dürfen fertig werden; weitere Starts und Übernahmen enden.
    func cancelLoading() { loading.generation += 1 }

    // MARK: - Öffnen

    /// Öffnen-Dialog (Dateien und Ordner) für dieses Fenster.
    func presentOpenPanel() {
        guard let urls = MediaOpenPanel.run() else { return }
        Task { await self.open(urls: urls) }
    }

    /// Lädt Dateien/Ordner (rekursiv), liest Tags im Hintergrund.
    func open(urls: [URL]) async {
        await open(urls: urls) { url, kind in
            try await Task.detached(priority: .userInitiated) {
                try Self.readStamped(url: url, kind: kind)
            }.value
        }
    }

    /// Testbarer Öffnen-Pfad. Der Leser wird nur für die eigentliche Datei-IO
    /// ausgetauscht; Auswahl, Reservierung und Ergebnisreihenfolge bleiben
    /// derselbe Produktionscode. Der Leser liefert Inhalt UND den dazu
    /// konsistenten Stempel (Tests dürfen nil geben — dann entfällt die
    /// Konfliktprüfung für diesen Eintrag).
    func open(urls: [URL],
              read: @escaping @Sendable (URL, MediaKind) async throws -> (LoadedData, FileStamp?)) async {
        if loading.operationCount == 0 { loading.completed = 0; loading.total = 0 }
        let generation = loading.generation
        loading.operationCount += 1
        defer { loading.operationCount -= 1 }

        // Verzeichnisse expandieren und auf Medien-Endungen filtern (Hintergrund).
        let candidates = await Task.detached(priority: .userInitiated) {
            MediaFormats.expandMediaFiles(urls)
        }.value

        guard generation == loading.generation, !Task.isCancelled else { return }

        // Bereits geladene UND gerade ladende Dateien in einem MainActor-Schritt
        // vergleichen und reservieren. Zwischen Prüfung und Eintragen kann kein
        // zweiter `open`-Aufruf dazwischenfunken.
        let existing = Set(entries.map { MediaFormats.canonicalFileURL($0.url) })
        let newFiles = candidates.filter {
            !existing.contains($0) && loading.urls.insert($0).inserted
        }
        guard !newFiles.isEmpty else { return }
        defer { loading.urls.subtract(newFiles) }

        loading.total += newFiles.count
        var failures: [String] = []
        var settled = Set<Int>()
        var selectionCursor = 0
        // Jeder Abschluss ist ein kleines Paket. Bereits sichtbare Einträge
        // bleiben dieselben Objekte, damit Bearbeitungspuffer erhalten bleiben.
        let positions = Dictionary(uniqueKeysWithValues: newFiles.enumerated().map { ($1, $0) })
        await withTaskGroup(of: (Int, Result<(LoadedData, FileStamp?), Error>).self) { group in
            var next = 0
            @MainActor func addNext() {
                guard next < newFiles.count, generation == loading.generation, !Task.isCancelled else { return }
                let index = next
                let url = newFiles[index]
                next += 1
                group.addTask {
                    do { return (index, .success(try await read(url, MediaKind.forURL(url) ?? .audio))) }
                    catch { return (index, .failure(error)) }
                }
            }
            for _ in 0..<min(8, newFiles.count) { addNext() }
            for await (index, result) in group {
                guard generation == loading.generation, !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
                loading.completed += 1
                let url = newFiles[index]
                switch result {
                case .success(let (loaded, stamp)):
                    let entry = FileEntry(url: url, loaded: loaded, stamp: stamp)
                    let insertion = entries.firstIndex { (positions[$0.url] ?? -1) > index } ?? entries.endIndex
                    entries.insert(entry, at: insertion)

                case .failure: failures.append(url.lastPathComponent)
                }
                settled.insert(index)
                // Automatische Auswahl erst am ersten lesbaren Eingabepfad.
                // Eine zwischenzeitliche Benutzerauswahl hat Vorrang.
                while selection.isEmpty, settled.contains(selectionCursor) {
                    let candidate = newFiles[selectionCursor]
                    if entries.contains(where: { $0.url == candidate }) { selection = [candidate] }
                    selectionCursor += 1
                }
                addNext()
            }
        }
        if !failures.isEmpty {
            alertMessage = String(localized: "Nicht lesbar (Format unbekannt?):") + "\n" + failures.joined(separator: "\n")
        }
    }

}
