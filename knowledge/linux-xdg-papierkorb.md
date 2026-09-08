# Linux: Papierkorb nach XDG, Linux-Build und Linux-CI

Konsultieren bei Arbeit an `XDGTrash`, am Linux-Job in
`.github/workflows/tests.yml`, an `scripts/linux-deps.sh` oder wenn Core/CLI
unter Linux nicht bauen. Stand: 0.39.0 (2026-09-03, AP16).

## Papierkorb nach freedesktop-Spezifikation

Linux hat keinen Systemaufruf für den Papierkorb; er ist eine Verzeichnis-
Konvention, die Nautilus, Nemo, Dolphin, Thunar und `gio trash` teilen
(https://specifications.freedesktop.org/trash-spec/latest/). `XDGTrash`
(`Sources/TagExplosionCore/XDGTrash.swift`) setzt sie so um:

- **Home-Papierkorb** `$XDG_DATA_HOME/Trash` (Standard `~/.local/share/Trash`)
  mit `files/<Name>` und `info/<Name>.trashinfo`. Gilt für alles auf demselben
  Datenträger wie das Datenverzeichnis (Vergleich der Gerätenummern `st_dev`
  über `attributesOfItem[.systemNumber]`, das gibt es auf beiden Plattformen).
- **Datenträger-Papierkorb** für andere Platten: erst `<Einhängepunkt>/.Trash`
  (muss Verzeichnis sein, kein Symlink, Sticky-Bit gesetzt) → darin `<uid>/`;
  sonst `<Einhängepunkt>/.Trash-<uid>` selbst anlegen. Der Einhängepunkt ist
  der oberste Vorfahr mit derselben Gerätenummer (`XDGTrash.mountPoint`);
  Linux-Foundation kennt `volumeURLKey` nicht.
- **Kein Ausweichen auf den Home-Papierkorb**, wenn der Datenträger keinen
  Papierkorb erlaubt: Das kopierte quer über Datenträger und könnte die
  Systemplatte unbemerkt füllen — derselbe Grundsatz wie beim macOS-Weg.
  Dann wirft `backUp`, und der Nutzer entscheidet (`--no-backup`).
- **Persönliche Papierkorb-Verzeichnisse prüfen:** Wurzel, `files` und `info`
  müssen echte Verzeichnisse des Benutzers sein und dürfen keine Schreibrechte
  für Gruppe oder andere Benutzer haben. Vorhandene Symlinks oder unsichere
  Verzeichnisse werden abgelehnt, nicht umgebogen oder umberechtigt. Neue
  Verzeichnisse entstehen mit 0700. Diese zusätzliche Schutzregel kann einen
  XDG-Papierkorb auf Dateisystemen ohne passende Rechteverwaltung ablehnen.
- **Verknüpftes Datenverzeichnis:** Die Datenträgerwahl prüft das aufgelöste
  Ziel von `XDG_DATA_HOME`, nicht die Gerätenummer des Symlinks. Relative
  Umgebungswerte werden gemäß der
  [Basisverzeichnisspezifikation](https://specifications.freedesktop.org/basedir/0.8/)
  ignoriert; sie dürfen keinen Papierkorb im Arbeitsverzeichnis erzeugen.
- **`.trashinfo`**: `Path=` prozent-kodiert (nur ASCII-Buchstaben, Ziffern,
  `-._~/` bleiben roh; Leerzeichen, Klammern, Umlaute werden UTF-8-byteweise
  kodiert), beim Datenträger-Papierkorb **relativ zum Einhängepunkt**;
  `DeletionDate=` in Ortszeit ohne Zone (`yyyy-MM-dd'T'HH:mm:ss`).
- **Namen reservieren**: Die `.trashinfo` entsteht zuerst mit `O_EXCL`; ist
  der Name belegt, folgt „Name (2)", „Name (3)" … So können zwei Prozesse
  nicht denselben Eintrag anlegen.
- **Ordner statt Datei**: `TrashBackup` legt wie unter macOS pro Sitzung und
  Datenträger einen Ordner im Papierkorb an und befüllt ihn danach direkt. Als
  Herkunft (`Path`) steht der Ordner der ersten gesicherten Datei — so landet
  ein „Wiederherstellen" im Dateimanager neben der Musik statt irgendwo.
- **Tests laufen auf macOS mit**: `XDGTrash(dataHome: <Temp>)` und
  `TrashBackup(xdgTrash:)` spielen den Linux-Weg durch, der Datenträger-Fall
  über das `hdiutil`-Volume aus `TestVolume`. Falle: macOS speichert Umlaute
  zerlegt (NFD, `%CC%88`), Linux zusammengesetzt (`%C3%84`) — Erwartungen
  müssen beides zulassen.

## Linux-Foundation: was fehlt

- `URLResourceKey.volumeAvailableCapacityForImportantUsageKey` und die anderen
  Volume-Schlüssel gibt es nicht → `VolumeSpace.availableBytes` nutzt dort
  `FileManager.attributesOfFileSystem(forPath:)[.systemFreeSize]` (statvfs).
- `volumeSupportsFileCloningKey` fehlt ebenfalls; Kopien kosten unter Linux
  immer vollen Platz (`supportsCloning` liefert `false`).
- `clonefile` ist Darwin-only; `TrashBackup.clone` fällt auf `copyItem` zurück.
- **`String.data(using: .isoLatin1)` liefert nil, sobald der Text CRLF
  enthält** (swift-corelibs, Swift 6.0; `"a\r\nb"` → nil, `"Grüße"` → ok).
  Betroffen waren Untertitel- und NFO-Schreibwege. `String.encoded(as:)`
  (`TextEncoding.swift`) geht über `NSString.data(using:)`, das auf beiden
  Plattformen korrekt kodiert. Neue Legacy-Kodierungsstellen nutzen den Helfer.
- `String(data:encoding: .isoLatin1)` hat dieselbe CRLF-Lücke wie das
  Kodieren → `String.decoded(_:as:)` (NSString-Weg), benutzt in
  `SubtitleFile`, `KodiNFOFile` und dem MacRoman-Fallback in `MediaInfoReader`.
- `FileManager.replaceItemAt` wirft unter Linux immer „file doesn't exist"
  (corelibs). Produktion nutzt es nicht (`AtomicFileRewrite` geht über
  `rename`); die Tests, die eine fremde Ersetzung simulieren, gehen über
  `TestFiles.replaceAtomically` (Darwin: `replaceItemAt`, sonst `rename(2)`).
- CryptoKit fehlt → `PortableSHA256` (reines Swift, FIPS 180-4) liefert dem
  Journal dieselbe Prüfsumme; Test vergleicht mit bekannten Vektoren und
  unter macOS mit CryptoKit.
- `XMLElement.attribute(forName:)` findet unter FoundationXML Attribute eines
  Elements mit Standard-Namespace nicht (nil); `attributes?.first { $0.name
  == … }` funktioniert überall.
- ImageIO (Cover verkleinern/wandeln) und CoreGraphics (Rechnung aus PDF)
  gibt es nur auf Apple-Plattformen. `CoverTools.isConversionAvailable` und
  `EInvoiceReader.isPDFExtractionAvailable` sagen es an; die betroffenen Tests
  überspringen sich damit sichtbar statt rot zu werden.
- **Tests nie als root laufen lassen:** root ignoriert Dateirechte, damit
  scheitern die Schreibschutz-Tests („Schreibgeschützter Ordner bricht ab").
  Im Container deshalb `docker exec --user 1000:1000 -e HOME=/tmp/h …`
  (SwiftPM-Cache und `.gitconfig` dorthin kopieren, `.build` chownen).
- **mediainfo ersetzt ohne UTF-8-Locale jeden Umlaut durch „?"** — schon
  in seiner Textausgabe, also unrettbar für den JSON-Leser. Docker-Container
  und CI-Jobs haben oft `LANG` leer. `MediaInfoReader.utf8Environment()`
  gibt `LC_ALL=C.UTF-8` mit, wenn keine UTF-8-Locale gesetzt ist.
- Foundations JSON-Fehlertext nennt unter Linux keine Zeilennummer;
  `TagRulesError.invalidJSON(line:)` bleibt dort nil (Test erlaubt es).
- **Fixture-Skripte müssen mit GNU sed laufen:** `sed -i ''` ist BSD-Syntax;
  GNU sed liest das leere Argument als Skript und die Regel als Dateinamen
  („can't read /…/d"). Portabel ist nur `sed … "$f" > "$f.tmp" && mv`.
  Im Docker-Lauf fiel das nicht auf, weil `rsync` die auf dem Mac erzeugten
  Fixtures mitspiegelte — beim Linux-Lauf deshalb `Fixtures/generated`
  ausschließen oder vorher löschen, damit das Skript wirklich dort läuft.
- `XMLDocument` liegt unter Linux im Modul `FoundationXML` (in jeder Datei
  `#if canImport(FoundationXML) import FoundationXML #endif`).
- Swift 6.0 (Linux-CI) ist strenger als das lokale Xcode-Swift: `#expect(a ==
  (try f()))` kompiliert dort nicht („call can throw … non-throwing
  autoclosure"), und lange `compactMap`/`filter`-Ketten kippen ins
  „unable to type-check". `try` vor `#expect` hochziehen, Ketten aufteilen.

## TagLib 2 aus dem Quelltext

Ubuntu 24.04 liefert `libtag1-dev` = TagLib 1.13; der Shim braucht die
TagLib-2-API (komplexe Properties, MP4-/Matroska-Kapitel ab 2.3).
`scripts/linux-deps.sh` baut deshalb TagLib 2.3.1 (Version und SHA-256 aus der
Homebrew-Formel gepinnt) mit `-DBUILD_BINDINGS=ON` (liefert `taglib_c.pc` für
SwiftPM) nach `/usr/local` und ruft `ldconfig`. Pakete dazu: `cmake`,
`build-essential`, `pkg-config`, `zlib1g-dev`, `libutfcpp-dev`. Dasselbe
Skript läuft im CI-Job und im lokalen Container.

## Lokaler Linux-Lauf in Docker

Ein Archiv des zu prüfenden Commits enthält weder lokale Buildartefakte noch
bereits auf macOS generierte Fixtures. Abhängigkeiten werden im Container
installiert; die Tests laufen anschließend mit einem eigenen Benutzer.
`--init` sorgt dafür, dass beendete Nachkommen aufgeräumt werden. Ohne diese
Prozessbereinigung kann der Abbruchtest noch eine Zombie-Prozesskennung sehen.

```bash
git archive --format=tar HEAD > /tmp/tagx-source.tar
docker run --init --rm --cpus=2 --memory=6g -i swift:6.0 bash -c '
  set -eu
  mkdir /work
  tar -x -C /work
  cd /work
  TAGX_BUILD_JOBS=2 ./scripts/linux-deps.sh
  useradd --create-home --uid 10001 tagxqa
  chown -R tagxqa:tagxqa /work
  runuser -u tagxqa -- swift test -j 2
' < /tmp/tagx-source.tar
```

Der Container benötigt keinen beschreibbaren Bind-Mount. Seine Dateien
verschwinden mit `--rm`; das lokale Quellarchiv kann danach entfernt werden.
Für uncommittierte Änderungen muss das Archiv vor dem Lauf gezielt ergänzt
werden; der Prüfbericht nennt dann diesen abweichenden Stand.

`scripts/linux-deps.sh` installiert auch `zip`: Ohne das Werkzeug erzeugt der
Fixture-Generator keine EPUB-, Office- und Comic-Archive. Ein vollständiger
Linux-Lauf vom 2026-09-08 machte diese zuvor implizite Abhängigkeit sichtbar.
`TAGX_BUILD_JOBS` begrenzt den TagLib-Build; `swift test -j` begrenzt SwiftPM.

Validierung am 2026-09-08: 469 Linux-Tests bestanden in 19,920 Sekunden
reiner Testzeit (Swift 6.0, Container mit zwei CPU-Kernen, eigener Benutzer,
frisch erzeugte Fixtures). Geprüft wurde 0.46.13 samt Änderungen am Linux-
Abhängigkeitsskript. Der erste Kontrolllauf zeigte fehlende Archiv-Fixtures
wegen `zip` sowie die genannten Root-/Prozessbereinigungsfehler; der korrigierte
Lauf hatte keine Fehler. Beide Container wurden automatisch entfernt.

Die CI benötigt keinen separaten `swift build` vor `swift test`: Das Testziel
hängt ausdrücklich vom CLI-Produkt ab. Der macOS-Plist-Test baut weiterhin ein
echtes Bundle, verwendet dafür aber `--debug`; die Feed-URL-Prüfung hängt nicht
von der Optimierungsstufe ab. Lokal sanken seine beiden Buildzeiten von
38,15 + 33,21 auf 0,20 + 2,83 Sekunden. Release-Signierung und Mindestversion
prüfen weiterhin ihre eigenen Skripttests und der Release-Ablauf.

Erneute Validierung am 2026-09-08: Der unveränderte Commit `499d7bd`
(0.46.25) bestand 477 Tests in 22,166 Sekunden reiner Testzeit unter
Swift 6.0. Wieder mit zwei CPU-Kernen, eigenem Benutzer und frisch erzeugten
Fixtures; Exit-Code 0, Container automatisch entfernt.
