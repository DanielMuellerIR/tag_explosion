# Tag Explosion

Native macOS-App zum Anzeigen und Bearbeiten von Medien-Metadaten — schick,
schnell und Apple-like.

- **Audio** (mp3/ID3, m4a/m4b, flac, ogg, opus, wav, aiff, wavpack …):
  alle Tag-Felder inkl. Custom-Keys, Coverbilder, Batch-Bearbeitung
  (gemeinsame Felder, Tracks nummerieren, Titel aus Dateinamen, Cover für alle).
- **Bilder** (jpg, png, heic, tiff, webp …): EXIF/IPTC/XMP harmonisiert
  (MWG) — Titel, Beschreibung, Schlagwörter, Ersteller, Copyright, Datum,
  Bewertung, GPS; komplette Metadaten-Ansicht; Batch.
- **Video** (mp4, m4v, mkv, webm): Tags bearbeiten; alles andere read-only.
- **Technik-Panel:** vollständige `mediainfo`-Ansicht (filterbar, kopierbar)
  für jede Datei.
- **CLI `tagx`:** alles auch headless, mit JSON-Ausgabe (`tagx show --json`,
  `tagx set`, `tagx cover`, `tagx info`, `tagx exif`).

**Status:** funktionsfähige 0.x-Entwicklung (siehe [docs/PLAN.md](docs/PLAN.md)).

## Bestandteile

| Teil | Beschreibung |
|------|--------------|
| `TagExplosion.app` | SwiftUI-App (macOS) |
| `tagx` | CLI mit maschinenlesbarer Ausgabe (JSON), Linux-portabel |
| `TagExplosionCore` | Swift-Library: Tag-IO (TagLib), MediaInfo-Integration |

## Bauen

Voraussetzungen: Xcode-Toolchain, Homebrew mit `taglib`, `media-info` (zur Laufzeit),
optional `ffmpeg` (Test-Fixtures).

```sh
./build.sh          # baut tagx + TagExplosion.app
swift test          # Tests (generieren sich ihre Fixtures selbst)
```

## Lizenz

MIT (siehe [LICENSE](LICENSE)). TagLib wird als Systembibliothek dynamisch
gelinkt (LGPL/MPL); mediainfo (BSD-2) und exiftool (Artistic) werden nur als
externe Programme aufgerufen.
