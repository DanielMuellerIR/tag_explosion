# Roadmap — Tag Explosion

Stand: 2026-09-02. Ergänzt [PLAN.md](PLAN.md) (Architektur, erledigte
Meilensteine) um die noch offenen Erweiterungen. Jeder Punkt ist ein
Arbeitspaket (AP) mit Status; abgeschlossene Pakete wandern mit Version in den
[CHANGELOG](../CHANGELOG.md) und werden hier nur noch als „✅ x.y.z" geführt.

Status-Kürzel: ⬜ offen · 🔧 in Arbeit · ✅ erledigt (Version) · ⏸ zurückgestellt

## Leitlinien für alle Pakete

- Jede neue Endung kommt zentral nach `Sources/TagExplosionCore/MediaFormats.swift`
  und bekommt einen Roundtrip- oder Lesetest mit generierter Fixture
  (`Tests/TagExplosionCoreTests/Fixtures/generate_fixtures.sh`); keine echten
  Mediendateien im Repo.
- Jeder Schreibweg läuft über `AtomicFileRewrite` und `TrashBackup` (siehe
  [knowledge/dateisicherheit-schreibwege.md](../knowledge/dateisicherheit-schreibwege.md)).
- Alles, was die App kann, kann auch `tagx` (JSON-Ausgabe, Exit-Codes).
- Neue UI-Texte zweisprachig (en/de) in den App-Ressourcen.
- Abhängigkeiten bleiben MIT-kompatibel: TagLib nur dynamisch, exiftool,
  mediainfo und Calibre nur als CLI-Aufruf.

## Welle 1 — Abdeckung mit vorhandener Technik

| AP | Inhalt | Aufwand | Status |
|----|--------|---------|--------|
| AP1 | **Weitere Audio-/Container-Endungen über TagLib:** Tracker-Module (mod, s3m, xm, it), Sun/NeXT `au`, AIFF-C `aifc`, `mp2`, `3gp`/`3g2`, Matroska-Audio `mka`, Ogg-Video `ogv`. Fixtures per ffmpeg, wo ffmpeg das Format encodieren kann; Tracker-Formate nur Leseweg-Test mit synthetischer Minimaldatei. | klein | ✅ 0.25.0 |
| AP2 | **Kamera-RAW und XMP-Sidecar:** RAW-Endungen (cr2, cr3, nef, arw, raf, orf, rw2, pef) lesen via exiftool; Schreiben in die XMP-Sidecar-Datei (`<name>.xmp`), nie ins RAW. `.xmp` als eigenes Format anzeigen/bearbeiten. Zusätzlich avif, jxl, bmp, psd, svg (Lesen; avif/jxl auch Schreiben). Option „Sidecar statt Original schreiben" für alle Bildformate. | mittel | ✅ 0.27.0 |
| AP3 | **Umbenennen aus Tags und Tags aus Dateinamen** mit Format-Mustern (`%artist% - %title%`, `%track%`, `%album%` …). Muster-Engine im Core, Vorschau vor dem Umbenennen, Kollisionen erkennen, `tagx rename` und `tagx parse` (dry-run per Voreinstellung), Batch-Editor-Menü in der App. | groß | ✅ 0.26.0 |
| AP4 | **Office, Comics, Markdown:** docx/xlsx/pptx (`docProps/core.xml`) und odt/ods/odp (`meta.xml`) mit Titel, Autor, Schlagwörtern, Beschreibung, Datum — ZIP-plus-XML-Weg wie bei EPUB. CBZ mit `ComicInfo.xml` (Titel, Serie, Nummer, Autor, Verlag, Zusammenfassung; Cover = erste Seite). Markdown-Frontmatter (YAML) als Metadatenblock lesen/schreiben. Neue Medienart `document` mit eigenem Editor und `tagx doc`. | groß | ✅ 0.28.0 |
| AP5 | **Kapitel für Hörbücher und Podcasts:** ID3 CHAP/CTOC, MP4-Chapters (Nero + QuickTime-Text-Track soweit TagLib es zulässt), Matroska-Chapters. Eigener Shim-Teil in `Sources/CTagShim`, Kapitelliste im Editor (Titel, Start, Ende), `tagx chapters show/set/import` mit JSON. | groß | ✅ 0.24.0 |

## Welle 2 — Audio-Tiefe und Nebendaten

