// Originalzustand, Bearbeitungspuffer und sichere Speicher-Snapshots je Datei.
import Foundation
import EInvoiceCore
#if !os(Linux)
import Observation
#endif
import TagExplosionCore

// Endungs-Sets kommen zentral aus dem Core (MediaFormats), damit App, CLI
// und Export/Import dieselbe Dateierkennung nutzen.
public let audioExtensions = MediaFormats.audio
public let imageExtensions = MediaFormats.image
public let videoExtensions = MediaFormats.video
public let ebookExtensions = MediaFormats.ebook
public let documentExtensions = MediaFormats.document
public let playlistExtensions = MediaFormats.playlist

/// Art der geladenen Datei — bestimmt Editor und Speicherweg. Direkt der
/// Core-Typ (auch das Archiv nutzt ihn); die Zuordnung inklusive des
/// Video→audio-Wegs liegt zentral in MediaFormats.
public typealias MediaKind = MediaFormats.Kind

extension MediaFormats.Kind {
    public static func forURL(_ url: URL) -> MediaKind? { MediaFormats.kind(of: url) }
}

/// Eine geladene Datei mit Original-Zustand und Bearbeitungspuffer.
#if !os(Linux)
@Observable
#endif
@MainActor
public final class FileEntry: Identifiable {
    public nonisolated let url: URL
    public nonisolated let kind: MediaKind
    public nonisolated var id: URL { url }

    private struct AudioState {
        var original: TagData
        var sidecars: AudioSidecars
        var properties: [TagProperty]
        var artworks: [Artwork]
        var chapters: [Chapter]
        var syncedLyrics: [SyncedLyricLine]
        var lyricsLanguage: String
        var videoNFOFields: NFOFields
        var fixedFieldDrafts: [String: String] = [:]
        var lyricsLanguageDraft: String?

        init(_ original: TagData, sidecars: AudioSidecars) {
            self.original = original
            self.sidecars = sidecars
            properties = original.properties
            artworks = original.artworks
            chapters = original.chapters
            syncedLyrics = original.syncedLyrics
            lyricsLanguage = original.lyricsLanguage
            videoNFOFields = sidecars.nfoFields
        }

        var isDirty: Bool {
            !fixedFieldDrafts.isEmpty || lyricsLanguageDraft != nil
                || properties != original.properties || artworks != original.artworks
                || chapters != original.chapters || syncedLyrics != original.syncedLyrics
                || lyricsLanguage != original.lyricsLanguage || videoNFOFields != sidecars.nfoFields
        }

        var snapshot: AudioSnapshot {
            AudioSnapshot(
                properties: properties, artworks: artworks,
                chapters: original.supportsChapters && chapters != original.chapters ? chapters : nil,
                syncedLyrics: syncedLyrics != original.syncedLyrics ? syncedLyrics : nil,
                lyricsLanguage: lyricsLanguage != original.lyricsLanguage ? lyricsLanguage : nil,
                original: original,
                lrcState: sidecars.lrcState,
                nfo: videoNFOFields != sidecars.nfoFields
                    ? sidecars.nfo.map {
                        NFOSnapshot(url: $0.url, fields: videoNFOFields,
                                    original: sidecars.nfoFields, stamp: $0.stamp)
                    }
                    : nil)
        }

        mutating func acceptSaved(_ saved: AudioSnapshot, data: TagData, sidecars: AudioSidecars) {
            // nil im Auftrag bedeutet unverändert. Der Vergleich braucht
            // deshalb das damalige Original, bevor das Read-back es ersetzt.
            let savedNFOFields = saved.nfo?.fields ?? self.sidecars.nfoFields
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
            original = data
            self.sidecars = sidecars
        }
    }

    private struct EbookState {
        var original: EbookCoreFields
        var originalCover: Data?
        var fields: EbookCoreFields
        var coverReplacement: Data?

        init(_ original: EbookCoreFields, cover: Data?) {
            self.original = original
            originalCover = cover
            fields = original
        }
    }

