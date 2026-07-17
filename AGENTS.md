# AGENTS.md — tag_explosion

## Typ & Zweck

- **Typ:** macOS-App (SwiftUI) + portabler Swift-Core + CLI
- **Zweck:** Medien-Metadaten anzeigen (alles, was mediainfo kann) und editieren
  (alles, was kid3 kann: Tags + Cover für mp3, m4a/m4b, flac, ogg, opus, wav, aiff …),
  Apple-like und schnell. Später Bilder (EXIF/IPTC/XMP) und Video.
- **Plattform:** macOS (App); Core/CLI Linux-portabel gehalten. Open Source, MIT.

## Architektur

Details in [docs/PLAN.md](docs/PLAN.md). Kurzfassung:

- `Sources/CTagShim/` — eigener C++-Shim (MIT) über System-TagLib (Homebrew/apt,
  LGPL/MPL) mit C-Schnittstelle. **Einziger** TagLib-Berührungspunkt.
- `Sources/TagExplosionCore/` — portables Swift: Datenmodell, Tag-IO über Shim,
  MediaInfo-JSON-Wrapper (Prozessaufruf). Kein AppKit/SwiftUI hier.
- `Sources/tagx/` — CLI (maschinenlesbare Ausgabe, Exit-Codes) für Headless-Betrieb
  und Tests.
- `App/` — SwiftUI-App; wird als SPM-Executable gebaut und per `build.sh` zu
  `TagExplosion.app` gebündelt (kein gepflegtes .xcodeproj; bewusst headless-baubar).

## Konventionen

- Kommentare/Doku Deutsch, Identifier Englisch, Daten ISO 8601.
- Pfade relativ, nie absolute Home-Pfade.
- `VERSION`-Datei ist Single Source of Truth (semver); bei jedem abgeschlossenen
  Schritt Bump + Commit. Gepusht wird nur zum internen Backup-Remote (siehe
  private Infra-Doku); GitHub nur auf expliziten Auftrag.
- **Keine echten Mediendateien committen** (Urheberrecht) — Test-Fixtures werden
  per `Tests/Fixtures/generate_fixtures.sh` (ffmpeg) erzeugt.
- Lizenz-Regel: Abhängigkeiten müssen MIT-kompatibel bleiben (TagLib nur dynamisch
  als Systembibliothek linken; mediainfo/exiftool nur als CLI aufrufen).

## Test

- `swift test` — Unit-/Roundtrip-Tests (Fixtures werden bei Bedarf generiert).
- Cross-Check der Schreibergebnisse: `kid3-cli` (unter macOS im Bundle
  /Applications/kid3.app/Contents/MacOS/), `mediainfo`, `ffprobe`.
- Reale lokale Testdateien nur lesend bzw. auf Kopien bearbeiten; nie committen.

## Fallen / Agent-Hinweise

- mediainfo-JSON ist nicht immer sauberes UTF-8 (Latin1-Reste in ID3) — Encoding-
  Fallback nötig (UTF-8 → MacRoman → Latin1 probieren).
- Cover können ohne MIME-Type vorliegen → aus Magic Bytes ableiten.
- TagLib `File::save()` schreibt in-place; vor Batch-Writes Backup-Option beachten.
- App läuft ohne Sandbox (externe CLI-Tools) — bei Distribution Hardened Runtime
  + Notarisierung.
- Projekt-Erkenntnisse (TagLib-Fallen, Format-Quirks) gehören nach `knowledge/`
  (eine Datei pro Problem + Zeile in `knowledge/INDEX.md`).

## Status

- In Entwicklung, siehe [docs/PLAN.md](docs/PLAN.md) Meilensteine.

## Verzeichnisstruktur

<!-- directory-structure: generated -->
- [docs/PLAN.md](docs/PLAN.md) — Architekturplan und Meilensteine
- [Sources/](Sources/) — CTagShim (C++), TagExplosionCore (Swift), tagx (CLI)
- [App/](App/) — SwiftUI-App-Quellen
- [Tests/](Tests/) — XCTest + Fixture-Generator
- [VERSION](VERSION) — semver, Quelle der Wahrheit
- [build.sh](build.sh) — baut CLI und App-Bundle
<!-- /directory-structure -->