| AP | Inhalt | Aufwand | Status |
|----|--------|---------|--------|
| AP6 | **ID3-Schichten und ID3v2.3-Option:** ID3v1, ID3v2, APE getrennt anzeigen und einzeln entfernen („Schicht strippen"); Schreiboption ID3v2.3 statt v2.4 für alte Player (Shim-Overload von `MPEG::File::save`). | mittel | ✅ 0.29.0 |
| AP7 | **Feste Felder mit Prüfung:** Lyrics (USLT) mit Sprache und synchronisierte Lyrics (SYLT / LRC-Sidecar), ReplayGain und R128-Lautheit (Wertebereich prüfen), Podcast-Felder (Episode, Season, Podcast-URL, GUID) für MP4 und ID3. | mittel | ✅ 0.33.0 |
| AP8 | **Playlists und Cue-Sheets:** `.cue` anzeigen und bearbeiten (Titel, Interpret, Index); `.m3u`/`.m3u8`/`.pls`/`.xspf` anzeigen und aus einer Auswahl exportieren. | mittel | ✅ 0.31.0 |
| AP9 | **Video-Sidecars:** Kodi/Jellyfin `.nfo` (XML) anzeigen und bearbeiten; `.srt`/`.vtt` mit Sprache und Titel anzeigen. | klein | ✅ 0.32.0 |
| AP10 | **Rechnungen erweitern:** Order-X und Peppol-Bestellung/Gutschrift über den CII/UBL-Unterbau; Warnhinweise aus einer Grundvalidierung (Pflichtfelder nach EN 16931, Summenprüfung BT-106…BT-115). | mittel | ✅ 0.30.0 |

## Welle 3 — Werkzeuge rund um die Bibliothek

| AP | Inhalt | Aufwand | Status |
|----|--------|---------|--------|
| AP11 | **Konsistenzprüfung über Ordner:** fehlende Cover, abweichende Album-Interpreten, Lücken und Dubletten in der Track-Nummerierung, uneinheitliche Jahreszahlen; Bericht in App und `tagx check --json`. | mittel | 🔧 |
| AP12 | **Cover-Werkzeuge:** Größe/Format anzeigen und prüfen, verkleinern, nach JPEG wandeln, `folder.jpg`/`cover.jpg` übernehmen oder exportieren. | mittel | ✅ 0.34.0 |
| AP13 | **Batch-Regeln als Skript:** Regeldatei (JSON) für Groß-/Kleinschreibung, Feldkopien, Suchen/Ersetzen, Leerzeichen trimmen; `tagx apply rules.json` und Regel-Editor in der App. | mittel | 🔧 |
| AP14 | **Undo-Historie:** die Papierkorb-Sicherungen aus `TrashBackup` als Versionsliste pro Datei anzeigen und einzeln zurückholen. | mittel | 🔧 |
| AP15 | **Online-Lookup:** MusicBrainz und Discogs (Release-Suche, Tags übernehmen), optional AcoustID-Fingerprint über `fpcalc`. Nur auf ausdrückliche Aktion, mit Datenschutzhinweis im UI; kein automatischer Netzzugriff. | groß | 🔧 |
| AP16 | **Linux-Papierkorb** nach XDG-Spezifikation plus Linux-Job in der CI, damit der abgesicherte Modus dort funktioniert (siehe Backlog in PLAN.md, Priorität niedrig). | mittel | ⏸ |
| AP17 | **Finder-Integration:** Quick-Look-Vorschau der Tags und Kontextmenü „In Tag Explosion öffnen". Braucht ein Extension-Target und damit einen Xcode-Projektpfad; erst entscheiden, ob das mit dem headless-Build vereinbar bleibt. | groß | ⏸ |

## Vorgehen

- Pakete einer Welle laufen parallel in getrennten Git-Worktrees auf
  Zweigen `wp/apN-<kurzname>`; je Worktree ein Bearbeiter. Zusammenführung
  nach `main` nacheinander, pro Paket ein Versionsschritt (Minor bei neuer
  Funktion) und ein CHANGELOG-Eintrag.
- Vor dem Merge: `swift test` (Root) und `swift test` in `App/` grün,
  `build.sh` baut das Bundle.
- Erkenntnisse (Format-Fallen, Tool-Quirks) nach `knowledge/` mit Zeile in
  `knowledge/INDEX.md`.