    private struct DocumentState {
        var original: DocumentCoreFields
        var cover: Data?
        var info: [DocumentInfoItem]
        var fields: DocumentCoreFields

        init(_ original: DocumentCoreFields, cover: Data?, info: [DocumentInfoItem]) {
            self.original = original
            self.cover = cover
            self.info = info
            fields = original
        }
    }

    private enum EntryState {
        case audio(AudioState)
        case image(ImageCoreReading, fields: ImageCoreFields)
        case ebook(EbookState)
        case invoice(EInvoiceDocument)
        case document(DocumentState)
        case nfo(NFOContents, fields: NFOFields)
        case subtitle(SubtitleContents, fields: SubtitleEditableFields)
        case playlist(PlaylistContents, fields: PlaylistCoreFields)

        init(_ loaded: LoadedData) {
            switch loaded {
            case .audio(let data, let sidecars): self = .audio(AudioState(data, sidecars: sidecars))
            case .image(let reading): self = .image(reading, fields: reading.fields)
            case .ebook(let fields, let cover): self = .ebook(EbookState(fields, cover: cover))
            case .invoice(let document): self = .invoice(document)
            case .document(let fields, let cover, let info):
                self = .document(DocumentState(fields, cover: cover, info: info))
            case .sidecar(.nfo(let contents)): self = .nfo(contents, fields: contents.fields)
            case .sidecar(.subtitle(let contents)): self = .subtitle(contents, fields: contents.fields)
            case .playlist(let contents): self = .playlist(contents, fields: contents.fields)
            }
        }

        var kind: MediaKind {
            switch self {
            case .audio: .audio
            case .image: .image
            case .ebook: .ebook
            case .invoice: .invoice
            case .document: .document
            case .nfo, .subtitle: .sidecar
            case .playlist: .playlist
            }
        }

        var loaded: LoadedData {
            switch self {
            case .audio(let audio): .audio(audio.original, sidecars: audio.sidecars)
            case .image(let reading, _): .image(reading)
            case .ebook(let ebook): .ebook(ebook.original, cover: ebook.originalCover)
            case .invoice(let document): .invoice(document)
            case .document(let document): .document(document.original, cover: document.cover, info: document.info)
            case .nfo(let contents, _): .sidecar(.nfo(contents))
            case .subtitle(let contents, _): .sidecar(.subtitle(contents))
            case .playlist(let contents, _): .playlist(contents)
            }
        }
    }

    private var state: (payload: EntryState, stamp: FileStamp?)

    /// Stand der zuletzt gelesenen Dateiversion für die Konfliktprüfung.
    public var diskStamp: FileStamp? { state.stamp }

    // Die öffentlichen Zugriffe bleiben als Bindings verwendbar. Ein
    // inaktiver Editor liest weiterhin Neutralwerte und hält keinen Puffer.
    private var audioState: AudioState? {
        get { if case .audio(let audio) = state.payload { audio } else { nil } }
        set { if let newValue { state.payload = .audio(newValue) } }
    }

    public var original: TagData { audioState?.original ?? TagData(properties: [], artworks: [], audio: nil) }
    public var audioSidecars: AudioSidecars { audioState?.sidecars ?? AudioSidecars() }

    public var properties: [TagProperty] {
        get { audioState?.properties ?? [] }
        set { audioState?.properties = newValue }
    }

    public var artworks: [Artwork] {
        get { audioState?.artworks ?? [] }
        set { audioState?.artworks = newValue }
    }

    private var frontCoverIndex: Int? {
        artworks.firstIndex { $0.pictureType == "Front Cover" }
            ?? artworks.firstIndex { $0.pictureType.isEmpty }
    }

    // Ein ausdrücklich typisiertes Frontcover hat Vorrang. Untypisierte
    // Bestandsbilder behalten die bisherige Cover-Bedienung; Booklets nicht.
    public var frontCover: Artwork? { frontCoverIndex.map { artworks[$0] } }

    public func setFrontCover(_ artwork: Artwork) {
        if let index = frontCoverIndex {
            artworks[index] = artwork
        } else {
            artworks.insert(artwork, at: 0)
        }
    }

