# AGENTS.md — tag_explosion

## Typ & Zweck

- **Typ:** macOS-App (SwiftUI) + portabler Swift-Core + CLI
- **Zweck:** Medien-Metadaten anzeigen (alles, was mediainfo kann) und editieren
  (alles, was kid3 kann: Tags + Cover für mp3, m4a/m4b, flac, ogg, opus, wav, aiff …),
  Apple-like und schnell. Dazu Bilder (EXIF/IPTC/XMP via exiftool), Video und
  E-Books (EPUB nativ, PDF via exiftool, mobi/azw3/fb2 via Calibre-CLI).
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
  Schritt Bump + Commit. Standard-Remote ist das interne Backup (siehe private
  Infra-Doku); der öffentliche GitHub-Remote wird nur auf ausdrücklichen
  Auftrag bedient.
- **Keine echten Mediendateien committen** (Urheberrecht) — Test-Fixtures werden
  per `Tests/Fixtures/generate_fixtures.sh` (ffmpeg) erzeugt.
- Lizenz-Regel: Abhängigkeiten müssen MIT-kompatibel bleiben (TagLib nur dynamisch
  als Systembibliothek linken; mediainfo/exiftool nur als CLI aufrufen).

## Test

- `swift test` — Unit-/Roundtrip-/Integritätstests (Fixtures werden bei Bedarf
  generiert). Dieselben Tests laufen in `.github/workflows/tests.yml` auf macOS.
- App-Tests: `swift test` im Ordner `App/`.
- Cross-Check der Schreibergebnisse: `kid3-cli` (unter macOS im Bundle
  /Applications/kid3.app/Contents/MacOS/), `mediainfo`, `ffprobe`.
- Reale lokale Testdateien nur lesend bzw. auf Kopien bearbeiten; nie committen.

## Fallen / Agent-Hinweise

- mediainfo-JSON ist nicht immer sauberes UTF-8 (Latin1-Reste in ID3) — Encoding-
  Fallback nötig (UTF-8 → MacRoman → Latin1 probieren).
- Cover können ohne MIME-Type vorliegen → aus Magic Bytes ableiten.
- **Dateisicherheit hat Vorrang.** Jeder Schreibweg läuft über
  `AtomicFileRewrite` (Kopie → prüfen → atomar ersetzen) und ruft vorher
  `TrashBackup.shared.backUp(url)` auf. TagLib `File::save()` schreibt in-place
  und darf deshalb nie direkt auf eine Originaldatei angewendet werden.
  Fallen und Begründungen: [knowledge/dateisicherheit-schreibwege.md](knowledge/dateisicherheit-schreibwege.md).
- App läuft ohne Sandbox (externe CLI-Tools). Distribution über zwei Skripte,
  die beide das Notary-Profil über `scripts/notary-profile.sh` klären
  (`NOTARY_PROFILE`, sonst clone-lokale `git config`, sonst Abfrage):
  `./install.sh` (notarisierter Build nach `/Applications`, erst nach
  bestandener Stapler-/Gatekeeper-/Signaturprüfung) und `./release.sh`
  (verteilbares DMG mit Hintergrundbild, headless `--no-finder-layout`).
  Darunter liegt `build.sh --release [--no-dmg]`.
- Auto-Update via Sparkle (exakt gepinnt, `App/Package.swift`): build.sh bündelt
  `Sparkle.framework` immer (rpath `@loader_path/../Frameworks` — ohne Framework
  startet die App nicht) und signiert Sparkles Helfer innen→außen, nie `--deep`.
  Release-Ablauf + Schlüssel: [docs/sparkle-release.md](docs/sparkle-release.md).
  Erste Sparkle-Version muss einmal manuell installiert werden (Bootstrap).
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
- [CHANGELOG.md](CHANGELOG.md) — Produktgeschichte ab 0.16.0
- [build.sh](build.sh) — baut CLI und App-Bundle
- [install.sh](install.sh) · [release.sh](release.sh) — notarisierte Installation, verteilbares DMG
- [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) — Lizenzen der Dritt-Komponenten
- [knowledge/](knowledge/INDEX.md) — Projekt-Wissensbasis (eine Datei pro Problem)
- [scripts/](scripts/) — GUI-Selbsttests, Icon-Generator
<!-- /directory-structure -->
