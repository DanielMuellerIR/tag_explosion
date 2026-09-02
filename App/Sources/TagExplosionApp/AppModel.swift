// Zentrales App-Modell: geladene Dateien, Auswahl, Laden/Speichern.
// UI-State läuft auf dem MainActor; Datei-IO in Hintergrund-Tasks.
import AppKit
import EInvoiceCore
import Observation
import SwiftUI
import TagExplosionCore
import UniformTypeIdentifiers

// Endungs-Sets kommen zentral aus dem Core (MediaFormats), damit App, CLI
// und Export/Import dieselbe Dateierkennung nutzen.
let audioExtensions = MediaFormats.audio
let imageExtensions = MediaFormats.image
let videoExtensions = MediaFormats.video
let ebookExtensions = MediaFormats.ebook
let documentExtensions = MediaFormats.document
let playlistExtensions = MediaFormats.playlist

/// Art der geladenen Datei — bestimmt Editor und Speicherweg. Direkt der
/// Core-Typ (auch das Archiv nutzt ihn); die Zuordnung inklusive des
/// Video→audio-Wegs liegt zentral in MediaFormats.
typealias MediaKind = MediaFormats.Kind

extension MediaFormats.Kind {
    static func forURL(_ url: URL) -> MediaKind? { MediaFormats.kind(of: url) }
}

/// Eine geladene Datei mit Original-Zustand und Bearbeitungspuffer.
@Observable
@MainActor
final class FileEntry: Identifiable {
    nonisolated let url: URL
    nonisolated let kind: MediaKind
    nonisolated var id: URL { url }

    /// Zustand wie zuletzt von der Platte gelesen (Audio); andere Medienarten
    /// behalten die Neutralwerte der Property-Defaults.
    private(set) var original = TagData(properties: [], artworks: [], audio: nil)
    /// Bearbeitungspuffer — das, was die UI anzeigt und ändert (Audio).
    var properties: [TagProperty] = []
    var artworks: [Artwork] = []
    /// Kapitel (nur bei Formaten mit Kapiteln, siehe `supportsChapters`).
    var chapters: [Chapter] = []

    /// Original und Bearbeitungspuffer für Bilder (nur bei kind == .image).
    /// `imageOriginal` ist der zusammengeführte Stand (Sidecar-Werte
    /// überlagern eingebettete); `imageReading` trägt dazu, welche Felder
    /// aus der Sidecar stammen und wie deren Stempel beim Lesen war.
    private(set) var imageOriginal = ImageCoreFields()
    private(set) var imageReading = ImageCoreReading(fields: ImageCoreFields())
    var imageFields = ImageCoreFields()

    /// Original und Bearbeitungspuffer für E-Books (nur bei kind == .ebook).
    private(set) var ebookOriginal = EbookCoreFields()
    var ebookFields = EbookCoreFields()
    /// Cover, wie es beim Lesen in der Datei stand (nil = keins). Nur damit
    /// lässt sich erkennen, ob ein ausgewähltes Cover überhaupt eine Änderung
    /// ist — ein Schreibvorgang mit identischen Bytes tauscht die Datei sonst
    /// ohne jeden inhaltlichen Grund aus.
    private(set) var ebookOriginalCover: Data?
    /// Neues Cover, das beim Speichern geschrieben wird (nil = unverändert).
    /// Über `setEbookCover(_:)` setzen, nicht direkt: Nur so werden gleiche
    /// Bytes als "keine Änderung" erkannt.
    private(set) var ebookCoverReplacement: Data?

    /// Geparste E-Rechnung (nur bei kind == .invoice). Kein Bearbeitungs-
    /// puffer: Rechnungen sind reine Anzeige.
    private(set) var invoiceDocument: EInvoiceDocument?

    /// Original und Bearbeitungspuffer für Dokumente (nur bei kind == .document).
    private(set) var documentOriginal = DocumentCoreFields()
    var documentFields = DocumentCoreFields()
    /// CBZ: erste Seite als Cover — reine Anzeige, kein Schreibweg.
    private(set) var documentCover: Data?
    /// Anzeigeinformationen (Anwendung, Seiten, Wörter …), nur lesend.
    private(set) var documentInfo: [DocumentInfoItem] = []

    /// Sidecars (nur bei kind == .sidecar): gelesener Inhalt (Anzeige) plus
    /// Original und Bearbeitungspuffer der NFO- bzw. VTT-Felder.
    private(set) var sidecarContents: SidecarContents?
    private(set) var nfoOriginal = NFOFields()
    var nfoFields = NFOFields()
    private(set) var subtitleOriginal = SubtitleEditableFields()
    var subtitleFields = SubtitleEditableFields()
    /// Playlist/Cue-Sheet (nur bei kind == .playlist): Anzeigeinhalt mit
    /// aufgelösten Einträgen, dazu Original und Bearbeitungspuffer der
    /// Beschriftung (Kopffelder, Titel/Interpret je Eintrag).
    private(set) var playlistContents = PlaylistContents(
        format: .m3u, fields: PlaylistCoreFields(), entries: [])
    private(set) var playlistOriginal = PlaylistCoreFields()
    var playlistFields = PlaylistCoreFields()

    /// Stand der Datei auf der Platte, als sie zuletzt gelesen wurde. Vor dem
    /// Schreiben wird dagegen geprüft: Hat ein anderes Programm die Datei
    /// inzwischen geändert, darf das Speichern sie nicht überschreiben.
    private(set) var diskStamp: FileStamp?

    /// Fehlertext des letzten Speicherversuchs (nil = ok).
    var lastError: String?
    /// Ein Speichervorgang pro Datei reicht aus. Der Zustand verhindert, dass
    /// zwei Buttons gleichzeitig denselben TagLib-/Dateischreibvorgang starten.
    var isSaving = false
    /// Wartende Aktionen (Entfernen, Import, Schließen) werden erst nach dem
    /// laufenden Schreibvorgang fortgesetzt. Continuations vermeiden Polling
    /// und machen den Ablauf auch in headless Tests deterministisch.
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []

    /// Unveränderlicher Stand zu Beginn eines Speichervorgangs. Der Puffer darf
    /// sich währenddessen weiter ändern; deshalb schreiben wir nie direkt aus
    /// den später möglicherweise veränderten UI-Feldern.
    enum SaveSnapshot: Sendable {
        /// `chapters` ist nil, wenn das Format keine Kapitel kennt — dann
        /// fasst der Schreibweg die Kapitel gar nicht an.
        case audio(properties: [TagProperty], artworks: [Artwork], chapters: [Chapter]?)
        /// `sidecar`: Sidecar-Zustand aus dem Lesevorgang — damit erkennt der
        /// Schreibweg eine inzwischen fremd angelegte oder geänderte Sidecar.
        case image(fields: ImageCoreFields, original: ImageCoreFields, sidecar: SidecarState)
        case ebook(fields: EbookCoreFields, original: EbookCoreFields, cover: Data?)
        case document(fields: DocumentCoreFields, original: DocumentCoreFields)
        case sidecar(fields: SidecarFields, original: SidecarFields)
        case playlist(fields: PlaylistCoreFields, original: PlaylistCoreFields)
    }

    /// `stamp` gehört zum gelesenen `loaded`-Zustand (konsistenter
    /// Schnappschuss aus `AppModel.readStamped`). Beides zusammen ist die
    /// Vergleichsbasis für die Konfliktprüfung beim Speichern.
    init(url: URL, loaded: LoadedData, stamp: FileStamp?) {
        self.url = url
        self.diskStamp = stamp
        switch loaded {
        case .audio(let data):
            self.kind = .audio
            self.original = data
            self.properties = data.properties
            self.artworks = data.artworks
            self.chapters = data.chapters
        case .image(let reading):
            self.kind = .image
            self.imageReading = reading
            self.imageOriginal = reading.fields
            self.imageFields = reading.fields
        case .ebook(let fields, let cover):
            self.kind = .ebook
            self.ebookOriginal = fields
            self.ebookFields = fields
            self.ebookOriginalCover = cover
        case .invoice(let document):
            self.kind = .invoice
            self.invoiceDocument = document
        case .document(let fields, let cover, let info):
            self.kind = .document
            self.documentOriginal = fields
            self.documentFields = fields
            self.documentCover = cover
            self.documentInfo = info
        case .sidecar(let contents):
            self.kind = .sidecar
            self.acceptNewSidecarOriginal(contents)
        case .playlist(let contents):
            self.kind = .playlist
            self.playlistContents = contents
            self.playlistOriginal = contents.fields
            self.playlistFields = contents.fields
        }
    }

    /// Bequemer Weg für Tests: Stempel getrennt vom Inhalt erheben. Der
    /// Produktionspfad benutzt ausschließlich den konsistenten Schnappschuss
    /// (`AppModel.readStamped`), weil zwischen Lesen und Stempeln sonst eine
    /// fremde Änderung unbemerkt dazwischenrutschen kann.
    convenience init(url: URL, loaded: LoadedData) {
        self.init(url: url, loaded: loaded, stamp: FileStamp.current(of: url))
    }

