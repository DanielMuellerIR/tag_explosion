# Tag Explosion

Native macOS-App zum Anzeigen und Bearbeiten von Medien-Metadaten — schick,
schnell und Apple-like. Anzeigen kann sie (fast) alles, was `mediainfo` kennt;
bearbeiten kann sie Audio-Tags inkl. Coverbilder wie kid3 (mp3/ID3, m4a/m4b,
flac, ogg, opus, wav, aiff …). Bilder (EXIF/IPTC/XMP) und Video folgen.

**Status:** frühe Entwicklung.

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
