# Tag Explosion — Architekturplan

Stand: 2026-07-17. Dieses Dokument beschreibt den Plan; Abweichungen werden hier nachgezogen.

## Ziel

Native macOS-App zum Anzeigen und Bearbeiten von Medien-Metadaten:

- **Anzeigen**: alles, was `mediainfo` ausgeben kann (technische Details aller Container/Codecs).
- **Bearbeiten**: alles, was kid3 kann (Tags inkl. Coverbilder für mp3/ID3, m4a/m4b/MP4,
  ogg/Vorbis, opus, flac, wav, aiff, ape, wavpack, dsf …) — aber schick, modern, Apple-like.
- **Prioritäten**: 1. Audio (Einzeldatei), 2. Batch, 3. Bilder (EXIF/IPTC/XMP), 4. Video (nice-to-have).
- Open Source, MIT. GUI Swift-nativ (SwiftUI), Core Linux-portabel.

## Architektur

Drei Schichten, ein Swift-Package-Monorepo:

```
┌─────────────────────────────────────────────┐
│ TagExplosion.app   (SwiftUI, nur macOS)     │
├─────────────────────────────────────────────┤
│ tagx               (CLI, portabel)          │  ← headless Testbarkeit, Batch-Skripting
├─────────────────────────────────────────────┤
│ TagExplosionCore   (Swift-Library, portabel)│  ← Datenmodell, Lesen/Schreiben, Fassade
├─────────────────────────────────────────────┤
│ CTagShim           (C++→C-Shim über TagLib) │  ← einziger TagLib-Berührungspunkt
└─────────────────────────────────────────────┘
```

### Warum TagLib (2.3, Homebrew/apt) + eigener Shim?

- TagLib ist die Referenz fürs *Schreiben* von Audio-Tags (kid3 nutzt es selbst),
  battle-tested, C++, läuft auf macOS und Linux. Lizenz LGPL-2.1 **oder MPL-1.1**
  → als dynamisch gelinkte Systembibliothek problemlos mit MIT kompatibel.
- Die mitgelieferte C-API (`tag_c.h`) ist zu schmal (keine Kapitel, kein Frame-Zugriff).
  Deshalb eigener **MIT-lizenzierter C++-Shim** mit schlanker C-Schnittstelle,
  die Swift direkt importieren kann. Der Shim kapselt:
  - PropertyMap (alle Textfelder, beliebige Schlüssel) lesen/schreiben
  - Komplexe Properties (PICTURE = Cover, mehrere pro Datei) lesen/schreiben
  - AudioProperties (Dauer, Bitrate, Samplerate, Kanäle, Encoding-Details)
  - später: ID3v2-Frame-Details, Kapitel (CHAP/CTOC), MP4-Spezialatome
- Kein Swift-C++-Interop direkt gegen TagLib: zu fragil über TagLib-Versionen,
  C-Grenze ist stabil und Linux-tauglich.

### Anzeigen: MediaInfo

- `mediainfo --Output=JSON` (BSD-2-Lizenz, CLI vorhanden auf Mac & Linux) liefert die
  vollständige technische Ansicht. Wrapper in `TagExplosionCore` (Prozessaufruf, JSON-Decode).
  Kein Linken gegen libmediainfo nötig → einfach, robust, lizenzsauber.
- TagLib bleibt die Quelle der Wahrheit fürs *Editieren*; MediaInfo ist read-only-Panel.

### Bilder (Phase 3): exiftool

- exiftool (Perl, Artistic License, CLI) ist der De-facto-Standard für EXIF/IPTC/XMP
  lesen **und schreiben**. Wrapper analog MediaInfo (`exiftool -j`, `-stay_open` für Batch-Performance).
- Anzeige-Vorschau über native ImageIO im App-Layer (nicht im portablen Core).

### Video (Phase 4)

- Anzeige über MediaInfo (kommt gratis mit). Bearbeitung: TagLib 2.3 kann MP4 und
  inzwischen Matroska-Tags; ffmpeg als Fallback für Remux-Fälle. Genauer Umfang offen.

## Datenmodell (Core)

- `MediaFile`: URL, Formatinfo, `[TagField]`, `[Artwork]`, `AudioInfo`, Dirty-State.
- `TagField`: Schlüssel (normalisiert, z.B. `ARTIST`) + Werte (mehrwertig) + Herkunft.
  Bekannte Schlüssel bekommen Anzeige-Metadaten (deutscher Label, Reihenfolge, Editor-Typ),
  unbekannte werden generisch angezeigt (nichts verstecken!).
- `Artwork`: Daten, MIME (kann fehlen → aus Magic Bytes ableiten), Bildtyp (Front/Back/…), Beschreibung.
- Schreiben ist **atomar pro Datei** über TagLib `File::save()`; vorher optionales Backup.

## GUI (Phase 1, Haupt-Prio)

- SwiftUI, `NavigationSplitView`: links Datei-/Ordnerliste, Mitte/rechts Editor + Info.
- Einzeldatei: großes Cover (Austausch per Drag&Drop/Dateidialog), Kernfelder prominent
  (Titel, Künstler, Album, …), alle weiteren Felder in gruppierter, durchsuchbarer Liste,
  MediaInfo-Rohansicht als eigener Tab (durchsuchbar, kopierbar).
- Öffnen: Drag&Drop aufs Fenster/Dock, ⌘O, Ordner rekursiv.
- Änderungen gepuffert, expliziter Speichern-Schritt (⌘S), Dirty-Indikator, Undo.
- Performance: Verzeichnis-Scan und Tag-Reads nebenläufig (Swift Concurrency), UI bleibt flüssig.

## Build & Projektstruktur