    /// Derselbe Eintrag unter neuem Pfad — nach dem Umbenennen der Datei.
    /// `url` ist bewusst unveränderlich (sie ist die Identität in Liste und
    /// Auswahl), deshalb entsteht ein neues Objekt. Es übernimmt Original,
    /// Bearbeitungspuffer, Cover-Auswahl und Plattenstempel unverändert:
    /// Umbenennen ändert weder Inhalt noch Inode noch Änderungszeit der
    /// Datei, der alte Stempel bleibt also gültig.
    /// `sidecar`: neuer Pfad der mit umbenannten XMP-Sidecar (Bilder); nil
    /// lässt den gelesenen Sidecar-Pfad, wie er ist.
    convenience init?(relocating other: FileEntry, to url: URL, sidecar: URL? = nil) {
        guard var loaded = other.loadedState else { return nil }
        if let sidecar, case .image(var reading) = loaded {
            reading.sidecarURL = sidecar
            loaded = .image(reading)
        }
        self.init(url: url, loaded: loaded, stamp: other.diskStamp)
        properties = other.properties
        artworks = other.artworks
        imageFields = other.imageFields
        ebookFields = other.ebookFields
        ebookCoverReplacement = other.ebookCoverReplacement
        documentFields = other.documentFields
        nfoFields = other.nfoFields
        subtitleFields = other.subtitleFields
        playlistFields = other.playlistFields
        lastError = other.lastError
    }

    /// Der zuletzt gelesene Plattenstand als `LoadedData` — die Umkehrung
    /// von `init(url:loaded:stamp:)`. nil nur für einen Rechnungseintrag
    /// ohne Dokument, den der Initialisierer gar nicht erzeugt.
    var loadedState: LoadedData? {
        switch kind {
        case .audio: return .audio(original)
        case .image: return .image(imageReading)
        case .ebook: return .ebook(ebookOriginal, cover: ebookOriginalCover)
        case .invoice: return invoiceDocument.map(LoadedData.invoice)
        case .document:
            return .document(documentOriginal, cover: documentCover, info: documentInfo)
        case .sidecar:
            return sidecarContents.map(LoadedData.sidecar)
        case .playlist:
            return .playlist(playlistContents)
        }
    }

    var audio: AudioInfo? { original.audio }
    var isReadOnly: Bool { kind == .audio && original.isReadOnly }
    /// Nur MP3, MP4 und Matroska tragen Kapitel; nur dann zeigt der Editor
    /// den Kapitel-Abschnitt.
    var supportsChapters: Bool { kind == .audio && original.supportsChapters }
    /// Tag-Schichten (ID3v1/ID3v2/APE …) laut letztem Lesestand; leer bei
    /// Formaten ohne Schichtenmodell — nur dann fehlt der Abschnitt im Editor.
    /// Kein Bearbeitungspuffer: Entfernen läuft direkt über
    /// `AppModel.stripLayer` und liest die Datei danach neu.
    var layers: [TagLayer] { kind == .audio ? original.layers : [] }

    var isDirty: Bool {
        switch kind {
        case .audio:
            return properties != original.properties || artworks != original.artworks
                || chapters != original.chapters
        case .image:
            return imageFields != imageOriginal
        case .ebook:
            return ebookFields != ebookOriginal || ebookCoverReplacement != nil
        case .invoice:
            // Reine Anzeige — es gibt nichts zu ändern und nichts zu speichern.
            return false
        case .document:
            return documentFields != documentOriginal
        case .sidecar:
            return nfoFields != nfoOriginal || subtitleFields != subtitleOriginal
        case .playlist:
            return playlistFields != playlistOriginal
        }
    }

    /// Verwirft alle ungespeicherten Änderungen.
    func revert() {
        properties = original.properties
        artworks = original.artworks
        chapters = original.chapters
        imageFields = imageOriginal
        ebookFields = ebookOriginal
        ebookCoverReplacement = nil
        documentFields = documentOriginal
        nfoFields = nfoOriginal
        subtitleFields = subtitleOriginal
        playlistFields = playlistOriginal
        lastError = nil
    }

    /// Nach erfolgreichem Speichern/Neuladen den Originalzustand ersetzen.
    func acceptNewOriginal(_ data: TagData) {
        original = data
        properties = data.properties
        artworks = data.artworks
        chapters = data.chapters
        lastError = nil
    }

    /// Bild-Pendant zu `acceptNewOriginal`.
    func acceptNewImageOriginal(_ reading: ImageCoreReading) {
        imageReading = reading
        imageOriginal = reading.fields
        imageFields = reading.fields
        lastError = nil
    }

    /// E-Book-Pendant zu `acceptNewOriginal`.
    func acceptNewEbookOriginal(_ fields: EbookCoreFields, cover: Data?) {
        ebookOriginal = fields
        ebookFields = fields
        ebookOriginalCover = cover
        ebookCoverReplacement = nil
        lastError = nil
    }

    /// Dokument-Pendant zu `acceptNewOriginal`.
    func acceptNewDocumentOriginal(_ fields: DocumentCoreFields, cover: Data?,
                                   info: [DocumentInfoItem]) {
        documentOriginal = fields
        documentFields = fields
        documentCover = cover
        documentInfo = info
        lastError = nil
    }

    /// Sidecar-Pendant zu `acceptNewOriginal`: Original und Puffer der
    /// jeweiligen Art; die andere Art bleibt auf ihren Neutralwerten.
    func acceptNewSidecarOriginal(_ contents: SidecarContents) {
        sidecarContents = contents
        switch contents {
        case .nfo(let nfo):
            nfoOriginal = nfo.fields
            nfoFields = nfo.fields
        case .subtitle(let subtitle):
            subtitleOriginal = subtitle.fields
            subtitleFields = subtitle.fields
        }
        lastError = nil
    }

    /// Playlist-Pendant zu `acceptNewOriginal`.
    func acceptNewPlaylistOriginal(_ contents: PlaylistContents) {
        playlistContents = contents
        playlistOriginal = contents.fields
        playlistFields = contents.fields
        lastError = nil
    }

    /// Ein ausgewähltes Cover zählt nur als Änderung, wenn es sich von dem in
    /// der Datei unterscheidet. Dieselbe Bilddatei noch einmal auszuwählen ist
    /// inhaltlich ein Nichts-Tun und darf keinen Schreibvorgang auslösen: Der
    /// atomare Austausch gäbe der Datei eine neue Identität, änderte die
    /// Änderungszeit, legte eine Sicherung an und ließe vorhandene Hardlinks
    /// auf dem alten Stand zurück.
    /// Während eines laufenden Speicherns wird bewusst NICHT normalisiert:
    /// `ebookOriginalCover` ist dann veraltet (das Read-back ersetzt es gleich
    /// durch das gerade geschriebene Cover). Eine Auswahl des alten Originals
    /// würde sonst zu nil normalisiert und ginge nach dem Save verloren —
    /// `acceptSaved` gleicht die Auswahl stattdessen mit dem wirklich
    /// geschriebenen Cover ab.
    func setEbookCover(_ data: Data) {
        ebookCoverReplacement = (!isSaving && data == ebookOriginalCover) ? nil : data
    }

    /// Frisch gelesenen Platten-Zustand als neues Original übernehmen.
    /// `stamp` muss zum selben Leseschnappschuss gehören wie `loaded` —
    /// ein getrennt erhobener Stempel könnte schon zu einer fremden, nie
    /// gelesenen Dateiversion gehören, die das nächste Speichern dann als
    /// "unverändert" überschriebe.
    func acceptNew(_ loaded: LoadedData, stamp: FileStamp?) {
        diskStamp = stamp
        switch loaded {
        case .audio(let data): acceptNewOriginal(data)
        case .image(let reading): acceptNewImageOriginal(reading)
        case .ebook(let fields, let cover): acceptNewEbookOriginal(fields, cover: cover)
        case .invoice(let document):
            invoiceDocument = document
            lastError = nil
        case .document(let fields, let cover, let info):
            acceptNewDocumentOriginal(fields, cover: cover, info: info)
        case .sidecar(let contents):
            acceptNewSidecarOriginal(contents)
        case .playlist(let contents):
            acceptNewPlaylistOriginal(contents)
        }
    }

    /// Markiert genau einen Speicherauftrag als aktiv und liefert dessen Stand.
    /// nil bedeutet: Die Datei ist sauber oder wird bereits gespeichert.
    func beginSaving() -> SaveSnapshot? {
        guard isDirty, !isSaving else { return nil }
        isSaving = true
        switch kind {
        case .audio:
            return .audio(properties: properties, artworks: artworks,
                          chapters: supportsChapters ? chapters : nil)
        case .image:
            return .image(fields: imageFields, original: imageOriginal,
                          sidecar: imageReading.sidecar)
        case .ebook:
            return .ebook(fields: ebookFields, original: ebookOriginal,
                          cover: ebookCoverReplacement)
        case .invoice:
            // Nicht erreichbar: isDirty ist für Rechnungen immer false.
            isSaving = false
            return nil
        case .document:
            return .document(fields: documentFields, original: documentOriginal)
        case .sidecar:
            switch sidecarContents {
            case .nfo: return .sidecar(fields: .nfo(nfoFields), original: .nfo(nfoOriginal))
            case .subtitle:
                return .sidecar(fields: .subtitle(subtitleFields), original: .subtitle(subtitleOriginal))
            case nil:
                isSaving = false
                return nil
            }
        case .playlist:
            return .playlist(fields: playlistFields, original: playlistOriginal)
        }
    }