    public func removeFrontCover() {
        if let index = frontCoverIndex { artworks.remove(at: index) }
    }

    /// Kapitel stehen nur bei Formaten mit Kapitelunterstützung bereit.
    public var chapters: [Chapter] {
        get { audioState?.chapters ?? [] }
        set { audioState?.chapters = newValue }
    }

    /// ID3v2 speichert Sprache und synchronisierte Zeilen in der Datei.
    /// Andere Audio-Formate lesen und schreiben die Zeilen über die LRC-Sidecar.
    public var lyricsLanguage: String {
        get { audioState?.lyricsLanguage ?? "" }
        set { audioState?.lyricsLanguage = newValue }
    }

    public var syncedLyrics: [SyncedLyricLine] {
        get { audioState?.syncedLyrics ?? [] }
        set { audioState?.syncedLyrics = newValue }
    }

    public var videoNFOOriginal: NFOFields { audioSidecars.nfoFields }
    public var videoNFOFields: NFOFields {
        get { audioState?.videoNFOFields ?? NFOFields() }
        set { audioState?.videoNFOFields = newValue }
    }

    public var fixedFieldDrafts: [String: String] {
        get { audioState?.fixedFieldDrafts ?? [:] }
        set { audioState?.fixedFieldDrafts = newValue }
    }

    public var lyricsLanguageDraft: String? {
        get { audioState?.lyricsLanguageDraft }
        set { audioState?.lyricsLanguageDraft = newValue }
    }

    /// Der Lesestand enthält auch die Herkunft und den Stempel der
    /// XMP-Felder, die den eingebetteten Bilddaten überlagert wurden.
    public var imageReading: ImageCoreReading {
        if case .image(let reading, _) = state.payload { reading } else { ImageCoreReading(fields: ImageCoreFields()) }
    }

    public var imageOriginal: ImageCoreFields { imageReading.fields }
    public var imageFields: ImageCoreFields {
        get { if case .image(_, let fields) = state.payload { fields } else { ImageCoreFields() } }
        set {
            guard case .image(let reading, _) = state.payload else { return }
            state.payload = .image(reading, fields: newValue)
        }
    }

    private var ebookState: EbookState? {
        get { if case .ebook(let ebook) = state.payload { ebook } else { nil } }
        set { if let newValue { state.payload = .ebook(newValue) } }
    }

    public var ebookOriginal: EbookCoreFields { ebookState?.original ?? EbookCoreFields() }
    public var ebookFields: EbookCoreFields {
        get { ebookState?.fields ?? EbookCoreFields() }
        set { ebookState?.fields = newValue }
    }
    public var ebookOriginalCover: Data? { ebookState?.originalCover }
    /// nil = unverändert. `setEbookCover(_:)` gleicht die Auswahl mit dem Original ab.
    public var ebookCoverReplacement: Data? { ebookState?.coverReplacement }

    public var invoiceDocument: EInvoiceDocument? {
        if case .invoice(let document) = state.payload { document } else { nil }
    }

    private var documentState: DocumentState? {
        get { if case .document(let document) = state.payload { document } else { nil } }
        set { if let newValue { state.payload = .document(newValue) } }
    }

    public var documentOriginal: DocumentCoreFields { documentState?.original ?? DocumentCoreFields() }
    public var documentFields: DocumentCoreFields {
        get { documentState?.fields ?? DocumentCoreFields() }
        set { documentState?.fields = newValue }
    }
    /// CBZ: erste Seite als Cover, nur zur Anzeige.
    public var documentCover: Data? { documentState?.cover }
    public var documentInfo: [DocumentInfoItem] { documentState?.info ?? [] }

    public var sidecarContents: SidecarContents? {
        switch state.payload {
        case .nfo(let contents, _): .nfo(contents)
        case .subtitle(let contents, _): .subtitle(contents)
        default: nil
        }
    }

