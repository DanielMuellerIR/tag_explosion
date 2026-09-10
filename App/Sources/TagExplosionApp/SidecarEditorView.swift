// Editor für Video-Sidecars: Kodi-/Jellyfin-NFO (Felder editierbar, Anzeige
// von Darstellern, IDs, Artwork und zugehörigem Video) und Untertitel
// srt/vtt (Kennzahlen, bei VTT Titel und Language-Zeile editierbar, dazu die
// Zeitverschiebung aller Cues).
import SwiftUI
import TagExplosionCore

struct SidecarEditorView: View {
    @Bindable var entry: FileEntry
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let error = entry.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                switch entry.sidecarContents {
                case .nfo(let contents):
                    if contents.isURLOnly {
                        urlOnlySection(contents)
                    } else {
                        nfoFieldsSection(contents)
                    }
                    infoSection(title: "NFO-Info (nur Anzeige)", items: contents.info)
                case .subtitle(let contents):
                    subtitleInfoSection(contents.info)
                    if contents.info.format == .vtt {
                        vttHeaderSection(contents.info)
                    } else {
                        srtNote
                    }
                    SubtitleShiftSection(entry: entry)
                case nil:
                    EmptyView()
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }

    // MARK: - Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.url.lastPathComponent)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            Text(entry.url.deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if case .nfo = entry.sidecarContents {
                // Umgekehrte Kopplung: Gibt es das Video zu dieser NFO?
                if let video = MediaFormats.videoURL(forNFO: entry.url) {
                    Label(String(localized: "Video daneben: \(video.lastPathComponent)"),
                          systemImage: "film")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Kein Video mit diesem Namen daneben.", systemImage: "film")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            FilenamePatternMenu(entries: [entry])
                .padding(.top, 4)
        }
    }

    // MARK: - NFO

    private func urlOnlySection(_ contents: NFOContents) -> some View {
        GroupBox("Nur-URL-NFO (nur Anzeige)") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Diese NFO enthält nur Scraper-Adressen und kein XML; sie wird nicht beschrieben.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(contents.urls, id: \.self) { url in
                    Text(url)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func nfoFieldsSection(_ contents: NFOContents) -> some View {
        let isEpisode = contents.rootName == "episodedetails"
            || !entry.nfoFields.showTitle.isEmpty || !entry.nfoFields.season.isEmpty
            || !entry.nfoFields.episode.isEmpty
        return GroupBox("NFO-Felder") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                textRow("Titel", $entry.nfoFields.title)
                textRow("Originaltitel", $entry.nfoFields.originalTitle)
                textRow("Sortiertitel", $entry.nfoFields.sortTitle)
                if isEpisode {
                    textRow("Serie", $entry.nfoFields.showTitle)
                    GridRow {
                        GridFieldLabel("Staffel / Folge")
                        HStack {
                            TextField("", text: $entry.nfoFields.season)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 80)
                            TextField("", text: $entry.nfoFields.episode)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 80)
                        }
                    }
                }
                GridRow {
                    GridFieldLabel("Jahr")
                    TextField("JJJJ", text: $entry.nfoFields.year)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .frame(maxWidth: 100)
                }
                GridRow {
                    GridFieldLabel(isEpisode ? "Ausstrahlung" : "Premiere")
                    TextField("JJJJ-MM-TT", text: $entry.nfoFields.premiered)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .frame(maxWidth: 160)
                }
                textRow("Tagline", $entry.nfoFields.tagline)
                textRow("Kurzbeschreibung", $entry.nfoFields.outline)
                GridRow {
                    GridFieldLabel("Handlung")
                    TextField("", text: $entry.nfoFields.plot, axis: .vertical)
                        .lineLimit(3...10)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    GridFieldLabel("Genres")
                    TextField("kommagetrennt", text: listBinding(\.genres))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    GridFieldLabel("Tags")
                    TextField("kommagetrennt", text: listBinding(\.tags))
                        .textFieldStyle(.roundedBorder)
                }
                textRow("Studio", $entry.nfoFields.studio)
                GridRow {
                    GridFieldLabel("Regie")
                    TextField("kommagetrennt", text: listBinding(\.directors))
                        .textFieldStyle(.roundedBorder)
                }
                textRow("Drehbuch", $entry.nfoFields.credits)
                GridRow {
                    GridFieldLabel("Bewertung")
                    HStack {
                        TextField("0–10", text: $entry.nfoFields.rating)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 80)
                        Text("Eigene:")
                            .foregroundStyle(.secondary)
                        TextField("0–10", text: $entry.nfoFields.userRating)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 80)
                    }
                }
                textRow("Altersfreigabe", $entry.nfoFields.mpaa)
                GridRow {
                    GridFieldLabel("Laufzeit (min)")
                    TextField("", text: $entry.nfoFields.runtime)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                }
                Text("Unbekannte Elemente, Reihenfolge und Einrückung der NFO bleiben beim Speichern erhalten.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .gridCellColumns(2)
            }
            .padding(8)
        }
    }

    private func textRow(_ label: LocalizedStringKey, _ text: Binding<String>) -> some View {
        GridRow {
            GridFieldLabel(label)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func listBinding(_ keyPath: WritableKeyPath<NFOFields, [String]>) -> Binding<String> {
        Binding(
            get: { entry.nfoFields[keyPath: keyPath].joined(separator: ", ") },
            set: { entry.nfoFields[keyPath: keyPath] = $0.splitCommaList() }
        )
    }

    private func infoSection(title: LocalizedStringKey, items: [DocumentInfoItem]) -> some View {
        GroupBox(title) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    GridRow {
                        Text(item.label)
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        Text(item.value)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Untertitel

    private func subtitleInfoSection(_ info: SubtitleInfo) -> some View {
        var items: [DocumentInfoItem] = [
            DocumentInfoItem(label: String(localized: "Format"), value: info.format.rawValue.uppercased()),
            DocumentInfoItem(label: String(localized: "Cues"), value: String(info.cueCount)),
        ]
        if let start = info.firstStartMilliseconds, let end = info.lastEndMilliseconds {
            items.append(DocumentInfoItem(
                label: String(localized: "Zeitspanne"),
                value: "\(ChapterList.formatTimestamp(start)) – \(ChapterList.formatTimestamp(end))"
                    + " (\(ChapterList.formatTimestamp(info.spanMilliseconds)))"))
        }
        items.append(DocumentInfoItem(label: String(localized: "Zeichensatz"), value: info.encoding))
        items.append(DocumentInfoItem(label: String(localized: "Zeilenende"), value: info.lineEndings))
        items.append(DocumentInfoItem(
            label: String(localized: "Sprache (Dateiname)"),
            value: info.languageFromName ?? String(localized: "keine")))
        if !info.flagsFromName.isEmpty {
            items.append(DocumentInfoItem(label: "Flags", value: info.flagsFromName.joined(separator: ", ")))
        }
        return infoSection(title: "Untertitel (nur Anzeige)", items: items)
    }

    private func vttHeaderSection(_ info: SubtitleInfo) -> some View {
        GroupBox("WebVTT-Kopf") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                textRow("Titel", $entry.subtitleFields.title)
                GridRow {
                    GridFieldLabel("Language")
                    TextField("z.B. de", text: $entry.subtitleFields.language)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 140)
                }
                if let header = info.header {
                    ForEach(Array(header.lines.enumerated()), id: \.offset) { _, line in
                        GridRow {
                            Text("Kopfzeile")
                                .gridColumnAlignment(.trailing)
                                .foregroundStyle(.secondary)
                            Text(line)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    ForEach(Array(header.notes.enumerated()), id: \.offset) { _, note in
                        GridRow {
                            Text("NOTE")
                                .gridColumnAlignment(.trailing)
                                .foregroundStyle(.secondary)
                            Text(note)
                                .textSelection(.enabled)
                        }
                    }
                }
                Text("Titel und Language-Zeile werden im Kopf gespeichert; alle Cues bleiben unverändert.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .gridCellColumns(2)
            }
            .padding(8)
        }
    }

    private var srtNote: some View {
        GroupBox("SRT") {
            // Das Muster steht verbatim: "%{" darf nie durch die Format-
            // Auswertung lokalisierter Texte laufen.
            (Text("SRT hat keinen Kopfblock. Die Sprache steckt im Dateinamen — Umbenennen über „Dateiname ↔ Tags“ mit dem Muster ")
             + Text(verbatim: "%{base}.de").font(.body.monospaced()) + Text(verbatim: "."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}

/// „Alle Cues um +1,5 s": eigener Schreibweg über `AppModel.shiftSubtitle`
/// (Sicherung, atomarer Austausch, Neuladen). Gesperrt, solange der
/// VTT-Kopf ungespeicherte Änderungen hat — beides zusammen wäre zwei
/// Schreibvorgänge auf einer Datei.
private struct SubtitleShiftSection: View {
    @Bindable var entry: FileEntry
    @Environment(AppModel.self) private var model
    @State private var secondsText = "1.5"

    private var seconds: Double? {
        Double(secondsText.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        GroupBox("Zeitversatz") {
            HStack(spacing: 8) {
                Text("Alle Cues verschieben um")
                TextField("Sekunden", text: $secondsText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 90)
                Text("s")
                Button("Verschieben") {
                    guard let seconds else { return }
                    Task { await model.shiftSubtitle(entry: entry, seconds: seconds) }
                }
                .disabled(seconds == nil || seconds == 0 || entry.isDirty || entry.isSaving
                          || model.isDestructiveActionLocked)
                Spacer()
            }
            .padding(8)
        }
    }
}