```
tag_explosion/
├── Package.swift          # SPM: CTagShim, TagExplosionCore, tagx, Tests
├── Sources/
│   ├── CTagShim/          # C++-Shim (include/ + shim.cpp), linkt libtag
│   ├── TagExplosionCore/  # portables Swift
│   └── tagx/              # CLI (swift-argument-parser)
├── App/                   # SwiftUI-App (Xcode-Projekt oder xcodegen — nach Recherche)
├── Tests/                 # XCTest; Fixtures werden per ffmpeg-Skript generiert
│   └── Fixtures/generate_fixtures.sh
├── docs/PLAN.md           # dieses Dokument
├── VERSION                # semver, Quelle der Wahrheit
├── AGENTS.md · README.md · LICENSE (MIT)
```

- **Keine echten Mediendateien im Repo** (Urheberrecht): Test-Fixtures werden per
  ffmpeg generiert (Sinuston, 1–2 s, alle Formate). Reale lokale Testdateien dienen
  nur lokal-manuell (read-only bzw. Kopien).
- Versionierung: `VERSION`-Datei (semver), bei jedem abgeschlossenen Schritt Bump + Commit.
- Remote: nur internes Backup-Remote. GitHub erst auf Auftrag.

## Abgleich mit kid3 (2026-07-17, kid3 3.9.6)

Kreuzkompatibilität verifiziert: kid3-geschriebene Dateien (inkl. USLT-Lyrics,
BPM) liest tagx korrekt; tagx-geschriebene Custom-/Standard-Felder liest kid3
korrekt (Custom-Keys landen als TXXX). Was kid3 kann und wir (noch) nicht:

- ID3v1/v2/APE getrennt anzeigen/bearbeiten/strippen (wir: TagLib-vereinheitlicht)
- Frame-Detailansicht (rohe ID3-Frames) und ID3v2.3-Schreiboption
- Dateiname ↔ Tag mit Format-Mustern (beide Richtungen, Umbenennen aus Tags)
- Online-Import (MusicBrainz/Discogs), Playlist-Export, Groß-/Kleinschreibungs-Werkzeuge
- Dafür haben wir: MediaInfo-Vollansicht, Bilder (EXIF/IPTC/XMP), moderne UI,
  Matroska-Tags, maschinenlesbare CLI (JSON)

## App-Icon

- Motiv: Comic-Explosions-Sprechblase mit Preisschild („M1a"), generiert mit
  MiniMax image-01 (2026-07-17; Outputs gehören laut MiniMax-Platform-ToS dem
  Nutzer — MIT-kompatibel). Quelle: `App/Resources/AppIcon-Quelle.png`.
- **Bewusst Full-Bleed** statt Apple-HIG-Raster (824/1024-Kachel): Icon füllt
  die komplette Squircle-Fläche → wirkt im Dock so groß wie Chrome/Firefox
  statt kleiner (Daniels Fastra-Feedback). Neu erzeugen:
  `swift scripts/icon-from-image.swift App/Resources/AppIcon-Quelle.png App/Resources`
- `scripts/make-icon.swift` bleibt als programmatischer Fallback erhalten.

## Backlog / Notizen

- TagLib schreibt ID3v2.4; Option für ID3v2.3 (Kompatibilität alter Player) über
  Shim-Erweiterung (`MPEG::File::save`-Overload) später anbieten.
- Kapitel (CHAP/CTOC bzw. MP4-Chapters) für Hörbücher: eigener Shim-Teil, später.
- Homebrew-ffmpeg hier ohne libvorbis — Fixtures nutzen den eingebauten
  Vorbis-Encoder (kann nur Stereo, daher `-ac 2`).
- GUI-Tests: Maus-Klicks via CGEvent funktionieren, synthetische Tastatur-Events
  erreichen SwiftUI-TextFields nicht zuverlässig → UI-Tests setzen Werte über die
  Accessibility-API (`scripts/dev-uitest.swift`) und speichern über den Menüpunkt.

## Verifikation

- Unit-Tests: Roundtrip (schreiben → lesen → vergleichen) für jedes Format; Edge-Cases
  (fehlender MIME-Type beim Cover, Latin1-Umlaute in ID3v1/v2.3, mehrwertige Felder).
- Cross-Check: `kid3-cli` (in /Applications/kid3.app) und `mediainfo` lesen unsere
  Schreibergebnisse gegen; ffprobe als dritter Zeuge.
- GUI-Tests headless soweit möglich; computer-use nur kurz und App danach ausblenden.

## Meilensteine / Versionen

| Version | Inhalt |
|---------|--------|
| 0.1.0   | Repo-Gerüst, Core liest Tags+Cover+AudioProps (mp3, m4a/m4b, flac, ogg, opus), tagx `show` — ✅ zusammen mit 0.2.0 gelandet |
| 0.2.0   | Schreiben inkl. Cover, Roundtrip-Tests grün, tagx `set`/`cover` — ✅ (kid3-cli/ffprobe-Gegenprobe ok) |
| 0.3.0   | MediaInfo-Panel-Daten, App-Gerüst mit Einzeldatei-Editor (read-only) — ✅ zusammen mit 0.4.0 |
| 0.4.0   | App editiert + speichert, Cover-Tausch, Revert — ✅ (AX-End-to-End-Test grün; echtes Undo noch offen) |
| 0.5.0   | Dateiliste/Ordner, Batch-Edit — ✅ (AX-Test über mp3/flac/m4a) |
| 0.6.0   | Bilder (exiftool, MWG-harmonisiert): Editor, Batch, tagx exif — ✅ |
| 0.7.0   | Video-Anzeige/-Tags: mp4/m4v/mkv editierbar, mov/avi read-only via mediainfo — ✅ |
| 0.9.0   | Distribution: build.sh --release (TagLib gebündelt, Developer-ID + Hardened Runtime, notariert + gestapelt) — ✅ |