    public var nfoOriginal: NFOFields {
        if case .nfo(let contents, _) = state.payload { contents.fields } else { NFOFields() }
    }
    public var nfoFields: NFOFields {
        get { if case .nfo(_, let fields) = state.payload { fields } else { NFOFields() } }
        set {
            guard case .nfo(let contents, _) = state.payload else { return }
            state.payload = .nfo(contents, fields: newValue)
        }
    }

    public var subtitleOriginal: SubtitleEditableFields {
        if case .subtitle(let contents, _) = state.payload { contents.fields } else { SubtitleEditableFields() }
    }
    public var subtitleFields: SubtitleEditableFields {
        get { if case .subtitle(_, let fields) = state.payload { fields } else { SubtitleEditableFields() } }
        set {
            guard case .subtitle(let contents, _) = state.payload else { return }
            state.payload = .subtitle(contents, fields: newValue)
        }
    }

    public var playlistContents: PlaylistContents {
        if case .playlist(let contents, _) = state.payload {
            contents
        } else {
            PlaylistContents(format: .m3u, fields: PlaylistCoreFields(), entries: [])
        }
    }
    public var playlistOriginal: PlaylistCoreFields { playlistContents.fields }
    public var playlistFields: PlaylistCoreFields {
        get { if case .playlist(_, let fields) = state.payload { fields } else { PlaylistCoreFields() } }
        set {
            guard case .playlist(let contents, _) = state.payload else { return }
            state.payload = .playlist(contents, fields: newValue)
        }
    }

    /// Fehlertext des letzten Speicherversuchs (nil = ok).
    public var lastError: String?
    /// Ein Speichervorgang pro Datei reicht aus. Der Zustand verhindert, dass
    /// zwei Buttons gleichzeitig denselben TagLib-/Dateischreibvorgang starten.
    public var isSaving = false
    /// Wartende Aktionen (Entfernen, Import, Schließen) werden erst nach dem
    /// laufenden Schreibvorgang fortgesetzt. Continuations vermeiden Polling
    /// und machen den Ablauf auch in headless Tests deterministisch.
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []

    /// Unveränderlicher Stand zu Beginn eines Speichervorgangs. Der Puffer darf
    /// sich währenddessen weiter ändern; deshalb schreiben wir nie direkt aus
    /// den später möglicherweise veränderten UI-Feldern.
    public enum SaveSnapshot: Sendable {
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
    public struct AudioSnapshot: Sendable {
        public init(properties: [TagProperty], artworks: [Artwork], chapters: [Chapter]?,
                    syncedLyrics: [SyncedLyricLine]?, lyricsLanguage: String?, original: TagData,
                    lrcState: SidecarState = .unknown, nfo: NFOSnapshot? = nil) {
            self.properties = properties; self.artworks = artworks; self.chapters = chapters
            self.syncedLyrics = syncedLyrics; self.lyricsLanguage = lyricsLanguage
            self.original = original; self.lrcState = lrcState; self.nfo = nfo
        }
        public var properties: [TagProperty]
        public var artworks: [Artwork]
        /// nil, wenn das Format keine Kapitel kennt — dann fasst der
        /// Schreibweg die Kapitel gar nicht an.
        public var chapters: [Chapter]?
        /// nil = unverändert. Bei ID3v2-Trägern landen die Zeilen als SYLT
        /// in der Datei, sonst in der Sidecar `<name>.lrc`.
        public var syncedLyrics: [SyncedLyricLine]?
        /// nil = unverändert (nur ID3v2 speichert eine Sprache).
        public var lyricsLanguage: String?
        public var original: TagData
        /// Zustand der `<name>.lrc` beim Lesen (auch ihre Abwesenheit). Der
        /// Schreibweg prüft ihn unmittelbar vor dem Austausch der Sidecar.
        public var lrcState: SidecarState = .unknown
        /// Geänderte Felder der NFO neben einem Video samt Lesestand;
        /// nil = NFO unverändert oder keine vorhanden.
        public var nfo: NFOSnapshot? = nil

        /// Geänderte Lyrics außerhalb des Containers; ID3v2 speichert sie eingebettet.
        public var sidecarLyrics: [SyncedLyricLine]? {
            original.supportsSyncedLyrics ? nil : syncedLyrics
        }

