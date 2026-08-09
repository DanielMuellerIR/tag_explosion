# Changelog

Produktgeschichte von Tag Explosion. Format nach
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/), Versionierung nach
[Semantic Versioning](https://semver.org/lang/de/).

Diese Datei beginnt mit 0.16.0. Die Entwicklungsschritte davor stehen in den
Meilensteinen in [docs/PLAN.md](docs/PLAN.md); die ausführliche Begründung
jeder Entscheidung steht im jeweiligen Commit.

## [0.20.1] — 2026-08-10

Alle Punkte dieser Version stammen aus dem Code-Review vom 2026-08-09.

### Geändert

- Audio-, Bild- und E-Book-Leser verwenden denselben Schnappschussvertrag:
  Inhalt und Datei-Stempel werden vor und nach allen zusammengehörigen Reads
  geprüft. Bei E-Books gehören Felder und Cover zu einem gemeinsamen Stand;
  auch ein vermeintlicher No-op wird vor der Erfolgsmeldung erneut geprüft.
- Die Dokumentation beschreibt jetzt korrekt, dass auch exiftool ausschließlich
  eine Geschwisterkopie innerhalb von `AtomicFileRewrite` verändert. Ein
  zweiter Hardlink bleibt beim atomaren Austausch bewusst auf der alten
  Fassung; behoben wurde die zuvor unerkannte Ersetzung am selben Pfad.

### Behoben

- Archivimporte erfassen Zielpfad, Dateiidentität und Stempel gemeinsam in der
  Vorprüfung und tragen genau diesen Stand bis zum Read, No-op oder atomaren
  Austausch. Eine neue Inode gilt niemals allein wegen desselben Pfads als die
  zuvor geprüfte Datei.
- `tagx exif set` und `tagx ebook set` reichen den gelesenen Stempel bis in den
  atomaren Schreibweg weiter. Fremde Änderungen nach dem Lesen werden weder
  überschrieben noch fälschlich als „No changes" bestätigt.
- E-Book-Backups können Felder und Cover nicht mehr aus zwei nacheinander am
  selben Pfad gesehenen Dateifassungen mischen.
- EPUB-Cover-IDs werden gegen alle IDs des OPF-Dokuments gewählt, nicht nur
  gegen Manifest-IDs.
- Der Installer entfernt ein bei der Endprüfung abgelehntes Bundle auch bei
  einer Erstinstallation. Bei Updates bleibt die gute alte Fassung erhalten,
  falls schon das Zurückholen fehlschlägt.

## [0.20.0] — 2026-08-07

Alle Punkte dieser Version stammen aus dem Code-Review vom 2026-08-06.

### Geändert

- Bild-Metadaten schreibt exiftool nicht mehr direkt in die Originaldatei,
  sondern in eine Geschwisterkopie; erst nach der Prüfung ersetzt sie das
  Original in einem atomaren Schritt, und der Datei-Stempel wird unmittelbar
  davor noch einmal verglichen. Eine fremde Änderung während des
  exiftool-Laufs kann so nicht mehr still verworfen werden. Nebenwirkung wie
  schon bei Audio: Die Datei bekommt eine neue Inode, zusätzliche Hardlinks
  zeigen danach weiter auf den alten Stand.
- `tagx set` bricht mit einer Fehlermeldung ab, wenn ein anderes Programm die
  Datei zwischen Lesen und Schreiben verändert hat — auch dann, wenn sich aus
  Sicht des gelesenen Standes gar nichts ändern müsste. Vorher meldete der
  Befehl in diesem Fall „0 field(s) changed" und Erfolg, obwohl der gewünschte
  Wert nicht in der Datei stand.

### Behoben

- Die Rückfrage „Datei wurde außerhalb geändert" führt genau die angeklickte
  Entscheidung aus. Vorher räumte das Schließen des Dialogs die bestätigte
  Datei aus der Warteschlange: Sie wurde nicht gespeichert, und die Bestätigung
  traf stattdessen die nächste Datei ohne deren eigene Rückfrage.
- Archiv-Import: Jedes Ziel wird unmittelbar vor seiner Änderung erneut auf
  Dateiidentität geprüft. Wird eine noch nicht bearbeitete Datei während des
  laufenden Imports durch eine Verknüpfung auf eine andere Datei ersetzt,
  bleibt diese unangetastet; der Eintrag erscheint als fehlgeschlagen. Der beim
  Lesen erhobene Stempel wandert außerdem bis in den Schreibvorgang.
- Tag-Export und Tag-Sicherung erzeugen kein Archiv mehr, das der eigene Import
  später ablehnen würde (etwa eine Bildbewertung außerhalb von -1 bis 5). Eine
  solche Sicherung ließe sich nicht wiederherstellen.
- EPUB: Die id einer neu geschriebenen Serie weicht allen im OPF vergebenen ids
  aus, nicht nur denen der `<meta>`-Elemente. Vorher konnte eine doppelte
  XML-ID entstehen und die zugehörigen `refines`-Verweise mehrdeutig machen.
- E-Book-Schreibweg: Innerhalb der Geschwisterkopie entsteht keine zweite
  Vollkopie mehr, und Fehlermeldungen nennen die gewählte Datei statt des
  versteckten Zwischenpfads.
- Eine Videodatei, die zwischen Auswahl und Lesen verschwindet, landet nicht
  mehr als schreibgeschützter Platzhalter in der Liste.
- `install.sh` stellt die bisherige Installation wieder her, wenn der Austausch
  abgebrochen wird oder die abschließende Prüfung des installierten Bundles
  fehlschlägt. Vorher konnte `/Applications/TagExplosion.app` ganz verschwinden
  oder ein abgelehntes Bundle stehen bleiben.
- `build.sh --debug` behält seine Debug-Symbole; gestrippt wird nur noch der
  Release-Build.
- Die CLI-Tests erzeugen ihre Audio-Fixture selbst. Ein gefilterter Testlauf
  auf einem frischen Checkout scheiterte vorher am fehlenden `sample.mp3`.

## [0.19.0] — 2026-08-03

### Behoben

- Dateisicherheit: Der beim Lesen erhobene Datei-Stempel wird jetzt bis
  unmittelbar vor den atomaren Austausch mitgeführt und dort erneut geprüft.
  Ändert ein anderes Programm die Datei währenddessen, bricht das Speichern ab,
  statt die fremde Änderung zu verwerfen. Der Stempel enthält zusätzlich die
  Dateikennung, damit auch eine gleich große Ersetzung mit erhaltener
  Änderungszeit auffällt.
- Die App liest Inhalt und Stempel als einen zusammengehörigen Schnappschuss.
  Vorher konnten alte Daten mit dem Stempel einer neueren, fremden Dateiversion
  zusammenkommen — das nächste Speichern hätte diese Version ungefragt
  überschrieben.
- Beim Speichern mehrerer Dateien bekommt jede Datei mit fremder Änderung ihre
  eigene Rückfrage. Vorher überschrieb ein zweiter Konflikt den ersten: Der
  Dialog gehörte dann zur falschen Datei.
- EPUB: Eine Autorenänderung löscht keine Mitwirkenden mit anderer Rolle
  (Herausgeber, Übersetzer) mehr, und eine Serienänderung lässt unabhängige
  Sammlungen des Buchs stehen. Platzmangel wird wieder als solcher gemeldet.
- Archiv-Import: Wird ein freigegebenes Ziel nach der Anzeige durch eine
  Verknüpfung auf eine andere Datei ersetzt, bricht der Import ab.
  Bildbewertungen außerhalb von -1 bis 5 und Serienangaben für PDF werden vor
  jeder Änderung abgelehnt. Zwei Sicherungen desselben Ordners innerhalb einer
  Sekunde überschreiben sich nicht mehr.
- Papierkorb-Sicherung: parallele Sicherungen laufen serialisiert, ein
  gemerkter Stand gilt nur solange seine Kopie wirklich existiert, und ein
  Stapel wird vor der ersten Kopie im Ganzen gegen den freien Platz geprüft.
  Auf Nicht-APFS-Datenträgern schlägt die Platzprüfung nicht mehr grundlos fehl.
- `tagx set` schreibt nur noch, wenn sich wirklich etwas ändert, und meldet die
  echte Zahl geänderter Felder.
- `./install.sh` beendet eine laufende App nur noch regulär und bricht ab, wenn
  sie nicht beendet wird; ungesicherte Änderungen gehen dadurch nicht mehr
  verloren. Das neue Bundle wird erst vollständig geprüft und dann eingesetzt —
  eine fehlgeschlagene Aktualisierung lässt die alte Installation stehen.

### Geändert

- Die in-place arbeitenden Backend-Methoden von `TagFile` und `EbookTool` sind
  nicht mehr Teil der öffentlichen Core-Schnittstelle. Schreiben läuft von außen
  ausschließlich über den abgesicherten Transaktionsweg.
- `THIRD-PARTY-NOTICES.md` und die READMEs beschreiben jetzt genau, was beim
  Bündeln an TagLib und Sparkle verändert wird (Install-Namen, entfernter
  `XPCServices`-Ordner, Neusignierung) statt sie pauschal „unverändert" zu
  nennen.

## [0.18.0] — 2026-07-29

### Hinzugefügt

- Fehlen `mediainfo` oder `exiftool`, bietet die App bei jedem Start an, die
  fehlenden Formeln über Homebrew zu installieren (mit Fortschrittsanzeige und
  ehrlicher Fehlermeldung); ohne Homebrew verweist sie auf brew.sh. „Später"
  verschiebt auf den nächsten Start, „Nicht mehr fragen" beendet das Angebot
  dauerhaft. Calibre bleibt bewusst außen vor (optionales Extra, Cask statt
  Formel).

## [0.17.3] — 2026-07-25

### Geändert

- `docs/sparkle-release.md` um die beiden Stolpersteine des ersten echten
  Release-Laufs ergänzt: Die Umgebung `github-pages` muss neben `main` auch
  Tags (`v*`) zum Deployment zulassen, sonst lehnt sie den vom Release
  ausgelösten Lauf ab; und `sign_update --verify` braucht `--account`, um den
  Feed gegen das DMG zu prüfen.

## [0.17.2] — 2026-07-25

### Hinzugefügt

- Social-Preview-Bild für GitHub (`docs/social-preview.png`) samt
  reproduzierbarem Generator `scripts/gen-social-preview.py`.

### Geändert

- `docs/sparkle-release.md`: genaue Befehle für den Export des
  Sparkle-Schlüssels (mit `--account`, ohne ihn je auf stdout zu zeigen), der
  Release-Ablauf verweist jetzt auf `release.sh`, und es steht dort, warum
  dieses Projekt seinen eigenen Schlüssel behält, obwohl Sparkle einen
  Schlüssel für beliebig viele Apps erlaubt: Jede bereits verteilte Fassung
  akzeptiert nur Updates, die zu ihrem eingebauten `SUPublicEDKey` passen.

## [0.17.1] — 2026-07-25

### Behoben

- Die Bildvorschau ließ ein `NSImage` aus einem Hintergrund-Task auf den
  MainActor wandern. Mit älteren Swift-6-Toolchains als der lokalen ist das ein
  Übersetzungsfehler — gefunden vom ersten CI-Lauf auf GitHub. Gelesen werden
  jetzt die Bytes, das Bild entsteht auf dem MainActor.

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
