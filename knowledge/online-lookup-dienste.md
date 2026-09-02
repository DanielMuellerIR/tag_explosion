# Online-Lookup: MusicBrainz, Discogs, AcoustID (Stand 2026-09-02)

Konsultieren bei Arbeit an `Sources/TagExplosionCore/OnlineLookup/`,
`tagx lookup`, dem Sheet „Online nachschlagen …" oder den Einstellungen
für Online-Dienste.

## Grundregel: kein Netz ohne Klick

- Der Core prüft die Freigabe **nicht** — `OnlineLookupService` schickt, was
  man ihm sagt, damit Tests ihn mit einem Stub direkt ansprechen können. Die
  Freigabe prüfen die Aufrufer: die CLI über `TAGX_ONLINE=1`
  (`OnlineLookupConsent.require(enabled:)`), die App über die Einstellung
  `onlineServicesAllowed` (Voreinstellung aus) plus den einmal bestätigten
  Datenschutzhinweis (`OnlineLookupAccess.decision`). Ein neuer Aufrufer muss
  diese Prüfung selbst einbauen.
- Erst nach dem Klick auf „Suchen" geht die erste Anfrage raus. Das Sheet lädt
  nach der Auswahl eines Kandidaten Trackliste und (wenn „Cover übernehmen"
  an ist) das Cover nach — das sind Folgeanfragen derselben Aktion, keine
  automatischen.

## Dienste

- **MusicBrainz** verlangt einen User-Agent mit Kontakt
  (`TagExplosion/<Version> (<Projekt-URL>)`) und höchstens eine Anfrage pro
  Sekunde; sonst kommt 503. `RateLimiter` (ein Actor je Dienst) und die
  Wiederholung nach `Retry-After` (höchstens 2 Versuche, 1–30 s) sitzen in
  `LookupTransport`, nicht in den Clients. Cover kommen vom Cover Art Archive
  (`/release/<id>/front-500`, leitet auf archive.org weiter; 404 = kein Cover,
  wird zu `nil`).
- **Discogs** ohne Token: 25 Anfragen/Minute, keine Bilder in der Suche. Der
  Token geht nur als Header `Authorization: Discogs token=…` — nie in die URL,
  nie ins Log. Die Suche liefert „Interpret - Album" als *einen* Titel und
  hängt bei Namensdubletten „ (2)" an; beides wird beim Parsen zerlegt.
  Positionen der Trackliste: „7" (CD), „2-3" (CD 2, Track 3), „A1" (Vinyl →
  laufende Nummer). Überschriften haben `type_ = "heading"`.
- **AcoustID** braucht `fpcalc` (Homebrew `chromaprint`, wird über den
  vorhandenen Prozessweg `MediaInfoReader.run` gestartet) und einen
  Client-Key (acoustid.org/new-application). Der Lookup läuft als POST mit
  Formular-Body, damit Key und Fingerabdruck nicht in der URL stehen. `meta`
  wird mit `+` getrennt und muss als `%2B` kodiert werden — ein echtes `+` im
  Body wäre ein Leerzeichen. Releases stehen je nach `meta` flach unter dem
  Recording oder unter `releasegroups[].releases`; der Parser liest beides.
  AcoustID kennt keine Trackliste; die holt danach der MusicBrainz-Client
  über die Release-ID, die AcoustID-Kennung bleibt am erkannten Titel.

## Zuordnung und Plan

- `TrackMatcher`: erst Tracknummer (plus CD-Nummer, wenn beide Seiten eine
  haben; nur bei genau einem Treffer), dann Dauer ±3 s mit Titelähnlichkeit
  ≥ 0,35, sonst nur Titel ≥ 0,75. Klammerzusätze („(Remastered 2009)")
  zählen als zweite Wertung ×0,9 — sonst passt „Nachtlied (Remaster)" nicht
  zu „Nachtlied". Jeder Titel wird höchstens einer Datei zugeordnet.
- `LookupPlanner` liefert nur echte Änderungen; leere Sollwerte löschen nie
  ein Feld. Kennungen: `MUSICBRAINZ_ALBUMID/TRACKID/ARTISTID/RELEASEGROUPID`,
  `ACOUSTID_ID`, `DISCOGS_RELEASE_ID` (letzteres landet in ID3 als TXXX).
- Schreiben: CLI über `FileStamp` aus dem Lesestand + `TrashBackup` +
  `TagFile.write` — der Stempel ist hier wichtiger als sonst, weil zwischen
  Lesen und Schreiben die Netzantwort liegt. Die App schreibt gar nicht
  selbst: „Übernehmen" setzt nur den Bearbeitungspuffer, gespeichert wird
  mit ⌘S über den normalen Weg.

## Zugangsdaten

- App: Keychain (`SecItem…`, Service
  `io.github.danielmuellerir.tagexplosion.online-lookup`, „nur dieses Gerät"),
  nicht `UserDefaults`. CLI: `TAGX_DISCOGS_TOKEN`, `TAGX_ACOUSTID_KEY` — keine
  Argumente, weil `ps` sie zeigen würde.
- In Swift-Strings gilt `„…"` mit geradem Schlusszeichen nicht: Das `"`
  beendet den String. In UI-Texten deshalb `„…“`; in Kommentaren und
  mehrzeiligen `"""`-Strings ist das gerade Zeichen unproblematisch.