    /// Macht die Bedienung wieder frei, auch wenn das Schreiben fehlgeschlagen
    /// ist. Original und Bearbeitungspuffer werden hier absichtlich nicht
    /// verändert.
    func finishSaving() {
        isSaving = false
        let waiters = saveWaiters
        saveWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Wartet nur dann, wenn aktuell wirklich geschrieben wird. Da diese
    /// Methode und `finishSaving()` auf dem MainActor laufen, kann zwischen
    /// Prüfung und Eintragen kein Abschluss verloren gehen.
    func waitUntilSaveFinished() async {
        guard isSaving else { return }
        await withCheckedContinuation { saveWaiters.append($0) }
    }

    /// Übernimmt ausschließlich den von `snapshot` gesicherten Plattenstand.
    /// Hat die Person während des Schreibens weitergetippt, bleibt dieser neuere
    /// Puffer erhalten und ist gegenüber dem neuen Original weiterhin dirty.
    /// `stamp` gehört zum Read-back `reloaded` (konsistenter Schnappschuss) —
    /// so kann nie ein Stempel einer neueren, fremden Dateiversion mit den
    /// hier gelesenen älteren Daten kombiniert werden.
    func acceptSaved(_ snapshot: SaveSnapshot, reloaded: LoadedData, stamp: FileStamp?) {
        // Der eigene Schreibvorgang ist die neue Vergleichsbasis.
        diskStamp = stamp
        switch (snapshot, reloaded) {
        case (.audio(let savedProperties, let savedArtworks, let savedChapters), .audio(let data)):
            original = data
            if properties == savedProperties { properties = data.properties }
            if artworks == savedArtworks { artworks = data.artworks }
            if savedChapters == nil || chapters == savedChapters { chapters = data.chapters }
        case (.image(let savedFields, _, _), .image(let reading)):
            imageReading = reading
            imageOriginal = reading.fields
            if imageFields == savedFields { imageFields = reading.fields }
        case (.ebook(let savedFields, _, let savedCover), .ebook(let fields, let cover)):
            ebookOriginal = fields
            ebookOriginalCover = cover
            if ebookFields == savedFields { ebookFields = fields }
            // Ein gleiches Ersatz-Cover wurde geschrieben und ist daher nicht
            // mehr dirty. Genauso wenig dirty ist eine Auswahl, die dem
            // ZURÜCKGELESENEN Cover entspricht: Bei einem reinen Feld-Save
            // (savedCover == nil) konnte `setEbookCover` das erneut gewählte
            // Originalcover nicht normalisieren (isSaving) — der Abgleich mit
            // dem Read-back holt das hier nach, sonst bliebe der Eintrag ohne
            // Inhaltsänderung dirty und der nächste Save tauschte die Datei
            // unnötig aus. Ein inzwischen ausgewähltes anderes Cover bleibt.
            if ebookCoverReplacement == savedCover || ebookCoverReplacement == cover {
                ebookCoverReplacement = nil
            }
        case (.document(let savedFields, _), .document(let fields, let cover, let info)):
            documentOriginal = fields
            documentCover = cover
            documentInfo = info
            if documentFields == savedFields { documentFields = fields }
        case (.sidecar(let savedFields, _), .sidecar(let contents)):
            sidecarContents = contents
            switch (savedFields, contents) {
            case (.nfo(let saved), .nfo(let nfo)):
                nfoOriginal = nfo.fields
                if nfoFields == saved { nfoFields = nfo.fields }
            case (.subtitle(let saved), .subtitle(let subtitle)):
                subtitleOriginal = subtitle.fields
                if subtitleFields == saved { subtitleFields = subtitle.fields }
            default:
                assertionFailure("Sidecar snapshot and read-back have different sidecar kinds")
            }
        case (.playlist(let savedFields, _), .playlist(let contents)):
            playlistContents = contents
            playlistOriginal = contents.fields
            if playlistFields == savedFields { playlistFields = contents.fields }
        default:
            // Ein Snapshot gehört immer zur selben FileEntry-Instanz. Falls ein
            // späterer Umbau das verletzt, darf kein fremder Zustand übernommen werden.
            assertionFailure("Save snapshot and read-back have different media kinds")
        }
        lastError = nil
    }

    // Bequeme Zugriffe für die UI ------------------------------------------

    /// Erster Wert eines Schlüssels (für Einfach-Felder).
    func firstValue(_ key: String) -> String {
        properties.first { $0.key == key }?.value ?? ""
    }

    /// Setzt einen Schlüssel auf genau einen Wert (leer = Feld entfernen).
    func setSingleValue(_ key: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = properties.firstIndex(where: { $0.key == key }) {
            if trimmed.isEmpty {
                properties.removeAll { $0.key == key }
            } else {
                // Ersten Eintrag ändern, weitere gleichnamige entfernen
                properties[index].value = trimmed
                var seen = false
                properties.removeAll { prop in
                    if prop.key == key {
                        if seen { return true }
                        seen = true
                    }
                    return false
                }
            }
        } else if !trimmed.isEmpty {
            properties.append(TagProperty(key: key, value: trimmed))
        }
    }

    var displayTitle: String {
        let title: String
        switch kind {
        case .audio: title = firstValue("TITLE")
        case .image: title = imageFields.title
        case .ebook: title = ebookFields.title
        case .invoice: title = invoiceDocument?.summary.invoiceNumber ?? ""
        case .document: title = documentFields.title
        case .sidecar:
            switch sidecarContents {
            case .nfo: title = nfoFields.title
            case .subtitle: title = subtitleFields.title
            case nil: title = ""
            }
        case .playlist: title = playlistFields.title
        }
        return title.isEmpty ? url.lastPathComponent : title
    }

    /// Alles, was der Fensterkopf über diese Datei wissen muss.
    var chromeEntry: WindowChromeEntry {
        WindowChromeEntry(title: displayTitle, url: url,
                          isDirty: isDirty, isSaving: isSaving)
    }

    var displaySubtitle: String {
        switch kind {
        case .audio:
            return [firstValue("ARTIST"), firstValue("ALBUM")]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case .image:
            return imageFields.keywords.joined(separator: ", ")
        case .ebook:
            return ebookFields.authors.joined(separator: ", ")
        case .invoice:
            guard let summary = invoiceDocument?.summary else { return "" }
            return [summary.sellerName ?? "", summary.issueDate ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case .document:
            return documentFields.authors.joined(separator: ", ")
        case .sidecar:
            switch sidecarContents {
            case .nfo(let nfo):
                return [nfo.rootName ?? "url", nfoFields.year]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            case .subtitle(let subtitle):
                let info = subtitle.info
                let language = info.languageFromName ?? ""
                return [language, "\(info.cueCount) cues"]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            case nil:
                return ""
            }
        case .playlist:
            let count = playlistContents.entries.count
            let performer = playlistFields.performer
            let entries = String(localized: "\(count) Einträge")
            return performer.isEmpty ? entries : "\(performer) · \(entries)"
        }
    }
}

/// Frisch gelesener Datei-Zustand (Audio, Bild, E-Book oder E-Rechnung).
enum LoadedData: Sendable {
    case audio(TagData)
    /// Bilder tragen ihren Sidecar-Zustand mit: welche Felder aus der
    /// XMP-Sidecar stammen und wie deren Stempel beim Lesen war.
    case image(ImageCoreReading)
    /// E-Books tragen ihr Cover mit: Felder und Cover stammen aus einem
    /// gemeinsamen Lesevorgang, und nur mit dem Original-Cover im Speicher
    /// lässt sich ein gleich gebliebenes Cover als Nichts-Tun erkennen.
    case ebook(EbookCoreFields, cover: Data?)
    /// E-Rechnung (XML) — reine Anzeige, es gibt keinen Bearbeitungspuffer.
    case invoice(EInvoiceDocument)
    /// Dokumente: Felder, CBZ-Cover (nur Anzeige) und Anzeigeinformationen
    /// aus einem gemeinsamen Lesevorgang.
    case document(DocumentCoreFields, cover: Data?, info: [DocumentInfoItem])
    /// Video-Sidecars: NFO-Inhalt oder Untertitel-Infos plus editierbare Felder.
    case sidecar(SidecarContents)
    /// Playlist/Cue-Sheet: Anzeigeinhalt (Einträge mit aufgelösten Pfaden)
    /// samt der bearbeitbaren Beschriftung in `fields`.
    case playlist(PlaylistContents)
}

/// Entscheidung für eine Aktion, die ungespeicherte Editor-Puffer zerstören
/// oder durch Plattenwerte ersetzen würde.
enum DirtyConflictDecision {
    case save
    case discard
    case cancel
}

/// Der für SwiftUI sichtbare Teil einer wartenden Aktion. Die eigentliche
/// Abschluss-Closure bleibt privat im Modell, damit die View keine Dateilogik
/// oder Terminierungsdetails kennen muss.
struct PendingDirtyConflict: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let affectedEntryCount: Int
    var failureMessage: String?

    var displayedMessage: String { failureMessage ?? message }
}

/// Explizite Freigabe für Archive, die mindestens ein Ziel außerhalb ihres
/// eigenen Verzeichnisses enthalten. Angezeigt wird bewusst die vollständige
/// aufgelöste Zielliste, nicht nur der erste auffällige Pfad.
struct PendingExternalImportApproval: Identifiable {
    let id = UUID()
    let targetPaths: [String]
    let externalTargetCount: Int

    var displayedMessage: String {
        String(localized:
            "Dieses Archiv enthält \(externalTargetCount) Ziel(e) außerhalb seines Ordners. Alle aufgelösten Ziele:")
            + "\n\n" + targetPaths.joined(separator: "\n")
    }
}

/// Rückmeldung an den AppDelegate nach einer asynchronen Terminierungsfrage.
/// AppKit-Typen bleiben dabei aus der headless testbaren Konfliktlogik heraus.
enum TerminationDecision {
    case terminateNow
    case terminateCancel
}

/// Globaler App-Zustand.
@Observable
@MainActor
final class AppModel {
    private struct PendingAction {
        var conflict: PendingDirtyConflict
        let entries: [FileEntry]
        let perform: @MainActor () async -> Void
        let cancel: @MainActor () -> Void
    }

