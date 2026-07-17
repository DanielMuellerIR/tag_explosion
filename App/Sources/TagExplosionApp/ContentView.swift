// Hauptfenster: Sidebar mit Dateiliste, rechts der Editor.
import SwiftUI
import TagExplosionCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            if let entry = model.selectedEntry {
                switch entry.kind {
                case .audio:
                    EditorView(entry: entry)
                        .id(entry.url) // Editor-State pro Datei zurücksetzen
                case .image:
                    ImageEditorView(entry: entry)
                        .id(entry.url)
                case .ebook:
                    EbookEditorView(entry: entry)
                        .id(entry.url)
                }
            } else if model.selectedEntries.count > 1 {
                let selected = model.selectedEntries
                if selected.allSatisfy({ $0.kind == .audio }) {
                    BatchEditorView(entries: selected)
                        .id(model.selection)
                } else if selected.allSatisfy({ $0.kind == .image }) {
                    ImageBatchEditorView(entries: selected)
                        .id(model.selection)
                } else if selected.allSatisfy({ $0.kind == .ebook }) {
                    EbookBatchEditorView(entries: selected)
                        .id(model.selection)
                } else {
                    ContentUnavailableView(
                        "Gemischte Auswahl",
                        systemImage: "rectangle.on.rectangle.slash",
                        description: Text("Audio, Bilder und E-Books bitte getrennt auswählen,\num sie gemeinsam zu bearbeiten.")
                    )
                }
            } else {
                DropPlaceholder()
            }
        }
        .navigationTitle(navigationTitle)
        .navigationSubtitle(subtitle)
        // Drop überall im Fenster: Dateien/Ordner laden
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Öffnen", systemImage: "folder")
                }
                .help("Dateien oder Ordner öffnen (⌘O)")

                Button {
                    Task { await model.saveSelected() }
                } label: {
                    Label("Speichern", systemImage: "checkmark.circle.fill")
                }
                .disabled(!model.selectionIsDirty)
                .help("Änderungen der Auswahl speichern (⌘S)")

                if model.entries.filter(\.isDirty).count > 1 {
                    Button {
                        Task { await model.saveAll() }
                    } label: {
                        Label("Alle speichern", systemImage: "checkmark.circle.badge.questionmark")
                    }
                    .help("Alle geänderten Dateien speichern (⌥⌘S)")
                }
            }
        }
        .alert("Hinweis", isPresented: .init(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var navigationTitle: String {
        if let entry = model.selectedEntry { return entry.displayTitle }
        if model.selectedEntries.count > 1 { return "\(model.selectedEntries.count) Dateien" }
        return "Tag Explosion"
    }

    private var subtitle: String {
        if let entry = model.selectedEntry {
            return entry.isDirty ? "Bearbeitet" : ""
        }
        if model.selectedEntries.count > 1 {
            let dirty = model.selectedEntries.filter(\.isDirty).count
            return dirty > 0 ? "\(dirty) bearbeitet" : ""
        }
        return model.entries.isEmpty ? "" : "\(model.entries.count) Dateien"
    }

    @ViewBuilder
    private var sidebar: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.entries) { entry in
                FileRow(entry: entry)
                    .tag(entry.url)
                    .contextMenu {
                        Button("Aus Liste entfernen") {
                            model.remove(urls: [entry.url])
                        }
                        Button("Im Finder zeigen") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                    }
            }
        }
        .overlay {
            if model.entries.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    "Keine Dateien",
                    systemImage: "music.note.list",
                    description: Text("Mediendateien hierher ziehen\noder mit ⌘O öffnen")
                )
            }
            if model.isLoading {
                ProgressView("Lade …")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let collector = URLCollector()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collector.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            Task { await model.open(urls: collector.snapshot()) }
        }
        return !providers.isEmpty
    }
}

/// Thread-sicherer URL-Sammler für die NSItemProvider-Callbacks
/// (die auf beliebigen Queues eintreffen).
final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func snapshot() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

/// Eine Zeile in der Dateiliste: Titel, Untertitel, Dirty-Punkt.
struct FileRow: View {
    let entry: FileEntry

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .lineLimit(1)
                Text(entry.displaySubtitle.isEmpty ? entry.url.lastPathComponent : entry.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if entry.isDirty {
                Circle()
                    .fill(.orange)
                    .frame(width: 8, height: 8)
                    .help("Ungespeicherte Änderungen")
            }
        }
        .padding(.vertical, 2)
    }
}

/// Platzhalter, solange nichts ausgewählt/geladen ist: erklärt, welche
/// Medientypen die App annimmt, und listet alle unterstützten Formate auf.
struct DropPlaceholder: View {
    // Anzeige-Gruppen aus den echten Endungs-Sets abgeleitet, damit die Liste
    // nicht von der tatsächlichen Unterstützung wegdriften kann. Einzige
    // Kosmetik: mp4 zeigen wir bei Video (dort erwarten es Nutzer), technisch
    // läuft es über denselben TagLib-Weg wie Audio (siehe MediaKind).
    private static let audioDisplay = audioExtensions.subtracting(["mp4"]).sorted()
    private static let imageDisplay = imageExtensions.sorted()
    private static let videoDisplay = videoExtensions.union(["mp4"]).sorted()
    private static let ebookDisplay = ebookExtensions.sorted()
    /// Hinweis auf die nur-mit-Calibre-Formate, falls Calibre fehlt.
    private static let ebookTagFormats = EbookTool.calibreAvailable
        ? "EPUB-OPF · PDF Info/XMP · Calibre (mobi/azw3/fb2)"
        : "EPUB-OPF · PDF Info/XMP (mobi/azw3/fb2 mit Calibre)"

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "tag.circle")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)

            VStack(spacing: 8) {
                Text("Tag Explosion")
                    .font(.title2.bold())
                Text("Audio-, Bild-, Video- und E-Book-Dateien oder Ordner hierher ziehen,\num Metadaten anzuzeigen und zu bearbeiten.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 30) {
                FormatColumn(title: "Audio", systemImage: "music.note",
                             formats: Self.audioDisplay,
                             tagFormats: "ID3v1/v2 · MP4-Atome · Vorbis Comments · APEv2 · ASF · RIFF-Info")
                FormatColumn(title: "Bilder", systemImage: "photo",
                             formats: Self.imageDisplay,
                             tagFormats: "EXIF · IPTC · XMP (MWG-harmonisiert)")
                FormatColumn(title: "Video", systemImage: "film",
                             formats: Self.videoDisplay,
                             tagFormats: "MP4-Atome · Matroska-Tags (mov/avi nur Anzeige)")
                FormatColumn(title: "E-Books", systemImage: "book",
                             formats: Self.ebookDisplay,
                             tagFormats: Self.ebookTagFormats)
            }
        }
        .padding(32)
    }
}

/// Eine Spalte der Formatübersicht: Medientyp-Überschrift, alle Datei-Endungen
/// und die unterstützten Tag-Formate.
private struct FormatColumn: View {
    let title: String
    let systemImage: String
    let formats: [String]
    let tagFormats: String

    var body: some View {
        VStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(formats.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
            Text(tagFormats)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
    }
}
