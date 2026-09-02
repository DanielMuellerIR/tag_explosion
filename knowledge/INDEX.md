# Wissens-Index tag_explosion

Eine Datei pro Problem; konsultieren, wenn der Trigger zutrifft.

- [dateisicherheit-schreibwege.md](dateisicherheit-schreibwege.md) — Bei jedem
  Schreibweg und beim abgesicherten Modus: atomarer Rahmen, Papierkorb-
  Sicherung, `URL.resourceValues`-Cache-Falle, Platz- und Pfad-Regeln.
- [linux-xdg-papierkorb.md](linux-xdg-papierkorb.md) — Bei Linux-Build,
  Linux-CI oder Arbeit an `XDGTrash`: freedesktop-Papierkorb-Regeln,
  Linux-Foundation-Lücken (`volumeURLKey`, Volume-Kapazität), TagLib 2 aus
  dem Quelltext, Docker-Lauf auf Popo (Git braucht dort HTTP/1.1).
- [taglib-shim.md](taglib-shim.md) — Bei Arbeit am CTagShim/TagLib-Upgrade:
  Encoding-Default, C-API-Grenzen, PropertyMap-Verhalten, Format-Toleranzen.
- [mediainfo-exiftool-wrapper.md](mediainfo-exiftool-wrapper.md) — Bei kaputten
  Umlauten in Reports oder exiftool-Schreibfehlern: Surrogate-Escapes, MWG-Modul.
- [gui-selbsttests.md](gui-selbsttests.md) — Bei GUI-/AX-Tests der App:
  was funktioniert (Maus, AX-Setzen), was nicht (synthetische Tastatur).
- [fenster-und-layout.md](fenster-und-layout.md) — Bei Arbeit an Fenstern,
  Menübefehlen oder SwiftUI-Layouts: ein Modell pro Fenster, Fenster anlegen
  ohne offenes Fenster, `representedURL` für Icon und Pfadmenü, gierige
  GeometryReader und `fixedSize` in `Grid`.
- [epub-opf-struktur.md](epub-opf-struktur.md) — Beim Schreiben von
  EPUB-Metadaten: Der `unique-identifier` des Pakets hängt meist am ISBN-Knoten;
  Identifier, refines und neue XML-IDs müssen konsistent nachgeführt werden.
- [ebook-meta-calibre-quirks.md](ebook-meta-calibre-quirks.md) — Beim
  E-Book-Backend mobi/azw3/fb2: azw3 verliert Serien, Datums-/Index-Semantik,
  nicht sicher löschbare Cover und LC_ALL=C.
- [e-rechnung-anzeige.md](e-rechnung-anzeige.md) — Bei Arbeit an EInvoiceCore,
  `tagx invoice` oder der Rechnungsansicht: Profil-URNs (BT-24), ambige
  BT-Zuordnungen (Nachlass/Zuschlag, VA/FC, BT-110/111), Dokumentart,
  Order-X/Peppol-Bestellungen ohne BT-Nummern, Grundvalidierung (Regelcodes,
  Toleranz, Währungsfalle), CGPDF-Extraktion samt
  Budgets/Dekompressions-Restrisiko, XMP-Präfix-Falle.
- [kapitel-hoerbuch.md](kapitel-hoerbuch.md) — Bei Arbeit an Kapiteln
  (CHAP/CTOC, MP4 Nero/QuickTime, Matroska): was TagLib 2.3 kann, Einheiten
  (ms vs. ns), fehlende MP4-Enden, welche Fremdwerkzeuge was lesen.
- [weitere-endungen-taglib.md](weitere-endungen-taglib.md) — Bei neuen
  Endungen oder Tracker-/Matroska-/3GP-Fragen: was TagLib 2.3 wirklich liest
  und schreibt (au/ogv gar nicht, mka ohne Cover, Tracker nur Titel/Kommentar
  in Latin1 mit Längenlimit), Fixture-Rezepte und die MP4-Fake-JPEG-Falle.
- [dateiname-muster-umbenennen.md](dateiname-muster-umbenennen.md) — Bei
  Arbeit an `FilenamePattern`, `FileRenamer`, `tagx rename`/`parse` oder den
  Dateinamen-Dialogen: warum Umbenennen ohne Papierkorb-Sicherung läuft,
  Alles-oder-nichts-Plan, Groß-/Kleinschreibung auf APFS, `%{` in
  lokalisierten Texten, neuer `FileEntry` nach dem Umbenennen.
- [dokument-container-metadaten.md](dokument-container-metadaten.md) — Bei
  Arbeit an DocumentTool, ZipContainer, `tagx doc` oder dem Dokument-Editor:
  ODF-`mimetype` an erster Stelle, fehlendes core.xml registrieren,
  ODF-`dc:creator`-Semantik, ComicInfo-Reihenfolge, Frontmatter-Subset und
  Byte-Identität des Bodys.
- [archiv-restore-vertrag.md](archiv-restore-vertrag.md) — Bei TagArchive-,
  Export-/Import- oder Wertebereichs-Arbeit: Export sichert Bestand nur
  strukturell geprüft, der Import prüft Änderungen zielbezogen je Eintrag
  vor Sicherung/Dry-run; Backend-Verträge für Serie und Coverformate.
