// Editor-Abschnitte für die festen Felder mit Prüfung (AP7):
//  - „Lyrics": mehrzeiliger Text, Sprache (nur ID3v2), synchronisierte
//    Zeilen mit LRC-Import/-Export (SYLT in der Datei oder Sidecar `<name>.lrc`);
//  - „Lautheit": ReplayGain (Track/Album, Gain/Peak) und bei Opus R128 (Q7.8,
//    dB daneben);
//  - „Podcast": Flag, Feed-URL, GUID, Kategorie, Stichwörter, Staffel,
//    Episode, Beschreibungen — nur für ID3v2 und MP4.
// Die Werte liegen als normale Properties im Bearbeitungspuffer; jedes Feld
// prüft beim Bestätigen über `FixedFields.normalized` und zeigt einen
// ungültigen Wert rot an, statt ihn ins Modell zu übernehmen. Gespeichert
// wird über den normalen Weg (Snapshot → TagFile.write / LRC-Sidecar).
import AppKit
import SwiftUI
import TagExplosionCore
import UniformTypeIdentifiers

// MARK: - Geprüftes Textfeld

/// Textfeld für ein festes Feld. Der Text wird erst beim Bestätigen (Return
/// oder Fokusverlust) geprüft und in die Speicherform gebracht; ein
/// ungültiger Wert bleibt sichtbar stehen, wird rot erklärt und nicht
/// übernommen. Leer entfernt das Feld.
struct ValidatedTagField: View {
    let key: String
    @Binding var value: String
    var placeholder = ""
    /// Zusatzanzeige rechts neben dem Feld (z.B. R128 als dB).
    var trailing: ((String) -> String)? = nil
    @State private var draft = ValidatedFieldDraft()
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                TextField(placeholder, text: Binding(
                    get: { draft.text }, set: { draft.edit($0) }))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onAppear { draft.synchronize(value) }
                    // Änderungen von außen (Verwerfen, Batch, Neuladen) nachziehen.
                    .onChange(of: value) { _, newValue in
                        if !focused {
                            draft.synchronize(newValue)
                            error = nil
                        }
                    }
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
                if let trailing, !value.isEmpty {
                    Text(trailing(value))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func commit() {
        do {
            if let normalized = try draft.commit(key: key) {
                value = normalized
                error = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Binding auf den ersten Wert eines Schlüssels (leer = Feld entfernen).
@MainActor
private func fieldBinding(_ entry: FileEntry, _ key: String) -> Binding<String> {
    Binding(get: { entry.firstValue(key) }, set: { entry.setSingleValue(key, $0) })
}

// MARK: - Lyrics

struct LyricsSection: View {
    @Bindable var entry: FileEntry
    @Environment(AppModel.self) private var model
    @State private var importError: String?
    @State private var languageText = ""
    @State private var languageError: String?
    @FocusState private var languageFocused: Bool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: Binding(
                    get: { FixedFields.lyricsText(in: entry.properties) },
                    set: { entry.properties = FixedFields.settingLyrics($0, in: entry.properties) }
                ))
                .font(.body)
                .frame(minHeight: 110, maxHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))

                if entry.supportsSyncedLyrics {
                    HStack(spacing: 8) {
                        Text("Sprache (ISO 639-2)")
                            .foregroundStyle(.secondary)
                        TextField("deu", text: $languageText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .focused($languageFocused)
                            .onAppear { languageText = entry.lyricsLanguage }
                            .onChange(of: entry.lyricsLanguage) { _, newValue in
                                if !languageFocused { languageText = newValue }
                            }
                            .onSubmit { commitLanguage() }
                            .onChange(of: languageFocused) { _, isFocused in
                                if !isFocused { commitLanguage() }
                            }
                            .help("Drei Buchstaben nach ISO 639-2, z.B. deu, eng; leer = unbekannt")
                        if let languageError {
                            Text(languageError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                Divider()

                syncedSummary

                if let importError {
                    Label(importError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                HStack(spacing: 12) {
                    Button("LRC importieren …") { importLRC() }
                    Button("LRC exportieren …") { exportLRC() }
                        .disabled(entry.syncedLyrics.isEmpty)
                    Spacer()
                    Button("Synchronisierte Lyrics entfernen") { entry.syncedLyrics = [] }
                        .disabled(entry.syncedLyrics.isEmpty)
                }
                .buttonStyle(.borderless)
            }
            .padding(8)
        } label: {
            Text("Lyrics")
        }
    }

    /// Zeilenzahl, Speicherort und die Zeilen selbst (aufklappbar).
    @ViewBuilder
    private var syncedSummary: some View {
        if entry.syncedLyrics.isEmpty {
            Text(entry.supportsSyncedLyrics
                 ? "Keine synchronisierten Lyrics (SYLT)"
                 : "Keine synchronisierten Lyrics — dieses Format hat kein SYLT; eine LRC-Datei wird als \(LRC.sidecarURL(for: entry.url).lastPathComponent) neben der Datei gespeichert.")
                .foregroundStyle(.secondary)
                .font(.callout)
        } else {
            DisclosureGroup {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
                    ForEach(Array(entry.syncedLyrics.enumerated()), id: \.offset) { _, line in
                        GridRow {
                            Text("[\(LRC.formatTimestamp(line.milliseconds))]")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(line.text)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.top, 4)
            } label: {
                Text(entry.supportsSyncedLyrics
                     ? "\(entry.syncedLyrics.count) synchronisierte Zeilen (SYLT in der Datei)"
                     : "\(entry.syncedLyrics.count) synchronisierte Zeilen (Sidecar \(LRC.sidecarURL(for: entry.url).lastPathComponent))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commitLanguage() {
        let normalized = FixedFields.normalizedLanguage(languageText)
        guard FixedFields.isValidLanguage(normalized) else {
            languageError = String(localized: "Drei Buchstaben nach ISO 639-2 (z.B. deu, eng)")
            return
        }
        languageError = nil
        entry.lyricsLanguage = normalized
        languageText = normalized
    }

    /// LRC-Datei laden: synchronisierte Zeilen ersetzen; ohne eigenen Text
    /// füllt sie auch die unsynchronisierten Lyrics.
    private func importLRC() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text, .data]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "LRC-Datei auswählen ([mm:ss.xx] Text je Zeile)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let document = try LRC.load(from: url)
            entry.syncedLyrics = document.lines
            if FixedFields.lyricsText(in: entry.properties).isEmpty {
                entry.properties = FixedFields.settingLyrics(LRC.plainText(document.lines), in: entry.properties)
            }
            importError = nil
        } catch {
            importError = String(localized: "LRC-Datei konnte nicht gelesen werden: \(error.localizedDescription)")
        }
    }

    private func exportLRC() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = LRC.sidecarURL(for: entry.url).lastPathComponent
        panel.message = String(localized: "Synchronisierte Lyrics als LRC exportieren")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = Data(LRC.render(entry.syncedLyrics).utf8)
        Task { await model.exportData(data, to: url) }
    }
}

// MARK: - Lautheit

struct LoudnessSection: View {
    @Bindable var entry: FileEntry

    private var showsR128: Bool { FixedFields.supportsR128(entry.url) }

    var body: some View {
        GroupBox {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                row(String(localized: "Track-Gain"), FixedFields.replayGainTrackGain, "-6.50 dB")
                row(String(localized: "Track-Peak"), FixedFields.replayGainTrackPeak, "0.987654")
                row(String(localized: "Album-Gain"), FixedFields.replayGainAlbumGain, "-6.50 dB")
                row(String(localized: "Album-Peak"), FixedFields.replayGainAlbumPeak, "0.987654")
                if showsR128 {
                    row(String(localized: "R128 Track"), FixedFields.r128TrackGain, "-1664", trailing: r128Decibel)
                    row(String(localized: "R128 Album"), FixedFields.r128AlbumGain, "-1664", trailing: r128Decibel)
                }
            }
            .padding(8)
            Text(showsR128
                 ? "Gain −60 … +60 dB, Peak 0 … 10, R128 als Q7.8-Ganzzahl (−32768 … 32767 = Wert/256 dB). Werte werden nur geprüft und gespeichert, nicht aus dem Audio berechnet."
                 : "Gain −60 … +60 dB, Peak 0 … 10. Werte werden nur geprüft und gespeichert, nicht aus dem Audio berechnet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding([.horizontal, .bottom], 8)
        } label: {
            Text("Lautheit")
        }
    }

    private func row(_ label: String, _ key: String, _ placeholder: String,
                     trailing: ((String) -> String)? = nil) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)
            ValidatedTagField(key: key, value: fieldBinding(entry, key), placeholder: placeholder,
                              trailing: trailing)
        }
    }

    /// Q7.8-Ganzzahl als dB daneben.
    private func r128Decibel(_ raw: String) -> String {
        guard let value = Loudness.parseR128(raw) else { return "" }
        return "= " + Loudness.formatGain(Loudness.r128ToDecibel(value))
    }
}

/// Batch-Variante: Album-Lautheit für alle ausgewählten Dateien setzen.
struct BatchLoudnessSection: View {
    let entries: [FileEntry]

    private var showsR128: Bool { entries.allSatisfy { FixedFields.supportsR128($0.url) } }

    var body: some View {
        GroupBox {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                row(String(localized: "Album-Gain"), FixedFields.replayGainAlbumGain)
                row(String(localized: "Album-Peak"), FixedFields.replayGainAlbumPeak)
                if showsR128 {
                    row(String(localized: "R128 Album"), FixedFields.r128AlbumGain)
                }
            }
            .padding(8)
        } label: {
            Text("Lautheit (Album, für alle setzen)")
        }
    }

    private func row(_ label: String, _ key: String) -> some View {
        let common = commonValue(key)
        return GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)
            ValidatedTagField(
                key: key,
                value: Binding(
                    get: { common ?? "" },
                    set: { newValue in for entry in entries { entry.setSingleValue(key, newValue) } }
                ),
                placeholder: common == nil ? String(localized: "— verschieden —") : "")
        }
    }

    private func commonValue(_ key: String) -> String? {
        guard let first = entries.first?.firstValue(key) else { return nil }
        return entries.allSatisfy { $0.firstValue(key) == first } ? first : nil
    }
}

// MARK: - Podcast

struct PodcastSection: View {
    @Bindable var entry: FileEntry

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Podcast (Flag)", isOn: Binding(
                    get: { FixedFields.parseFlag(entry.firstValue(FixedFields.podcast)) ?? false },
                    set: { entry.setSingleValue(FixedFields.podcast, $0 ? "1" : "") }
                ))
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    row(String(localized: "Feed-URL"), FixedFields.podcastURL, "https://…")
                    row(String(localized: "Episoden-GUID"), FixedFields.podcastID, "")
                    row(String(localized: "Kategorie"), FixedFields.podcastCategory, "")
                    row(String(localized: "Stichwörter"), FixedFields.keywords, String(localized: "kommagetrennt"))
                    row(String(localized: "Staffel"), FixedFields.season, "1")
                    row(String(localized: "Episode"), FixedFields.episode, "1")
                    row(String(localized: "Beschreibung"), FixedFields.podcastDescription, "")
                    if FixedFields.supportsLongDescription(entry.url) {
                        GridRow {
                            Text("Lange Beschreibung")
                                .gridColumnAlignment(.trailing)
                                .foregroundStyle(.secondary)
                            TextEditor(text: fieldBinding(entry, FixedFields.longDescription))
                                .font(.body)
                                .frame(minHeight: 60, maxHeight: 160)
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                        }
                    }
                }
            }
            .padding(8)
        } label: {
            Text("Podcast")
        }
    }

    private func row(_ label: String, _ key: String, _ placeholder: String) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)
            ValidatedTagField(key: key, value: fieldBinding(entry, key), placeholder: placeholder)
        }
    }
}