        /// Ob in der Mediendatei selbst etwas zu schreiben ist. Sidecars
        /// (LRC bei Formaten ohne SYLT, NFO) zählen nicht dazu.
        public var mediaChanged: Bool {
            properties != original.properties || artworks != original.artworks
                || (chapters != nil && chapters != original.chapters)
                || (original.supportsSyncedLyrics && syncedLyrics != nil)
                || lyricsLanguage != nil
        }

        /// Dieselbe Momentaufnahme ohne Sidecar-Stempel — für das bewusste
        /// Überschreiben nach dem Konfliktdialog (wie `expecting: nil` beim
        /// Medium). Ohne das liefe die Person in denselben Konflikt erneut.
        public func ignoringSidecarStamps() -> AudioSnapshot {
            var copy = self
            copy.lrcState = .unknown
            copy.nfo?.stamp = nil
            return copy
        }
    }

    /// NFO-Stand zu Beginn eines Speichervorgangs (siehe `AudioSnapshot.nfo`).
    public struct NFOSnapshot: Sendable {
        public init(url: URL, fields: NFOFields, original: NFOFields, stamp: FileStamp?) {
            self.url = url; self.fields = fields; self.original = original; self.stamp = stamp
        }
        public var url: URL
        public var fields: NFOFields
        public var original: NFOFields
        public var stamp: FileStamp?
    }

    /// `stamp` gehört zum gelesenen `loaded`-Zustand (konsistenter
    /// Schnappschuss aus `AppModel.readStamped`). Beides zusammen ist die
    /// Vergleichsbasis für die Konfliktprüfung beim Speichern.
    public convenience init(url: URL, loaded: LoadedData, stamp: FileStamp?) {
        self.init(url: url, payload: EntryState(loaded), stamp: stamp)
    }

    private init(url: URL, payload: EntryState, stamp: FileStamp?) {
        self.url = url
        self.kind = payload.kind
        self.state = (payload, stamp)
    }

    /// Bequemer Weg für Tests: Stempel getrennt vom Inhalt erheben. Der
    /// Produktionspfad benutzt ausschließlich den konsistenten Schnappschuss
    /// (`AppModel.readStamped`), weil zwischen Lesen und Stempeln sonst eine
    /// fremde Änderung unbemerkt dazwischenrutschen kann.
    public convenience init(url: URL, loaded: LoadedData) {
        self.init(url: url, loaded: loaded, stamp: FileStamp.current(of: url))
    }

    /// Derselbe Eintrag unter neuem Pfad — nach dem Umbenennen der Datei.
    /// Die unveränderliche URL ist die Identität in Auswahl und Liste.
    /// Puffer und Stempel bleiben gültig, da die Umbenennung Inhalt, Inode
    /// und Änderungszeit erhält. Ein neuer Sidecar-Pfad folgt dem Umzug.
    public convenience init?(relocating other: FileEntry, to url: URL, sidecar: URL? = nil) {
        var payload = other.state.payload
        if let sidecar {
            switch payload {
            case .image(var reading, let fields):
                reading.sidecarURL = sidecar
                payload = .image(reading, fields: fields)
            case .audio(var audio) where sidecar.pathExtension.lowercased() == SidecarTool.nfoExtension:
                audio.sidecars.nfo?.url = sidecar
                payload = .audio(audio)
            default:
                break
            }
        }
        self.init(url: url, payload: payload, stamp: other.diskStamp)
        lastError = other.lastError
    }

    /// Der zuletzt gelesene Plattenstand ohne die Bearbeitungspuffer.
    public var loadedState: LoadedData? { state.payload.loaded }