    private struct PendingExternalImportAction {
        let perform: @MainActor () async -> Void
    }

    var entries: [FileEntry] = []
    var selection: Set<URL> = []
    /// Das Fenster, in dem dieses Modell steckt — gesetzt von `WindowBridge`.
    /// `WindowSessions` erkennt daran, welche Modelle wirklich sichtbar sind;
    /// ein Modell ohne Fenster darf keine Dateien mehr zugeteilt bekommen.
    /// Bewusst nicht beobachtet: Es ist keine Anzeige-, sondern Zuordnungsinfo.
    @ObservationIgnored weak var hostWindow: NSWindow?
    /// Mehrere Öffnen-Aktionen können überlappen (z.B. Finder-Drop und
    /// Öffnen-Dialog). Der Zähler hält den Fortschrittsindikator sichtbar,
    /// bis auch der letzte Auftrag fertig ist.
    private var loadingOperationCount = 0
    /// URLs werden noch vor dem ersten Hintergrundzugriff reserviert. So kann
    /// ein zweiter Auftrag dieselbe Datei nicht parallel ein zweites Mal laden.
    private var openingURLs: Set<URL> = []
    /// Läuft mindestens ein Ladevorgang? (Fortschritt in der Sidebar)
    var isLoading: Bool { loadingOperationCount > 0 }
    /// Fehlermeldung für Alert-Anzeige.
    var alertMessage: String?
    /// Sichtbarer Save/Discard/Cancel-Zustand für Import, Entfernen, Fenster
    /// und App-Terminierung.
    private(set) var pendingConflict: PendingDirtyConflict?
    /// Eine Aktion wartet zunächst auf bereits laufende Speichervorgänge.
    /// Währenddessen darf kein zweiter konkurrierender Auftrag entstehen.
    private var isPreparingDestructiveAction = false
    /// Nach einem Klick auf Speichern/Verwerfen bleibt die UI gesperrt, bis
    /// alle betroffenen Dateien fertig behandelt sind.
    private(set) var isResolvingConflict = false
    private var pendingAction: PendingAction?
    /// Der Button beansprucht die Entscheidung synchron vor dem asynchronen
    /// Task. So kann SwiftUIs anschließendes Dialog-Dismiss nicht noch ein
    /// konkurrierendes „Abbrechen“ dazwischenschieben.
    private var claimedConflictDecision: DirtyConflictDecision?
    private(set) var pendingExternalImport: PendingExternalImportApproval?
    private var pendingExternalImportAction: PendingExternalImportAction?
    private var claimedExternalImportApproval: Bool?

    var isDestructiveActionLocked: Bool {
        pendingConflict != nil || pendingExternalImport != nil
            || pendingStaleWrite != nil || claimedStaleWrite != nil
            || isPreparingDestructiveAction || isResolvingConflict
    }

    /// Der Dialog selbst sperrt bereits die View. Diese Ergänzung deckt die
    /// kurze Warte- und Auflösungsphase ab, in der sonst ein Textfeld noch eine
    /// neue, unbestätigte Änderung annehmen könnte.
    var isEditorInteractionLocked: Bool {
        isPreparingDestructiveAction || isResolvingConflict
    }

    /// Die ausgewählten Einträge in Listenreihenfolge.
    var selectedEntries: [FileEntry] {
        entries.filter { selection.contains($0.url) }
    }

    /// Genau ein ausgewählter Eintrag (Einzel-Editor), sonst nil.
    var selectedEntry: FileEntry? {
        let selected = selectedEntries
        return selected.count == 1 ? selected.first : nil
    }

    var hasDirtyEntries: Bool {
        entries.contains { $0.isDirty }
    }

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
        loadingOperationCount += 1
        defer { loadingOperationCount -= 1 }

        // Verzeichnisse expandieren und auf Medien-Endungen filtern (Hintergrund).
        let candidates = await Task.detached(priority: .userInitiated) {
            MediaFormats.expandMediaFiles(urls)
        }.value

        // Bereits geladene UND gerade ladende Dateien in einem MainActor-Schritt
        // vergleichen und reservieren. Zwischen Prüfung und Eintragen kann kein
        // zweiter `open`-Aufruf dazwischenfunken.
        let existing = Set(entries.map { MediaFormats.canonicalFileURL($0.url) })
        let newFiles = candidates.filter {
            !existing.contains($0) && openingURLs.insert($0).inserted
        }
        guard !newFiles.isEmpty else { return }
        defer { openingURLs.subtract(newFiles) }

        // Tags parallel lesen (begrenzte Nebenläufigkeit, damit auch riesige
        // Ordner nicht zu viele offene Dateien erzeugen), Reihenfolge stabil.
        let results = await Self.readFiles(newFiles, read: read)

        var failures: [String] = []
        for (url, result) in results {
            switch result {
            case .success(let (loaded, stamp)):
                entries.append(FileEntry(url: url, loaded: loaded, stamp: stamp))
            case .failure:
                failures.append(url.lastPathComponent)
            }
        }
        if selection.isEmpty, let first = entries.first { selection = [first.url] }
        if !failures.isEmpty {
            alertMessage = String(localized: "Nicht lesbar (Format unbekannt?):") + "\n" + failures.joined(separator: "\n")
        }
    }

    /// Liest maximal acht Dateien gleichzeitig. Der Rückgabepuffer wird über
    /// den Eingabeindex sortiert, damit die Auswahl im Finder stabil bleibt.
    nonisolated private static func readFiles(
        _ urls: [URL],
        read: @escaping @Sendable (URL, MediaKind) async throws -> (LoadedData, FileStamp?)
    ) async -> [(URL, Result<(LoadedData, FileStamp?), Error>)] {
        await withTaskGroup(
            of: (Int, URL, Result<(LoadedData, FileStamp?), Error>).self,
            returning: [(URL, Result<(LoadedData, FileStamp?), Error>)].self
        ) { group in
            let maxConcurrent = 8
            var nextIndex = 0
            func addNext() {
                guard nextIndex < urls.count else { return }
                let index = nextIndex
                let url = urls[index]
                nextIndex += 1
                group.addTask {
                    let kind = MediaKind.forURL(url) ?? .audio
                    do {
                        // Der Read-only-Fallback für Container ohne TagLib-Leser
                        // steckt in `readLoaded`, damit Öffnen, Neuladen und
                        // Speichern-Read-back dieselbe Regel verwenden.
                        return (index, url, .success(try await read(url, kind)))
                    } catch {
                        return (index, url, .failure(error))
                    }
                }
            }
            for _ in 0..<min(maxConcurrent, urls.count) { addNext() }
            var buffer: [(Int, URL, Result<(LoadedData, FileStamp?), Error>)] = []
            for await item in group {
                buffer.append(item)
                addNext()
            }
            buffer.sort { $0.0 < $1.0 }
            return buffer.map { ($0.1, $0.2) }
        }
    }

    /// Liest den Datei-Zustand passend zur Medienart (Hintergrund-tauglich);
    /// gemeinsamer Lesepfad für Öffnen, Neuladen und Speichern-Read-back.
    nonisolated static func readLoaded(url: URL, kind: MediaKind) throws -> LoadedData {
        switch kind {
        case .audio:
            do {
                return .audio(try TagFile.read(at: url))
            } catch {
                // Container, für die TagLib keinen Tag-Leser hat (AVI, manche
                // MOV-Varianten, Sun-AU, Ogg-Video), sollen trotzdem geöffnet
                // werden können: Der Technik-Tab über mediainfo funktioniert
                // für sie, bearbeitbar sind sie nicht. Ohne diesen Weg endet
                // das Öffnen mit einem Fehler statt mit einer Ansicht.
                guard MediaFormats.toleratesMissingTagReader(url) else {
                    throw error
                }
                return .audio(TagData(properties: [], artworks: [], audio: nil, isReadOnly: true))
            }
        case .image: return .image(try ExifTool.readCoreReading(url: url))
        case .ebook:
            // Felder und Cover in einem Schnappschuss: Der Editor zeigt damit
            // garantiert das Cover derselben Dateifassung, und ein erneut
            // ausgewähltes gleiches Cover ist als Nichts-Tun erkennbar.
            do {
                let contents = try EbookTool.readSnapshot(
                    url: url, includeCover: EbookTool.supportsCover(url: url)).value
                return .ebook(contents.fields, cover: contents.cover?.data)
            } catch let error as TagError {
                // PDF-Metadaten brauchen exiftool — die E-Rechnungs-Anzeige
                // nicht (CoreGraphics + eigener Leser). Fehlt das Werkzeug,
                // soll ein Rechnungs-PDF trotzdem aufgehen: als reiner
                // Anzeige-Eintrag mit der eingebetteten Rechnung.
                if case .toolNotFound = error,
                   url.pathExtension.lowercased() == "pdf",
                   let document = try? EInvoiceReader.read(url: url) {
                    return .invoice(document)
                }
                throw error
            }
        case .invoice:
            // E-Rechnung (XML): vollständig parsen — reine Anzeige.
            return .invoice(try EInvoiceReader.read(url: url))
        case .document:
            let contents = try DocumentTool.readSnapshot(
                url: url, includeCover: DocumentTool.supportsCover(url: url)).value
            return .document(contents.fields, cover: contents.cover?.data, info: contents.info)
        case .sidecar:
            return .sidecar(try SidecarTool.readSnapshot(url: url).value)
        case .playlist:
            return .playlist(try PlaylistTool.readSnapshot(url: url).value)
        }
    }

