// Unveränderliche Ergebnisse der Medienleser einschließlich Sidecar-Stempel.
import Foundation
import EInvoiceCore
import TagExplosionCore

/// Sidecars, die zu einem Audio-/Video-Eintrag gehören und beim Lesen mit
/// erhoben werden. Sie hängen am selben Namensstamm wie das Medium.
struct AudioSidecars: Sendable, Equatable {
    /// Stempel der `<name>.lrc` beim Lesen; nil = keine Sidecar. Beim
    /// Speichern wird dagegen geprüft (fremde Änderung → Konflikt).
    var lrcStamp: FileStamp? = nil
    /// Kodi-NFO neben einem Video; nil = keine NFO daneben.
    var nfo: NFOSidecarReading? = nil

    /// Felder der NFO als Bearbeitungsgrundlage (leer ohne lesbare NFO).
    var nfoFields: NFOFields { nfo?.contents?.fields ?? NFOFields() }
}

/// Gelesene NFO-Sidecar eines Videos: Inhalt (nil, wenn unlesbar — dann
/// steht der Grund in `error`) und Stempel für die Konfliktprüfung.
struct NFOSidecarReading: Sendable, Equatable {
    var url: URL
    var contents: NFOContents?
    var stamp: FileStamp?
    var error: String? = nil

    /// Nur eine lesbare NFO mit Feldern (keine Nur-URL-NFO) ist editierbar.
    var isEditable: Bool { contents.map { !$0.isURLOnly } ?? false }
}

/// Frisch gelesener Datei-Zustand (Audio, Bild, E-Book oder E-Rechnung).
enum LoadedData: Sendable {
    /// Audio/Video samt Sidecar-Zustand (`.lrc`-Stempel, NFO) — beides wird
    /// mit dem Medium gelesen und beim Speichern gegen die Platte geprüft.
    case audio(TagData, sidecars: AudioSidecars = AudioSidecars())
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

