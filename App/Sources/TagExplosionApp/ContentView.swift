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
                }
            } else if model.selectedEntries.count > 1 {
                let selected = model.selectedEntries
                if selected.allSatisfy({ $0.kind == .audio }) {
                    BatchEditorView(entries: selected)
                        .id(model.selection)
                } else if selected.allSatisfy({ $0.kind == .image }) {
                    ImageBatchEditorView(entries: selected)
                        .id(model.selection)
                } else {
                    ContentUnavailableView(
                        "Gemischte Auswahl",
                        systemImage: "rectangle.on.rectangle.slash",
                        description: Text("Audio und Bilder bitte getrennt auswählen,\num sie gemeinsam zu bearbeiten.")
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
                    description: Text("Audiodateien hierher ziehen\noder mit ⌘O öffnen")
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

/// Platzhalter, solange nichts ausgewählt/geladen ist.
struct DropPlaceholder: View {
    var body: some View {
        ContentUnavailableView(
            "Tag Explosion",
            systemImage: "tag.circle",
            description: Text("Audiodateien oder Ordner hierher ziehen,\num Tags anzuzeigen und zu bearbeiten.")
        )
    }
}
