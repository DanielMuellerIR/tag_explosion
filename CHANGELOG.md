# Changelog

Produktgeschichte von Tag Explosion. Format nach
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/), Versionierung nach
[Semantic Versioning](https://semver.org/lang/de/).

Diese Datei beginnt mit 0.16.0. Die Entwicklungsschritte davor stehen in den
Meilensteinen in [docs/PLAN.md](docs/PLAN.md); die ausführliche Begründung
jeder Entscheidung steht im jeweiligen Commit.

## [0.17.0] — 2026-07-25

### Hinzugefügt

- `install.sh`: baut die App als Release, signiert sie mit Developer ID und
  Hardened Runtime, notarisiert sie bei Apple, heftet das Ticket an und
  installiert sie nach `/Applications` — aber erst, nachdem Stapler,
  Gatekeeper und Signatur die Notarisierung bestätigt haben.
  `--no-notarize` baut ein schnelles Testbundle, das im Projektordner bleibt.
- `release.sh`: erzeugt das verteilbare, notarisierte DMG mit Hintergrundbild
  und Finder-Layout.
- Beide Skripte fragen einmal nach dem lokalen notarytool-Schlüsselbundprofil
  und merken sich nur dessen Namen clone-lokal. Damit laufen sie auf jedem Mac,
  ohne dass etwas Vertrauliches im Repository landet.
- `THIRD-PARTY-NOTICES.md` mit den vollständigen Lizenztexten der
  mitgelieferten und gelinkten Komponenten (TagLib, Sparkle, ZIPFoundation,
  swift-argument-parser) und der Begründung, warum die nur aufgerufenen
  Programme lizenzrechtlich nicht durchgreifen. Ersetzt `THIRD-PARTY.md` und
  liegt auch im App-Bundle.
- READMEs: App-Symbol im Kopf und ein eigener Abschnitt darüber, wie die
  Dateien geschützt werden.

### Behoben

- Die Bildvorschau ließ ein `NSImage` aus einem Hintergrund-Task auf den
  MainActor wandern. Mit älteren Swift-6-Toolchains als der lokalen ist das ein
  Übersetzungsfehler — aufgefallen im neuen CI-Lauf. Gelesen werden jetzt die
  Bytes, das Bild entsteht auf dem MainActor.
- AVI-Dateien ließen sich nicht öffnen, obwohl sie als „nur Anzeige"
  angekündigt sind: TagLib kann AVI nicht lesen, und der Read-only-Fallback
  griff nur beim Öffnen, nicht beim Neuladen. Er liegt jetzt an einer Stelle
  für alle Lesewege. Eine wirklich kaputte Audiodatei meldet dagegen weiterhin
  einen Fehler, statt einen leeren Editor zu zeigen.

## [0.16.1] — 2026-07-25

### Behoben

- Eine Datei aus dem Finder zu öffnen („Öffnen mit …", Ziehen aufs
  Dock-Symbol, `open -a`) funktionierte nicht, wenn die App dabei startete:
  Sie lief unsichtbar ohne Fenster weiter und lud die Datei nie. Beim Start
  mit einer Datei legt SwiftUI kein Fenster an, und macOS liefert das
  Öffnen-Ereignis nur an ein vorhandenes Fenster aus. Die App sorgt jetzt
  selbst dafür, dass ein Fenster erscheint, und nimmt die Datei über den
  App-Delegate entgegen statt über SwiftUIs `onOpenURL`.

## [0.16.0] — 2026-07-25

### Hinzugefügt

- **Abgesicherter Modus** (Standard an): Vor jeder Änderung wandert eine
  unveränderte Kopie der Datei in den Papierkorb — gesammelt in einem Ordner
  je Sitzung und je Datenträger. Zum Wiederherstellen die Kopie zurückziehen,
  zum Aufräumen den Papierkorb leeren. Auf APFS entsteht die Kopie als Klon
  und belegt zunächst keinen zusätzlichen Platz. Abschaltbar in den
  Einstellungen (⌘,) sowie per `--no-backup` bzw. `TAGX_NO_BACKUP=1` in der
  CLI.
- Warnung, wenn eine geöffnete Datei zwischenzeitlich von einem anderen
  Programm geändert wurde. Gespeichert wird erst nach ausdrücklicher
  Bestätigung; der fremde Stand liegt dann als Kopie im Papierkorb.
- Prüfung des freien Speicherplatzes, bevor eine Datei geschrieben wird.
- GitHub-Actions-Workflow, der Core, CLI und App auf macOS baut und testet.

### Geändert

- Audio- und Video-Tags werden nicht mehr in-place geschrieben: Die Änderung
  entsteht an einer Geschwisterkopie, wird geprüft (Datei wieder lesbar,
  Kanäle, Samplerate und Spielzeit unverändert) und ersetzt das Original erst
  danach in einem atomaren Schritt. Ein Absturz, ein Formatfehler oder ein
  voller Datenträger kann keine halb geschriebene Datei mehr hinterlassen.
  Nebenwirkung: Die Datei bekommt dabei eine neue Inode, zusätzliche Hardlinks
  zeigen danach weiter auf den alten Stand.
- Dateipfade gehen immer absolut an mediainfo, exiftool und `ebook-meta`,
  damit ein Dateiname mit führendem Bindestrich nicht als Option gelesen wird.

### Behoben

- Die Prüfung auf fremde Änderungen war wirkungslos, weil `URL.resourceValues`
  einmal gelesene Werte zwischenspeichert. Sie liest den Dateizustand jetzt
  ungepuffert.
