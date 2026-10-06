# Dokumentations- und Code-Review vom 2026-10-06

Ausgangspunkt: Commit `ee3b4f0`, Version 0.47.3. Die nachfolgend belegten
Fehler sind in 0.47.4 behoben. Dokumentation und Implementierung wurden
abgeglichen; anschließend wurde der gesamte eigene Quell- und Testcode
korrektheitsorientiert gelesen. Der abschließende Diff wurde erneut geprüft.
Es bleiben keine bestätigten, unbearbeiteten Fehler aus diesem Review.

## Abdeckung und Architektur

Die Prüfung umfasst 253 Dateien: Swift-/C-/C++-Quellen, Tests, eigene
Entwicklerwerkzeuge, Paketmanifeste und CI-Workflows. Die einzelnen Pfade und
SHA-256-Werte des geprüften Endstands stehen im Eintrag
`2026-10-06-intensive-review` in [coverage.json](../.codeqa/coverage.json).
Die gelöschte bisherige Entwurfshilfe wurde ebenfalls vor ihrer Ersetzung gelesen.

| Bereich | Dateien | Prüfung |
| --- | ---: | --- |
| Portabler Core | 61 | Formatparser, Metadaten, Prozessaufrufe, sichere Schreibwege, Archive, Online-Dienste |
| EInvoiceCore | 10 | CII/UBL, Feldzuordnung, Validierung, begrenzte PDF-Extraktion |
| TagLib-Shim und Systemmodul | 4 | Speicherbesitz, Formatfähigkeiten, Kapitel, Schichten, Lyrics, Sonderfelder |
| CLI | 18 | Argumente, Exit-Codes, Vorschau, Zielprüfung und sämtliche Schreibbefehle |
| App und Finder-Vorschau | 51 | Lade-/Speicherzustände, Formularbindungen, Stapelaktionen, Online-Freigabe, asynchrone Vorschau |
| Core-/CLI-Tests und Fixture-/Shell-Hilfen | 59 | Vollständige Lektüre; vorhandene und ergänzte Regressionen |
| App-/Vorschau-Tests | 29 | Vollständige Lektüre; Zustände, echte Dateiänderungen und native Ansichten |
| Entwicklerskripte | 14 | Prozessbesitz, Distribution, Abhängigkeiten, Test- und Bildwerkzeuge |
| Paketmanifeste, Build/Install/Release, CI | 7 | Abhängigkeiten, Mindestversion, Bündelung, Signierfolge und Prüfaufrufe |
| **Summe** | **253** | |

Zusätzlich wurden beide READMEs, `AGENTS.md`, Changelog, Lizenzhinweise,
die acht vorhandenen Markdown-Dokumente in `docs/` und die 34 Wissensdateien
gelesen. Historische Messungen und frühere Reviews bleiben als solche erhalten.
Der Stringkatalog wurde auf vollständige englische Einträge geprüft
(623 Einträge, keine fehlenden englischen Übersetzungen); das ist keine
sprachliche Einzelabnahme sämtlicher Übersetzungen.

Fremdcode, erzeugte Medien-Fixtures, Build-Ausgaben und binäre Bildressourcen
gehören nicht zur eigenen Codeabdeckung. Paketversionen, lokale Lizenztexte,
Bundle-Konfiguration und die tatsächlich verwendete portable TagLib wurden
an ihren Schnittstellen geprüft.

Das Schichtenmodell aus portablem Core, eigenständigem Rechnungsleser, CLI
und SwiftUI-App passt weiterhin. Die Dateisicherheit liegt zentral in
`AtomicFileRewrite`, Dateistempeln und Papierkorb-Sicherung. Die Reparaturen
nutzen diese Wege. Ein Architekturwechsel oder eine allgemeine Zerlegung
gewachsener Fassaden ist durch die bestätigten Fehler nicht begründet.
Die bisher getrennte Formular-Entwurfshilfe wurde durch Entwürfe im
zuständigen `FileEntry` ersetzt, damit Save, Revert und spätere Eingaben
denselben Zustand sehen.

## Dokumentationskorrekturen

- READMEs unterscheiden jetzt PDF-Metadaten, Cover und Serien sowie die
  eingeschränkte Serienfähigkeit von AZW3. Calibre ist eine optionale
  Voraussetzung für dessen Formate.
- Tag-Archive sichern die vom Modell unterstützten Metadaten. Sie sind kein
  vollständiges Rohframe- oder Dateibackup. Schema 5 ergänzt die bisher
  fehlenden Audio-Details; ältere Archive lassen diese Felder stehen.
