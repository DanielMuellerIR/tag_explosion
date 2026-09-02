# Wissens-Index tag_explosion

Eine Datei pro Problem; konsultieren, wenn der Trigger zutrifft.

- [dateisicherheit-schreibwege.md](dateisicherheit-schreibwege.md) — Bei jedem
  Schreibweg und beim abgesicherten Modus: atomarer Rahmen, Papierkorb-
  Sicherung, `URL.resourceValues`-Cache-Falle, Platz- und Pfad-Regeln.
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
