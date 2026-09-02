// Kapitel-Abschnitt des Audio-Editors: editierbare Liste (Titel, Beginn,
// Ende), Hinzufügen/Entfernen, Import/Export als JSON oder Text. Nur sichtbar,
// wenn das Format Kapitel kann (MP3, MP4/M4A/M4B, Matroska). Gespeichert wird
// über den normalen Speichern-Weg des AppModel (Snapshot → TagFile.write).
import AppKit
import SwiftUI
import TagExplosionCore
import UniformTypeIdentifiers

struct ChapterSection: View {
    @Bindable var entry: FileEntry
    /// Fehlermeldung des letzten Imports (nil = keiner).
    @State private var importError: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if entry.chapters.isEmpty {
                    Text("Keine Kapitel")
                        .foregroundStyle(.secondary)
                        .padding(4)
                } else {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Text("")
                            Text("Titel").foregroundStyle(.secondary)
                            Text("Beginn").foregroundStyle(.secondary)
                            Text("Ende").foregroundStyle(.secondary)
                            Text("")
                        }
                        .font(.caption)
                        ForEach(entry.chapters.indices, id: \.self) { index in
                            chapterRow(index)
                        }
                    }
                }

                if let importError {
                    Label(importError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                HStack(spacing: 12) {
                    Button {
                        addChapter()
                    } label: {
                        Label("Kapitel hinzufügen", systemImage: "plus")
                    }
                    Button("Importieren …") { importChapters() }
                    Button("Exportieren …") { exportChapters() }
                        .disabled(entry.chapters.isEmpty)
                    Spacer()
                    Button("Alle Kapitel entfernen") { entry.chapters.removeAll() }
                        .disabled(entry.chapters.isEmpty)
                }
                .buttonStyle(.borderless)
            }
            .padding(8)
        } label: {
            Text("Kapitel")
        }
    }

    /// Eine Zeile: Nummer, Titel, Beginn, Ende, Entfernen.
    private func chapterRow(_ index: Int) -> some View {
        GridRow {
            Text("\(index + 1)")
                .foregroundStyle(.secondary)
                .font(.body.monospacedDigit())
                .gridColumnAlignment(.trailing)
            TextField(String(localized: "Kapiteltitel"), text: Binding(
                get: { entry.chapters[index].title },
                set: { entry.chapters[index].title = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            TimestampField(milliseconds: Binding(
                get: { entry.chapters[index].startMilliseconds },
                set: { entry.chapters[index].startMilliseconds = $0 }
            ))
            TimestampField(milliseconds: Binding(
                get: { entry.chapters[index].endMilliseconds },
                set: { entry.chapters[index].endMilliseconds = $0 }
            ))
            Button {
                entry.chapters.remove(at: index)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Kapitel entfernen")
        }
    }

    /// Neues Kapitel beginnt, wo das letzte endet, und reicht bis zum
    /// Dateiende (oder bis zum eigenen Beginn, wenn die Spielzeit unbekannt ist).
    private func addChapter() {
        let start = entry.chapters.last?.endMilliseconds ?? 0
        let length = entry.audio?.lengthMilliseconds ?? 0
        entry.chapters.append(Chapter(title: "", startMilliseconds: start,
                                      endMilliseconds: max(start, length)))
    }

    private func importChapters() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .text]
        panel.allowsMultipleSelection = false
        panel.message = String(localized:
            "Kapitelliste auswählen (JSON oder Text, eine Zeile je Kapitel: HH:MM:SS.mmm Titel)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            entry.chapters = try ChapterList.load(from: url, totalLength: entry.audio?.lengthMilliseconds)
            importError = nil
        } catch {
            importError = String(localized: "Kapitelliste konnte nicht gelesen werden: \(error.localizedDescription)")
        }
    }

    /// Export als Text (Standard) oder JSON — entschieden über die gewählte Endung.
    private func exportChapters() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .json]
        panel.nameFieldStringValue = entry.url.deletingPathExtension().lastPathComponent + "-chapters.txt"
        panel.message = String(localized: "Kapitel exportieren (Endung .json für JSON, sonst Text)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data: Data?
        if url.pathExtension.lowercased() == "json" {
            data = try? ChapterList.renderJSON(entry.chapters)
        } else {
            data = Data(ChapterList.renderText(entry.chapters).utf8)
        }
        try? data?.write(to: url)
    }
}

/// Zeitfeld `HH:MM:SS.mmm`. Der Text wird erst beim Bestätigen (Return oder
/// Fokusverlust) in Millisekunden übersetzt; ein ungültiger Text springt auf
/// den letzten gültigen Wert zurück, statt das Modell zu verändern.
struct TimestampField: View {
    @Binding var milliseconds: Int
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.body.monospacedDigit())
            .frame(width: 110)
            .focused($focused)
            .help("Zeit im Format HH:MM:SS.mmm")
            .onAppear { text = ChapterList.formatTimestamp(milliseconds) }
            // Import oder Sortierung ändern den Wert von außen — Text nachziehen.
            .onChange(of: milliseconds) { _, newValue in
                text = ChapterList.formatTimestamp(newValue)
            }
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
    }

    private func commit() {
        if let parsed = ChapterList.parseTimestamp(text) {
            milliseconds = parsed
        }
        text = ChapterList.formatTimestamp(milliseconds)
    }
}
