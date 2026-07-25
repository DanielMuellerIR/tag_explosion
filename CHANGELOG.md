# Changelog

Produktgeschichte von Tag Explosion. Format nach
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/), Versionierung nach
[Semantic Versioning](https://semver.org/lang/de/).

Diese Datei beginnt mit 0.16.0. Die Entwicklungsschritte davor stehen in den
Meilensteinen in [docs/PLAN.md](docs/PLAN.md); die ausführliche Begründung
jeder Entscheidung steht im jeweiligen Commit.

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
