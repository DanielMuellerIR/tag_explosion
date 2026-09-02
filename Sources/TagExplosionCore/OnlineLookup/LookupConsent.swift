// Grundsatz des Online-Lookups: Kein Netzzugriff ohne ausdrückliche Aktion
// des Nutzers. Hier stehen die Teile, die das absichern — die Freigabe, der
// User-Agent (MusicBrainz verlangt Name, Version und Kontakt) und der
// Datenschutzhinweis, den App und CLI vor dem ersten Zugriff zeigen.
import Foundation

public enum OnlineLookupConsent {
    /// Kontaktadresse im User-Agent, wie MusicBrainz sie verlangt: die
    /// öffentliche Projektseite.
    public static let contactURL = "https://github.com/DanielMuellerIR/tag_explosion"

    /// `TagExplosion/<version> (<Kontakt>)` — für alle drei Dienste gleich.
    public static func userAgent(version: String) -> String {
        let cleaned = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return "TagExplosion/\(cleaned.isEmpty ? "dev" : cleaned) (\(contactURL))"
    }

    /// Umgebungsvariable, mit der die CLI Online-Dienste freigibt.
    public static let environmentVariable = "TAGX_ONLINE"

    /// Ob `TAGX_ONLINE` auf 1/true steht.
    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let raw = environment[environmentVariable]?.lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    /// Wirft `onlineDisabled`, wenn die Freigabe fehlt. App und CLI rufen das
    /// vor JEDER Anfrage auf; die Clients selbst prüfen nichts, damit Tests
    /// sie mit einem Stub direkt ansprechen können.
    public static func require(enabled: Bool) throws {
        guard enabled else { throw LookupError.onlineDisabled }
    }

    /// Datenschutzhinweis, deutsch. Sachlich: welche Daten an welchen Dienst
    /// gehen, und dass nichts davon automatisch passiert.
    public static let privacyNoticeGerman = """
    Beim Nachschlagen sendet Tag Explosion Daten an den gewählten Dienst — \
    nur auf Ihre Aktion, nie automatisch beim Öffnen einer Datei.

    • MusicBrainz (musicbrainz.org) und Cover Art Archive (coverartarchive.org): \
    die Suchbegriffe (Interpret, Album, Titel, Jahr, Titelanzahl) und für \
    Cover die Release-Kennung.
    • Discogs (api.discogs.com): die Suchbegriffe; ein persönlicher Token wird \
    nur im Anfragekopf übertragen.
    • AcoustID (api.acoustid.org): ein Audio-Fingerabdruck der Datei \
    (berechnet mit fpcalc, kein Audio selbst), die Spieldauer und Ihr \
    Client-Key.

    Jede Anfrage trägt den User-Agent „TagExplosion/<Version>" mit der \
    Projektadresse. Ihre IP-Adresse sieht der jeweilige Dienst wie bei jedem \
    Webaufruf. Tag Explosion speichert keine Suchverläufe und sendet keine \
    Nutzungsdaten.
    """

    /// Datenschutzhinweis, englisch.
    public static let privacyNoticeEnglish = """
    When you look up a release, Tag Explosion sends data to the selected \
    service — only on your action, never automatically when a file is opened.

    • MusicBrainz (musicbrainz.org) and Cover Art Archive (coverartarchive.org): \
    the search terms (artist, album, title, year, track count) and, for cover \
    art, the release id.
    • Discogs (api.discogs.com): the search terms; a personal token travels \
    in the request header only.
    • AcoustID (api.acoustid.org): an audio fingerprint of the file (computed \
    with fpcalc, not the audio itself), its duration and your client key.

    Every request carries the user agent "TagExplosion/<version>" with the \
    project address. Each service sees your IP address as with any web \
    request. Tag Explosion keeps no search history and sends no usage data.
    """

    /// Kurzer Hinweis für die CLI, wie man die Freigabe erteilt.
    public static let cliHint = """
    Online lookup is off by default. Read the privacy notice \
    (`tagx lookup --privacy`) and set TAGX_ONLINE=1 to allow requests. \
    Credentials: TAGX_DISCOGS_TOKEN, TAGX_ACOUSTID_KEY (environment only, never arguments).
    """
}