    /// Liest Datei-Zustand UND Stempel als konsistenten Schnappschuss: Der
    /// Stempel wird vor und nach dem Lesen erhoben; nur wenn beide gleich
    /// sind, gehören Inhalt und Stempel sicher zusammen. Schreibt ein anderes
    /// Programm genau währenddessen, wird erneut gelesen; bleibt die Datei
    /// dauerhaft in Bewegung, bricht das Lesen ab. Ohne diese Kopplung könnte
    /// das Modell alte Daten mit dem Stempel einer neueren, fremden Version
    /// kombinieren — das nächste Speichern hielte die fremde Version dann für
    /// den eigenen Stand und überschriebe sie ungefragt.
    nonisolated static func readStamped(
        url: URL, kind: MediaKind,
        read: (URL, MediaKind) throws -> LoadedData = AppModel.readLoaded
    ) throws -> (LoadedData, FileStamp?) {
        var remainingAttempts = 3
        while true {
            let before = FileStamp.current(of: url)
            let loaded = try read(url, kind)
            let after = FileStamp.current(of: url)
            if before == after {
                // Ohne Stempel ist die Datei nicht (mehr) erreichbar. Für
                // Video-Container fängt `readLoaded` einen Lesefehler bewusst
                // als read-only-Platzhalter ab — ohne diese Prüfung landete
                // eine inzwischen verschwundene .avi/.mov als scheinbar
                // erfolgreich geöffneter Eintrag in der Liste.
                guard let after else { throw TagError.cannotOpen(path: url.path) }
                return (loaded, after)
            }
            remainingAttempts -= 1
            guard remainingAttempts > 0 else {
                throw TagError.fileChangedOnDisk(path: url.path)
            }
        }
    }

    // MARK: - Speichern

    /// Schlüssel der Auto-Backup-Einstellung (Toggle in den Einstellungen).
    static let autoBackupDefaultsKey = "autoBackupBeforeBatchSave"

    /// Schlüssel des abgesicherten Modus (Kopie in den Papierkorb vor jeder
    /// Änderung).
    static let safeModeDefaultsKey = "trashBackupBeforeSave"

    /// Abgesicherter Modus aktiv? Default an — solange die App jung ist, soll
    /// keine Änderung eine Datei endgültig kosten.
    static var safeModeEnabled: Bool {
        UserDefaults.standard.object(forKey: safeModeDefaultsKey) == nil
            || UserDefaults.standard.bool(forKey: safeModeDefaultsKey)
    }

    /// Überträgt die Einstellung in den Core. Muss beim Start und nach jeder
    /// Änderung der Einstellung laufen.
    static func applySafeMode() {
        TrashBackup.shared.isEnabled = safeModeEnabled
        TrashBackup.shared.folderLabel = String(localized: "Tag Explosion Sicherung")
    }

    /// Schlüssel der Einstellung „Bild-Metadaten in die XMP-Sidecar schreiben
    /// statt in die Bilddatei". Voreinstellung aus; für Kamera-RAW und
    /// Formate ohne exiftool-Schreibweg erzwingt der Core die Sidecar ohnehin.
    nonisolated static let imageSidecarDefaultsKey = "writeImageSidecar"

    /// Sidecar statt Original für alle Bildformate? (Default: aus).
    /// `nonisolated`, weil der Hintergrund-Schreibweg sie liest; UserDefaults
    /// ist threadsicher.
    nonisolated static var imageSidecarPreferred: Bool {
        UserDefaults.standard.bool(forKey: imageSidecarDefaultsKey)
    }

    /// Schlüssel der Einstellung „ID3v2.3 statt ID3v2.4 schreiben" (für alte
    /// Player, die v2.4 nicht lesen). Voreinstellung aus.
    nonisolated static let id3v23DefaultsKey = "writeID3v23"

    /// ID3v2-Version für den Audio-Schreibweg laut Einstellung (Default v2.4).
    /// `nonisolated`, weil der Hintergrund-Schreibweg sie liest.
    nonisolated static var preferredID3Version: ID3Version {
        UserDefaults.standard.bool(forKey: id3v23DefaultsKey) ? .v23 : .v24
    }

    /// Auto-Backup vor Batch-Speichern? (Default: an)
    static var autoBackupEnabled: Bool {
        UserDefaults.standard.object(forKey: autoBackupDefaultsKey) == nil
            || UserDefaults.standard.bool(forKey: autoBackupDefaultsKey)
    }

    /// Speichert alle ausgewählten Dateien mit Änderungen.
    func saveSelected() async {
        guard !isDestructiveActionLocked else { return }
        await saveEntries(selectedEntries.filter(\.isDirty))
    }

    /// Verwirft Änderungen aller ausgewählten Dateien.
    func revertSelected() {
        guard !isDestructiveActionLocked else { return }
        for entry in selectedEntries { entry.revert() }
    }

    var selectionIsDirty: Bool {
        selectedEntries.contains { $0.isDirty }
    }

    /// Die Auswahl kann nur einmal gleichzeitig gespeichert werden. Sichtbar
    /// deaktivierte Speichern-Aktionen verhindern unzulässige Doppel-Clicks.
    var selectionIsSaving: Bool {
        selectedEntries.contains { $0.isSaving }
    }

    var hasSavingEntries: Bool {
        entries.contains { $0.isSaving }
    }

    /// Hat dieses Fenster etwas zu verlieren? Ungespeicherte Änderungen, ein
    /// laufendes Speichern oder ein offener Dialog — jedes davon muss das
    /// Beenden aufhalten. Als benannte Eigenschaft, weil `WindowSessions` das
    /// Prädikat an zwei Stellen braucht (Rundenguard und Schlussabgleich) und
    /// ein Auseinanderlaufen die App unbeendbar machte (Review-Fund 2026-08-20).
    var hasUnfinishedWork: Bool {
        hasDirtyEntries || hasSavingEntries || isDestructiveActionLocked
    }

    func saveAll() async {
        guard !isDestructiveActionLocked else { return }
        await saveEntries(entries.filter(\.isDirty))
    }

    /// Gemeinsamer Speicherpfad: erst Auto-Backup, dann Datei für Datei.
    /// Der Rückgabewert ist für die Konfliktlogik entscheidend: Nur ein
    /// vollständig erfolgreicher Batch darf anschließend importieren, entfernen
    /// oder die App beenden. Modulintern, weil auch die Batch-Regeln
    /// (`applyRules`) diesen Weg nehmen.
    @discardableResult
    func saveEntries(_ dirty: [FileEntry]) async -> Bool {
        await saveEntries(dirty) { entry in
            await self.save(entry: entry)
        }
    }

    /// Variante mit austauschbarem Einzel-Speicherweg für headless Tests. Die
    /// Sicherung, Wartezeit und Erfolgsprüfung bleiben identisch zur App.
    @discardableResult
    private func saveEntries(
        _ dirty: [FileEntry],
        saveEntry: @escaping @MainActor (FileEntry) async -> Bool
    ) async -> Bool {
        let targets = uniqueEntries(dirty)
        await waitForSaves(in: targets)
        let pending = targets.filter(\.isDirty)
        guard !pending.isEmpty else { return true }
        guard await backupIfNeeded(before: pending) else { return false }
        var succeeded = true
        for entry in pending {
            if !(await saveEntry(entry)) { succeeded = false }
        }
        return succeeded
    }