- Angaben zu Kopier-Menüs und Technik-Panel entsprechen den tatsächlich
  vorhandenen Ansichten. CLI-Beispiele und Dateinamensmuster sind korrigiert.
- APFS-Klone garantieren weder einen kostenlosen gesamten Schreibvorgang
  noch freien Platz für geänderte Blöcke. Platzprüfung und atomarer Austausch
  gelten pro Datei; ein Stapel ist keine dateiübergreifende Transaktion.
- Die Undo-Historie dokumentiert ihre Grenze von 5000 Einträgen, mögliche
  Journalfehler und die Größenprüfung statt SHA-256 bei Dateien über 512 MiB.
- Architekturplan und Agent-Hinweise nennen die tatsächlichen Packages,
  Modelle, Fixture-Pfade und Textdekodierung. Geplante `exiftool -stay_open`-
  und ffmpeg-Remux-Wege werden nicht mehr als implementiert beschrieben.
- TagLib-Version, LGPL-Versionsangabe, ZIP-Verwendungen und Herkunft der
  deutschen Rechnungsfeldnamen sind berichtigt. Die Lizenzangabe folgt dem
  [Header der verwendeten TagLib-Version](https://github.com/taglib/taglib/blob/v2.3.2/taglib/toolkit/taglib.h).

## Behobene Codefehler und Nachweise

P1 bezeichnet hier drohenden Metadatenverlust, einen Absturz oder den Zugriff
auf ein nicht freigegebenes Ziel; P2 bezeichnet falsches Verhalten; P3 eine
Lücke der Prüfung. Die Tabelle fasst zusammenhängende Ursachen zusammen.

| Priorität | Fehler und korrigiertes Verhalten | Code und Nachweis |
| --- | --- | --- |
| P1 | Normales Tag-Speichern schrieb unveränderte Kapitel neu und entfernte unbekannte CHAP-Unterframes. Nur geänderte Kapitel werden geschrieben. | [FileEntry](../App/Sources/TagExplosionApp/FileEntry.swift); Snapshot-Test und echter App-Schreibweg erhalten einen zusätzlichen TXXX-Unterframe im CHAP. |
| P1 | Änderungen synchronisierter Lyrics übernahmen die USLT-Sprache. SYLT behält seine eigene Sprache; neu angelegte ID3-Tags akzeptieren die gewählte Sprache. | [TagFile](../Sources/TagExplosionCore/TagFile.swift), [Shim](../Sources/CTagShim/shim.cpp); getrennte Sprachen, unbekannte Sprache, neue ID3-Tags und Rücklesen geprüft. |
| P1 | Archive enthielten weder Kapitel noch SYLT und Lyrics-Sprachen. Schema 5 restauriert diese getrennt; fehlende Felder alter Schemata bleiben unverändert. | [TagArchive](../Sources/TagExplosionCore/TagArchive.swift); Export-/Restore-Roundtrip, alte Schemata und ungültiger zweiter Eintrag vor jeder Mutation geprüft. |
| P1 | Archivfreigabe und Dublettenprüfung betrachteten nur Bilder, obwohl ein XMP-Symlink auf ein anderes Schreibziel führen konnte. Tatsächliche Schreibziele und deren Zustand werden mit geprüft. | [TagArchive](../Sources/TagExplosionCore/TagArchive.swift); externe Sidecars, gemeinsame Ziele, Hardlinks, Retargeting vor/nach dem Lesen sowie No-op mit geänderter Sidecar geprüft. |
| P1 | NUL in C-String-Metadaten konnte Werte still abschneiden. Schlüssel, Werte, Bildbeschreibungen, Kapitel und SYLT werden vor dem Schreiben geprüft. | [FixedFields](../Sources/TagExplosionCore/FixedFields.swift), [TagFile](../Sources/TagExplosionCore/TagFile.swift); bytegleiches Original nach abgewiesener Änderung und CLI-Regel mit NUL geprüft. |
| P1 | Noch fokussierte Formulareingaben konnten beim Speichern fehlen; Fokusverlust konnte gemischte Stapelwerte leeren. Entwürfe gehören jetzt zur Datei und werden vor Save gemeinsam validiert. | [FileEntry](../App/Sources/TagExplosionApp/FileEntry.swift), [FixedFieldSections](../App/Sources/TagExplosionApp/FixedFieldSections.swift); echte Speicherung, ungültige Entwürfe, gemischte Werte, bewusstes Leeren, Revert und spätere Eingaben während Save geprüft. |
| P1 | XML konnte beim Bearbeiten still repariert werden oder externe Entities als leere Werte speichern. Strenge Vorprüfung und Sperre externer Deklarationen verhindern das; interne gewöhnliche Entities bleiben erhalten. Linux-spezifische DTD-Zugriffe stürzen nicht mehr ab. | [XMLTools](../Sources/TagExplosionCore/XMLTools.swift), [KodiNFOFile](../Sources/TagExplosionCore/KodiNFOFile.swift); defektes XML, mehrere Wurzeln, interne/externe Entities, Parameter-Entities, Encoding-Erhalt und DTD-Literale auf macOS und Linux geprüft. |
| P1 | Online-Cover in der CLI ersetzten sämtliche eingebetteten Bilder. Jetzt wird nur das Frontcover ersetzt oder ergänzt. | [LookupCommand](../Sources/tagx/LookupCommand.swift); bestehendes Booklet/Backcover mit und ohne vorhandenes Frontcover bleibt erhalten. |
| P1 | DMG-Aufräumen konnte ein fremdes Volume gleichen Namens aushängen. Jeder Lauf verwendet einen eindeutigen Mountpfad und behält Arbeitsdaten bei fehlgeschlagenem Aushängen. | [build.sh](../build.sh); Produktionsabschnitt mit Werkzeugattrappen für Fehler vor Mount, Attach-/Kopierfehler, TERM, Erfolg und Detach-Fehler geprüft. Finder-AppleScript kompiliert. |
| P2 | Stapelaktionen boten nicht speicherbare Felder und Cover an, auch bei read-only-Auswahl. Fähigkeiten gelten jetzt für alle gewählten Dateien und für die Aktionshandler. | [BatchEditorView](../App/Sources/TagExplosionApp/BatchEditorView.swift), [OnlineLookupSheet](../App/Sources/TagExplosionApp/OnlineLookupSheet.swift); gemischte Tracker-/Audio- und read-only-Auswahl geprüft und visuell kontrolliert. |
| P2 | Widerrufene Online-Freigabe ließ Detailergebnisse und einen folgenden Coverabruf zu. Widerruf verwirft Ergebnisse; weitere Verarbeitung prüft die aktuelle Freigabe. | [OnlineLookupDetails](../App/Sources/TagExplosionApp/OnlineLookupDetails.swift), [OnlineLookupSheet](../App/Sources/TagExplosionApp/OnlineLookupSheet.swift); gesteuerter Widerruf zwischen Detailantwort und Coverabruf. |
| P2 | Eine ältere Quick-Look-Anfrage konnte eine neuere Ansicht überschreiben. Der Controller leert die alte Ansicht und übernimmt nur die aktuelle Anfrage. | [MetadataPreviewController](../App/Sources/TagExplosionPreviewSupport/MetadataPreviewController.swift); Antworten in umgekehrter Reihenfolge, Abschlussfehler und Standardinitialisierung geprüft. |
| P2 | ZIP-Metadaten und Cover konnten unbegrenzt entpackt werden. Angekündigte und tatsächlich gelieferte Daten sind auf 16 MiB beziehungsweise 64 MiB begrenzt. | [ZipContainer](../Sources/TagExplosionCore/ZipContainer.swift); übergroße tatsächliche und manipulierte deklarierte Größe abgewiesen; bestehende große Container-Roundtrips weiterhin erfolgreich. |
| P2 | Office-Beziehungsziele mit Punktsegmenten, Prozentkodierung oder abweichender ASCII-Schreibweise wurden falsch gefunden. Paket-URIs werden normalisiert und mehrdeutige Ziele abgewiesen. | [OfficeDocumentFile](../Sources/TagExplosionCore/OfficeDocumentFile.swift); alternative Partnamen, `%20`, Unicode und Case-/Dot-Pfade geprüft. |
| P2 | EPUB 2 erhielt EPUB-3-Metadatenattribute für Serien und neue Cover. Der Schreiber verwendet jetzt die zur OPF-Version passenden Angaben. | [EpubFile](../Sources/TagExplosionCore/EpubFile.swift); EPUB-2-Serien- und Cover-Manifeste sowie EPUB-3-Roundtrips geprüft. |
| P2 | XSPF ignorierte geerbtes `xml:base`; leere Locations konnten zur Playlist selbst führen. Basen werden entlang der Vorfahren aufgelöst, leere Locations bleiben leer. | [XSPFPlaylistFile](../Sources/TagExplosionCore/XSPFPlaylistFile.swift); lokale und HTTP-Basen, Überschreibung und leere Location geprüft. |
| P2 | Calibre speicherte AZW3-Serienänderungen nicht verlässlich. UI und sämtliche Schreibwege lehnen diese vor der Mutation ab. | [EbookTool](../Sources/TagExplosionCore/EbookTool.swift); tatsächliche AZW3-Datei bleibt bei Ablehnung bytegleich; Fehlermeldungen nennen keinen falschen PDF-Bezug mehr. |
| P2 | MusicBrainz-Jahresfilter verwendeten das falsche Feld für Releases. Releases nutzen `date`, Recordings `firstreleasedate`. | [MusicBrainzClient](../Sources/TagExplosionCore/OnlineLookup/MusicBrainzClient.swift); abgefangene Such-URLs geprüft. |
| P2 | Exportierte GIF-/WebP-/BMP-Ordnercover wurden beim erneuten Laden nicht gefunden. Die Suche ergänzt diese Formate hinter der bisherigen JPEG-/PNG-Priorität. | [CoverTools](../Sources/TagExplosionCore/CoverTools.swift); Export-/Lade-Roundtrips. |
| P2 | `tagx parse` zählte Eingabeschlüssel statt tatsächlich geänderter Zielfelder. Aliase und bereits gleiche Werte zählen jetzt korrekt. | [RenameCommands](../Sources/tagx/RenameCommands.swift); Bild-, EPUB-, Dokument- und NFO-Felder, doppelte Aliase und teilweise unveränderte Werte geprüft. |
| P2 | Die portable TagLib 2.1.1 enthielt nicht die in Entwicklungsbuilds verfügbaren MP4-Kapitel- und Matroska-APIs. Der Release-Pin ist 2.3.2 für macOS 14. | [prepare-portable-taglib.sh](../scripts/prepare-portable-taglib.sh); echter Download mit SHA-256-Prüfung, Header, dylib-Abhängigkeiten, Mach-O-Mindestversion, vollständige Core-/CLI-Tests und App-/Vorschau-Build gegen 2.3.2 geprüft. |
| P2 | Sonderzeichen im Cachepfad veränderten die erzeugten pkg-config-Pfade. Sed-Ersetzung maskiert jetzt Backslash, `&` und `\|`. | [prepare-portable-taglib.sh](../scripts/prepare-portable-taglib.sh); echte synthetische Cache-Entpackung mit Leerzeichen und Sonderzeichen; Netzwerk/Prüfsumme in diesem Regressionstest ausdrücklich simuliert. |
| P2 | Die GUI-Testhilfe las und änderte ihren PID-Besitz parallel ohne Schutz. Das Set ist jetzt per Lock geschützt. | [gui-testkit.swift](../scripts/lib/gui-testkit.swift); vollständige Testhilfe kompiliert und ohne App-Start ausgeführt. |
| P3 | Ein FB2-Test hing unnötig von einer AZW3-Fixture ab; ein fehlender PDF-Test meldete ohne Prüfung Erfolg. Die Voraussetzungen sind getrennt und fehlende Fixtures werden als Skip sichtbar. | [EbookToolTests](../Tests/TagExplosionCoreTests/EbookToolTests.swift); macOS- und Linux-Läufe mit tatsächlich verfügbaren Voraussetzungen. |

Die dreizeilige Anordnung der Stapelaktionen beseitigt außerdem abgeschnittene
Beschriftungen. Der frühere Fehlermeldungszustand wird bei einer gültigen
Eingabe ohne verbleibende Änderung gelöscht. Beide Anpassungen wurden im
abschließenden App-Diff und in den betroffenen Tests geprüft.

## Ausgeführte Abschlussprüfungen

Die Zahlen sind die Meldungen der jeweiligen Swift-Testläufe; parametrisierte
Fälle und Skip-Zählung unterscheiden sich zwischen den Toolchains.

| Umgebung / Prüfung | Ergebnis |
| --- | --- |
| macOS, Swift 6.3.3, System-TagLib 2.3.1: `swift test` | 506 Core-Tests in 36 Suites und 65 CLI-Tests in 19 Suites bestanden; keine Skips |
| macOS: `swift test` in `App/` | 151 App-Tests in 27 Suites und 3 Vorschau-Tests in 2 Suites bestanden; Leistungsprüfung und opt-in-Rendering zunächst übersprungen |
| macOS: opt-in-Test `EditorRenderingTests` | 2 Tests bestanden, vier Ansichten in echten Hintergrundfenstern gerendert und visuell geprüft; Vordergrundprozess unverändert |
| Linux, Swift 6.0.3, TagLib 2.3.1, unprivilegierter Testbenutzer | Vollständiger Lauf erfolgreich; Framework meldet 565 Tests und 39 begründete Skip-Meldungen |
| macOS, tatsächliche portable TagLib 2.3.2 | Dieselben 506 Core- und 65 CLI-Tests bestanden; keine Skips |
| App und Vorschau gegen portable TagLib 2.3.2 | Beide Produkte erfolgreich gebaut und ihre Bibliotheksreferenzen geprüft |
| Debug-App-Bundle | `Tests/build-plist-tests.sh` erfolgreich, Version 0.47.4, Sparkle und Vorschau gebündelt |
| Acht Shell-Tests | Support, Bundle-Plist, Installer, Mindestversion, TagLib-Referenzen, portable Cachepfade, DMG-Besitz und Icon-Generatoren erfolgreich |
| Skriptsyntax | 23 Shell-/Python-Dateien erfolgreich geprüft |
| Echte lokale Medien auf Kopien | Zwei MP3 und eine M4A: Lesen und Titel-Schreibroundtrip mit 2.1.1/2.3.2 liefern dieselben Metadaten; Original-Hashes unverändert |

Die Linux-Skips betreffen insbesondere Apple-Frameworks, `hdiutil`, Calibre,
kid3 und ohne `sips` nicht erzeugte PDF-Fixtures. Diese Prüfwege liefen auf
macOS, soweit sie zum normalen vollständigen Testlauf gehören.
Der ausgeschaltete 1000-FLAC-Leistungstest wurde nicht zusätzlich gestartet.

## Grenzen und fortgeltende Verträge

- Die sichtbaren Editorzustände wurden nativ geprüft. Eine vollständige
  interaktive Abnahme aller Dialoge, Drag-and-drop-Wege und Sprachvarianten
  ist damit nicht behauptet.
- Quick-Look-Reihenfolge und Controllerinitialisierung sind getestet. Die
  tatsächliche Aktivierung der installierten Finder-Erweiterung wurde in
  diesem Review nicht wiederholt.
- Keine Installation, Notarisierung, Sparkle-Update-Transaktion, Veröffentlichung
  oder reale Finder-DMG-Anordnung. DMG-Besitz wurde mit kontrollierten
  Werkzeugattrappen, dessen AppleScript durch Kompilierung geprüft.
- Mach-O weist macOS 14 als Mindestversion der portablen TagLib aus. Ein
  tatsächlicher Lauf der App auf macOS 14 wurde nicht durchgeführt.
- Online-Suchparameter und Widerruf wurden mit kontrollierten Antworten
  geprüft; aktuelle Antworten sämtlicher externer Dienste wurden nicht
  umfassend live abgenommen.
- Archive sichern keine unbekannten Rohframes, zusätzlichen Lyrics-Frames,
  Tag-Layer-Versionen oder externen LRC-Sidecars. Für vollständige
  Wiederherstellung bleibt eine Dateisicherung nötig.
- XML mit externen DTDs oder Parameter-Entities wird bewusst abgewiesen;
  gewöhnliche interne General-Entities bleiben unterstützt.
- Dateiübergreifende Archivimporte und Stapelspeicherungen bleiben einzeln
  atomar. Nach einem späteren Dateifehler können frühere Dateien bereits
  erfolgreich gespeichert sein.

Die für die portable Bibliothek geprüften Versionsdaten stammen aus dem
[Homebrew-Manifest](https://formulae.brew.sh/api/formula/taglib.json);
die hinzugekommenen Format-APIs sind in der
[TagLib-Versionsgeschichte](https://taglib.org/older.html) beschrieben.
Die Linux-Reparaturen wurden zusätzlich mit den Implementierungen von
[XMLDocument](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.0-RELEASE/Sources/FoundationXML/XMLDocument.swift)
und der
[CFXML-Schnittstelle](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.0-RELEASE/Sources/_CFXMLInterface/CFXMLInterface.c)
abgeglichen und im tatsächlichen Swift-6.0-Lauf geprüft.