- [feste-felder-lyrics-lautheit-podcast.md](feste-felder-lyrics-lautheit-podcast.md) —
  Bei Arbeit an Lyrics (USLT/SYLT/LRC), ReplayGain/R128 oder Podcast-Feldern:
  welche Schlüssel TagLibs PropertyMap kennt und welche nicht (PCST, TKWD,
  TVSN/TVEP, keyw/ldes), warum PCST über die PropertyMap verloren geht,
  Sprache "XXX" nach jedem Textwechsel, Sidecar-Regeln, was kid3/mediainfo
  davon zeigen.
- [id3-schichten.md](id3-schichten.md) — Bei Tag-Schichten (ID3v1/ID3v2/APE/
  RIFF INFO/Vorbis), `tagx layers` oder der ID3v2.3-Option: welche Formate
  welche Schichten kennen, `strip()` schreibt bei MPEG/WAV sofort, die
  `List::erase`-Falle, FLAC-Vorbis bleibt als Hülle, was v2.3 am Datum kürzt.
- [playlists-cue.md](playlists-cue.md) — Bei Arbeit an PlaylistTool, den
  vier Backends (cue/m3u/pls/xspf), `tagx playlist`/`cue` oder dem
  Playlist-Editor: zeilenweiser Erhalt statt Neuaufbau, Encoding-Fallback
  wird beim Schreiben zu UTF-8, M3U-Anzeigetext ist ein Feld, Cue-Dauer nur
  je Datei, `cue apply` nur bei einer Datei je Track, `/private/tmp`-Falle.
- [raw-xmp-sidecar.md](raw-xmp-sidecar.md) — Bei Kamera-RAW, `.xmp` oder
  dem Schreibziel von Bildern: Sidecar-Regeln, feldweises Überlagern,
  exklusives Anlegen, warum Löschen über die Sidecar nichts im RAW löscht.
- [batch-regeln.md](batch-regeln.md) — Bei Arbeit an `TagRules.swift`,
  `tagx apply` oder dem Regel-Editor: Engine sieht nur den ersten Wert je
  Schlüssel, Medienart-Grenzen greifen erst beim Schreiben, Titel-Schreibweise
  und Abkürzungen, Zeilenangabe im JSON per eigenem Scanner, `%{` in
  lokalisierten Texten, `number` über alle Dateien.
- [kodi-nfo-untertitel.md](kodi-nfo-untertitel.md) — Bei Kodi-/Jellyfin-
  NFO, `.srt`/`.vtt`, `tagx nfo`/`subtitle` oder dem NFO-Abschnitt im
  Video-Editor: eigener XML-Serialisierer für Einrückungserhalt, Nur-URL-NFO,
  Inhaltsprüfung der Endung, Zeitverschiebung nur auf `-->`-Zeilen,
  `--seconds=-1.5`, Sprache aus dem Dateinamen.
- [cover-werkzeuge.md](cover-werkzeuge.md) — Bei Arbeit an CoverTools,
  `tagx cover info/convert/from-folder/to-folder` oder dem Cover-Menü der
  App: Header-Parser statt ImageIO für JPEG/PNG, was das Strip-Segment
  behalten muss (ICC, Adobe), Neukodierung nur mit ImageIO (Linux: Fehler),
  Ordner-Cover-Priorität und Groß-/Kleinschreibung, Export nur exklusiv.
- [konsistenzpruefung.md](konsistenzpruefung.md) — Bei Arbeit an
  `LibraryCheck`, `ImagePixelSize`, `tagx check` oder dem Prüf-Sheet:
  Gruppenschlüssel (Album + Album-Interpret normalisiert) und seine Grenze,
  Gesamtzahl aus „n/total" oder TRACKTOTAL, Disc-Regeln nur mit DISCNUMBER,
  `covers == nil` vs. leer, Dubletten nur mit bekannter Dauer, `--only` als
  Einzelwert, Sheet hängt am ContentView statt am Batch-Editor.
- [undo-historie-journal.md](undo-historie-journal.md) — Bei `BackupJournal`,
  `BackupHistory`, `tagx history` oder dem Versionen-Blatt: warum die
  Papierkorb-Kopien ein Journal brauchen, Journal-Regeln (nur `shared`
  schreibt, Verfall, `flock`, Bruchteil-Sekunden, Prüfsummen-Limit), Restore
  als normaler Schreibweg, XMP-Sidecar-Fall, Grenzen nach Umbenennen.
- [online-lookup-dienste.md](online-lookup-dienste.md) — Bei Arbeit am
  Online-Lookup (MusicBrainz/Discogs/AcoustID, `tagx lookup`, Sheet,
  Einstellungen): Freigabe liegt beim Aufrufer, User-Agent und 1 Anfrage/s,
  Token nur im Header, AcoustID per POST mit `%2B`, Discogs-Positionen und
  Titel-Splitting, Matcher-Schwellen, Keychain statt UserDefaults.