    public var audio: AudioInfo? { original.audio }
    public var isReadOnly: Bool { kind == .audio && original.isReadOnly }
    /// Nur MP3, MP4 und Matroska tragen Kapitel; nur dann zeigt der Editor
    /// den Kapitel-Abschnitt.
    public var supportsChapters: Bool { kind == .audio && original.supportsChapters }
    /// ID3v2-Träger (MP3/MP2, WAV, AIFF, DSF) speichern SYLT und die Sprache
    /// der Lyrics in der Datei; alle anderen Audio-Formate nutzen für
    /// synchronisierte Lyrics die Sidecar `<name>.lrc`.
    public var supportsSyncedLyrics: Bool { kind == .audio && original.supportsSyncedLyrics }
    /// Tag-Schichten (ID3v1/ID3v2/APE …) laut letztem Lesestand; leer bei
    /// Formaten ohne Schichtenmodell — nur dann fehlt der Abschnitt im Editor.
    /// Kein Bearbeitungspuffer: Entfernen läuft direkt über
    /// `AppModel.stripLayer` und liest die Datei danach neu.
    public var layers: [TagLayer] { kind == .audio ? original.layers : [] }

    public func commitFixedFieldDraft(_ key: String) throws {
        guard let raw = fixedFieldDrafts[key] else { return }
        let value = try normalizedDraft(raw, key: key)
        setSingleValue(key, value)
        fixedFieldDrafts.removeValue(forKey: key)
    }

    private func normalizedDraft(_ raw: String, key: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "" : try FixedFields.normalized(key: key, value: value)
    }

    public func commitLyricsLanguageDraft() throws {
        guard let raw = lyricsLanguageDraft else { return }
        let value = FixedFields.normalizedLanguage(raw)
        guard FixedFields.isValidLanguage(value) else {
            throw TagError.invalidFieldValue(field: "LYRICS language", reason: "expected three letters (ISO 639-2)")
        }
        lyricsLanguage = value
        lyricsLanguageDraft = nil
    }

    private func commitFieldDrafts() throws {
        var values: [String: String] = [:]
        for (key, raw) in fixedFieldDrafts { values[key] = try normalizedDraft(raw, key: key) }
        // Alle Felder prüfen, bevor irgendein Bearbeitungspuffer verändert wird.
        if let raw = lyricsLanguageDraft, !FixedFields.isValidLanguage(FixedFields.normalizedLanguage(raw)) {
            throw TagError.invalidFieldValue(field: "LYRICS language", reason: "expected three letters (ISO 639-2)")
        }
        for (key, value) in values { setSingleValue(key, value) }
        fixedFieldDrafts.removeAll()
        try commitLyricsLanguageDraft()
    }

    public var isDirty: Bool {
        switch state.payload {
        case .audio(let audio): audio.isDirty
        case .image(let reading, let fields): fields != reading.fields
        case .ebook(let ebook): ebook.fields != ebook.original || ebook.coverReplacement != nil
        case .invoice: false
        case .document(let document): document.fields != document.original
        case .nfo(let contents, let fields): fields != contents.fields
        case .subtitle(let contents, let fields): fields != contents.fields
        case .playlist(let contents, let fields): fields != contents.fields
        }
    }

    /// Verwirft alle ungespeicherten Änderungen.
    public func revert() {
        state.payload = EntryState(state.payload.loaded)
        lastError = nil
    }

    /// Nach erfolgreichem Speichern/Neuladen den Originalzustand ersetzen.
    public func acceptNewOriginal(_ data: TagData, sidecars: AudioSidecars = AudioSidecars()) {
        acceptNew(.audio(data, sidecars: sidecars), stamp: diskStamp)
    }

    /// NFO neben dem Video laut letztem Lesestand (nil = keine).
    public var videoNFO: NFOSidecarReading? { audioSidecars.nfo }

    public func acceptNewImageOriginal(_ reading: ImageCoreReading) {
        acceptNew(.image(reading), stamp: diskStamp)
    }

    public func acceptNewEbookOriginal(_ fields: EbookCoreFields, cover: Data?) {
        acceptNew(.ebook(fields, cover: cover), stamp: diskStamp)
    }

    public func acceptNewDocumentOriginal(_ fields: DocumentCoreFields, cover: Data?,
                                          info: [DocumentInfoItem]) {
        acceptNew(.document(fields, cover: cover, info: info), stamp: diskStamp)
    }

    public func acceptNewSidecarOriginal(_ contents: SidecarContents) {
        acceptNew(.sidecar(contents), stamp: diskStamp)
    }