    /// Schreibt vor einem Batch-Speichern (mehr als eine Datei) die Backups
    /// über TagArchiveIO (Namensschema und Ordner-Gruppierung liegen im Core,
    /// damit CLI-Wiederherstellung und App dasselbe Format teilen).
    /// false = Backup fehlgeschlagen, Speichern wird abgebrochen.
    private func backupIfNeeded(before dirtyEntries: [FileEntry]) async -> Bool {
        guard Self.autoBackupEnabled, dirtyEntries.count > 1 else { return true }
        let files = dirtyEntries.map(\.url)
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try TagArchiveIO.writeBackups(files: files)
            }.value
            return true
        } catch {
            alertMessage = String(localized: "Auto-Backup fehlgeschlagen — Speichern abgebrochen.")
                + "\n" + error.localizedDescription
            return false
        }
    }

    // MARK: - Ungespeicherte Änderungen vor destruktiven Aktionen

    /// Startet genau eine geschützte Aktion. Zuerst warten wir auf alle schon
    /// laufenden Saves derselben Dateien; erst dann entscheiden wir anhand der
    /// aktuellen Puffer, ob ein Save/Discard/Cancel-Dialog nötig ist.
    func requestDestructiveAction(
        title: String,
        message: String,
        entries affectedEntries: [FileEntry],
        perform: @escaping @MainActor () async -> Void,
        cancel: @escaping @MainActor () -> Void = {}
    ) async {
        guard !isDestructiveActionLocked else {
            // Besonders bei App-Terminierung muss jeder terminateLater-Aufruf
            // eine Antwort erhalten. Die neue, konkurrierende Anfrage wird
            // daher ausdrücklich abgebrochen statt still hängen zu bleiben.
            cancel()
            return
        }

        isPreparingDestructiveAction = true
        defer { isPreparingDestructiveAction = false }
        let targets = uniqueEntries(affectedEntries)
        await waitForSaves(in: targets)

        let dirty = targets.filter(\.isDirty)
        guard !dirty.isEmpty else {
            await perform()
            return
        }

        let conflict = PendingDirtyConflict(
            title: title,
            message: message,
            affectedEntryCount: dirty.count
        )
        let action = PendingAction(conflict: conflict, entries: targets,
                                   perform: perform, cancel: cancel)
        pendingAction = action
        pendingConflict = conflict
    }

    /// Beansprucht synchron genau eine sichtbare Entscheidung. Diese Methode
    /// wird direkt aus dem Button-Callback aufgerufen, noch bevor dessen
    /// `Task` geplant wird; der Dismiss-Callback kann sie danach nicht mehr
    /// durch `.cancel` ersetzen.
    @discardableResult
    func claimPendingConflict(_ decision: DirtyConflictDecision) -> Bool {
        guard pendingAction != nil, !isResolvingConflict else { return false }
        isResolvingConflict = true
        claimedConflictDecision = decision
        return true
    }

    /// Bequemer asynchroner Einstieg für nicht-visuelle Aufrufer und Tests.
    /// Die View benutzt stattdessen Claim + `resolveClaimedPendingConflict()`,
    /// damit sie die Entscheidung synchron sichern kann.
    func resolvePendingConflict(_ decision: DirtyConflictDecision) async {
        guard claimPendingConflict(decision) else { return }
        await resolveClaimedPendingConflict { entry in
            await self.save(entry: entry)
        }
    }

    /// Austauschbarer Schreibweg für Tests; der Produktionsweg oben verwendet
    /// exakt dieselbe Konfliktsteuerung und nur den echten Dateischreiber.
    func resolvePendingConflict(
        _ decision: DirtyConflictDecision,
        saveEntry: @escaping @MainActor (FileEntry) async -> Bool
    ) async {
        guard claimPendingConflict(decision) else { return }
        await resolveClaimedPendingConflict(saveEntry: saveEntry)
    }

    /// Führt ausschließlich die zuvor synchron beanspruchte Entscheidung aus.
    /// Ohne Claim bleibt der Konflikt unangetastet, damit ein versehentlicher
    /// zweiter Task keine fremde Auswahl übernehmen kann.
    func resolveClaimedPendingConflict() async {
        await resolveClaimedPendingConflict { entry in
            await self.save(entry: entry)
        }
    }

    /// Testbare Variante des geclaimten Ablaufs mit austauschbarem Schreiber.
    func resolveClaimedPendingConflict(
        saveEntry: @escaping @MainActor (FileEntry) async -> Bool
    ) async {
        guard let decision = claimedConflictDecision, var action = pendingAction else { return }
        defer {
            claimedConflictDecision = nil
            isResolvingConflict = false
        }

        switch decision {
        case .cancel:
            clearPendingAction()
            action.cancel()

        case .discard:
            // Nur die tatsächlich betroffenen Puffer verwerfen. Ein offener,
            // aber nicht importierter Editor bleibt bewusst unverändert.
            for entry in action.entries where entry.isDirty { entry.revert() }
            clearPendingAction()
            await action.perform()

        case .save:
            // Ein in der Zwischenzeit gestarteter Save muss vor dem eigenen
            // Batch enden. Danach speichern wir alle noch dirty Puffer erneut.
            await waitForSaves(in: action.entries)
            let succeeded = await saveEntries(
                action.entries.filter(\.isDirty), saveEntry: saveEntry
            )
            let stillDirty = action.entries.contains { $0.isDirty || $0.isSaving }
            guard succeeded, !stillDirty else {
                action.conflict.failureMessage = String(localized:
                    "Speichern fehlgeschlagen. Die Aktion wurde nicht ausgeführt.")
                pendingAction = action
                pendingConflict = action.conflict
                return
            }
            clearPendingAction()
            await action.perform()
        }
    }

    /// AppKit erhält seine konkrete Terminierungsantwort erst hier. Dadurch
    /// bleibt die Save/Discard/Cancel-Logik ohne Fenster und NSApplication
    /// ausführbar testbar.
    func requestTermination(
        reply: @escaping @MainActor (TerminationDecision) -> Void
    ) async {
        await requestDestructiveAction(
            title: String(localized: "Ungespeicherte Änderungen"),
            message: String(localized:
                "Vor dem Beenden müssen die Änderungen gespeichert oder verworfen werden."),
            entries: entries,
            perform: { reply(.terminateNow) },
            cancel: { reply(.terminateCancel) }
        )
    }

    /// Fenster-Schließen verwendet denselben Pfad wie Cmd-Q, antwortet aber
    /// über den vom NSWindowDelegate bereitgestellten Close-Bypass.
    func requestWindowClose(
        performClose: @escaping @MainActor () -> Void
    ) async {
        await requestDestructiveAction(
            title: String(localized: "Ungespeicherte Änderungen"),
            message: String(localized:
                "Vor dem Schließen des Fensters müssen die Änderungen gespeichert oder verworfen werden."),
            entries: entries,
            perform: performClose
        )
    }

    private func clearPendingAction() {
        pendingAction = nil
        pendingConflict = nil
    }

    /// Dedupliziert Klasseninstanzen, nicht URLs: Ein Eintrag kann während
    /// eines Imports noch denselben Pfad wie ein Symlink tragen, bleibt aber
    /// trotzdem nur ein Editor-Puffer.
    private func uniqueEntries(_ candidates: [FileEntry]) -> [FileEntry] {
        var seen: Set<ObjectIdentifier> = []
        return candidates.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func waitForSaves(in entries: [FileEntry]) async {
        for entry in uniqueEntries(entries) {
            await entry.waitUntilSaveFinished()
        }
    }

    // MARK: - Untertitel verschieben

    /// Verschiebt alle Cues einer Untertiteldatei um `seconds` und liest den
    /// Eintrag neu. Eigener Schreibweg neben `save`, weil sich dabei kein
    /// Feld des Puffers ändert: Stempelprüfung, Papierkorb-Sicherung und der
    /// atomare Austausch liegen im Core (`SubtitleFile.shift`).
    @discardableResult
    func shiftSubtitle(entry: FileEntry, seconds: Double) async -> Bool {
        guard entry.kind == .sidecar, !entry.isSaving, !entry.isDirty else { return false }
        let url = entry.url
        let stamp = entry.diskStamp
        let milliseconds = Int((seconds * 1000).rounded())
        guard milliseconds != 0 else { return false }
        entry.isSaving = true
        defer { entry.finishSaving() }
        do {
            let (loaded, newStamp) = try await Task.detached(priority: .userInitiated) {
                try FileStamp.requireUnchanged(stamp, at: url)
                try TrashBackup.shared.backUp(url)
                try SubtitleFile.shift(url: url, milliseconds: milliseconds, expecting: stamp)
                return try Self.readStamped(url: url, kind: .sidecar)
            }.value
            entry.acceptNew(loaded, stamp: newStamp)
            return true
        } catch {
            entry.lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Export/Import (JSON)

    /// Exportiert die Tags der Einträge als selbständige JSON-Datei.
    /// E-Rechnungen sind reine Anzeige und werden nicht mitgezählt — sonst
    /// entstünde ein Archiv, das weniger Dateien enthält als versprochen.
    func exportEntries(_ exportEntries: [FileEntry], to url: URL) async {
        let files = exportEntries
            .filter { MediaFormats.isArchivable(url: $0.url) }
            .map(\.url)
        guard !files.isEmpty else {
            alertMessage = String(localized:
                "Nichts zu exportieren: E-Rechnungen sind reine Anzeige und tragen keine editierbaren Tags.")
            return
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try TagArchiveIO.export(files: files, to: url, includeCovers: true)
            }.value
        } catch {
            alertMessage = String(localized: "Export fehlgeschlagen:") + "\n" + error.localizedDescription
        }
    }

    /// Wendet eine Export-/Backup-JSON auf die Platte an und lädt betroffene,
    /// bereits geöffnete Dateien neu.
    func importArchive(from url: URL) async {
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                let archive = try TagArchiveIO.load(url)
                let base = url.deletingLastPathComponent()
                let targets = try TagArchiveIO.validatedTargets(
                    archive, relativeTo: base, allowExternalTargets: true)
                let external = TagArchiveIO.externalTargets(targets, relativeTo: base)
                return (archive, base, targets, external)
            }.value
            // Die geprüfte Zielliste geht IMMER an `apply` — auch wenn kein
            // Ziel außerhalb des Archivordners liegt und deshalb kein
            // Freigabedialog nötig war. Genau diese Liste hat der Konflikt-
            // dialog verwendet, um betroffene offene Editoren zu bestimmen;
            // ein während des Dialogs umgebogener Symlink darf nicht auf eine
            // nie berücksichtigte Datei zeigen.
            let approvedTargets = prepared.2
            let allowExternal = !prepared.3.isEmpty
            await requestExternalApprovalOrScheduleImport(
                archive: prepared.0,
                relativeTo: prepared.1,
                targets: prepared.2,
                externalTargets: prepared.3
            ) { archive, base in
                try await Task.detached(priority: .userInitiated) {
                    try TagArchiveIO.apply(
                        archive, relativeTo: base, dryRun: false,
                        approvedTargets: approvedTargets,
                        allowExternalTargets: allowExternal)
                }.value
            }
        } catch {
            alertMessage = String(localized: "Import fehlgeschlagen:") + "\n" + error.localizedDescription
        }
    }

    /// Testbarer Import-Einstieg mit austauschbarem Schreiber. Die Archiv-
    /// Validierung und die Schnittmenge mit geöffneten Dateien bleiben dabei
    /// identisch zum echten JSON-Import.
    func importArchive(
        archive: TagArchive,
        relativeTo base: URL,
        apply: @escaping @Sendable (TagArchive, URL) async throws -> TagArchiveReport
    ) async {
        do {
            let targets = try await Task.detached(priority: .userInitiated) {
                try TagArchiveIO.validatedTargets(
                    archive, relativeTo: base, allowExternalTargets: true)
            }.value
            let external = TagArchiveIO.externalTargets(targets, relativeTo: base)
            await requestExternalApprovalOrScheduleImport(
                archive: archive, relativeTo: base, targets: targets,
                externalTargets: external, apply: apply)
        } catch {
            alertMessage = String(localized: "Import fehlgeschlagen:") + "\n" + error.localizedDescription
        }
    }

    private func requestExternalApprovalOrScheduleImport(
        archive: TagArchive,
        relativeTo base: URL,
        targets: [URL],
        externalTargets: [URL],
        apply: @escaping @Sendable (TagArchive, URL) async throws -> TagArchiveReport
    ) async {
        guard !isDestructiveActionLocked else { return }
        guard !externalTargets.isEmpty else {
            await scheduleImport(
                archive: archive, relativeTo: base, targets: targets, apply: apply)
            return
        }

        pendingExternalImport = PendingExternalImportApproval(
            targetPaths: targets.map(\.path),
            externalTargetCount: externalTargets.count)
        pendingExternalImportAction = PendingExternalImportAction(
            perform: { [weak self] in
                await self?.scheduleImport(
                    archive: archive, relativeTo: base,
                    targets: targets, apply: apply)
            })
    }

    /// Beansprucht Freigeben/Abbrechen synchron, damit Dialog-Button und
    /// Dismiss-Callback nicht zwei verschiedene Entscheidungen ausführen.
    @discardableResult
    func claimPendingExternalImport(approve: Bool) -> Bool {
        guard pendingExternalImportAction != nil,
              claimedExternalImportApproval == nil else { return false }
        claimedExternalImportApproval = approve
        return true
    }

    func resolveClaimedPendingExternalImport() async {
        guard let approve = claimedExternalImportApproval,
              let action = pendingExternalImportAction else { return }
        pendingExternalImport = nil
        pendingExternalImportAction = nil
        claimedExternalImportApproval = nil
        if approve { await action.perform() }
    }

    /// Der Archiv-Snapshot ist schon geladen und validiert, wird aber erst in
    /// der `perform`-Closure nach Save/Discard angewandt. Damit kann ein
    /// Konfliktdialog nie einen Teilimport vor der Entscheidung auslösen.
    private func scheduleImport(
        archive: TagArchive,
        relativeTo base: URL,
        targets: [URL],
        apply: @escaping @Sendable (TagArchive, URL) async throws -> TagArchiveReport
    ) async {
        let targetSet = Set(targets.map(MediaFormats.canonicalFileURL))
        let openedTargets = entries.filter {
            targetSet.contains(MediaFormats.canonicalFileURL($0.url))
        }
        // Feste Zuordnung Archiveintrag → geprüftes Ziel. `validatedTargets`
        // liefert die Ziele in der Reihenfolge der Archiveinträge, und deren
        // Pfade sind eindeutig (Archiv-Schemaprüfung).
        let targetsByArchivePath = Dictionary(
            uniqueKeysWithValues: zip(archive.files.map(\.path), targets))
        await requestDestructiveAction(
            title: String(localized: "Ungespeicherte Änderungen"),
            message: String(localized:
                "Vor dem Import müssen die Änderungen betroffener Dateien gespeichert oder verworfen werden."),
            entries: openedTargets,
            perform: { [weak self] in
                await self?.applyPreparedImport(
                    archive: archive, relativeTo: base,
                    targetsByArchivePath: targetsByArchivePath, apply: apply)
            }
        )
    }

    private func applyPreparedImport(
        archive: TagArchive,
        relativeTo base: URL,
        targetsByArchivePath: [String: URL],
        apply: @escaping @Sendable (TagArchive, URL) async throws -> TagArchiveReport
    ) async {
        do {
            let report = try await apply(archive, base)

            // Geänderte, geladene Einträge neu von der Platte lesen. Die Pfade
            // werden NICHT erneut aufgelöst: Ein nach der Prüfung umgebogener
            // Symlink zeigte sonst auf eine andere Datei, deren offener
            // Editor-Puffer beim Neuladen verlorenginge. `apply` schreibt
            // ausschließlich in die hier hinterlegten, freigegebenen Ziele.
            let changedPaths = Set(report.applied.compactMap {
                targetsByArchivePath[$0].map(MediaFormats.canonicalFileURL)
            })
            for entry in entries where changedPaths.contains(MediaFormats.canonicalFileURL(entry.url)) {
                await reload(entry: entry)
            }

            var summary = String(localized: "Import: \(report.applied.count) geändert, \(report.unchanged.count) unverändert")
            if !report.missing.isEmpty { summary += String(localized: ", \(report.missing.count) fehlend") }
            if !report.extra.isEmpty { summary += String(localized: ", \(report.extra.count) nicht im Archiv") }
            if !report.failed.isEmpty {
                summary += "\n" + String(localized: "Fehlgeschlagen:") + "\n" + report.failed
                    .map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            }
            alertMessage = summary
        } catch {
            alertMessage = String(localized: "Import fehlgeschlagen:") + "\n" + error.localizedDescription
        }
    }

    /// Entfernt eine Tag-Schicht (z.B. ID3v1) aus der Datei und liest sie neu.
    ///
    /// Läuft nur auf einer sauberen Datei: Der Bearbeitungspuffer würde nach
    /// dem Neuladen sonst still durch den Plattenstand ersetzt. Die View
    /// sperrt den Knopf deshalb bei ungespeicherten Änderungen; hier wird das
    /// trotzdem geprüft. Während des Entfernens gilt die Datei als „speichert"
    /// — derselbe Schutz wie beim Speichern gegen parallele Schreibzugriffe.
    @discardableResult
    func stripLayer(entry: FileEntry, kind: TagLayerKind) async -> Bool {
        guard !entry.isDirty, !entry.isSaving, !isDestructiveActionLocked else { return false }
        entry.isSaving = true
        defer { entry.finishSaving() }
        let url = entry.url
        let stamp = entry.diskStamp
        do {
            let (reloaded, newStamp) = try await Task.detached(priority: .userInitiated) {
                // Fremde Änderung seit dem Öffnen? Dann nicht anfassen.
                try FileStamp.requireUnchanged(stamp, at: url)
                try TrashBackup.shared.backUp(url)
                try TagFile.stripLayers([kind], from: url, expecting: stamp)
                return try Self.readStamped(url: url, kind: .audio)
            }.value
            entry.acceptNew(reloaded, stamp: newStamp)
            return true
        } catch {
            entry.lastError = error.localizedDescription
            alertMessage = String(localized: "Schicht entfernen fehlgeschlagen: \(entry.url.lastPathComponent)")
                + "\n" + error.localizedDescription
            return false
        }
    }

    /// Liest eine Datei neu von der Platte und ersetzt den Originalzustand.
    private func reload(entry: FileEntry) async {
        let url = entry.url
        let kind = entry.kind
        do {
            let (loaded, stamp) = try await Task.detached(priority: .userInitiated) {
                try Self.readStamped(url: url, kind: kind)
            }.value
            entry.acceptNew(loaded, stamp: stamp)
        } catch {
            entry.lastError = error.localizedDescription
        }
    }

    /// Schreibt den Bearbeitungspuffer einer Datei und liest sie neu ein.
    ///
    /// `ignoringDiskChange` überspringt die Prüfung auf fremde Änderungen —
    /// nur nach ausdrücklicher Bestätigung. Die Sicherungskopie im Papierkorb
    /// enthält dann den fremden Stand, das Überschreiben bleibt also umkehrbar.
    @discardableResult
    func save(entry: FileEntry, ignoringDiskChange: Bool = false) async -> Bool {
        let url = entry.url
        let kind = entry.kind
        let stamp = ignoringDiskChange ? nil : entry.diskStamp
        return await save(entry: entry, staleCandidate: ignoringDiskChange ? nil : entry) { snapshot in
            return try await Task.detached(priority: .userInitiated) {
                try Self.write(snapshot: snapshot, to: url, kind: kind, expecting: stamp)
            }.value
        }
    }

    /// Eine Datei wurde außerhalb der App verändert; das Speichern wartet auf
    /// die Entscheidung der Person.
    struct PendingStaleWrite: Equatable {
        var fileName: String
    }

    private(set) var pendingStaleWrite: PendingStaleWrite?
    /// Wartende Konflikte in Reihenfolge ihres Auftretens. Ein Batch kann
    /// mehrere Dateien mit fremden Änderungen enthalten — jede bekommt ihre
    /// eigene Frage. Ein einzelner Merker würde beim zweiten Konflikt den
    /// ersten überschreiben: Der Dialog gehörte dann zur falschen Datei.
    private var staleEntries: [FileEntry] = []
    /// Der synchron beanspruchte Konflikt: Eintrag plus Entscheidung
    /// (true = trotzdem speichern). Solange ein Claim besteht, ist der Eintrag
    /// schon aus `staleEntries` heraus — ein zusätzlicher Dismiss findet ihn
    /// dort nicht mehr und kann weder ihn noch den nächsten Eintrag abbrechen.
    private var claimedStaleWrite: (entry: FileEntry, write: Bool)?

    /// Beansprucht synchron genau den gerade angezeigten Konflikt. Der Aufruf
    /// steht direkt im Button-Callback, noch bevor dessen `Task` läuft; der
    /// unmittelbar danach folgende Dismiss-Callback trifft auf einen bereits
    /// vergebenen Claim und lässt die Warteschlange in Ruhe.
    @discardableResult
    func claimStaleWrite(write: Bool) -> Bool {
        guard claimedStaleWrite == nil, !staleEntries.isEmpty else { return false }
        claimedStaleWrite = (staleEntries.removeFirst(), write)
        // Erst nach der Entscheidung den nächsten Konflikt anzeigen, sonst
        // stünde der Dialog schon während des laufenden Schreibvorgangs da.
        pendingStaleWrite = nil
        return true
    }

    /// Führt ausschließlich den zuvor beanspruchten Konflikt aus.
    func resolveClaimedStaleWrite() async {
        await resolveClaimedStaleWrite { entry in
            await self.save(entry: entry, ignoringDiskChange: true)
        }
    }

    /// Testbare Variante mit austauschbarem Schreiber; die Warteschlangen-
    /// Logik ist identisch zum Produktionsweg oben.
    func resolveClaimedStaleWrite(saveEntry: @MainActor (FileEntry) async -> Bool) async {
        guard let claim = claimedStaleWrite else { return }
        claimedStaleWrite = nil
        if claim.write { _ = await saveEntry(claim.entry) }
        refreshPendingStaleWrite()
    }

    /// Trotzdem speichern — der bisherige Plattenstand liegt im Papierkorb.
    /// Bequemer Einstieg für nicht-visuelle Aufrufer und Tests; die View
    /// benutzt Claim + `resolveClaimedStaleWrite()`, damit sie die Entscheidung
    /// synchron sichern kann.
    func confirmStaleWrite() async {
        guard claimStaleWrite(write: true) else { return }
        await resolveClaimedStaleWrite()
    }

    /// Testbare Variante mit austauschbarem Schreiber.
    func confirmStaleWrite(saveEntry: @MainActor (FileEntry) async -> Bool) async {
        guard claimStaleWrite(write: true) else { return }
        await resolveClaimedStaleWrite(saveEntry: saveEntry)
    }

    /// Verwirft nur die aktuell angezeigte Frage; weitere wartende Konflikte
    /// bekommen danach ihre eigene Entscheidung.
    func cancelStaleWrite() {
        guard claimStaleWrite(write: false) else { return }
        claimedStaleWrite = nil
        refreshPendingStaleWrite()
    }

    private func refreshPendingStaleWrite() {
        pendingStaleWrite = staleEntries.first
            .map { PendingStaleWrite(fileName: $0.url.lastPathComponent) }
    }

    /// Gemeinsame Save-Steuerung. Der austauschbare Schreibblock ermöglicht
    /// einen headless Regressionstest, der einen laufenden Save exakt anhalten
    /// kann, ohne echte UI- oder Dateitiming-Rennen zu brauchen.
    @discardableResult
    func save(entry: FileEntry,
              staleCandidate: FileEntry? = nil,
              writeSnapshot: @escaping @Sendable (FileEntry.SaveSnapshot) async throws -> (LoadedData, FileStamp?)) async -> Bool {
        guard let snapshot = entry.beginSaving() else { return !entry.isDirty }
        defer { entry.finishSaving() }

        do {
            let (reloaded, stamp) = try await writeSnapshot(snapshot)
            entry.acceptSaved(snapshot, reloaded: reloaded, stamp: stamp)
            return true
        } catch TagError.fileChangedOnDisk(let path) where staleCandidate != nil {
            // Kein normaler Fehler, sondern eine Entscheidung: überschreiben
            // oder nicht. Der Puffer bleibt in jedem Fall erhalten.
            entry.lastError = TagError.fileChangedOnDisk(path: path).localizedDescription
            if let staleCandidate,
               !staleEntries.contains(where: { $0 === staleCandidate }) {
                staleEntries.append(staleCandidate)
            }
            if pendingStaleWrite == nil { refreshPendingStaleWrite() }
            return false
        } catch {
            // Der Puffer und das letzte gute Original bleiben unverändert.
            entry.lastError = error.localizedDescription
            alertMessage = String(localized: "Speichern fehlgeschlagen: \(entry.url.lastPathComponent)")
                + "\n" + error.localizedDescription
            return false
        }
    }

    /// Der eigentliche Hintergrundzugriff bekommt ausschließlich den Snapshot.
    /// Damit kann ein UI-Edit während await nicht in diesen Schreibvorgang rutschen.
    nonisolated private static func write(snapshot: FileEntry.SaveSnapshot,
                                          to url: URL, kind: MediaKind,
                                          expecting stamp: FileStamp?) throws -> (LoadedData, FileStamp?) {
        // Hat ein anderes Programm die Datei seit dem Öffnen geändert, wäre das
        // Speichern ein stilles Überschreiben fremder Arbeit. Diese frühe
        // Prüfung bricht vor Backup und Kopie ab; der Stempel wandert
        // zusätzlich bis in den atomaren Austausch (expecting:) und wird dort
        // unmittelbar vor dem rename ein letztes Mal geprüft.
        try FileStamp.requireUnchanged(stamp, at: url)
        // Unbrauchbare Eingaben schon vor der Sicherung ablehnen: Der
        // Schreibweg würde ein Nicht-Bild sonst als angebliches Cover in die
        // Datei legen, und ein Serienindex ohne Serie scheiterte erst NACH
        // der Papierkorb-Kopie — jeder solche Versuch legte eine unnötige
        // Sicherung der unveränderten Datei an.
        if case .image(let fields, let original, _) = snapshot {
            try ExifTool.requireValidCoreFields(fields, original: original)
        }
        if case .ebook(let fields, let original, let cover) = snapshot {
            try EbookTool.requireStorableSeries(fields, original: original, url: url)
            if let cover { try EbookTool.requireSupportedCover(cover, for: url) }
        }
        if case .document(let fields, let original) = snapshot {
            try DocumentTool.requireWritable(fields, original: original, url: url)
        }
        if case .sidecar(let fields, let original) = snapshot {
            try SidecarTool.requireWritable(fields, original: original, url: url)
        }
        if case .playlist(let fields, let original) = snapshot {
            try PlaylistTool.requireWritable(fields, original: original, url: url)
        }
        // Bilder: Kamera-RAW, Formate ohne exiftool-Schreibweg, eine schon
        // vorhandene Sidecar und die Einstellung lenken die Änderung in die
        // XMP-Sidecar `<name>.xmp`. Gesichert wird dann DIESE Datei; eine
        // noch fehlende Sidecar hat nichts zu sichern (backUp überspringt sie).
        let imageDestination: ImageWriteDestination? = kind == .image
            ? ExifTool.writeDestination(for: url, preferSidecar: imageSidecarPreferred)
            : nil
        // Abgesicherter Modus: erst die unveränderte Kopie in den Papierkorb,
        // dann schreiben. Scheitert die Sicherung, wird bewusst nicht geschrieben.
        try TrashBackup.shared.backUp(imageDestination?.url ?? url)
        switch (kind, snapshot) {
        case (.audio, .audio(let properties, let artworks, let chapters)):
            try TagFile.write(properties: properties, artworks: artworks, chapters: chapters,
                              to: url, expecting: stamp, id3Version: preferredID3Version)
        case (.image, .image(let fields, let original, let sidecar)):
            try ExifTool.writeCoreFields(url: url, fields: fields, original: original,
                                         expecting: stamp, to: imageDestination,
                                         sidecar: sidecar)
        case (.ebook, .ebook(let fields, let original, let cover)):
            try EbookTool.write(
                url: url, fields: fields, original: original,
                coverUpdate: cover.map(EbookCoverUpdate.set) ?? .unchanged,
                expecting: stamp)
        case (.document, .document(let fields, let original)):
            try DocumentTool.write(url: url, fields: fields, original: original,
                                   expecting: stamp)
        case (.sidecar, .sidecar(let fields, let original)):
            try SidecarTool.write(url: url, fields: fields, original: original, expecting: stamp)
        case (.playlist, .playlist(let fields, let original)):
            try PlaylistTool.write(url: url, fields: fields, original: original,
                                   expecting: stamp)
        default:
            throw TagError.saveFailed(path: url.path)
        }
        return try readStamped(url: url, kind: kind)
    }

    // MARK: - Liste verwalten

    /// Entfernen heißt nur „aus der Liste entfernen“, kann aber einen dirty
    /// Editor ohne sichtbare Rückfrage verschwinden lassen. Deshalb läuft es
    /// durch dieselbe zentrale Save/Discard/Cancel-Steuerung wie Import und
    /// Fenster-Schließen.
    func remove(urls: [URL]) async {
        let targets = Set(urls.map(MediaFormats.canonicalFileURL))
        let affected = entries.filter {
            targets.contains(MediaFormats.canonicalFileURL($0.url))
        }
        await requestDestructiveAction(
            title: String(localized: "Ungespeicherte Änderungen"),
            message: String(localized:
                "Vor dem Entfernen müssen die Änderungen gespeichert oder verworfen werden."),
            entries: affected,
            perform: { [weak self] in self?.removeNow(urls: targets) }
        )
    }

    private func removeNow(urls: Set<URL>) {
        entries.removeAll { urls.contains(MediaFormats.canonicalFileURL($0.url)) }
        selection = Set(selection.filter {
            !urls.contains(MediaFormats.canonicalFileURL($0))
        })
        if selection.isEmpty, let first = entries.first { selection = [first.url] }
    }
}
