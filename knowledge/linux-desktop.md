# Linux-Desktopclient

Der Linux-Client verwendet Rust/Tauri und dieselbe Swift-Anwendungsschicht wie
macOS. [Architektur](../docs/PLAN.md), [Bau und Distribution](../docs/linux.md).

- SwiftUI/AppKit bleiben in `App/`. `TagExplosionApplication` enthält
  `AppModel`, `FileEntry`, Aktionen und Darstellungsregeln. Unter Linux brauchen
  diese Klassen keine Observation-Makros; Zustände werden über IPC angefordert.
  Swift 6.2.1 hatte beim Linux-Linken von Observation ein undefiniertes
  `swift::threading::fatal`. Keine Ersatzsymbole in die Anwendung einbauen.
- Die Engine liest stdin mit POSIX `read`: Foundation `read(upToCount:)` kann an
  einer Pipe auf das Füllen des ganzen Puffers warten. stdout ist ausschließlich
  JSONL, normale Prozessausgaben gehen nach stderr. Nachrichten sind vor dem
  vollständigen Aufbau auf 24 MiB begrenzt; Cover werden separat übertragen.
- Die gemeinsame Anwendungslogik schützt Dateimutationen und Konflikte. Ein
  kaputter Prozesskanal wird nicht blind neu gestartet: Ein unbekannter
  Speicherausgang verlangt eine Prüfung, bevor man den Auftrag wiederholt.
- QPDF liefert nur PDF-Objekte. Identität von Filespec-Dictionaries muss erhalten
  bleiben, damit dasselbe Dokument in AF und Names nicht doppelt zählt.
  Stream-Decodierung bleibt begrenzt; die Auswahlregeln stehen im gemeinsamen
  `PDFEmbeddedInvoice`-Durchlauf.
- GTK/WebKit und Grafikbibliotheken bleiben beim Zielsystem. Alte gebündelte
  GTK-/Wayland-Bibliotheken neben neuem System-WebKit führen zu ABI-Konflikten.
  Die Engine und ihre Bibliotheken erhalten deshalb einen relativen ELF-RUNPATH
  unter `usr/lib/tagx`. Kein globaler `LD_LIBRARY_PATH`: Er würde auch von
  der Engine gestartete Systemwerkzeuge mit alten Bibliotheken überlagern.
  `AppRun` verändert den Grafik-Suchpfad nicht.
- Beim Tauri-Updater muss `plugins.updater` in der Konfiguration vorhanden sein.
  Nur ein `pubkey` am Plugin-Builder verhindert die anfängliche
  Konfigurations-Deserialisierung nicht. Der öffentliche Schlüssel ist in
  `Linux/updates.pub`; `linux-version.py` überträgt ihn und `VERSION`.
- Das Paket wird nach Signaturprüfung entpackt und auf Anwendung, Version und
  Zielplattform geprüft. Anschließend wird es im Installationsverzeichnis
  vollständig geschrieben und atomar gewechselt. Die bisherige Datei bleibt
  erhalten; kein automatisches Gesund-Erkennen nach dem Neustart behaupten.
- Docker-Tests brauchen `--init`, damit verwaiste Kindprozesse geerntet werden.
  Ein als Zombie noch sichtbarer Prozess ist kein Beleg für einen fehlenden Kill.
- Die native GUI-Prüfung läuft in einer separaten virtuellen KWin-Sitzung.
  Deren D-Bus-Aktivierungsumgebung muss den eigenen Wayland-Socket erhalten;
  nicht die Umgebung des normalen Benutzer-Systemd überschreiben. Einen vom
  Document-Portal erzeugten eigenen FUSE-Mount vor dem Entfernen des temporären
  Runtime-Verzeichnisses aushängen.

- Arch installiert ExifTool unter `/usr/bin/vendor_perl/exiftool`. Eine Login-Shell
  kann diesen Ordner im `PATH` haben, die Desktop-Sitzung dagegen nicht. Der
  gemeinsame Werkzeugfinder braucht den absoluten Fallback; Installationstests
  müssen die tatsächliche Desktop-Umgebung verwenden.

- `docker run --user` allein erzeugt keinen Eintrag in `/etc/passwd`. D-Bus
  braucht diesen Eintrag auch für eine private Sitzung. Das GUI-Bild erhält
  deshalb `TAGX_UID`/`TAGX_GID` passend zum Runner; der Start wird mit einer
  vom Standard abweichenden UID separat geprüft.