    public func acceptNewPlaylistOriginal(_ contents: PlaylistContents) {
        acceptNew(.playlist(contents), stamp: diskStamp)
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
    public func setEbookCover(_ data: Data) {
        ebookState?.coverReplacement = (!isSaving && data == ebookOriginalCover) ? nil : data
    }

    /// Frisch gelesenen Platten-Zustand als neues Original übernehmen.
    /// `stamp` muss zum selben Leseschnappschuss gehören wie `loaded` —
    /// ein getrennt erhobener Stempel könnte schon zu einer fremden, nie
    /// gelesenen Dateiversion gehören, die das nächste Speichern dann als
    /// "unverändert" überschriebe.
    public func acceptNew(_ loaded: LoadedData, stamp: FileStamp?) {
        let payload = EntryState(loaded)
        guard payload.kind == kind else { return }
        switch (state.payload, payload) {
        case (.nfo, .subtitle), (.subtitle, .nfo):
            return
        default:
            state = (payload, stamp)
            lastError = nil
        }
    }

    /// Markiert genau einen Speicherauftrag als aktiv und liefert dessen Stand.
    /// `allowingUnchanged` erfasst auch saubere Puffer vor direkten Dateiaktionen.
    /// nil bedeutet: kein Auftrag oder bereits laufendes Speichern.
    public func beginSaving(allowingUnchanged: Bool = false) -> SaveSnapshot? {
        guard !isSaving else { return nil }
        do { try commitFieldDrafts() } catch {
            lastError = error.localizedDescription
            return nil
        }
        guard isDirty || allowingUnchanged else { lastError = nil; return nil }
        let snapshot: SaveSnapshot
        switch state.payload {
        case .audio(let audio):
            snapshot = .audio(audio.snapshot)
        case .image(let reading, let fields):
            snapshot = .image(fields: fields, original: reading.fields, sidecar: reading.sidecar)
        case .ebook(let ebook):
            snapshot = .ebook(fields: ebook.fields, original: ebook.original, cover: ebook.coverReplacement)
        case .invoice:
            return nil
        case .document(let document):
            snapshot = .document(fields: document.fields, original: document.original)
        case .nfo(let contents, let fields):
            snapshot = .sidecar(fields: .nfo(fields), original: .nfo(contents.fields))
        case .subtitle(let contents, let fields):
            snapshot = .sidecar(fields: .subtitle(fields), original: .subtitle(contents.fields))
        case .playlist(let contents, let fields):
            snapshot = .playlist(fields: fields, original: contents.fields)
        }
        isSaving = true
        return snapshot
    }

    /// Macht die Bedienung wieder frei, auch wenn das Schreiben fehlgeschlagen
    /// ist. Original und Bearbeitungspuffer werden hier absichtlich nicht
    /// verändert.
    public func finishSaving() {
        isSaving = false
        let waiters = saveWaiters
        saveWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Wartet nur dann, wenn aktuell wirklich geschrieben wird. Da diese
    /// Methode und `finishSaving()` auf dem MainActor laufen, kann zwischen
    /// Prüfung und Eintragen kein Abschluss verloren gehen.
    public func waitUntilSaveFinished() async {
        guard isSaving else { return }
        await withCheckedContinuation { saveWaiters.append($0) }
    }

    /// Übernimmt ausschließlich den von `snapshot` gesicherten Plattenstand.
    /// Hat die Person während des Schreibens weitergetippt, bleibt dieser neuere
    /// Puffer erhalten und ist gegenüber dem neuen Original weiterhin dirty.
    /// `stamp` gehört zum Read-back `reloaded` (konsistenter Schnappschuss) —
    /// so kann nie ein Stempel einer neueren, fremden Dateiversion mit den
    /// hier gelesenen älteren Daten kombiniert werden.
    public func acceptSaved(_ snapshot: SaveSnapshot, reloaded: LoadedData, stamp: FileStamp?) {
        let payload: EntryState
        switch (state.payload, snapshot, reloaded) {
        case (.audio(var audio), .audio(let saved), .audio(let data, let sidecars)):
            audio.acceptSaved(saved, data: data, sidecars: sidecars)
            payload = .audio(audio)
        case (.image(_, let fields), .image(let saved, _, _), .image(let reading)):
            payload = .image(reading, fields: fields == saved ? reading.fields : fields)
        case (.ebook(var ebook), .ebook(let savedFields, _, let savedCover), .ebook(let fields, let cover)):
            ebook.original = fields
            ebook.originalCover = cover
            if ebook.fields == savedFields { ebook.fields = fields }
            // Während des Speicherns kann auch das alte Originalcover
            // erneut gewählt werden. Erst das Read-back zeigt, ob es
            // gegenüber dem neuen Original tatsächlich geändert ist.
            if ebook.coverReplacement == savedCover || ebook.coverReplacement == cover {
                ebook.coverReplacement = nil
            }
            payload = .ebook(ebook)
        case (.document(var document), .document(let saved, _), .document(let fields, let cover, let info)):
            document.original = fields
            document.cover = cover
            document.info = info
            if document.fields == saved { document.fields = fields }
            payload = .document(document)
        case (.nfo(_, let fields), .sidecar(.nfo(let saved), .nfo), .sidecar(.nfo(let contents))):
            payload = .nfo(contents, fields: fields == saved ? contents.fields : fields)
        case (.subtitle(_, let fields), .sidecar(.subtitle(let saved), .subtitle), .sidecar(.subtitle(let contents))):
            payload = .subtitle(contents, fields: fields == saved ? contents.fields : fields)
        case (.playlist(_, let fields), .playlist(let saved, _), .playlist(let contents)):
            payload = .playlist(contents, fields: fields == saved ? contents.fields : fields)
        default:
            // Der Stempel ist nur zusammen mit dem passenden Lesestand gültig.
            return
        }
        state = (payload, stamp)
        lastError = nil
    }

    // Bequeme Zugriffe für die UI ------------------------------------------

    /// Erster Wert eines Schlüssels (für Einfach-Felder).
    public func firstValue(_ key: String) -> String {
        properties.first { $0.key == key }?.value ?? ""
    }

    /// Setzt einen Schlüssel auf genau einen Wert (leer = Feld entfernen).
    public func setSingleValue(_ key: String, _ value: String) {
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

    /// Titel aus dem Bearbeitungspuffer, ohne Ersatz durch den Dateinamen.
    /// Suche und Sortierung sollen denselben Feldwert wie die Zeile verwenden.
    public var metadataTitle: String {
        switch state.payload {
        case .audio: firstValue("TITLE")
        case .image(_, let fields): fields.title
        case .ebook(let ebook): ebook.fields.title
        case .invoice(let document): document.summary.invoiceNumber ?? ""
        case .document(let document): document.fields.title
        case .nfo(_, let fields): fields.title
        case .subtitle(_, let fields): fields.title
        case .playlist(_, let fields): fields.title
        }
    }

    public var displayTitle: String {
        let title = metadataTitle
        return title.isEmpty ? url.lastPathComponent : title
    }

    public var displaySubtitle: String {
        switch state.payload {
        case .audio:
            return [firstValue("ARTIST"), firstValue("ALBUM")]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case .image(_, let fields):
            return fields.keywords.joined(separator: ", ")
        case .ebook(let ebook):
            return ebook.fields.authors.joined(separator: ", ")
        case .invoice(let document):
            let summary = document.summary
            return [summary.sellerName ?? "", summary.issueDate ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case .document(let document):
            return document.fields.authors.joined(separator: ", ")
        case .nfo(let contents, let fields):
            return [contents.rootName ?? "url", fields.year]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .subtitle(let contents, _):
            let info = contents.info
            return [info.languageFromName ?? "", "\(info.cueCount) cues"]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .playlist(let contents, let fields):
            let count = contents.entries.count
            let entries = String(localized: "\(count) Einträge")
            return fields.performer.isEmpty ? entries : "\(fields.performer) · \(entries)"
        }
    }
}
