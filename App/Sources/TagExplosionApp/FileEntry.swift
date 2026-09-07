// Originalzustand, Bearbeitungspuffer und sichere Speicher-Snapshots je Datei.
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
    /// Sprache der Lyrics (ISO 639-2; nur ID3v2 speichert sie) und
    /// synchronisierte Zeilen — aus SYLT (ID3v2) oder, bei anderen Formaten,
    /// aus der Sidecar `<name>.lrc` neben der Datei (siehe `readLoaded`).
    var lyricsLanguage: String = ""
    var syncedLyrics: [SyncedLyricLine] = []
    /// Sidecars eines Audio-/Video-Eintrags laut letztem Lesestand: Stempel
    /// der `<name>.lrc` und die Kodi-NFO neben einem Video. Beide gehören
    /// zur Konfliktprüfung beim Speichern — sonst überschriebe die App eine
    /// zwischenzeitlich fremd geänderte Sidecar ohne Rückfrage.
    private(set) var audioSidecars = AudioSidecars()
    /// Original und Bearbeitungspuffer der NFO neben einem Video. Sie zählen
    /// zu `isDirty`, damit Schließen/Beenden auch NFO-Eingaben nicht still
    /// verwerfen; gespeichert werden sie mit dem Eintrag (nur in die NFO).
    private(set) var videoNFOOriginal = NFOFields()
    var videoNFOFields = NFOFields()

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
        case audio(AudioSnapshot)
        /// `sidecar`: Sidecar-Zustand aus dem Lesevorgang — damit erkennt der
        /// Schreibweg eine inzwischen fremd angelegte oder geänderte Sidecar.
        case image(fields: ImageCoreFields, original: ImageCoreFields, sidecar: SidecarState)
        case ebook(fields: EbookCoreFields, original: EbookCoreFields, cover: Data?)
        case document(fields: DocumentCoreFields, original: DocumentCoreFields)
        case sidecar(fields: SidecarFields, original: SidecarFields)
        case playlist(fields: PlaylistCoreFields, original: PlaylistCoreFields)
    }

    /// Audio-Stand zu Beginn eines Speichervorgangs. `original` ist der
    /// zuletzt gelesene Dateizustand: Gegen ihn werden die festen Felder vor
    /// der Sicherung geprüft, und er entscheidet, ob die Mediendatei
    /// überhaupt angefasst werden muss (eine Änderung nur an der LRC-Sidecar
    /// schreibt das Medium nicht neu).
    struct AudioSnapshot: Sendable {
        var properties: [TagProperty]
        var artworks: [Artwork]
        /// nil, wenn das Format keine Kapitel kennt — dann fasst der
        /// Schreibweg die Kapitel gar nicht an.
        var chapters: [Chapter]?
        /// nil = unverändert. Bei ID3v2-Trägern landen die Zeilen als SYLT
        /// in der Datei, sonst in der Sidecar `<name>.lrc`.
        var syncedLyrics: [SyncedLyricLine]?
        /// nil = unverändert (nur ID3v2 speichert eine Sprache).
        var lyricsLanguage: String?
        var original: TagData
        /// Zustand der `<name>.lrc` beim Lesen (auch ihre Abwesenheit). Der
        /// Schreibweg prüft ihn unmittelbar vor dem Austausch der Sidecar.
        var lrcState: SidecarState = .absent
        /// Geänderte Felder der NFO neben einem Video samt Lesestand;
        /// nil = NFO unverändert oder keine vorhanden.
        var nfo: NFOSnapshot? = nil

        /// Geänderte Lyrics außerhalb des Containers; ID3v2 speichert sie eingebettet.
        var sidecarLyrics: [SyncedLyricLine]? {
            original.supportsSyncedLyrics ? nil : syncedLyrics
        }

        /// Ob in der Mediendatei selbst etwas zu schreiben ist. Sidecars
        /// (LRC bei Formaten ohne SYLT, NFO) zählen nicht dazu.
        var mediaChanged: Bool {
            properties != original.properties || artworks != original.artworks
                || (chapters != nil && chapters != original.chapters)
                || (original.supportsSyncedLyrics && syncedLyrics != nil)
                || lyricsLanguage != nil
        }

        /// Dieselbe Momentaufnahme ohne Sidecar-Stempel — für das bewusste
        /// Überschreiben nach dem Konfliktdialog (wie `expecting: nil` beim
        /// Medium). Ohne das liefe die Person in denselben Konflikt erneut.
        func ignoringSidecarStamps() -> AudioSnapshot {
            var copy = self
            copy.lrcState = .unknown
            copy.nfo?.stamp = nil
            return copy
        }
    }

    /// NFO-Stand zu Beginn eines Speichervorgangs (siehe `AudioSnapshot.nfo`).
    struct NFOSnapshot: Sendable {
        var url: URL
        var fields: NFOFields
        var original: NFOFields
        var stamp: FileStamp?
    }

    /// `stamp` gehört zum gelesenen `loaded`-Zustand (konsistenter
    /// Schnappschuss aus `AppModel.readStamped`). Beides zusammen ist die
    /// Vergleichsbasis für die Konfliktprüfung beim Speichern.
    init(url: URL, loaded: LoadedData, stamp: FileStamp?) {
        self.url = url
        self.kind = switch loaded {
        case .audio: .audio
        case .image: .image
        case .ebook: .ebook
        case .invoice: .invoice
        case .document: .document
        case .sidecar: .sidecar
        case .playlist: .playlist
        }
        // Initiales Öffnen und späteres Neuladen pflegen dieselben Felder.
        acceptNew(loaded, stamp: stamp)
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
        // Die NFO ist mit dem Video umbenannt worden: neuer Pfad, gleicher Inhalt.
        if let sidecar, case .audio(let data, var sidecars) = loaded, sidecars.nfo != nil,
           sidecar.pathExtension.lowercased() == SidecarTool.nfoExtension {
            sidecars.nfo?.url = sidecar
            loaded = .audio(data, sidecars: sidecars)
        }
        self.init(url: url, loaded: loaded, stamp: other.diskStamp)
        properties = other.properties
        artworks = other.artworks
        chapters = other.chapters
        syncedLyrics = other.syncedLyrics
        lyricsLanguage = other.lyricsLanguage
        videoNFOFields = other.videoNFOFields
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
        case .audio: return .audio(original, sidecars: audioSidecars)
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
    /// ID3v2-Träger (MP3/MP2, WAV, AIFF, DSF) speichern SYLT und die Sprache
    /// der Lyrics in der Datei; alle anderen Audio-Formate nutzen für
    /// synchronisierte Lyrics die Sidecar `<name>.lrc`.
    var supportsSyncedLyrics: Bool { kind == .audio && original.supportsSyncedLyrics }
    /// Tag-Schichten (ID3v1/ID3v2/APE …) laut letztem Lesestand; leer bei
    /// Formaten ohne Schichtenmodell — nur dann fehlt der Abschnitt im Editor.
    /// Kein Bearbeitungspuffer: Entfernen läuft direkt über
    /// `AppModel.stripLayer` und liest die Datei danach neu.
    var layers: [TagLayer] { kind == .audio ? original.layers : [] }

    var isDirty: Bool {
        switch kind {
        case .audio:
            return properties != original.properties || artworks != original.artworks
                || chapters != original.chapters || syncedLyrics != original.syncedLyrics
                || lyricsLanguage != original.lyricsLanguage
                || videoNFOFields != videoNFOOriginal
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
        syncedLyrics = original.syncedLyrics
        lyricsLanguage = original.lyricsLanguage
        videoNFOFields = videoNFOOriginal
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
    func acceptNewOriginal(_ data: TagData, sidecars: AudioSidecars = AudioSidecars()) {
        original = data
        properties = data.properties
        artworks = data.artworks
        chapters = data.chapters
        syncedLyrics = data.syncedLyrics
        lyricsLanguage = data.lyricsLanguage
        audioSidecars = sidecars
        videoNFOOriginal = sidecars.nfoFields
        videoNFOFields = sidecars.nfoFields
        lastError = nil
    }

    /// NFO neben dem Video laut letztem Lesestand (nil = keine).
    var videoNFO: NFOSidecarReading? { audioSidecars.nfo }

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
        case .audio(let data, let sidecars): acceptNewOriginal(data, sidecars: sidecars)
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
            return .audio(AudioSnapshot(
                properties: properties, artworks: artworks,
                chapters: supportsChapters ? chapters : nil,
                syncedLyrics: syncedLyrics != original.syncedLyrics ? syncedLyrics : nil,
                lyricsLanguage: lyricsLanguage != original.lyricsLanguage ? lyricsLanguage : nil,
                original: original,
                lrcState: audioSidecars.lrcState,
                nfo: videoNFOFields != videoNFOOriginal
                    ? audioSidecars.nfo.map {
                        NFOSnapshot(url: $0.url, fields: videoNFOFields,
                                    original: videoNFOOriginal, stamp: $0.stamp)
                    }
                    : nil))
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
        case (.audio(let saved), .audio(let data, let sidecars)):
            // nil im Schreibauftrag bedeutet unverändert. Verglichen wird
            // deshalb mit dem damaligen Original, bevor das Read-back es ersetzt.
            // Auch erstmals während des Speicherns eingegebene Werte bleiben so erhalten.
            let savedNFOFields = saved.nfo?.fields ?? videoNFOOriginal
            original = data
            audioSidecars = sidecars
            videoNFOOriginal = sidecars.nfoFields
            if videoNFOFields == savedNFOFields { videoNFOFields = sidecars.nfoFields }
            if properties == saved.properties { properties = data.properties }
            if artworks == saved.artworks { artworks = data.artworks }
            if chapters == (saved.chapters ?? saved.original.chapters) { chapters = data.chapters }
            if syncedLyrics == (saved.syncedLyrics ?? saved.original.syncedLyrics) {
                syncedLyrics = data.syncedLyrics
            }
            if lyricsLanguage == (saved.lyricsLanguage ?? saved.original.lyricsLanguage) {
                lyricsLanguage = data.lyricsLanguage
            }
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

