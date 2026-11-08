# Tag Explosion unter Linux

Die Linux-Oberfläche verwendet Tauri 2 und Rust. Dieselben Swift-Module wie
unter macOS lesen und schreiben die Dateien: `TagExplosionApplication`,
`TagExplosionCore`, `EInvoiceCore` und der dynamisch gelinkte TagLib-Shim.
Der lokale Prozess `tagx-engine` gehört zum Paket; Swift muss auf dem Zielsystem
nicht installiert sein. Die Oberfläche lädt keine entfernten Webseiten.

## Voraussetzungen und Installation

Das x86_64-AppImage wird auf Ubuntu 24.04 gebaut (glibc mindestens 2.39).
Linux Mint 22 und aktuelle Arch-basierte Distributionen werden unterstützt.
GTK 3, WebKitGTK 4.1, FUSE 2 und ein Secret-Service-Schlüsselbund gehören zur
Desktopumgebung. Ohne FUSE kann das AppImage mit
`--appimage-extract-and-run` gestartet werden.

MediaInfo, ExifTool, FFmpeg, ImageMagick, Chromaprint und gegebenenfalls Calibre
bleiben getrennte Systemprogramme. Sie ermöglichen technische Informationen,
Bild-/PDF-Metadaten, Cover-Konvertierung, Fingerabdrücke beziehungsweise weitere
E-Book-Formate. Die TagLib- und QPDF-Bibliotheken sowie die geprüften lokalen
Rechnungsprüfer einschließlich Java werden mitgeliefert.

Linux Mint / Ubuntu:

```sh
sudo apt install libfuse2t64 libgtk-3-0t64 libwebkit2gtk-4.1-0 \
  mediainfo libimage-exiftool-perl ffmpeg imagemagick libchromaprint-tools
# Für MOBI/AZW3/FB2 zusätzlich:
sudo apt install calibre
```

Arch-basierte Distributionen:

```sh
sudo pacman -S fuse2 gtk3 webkit2gtk-4.1 mediainfo perl-image-exiftool \
  ffmpeg imagemagick chromaprint
# Für MOBI/AZW3/FB2 zusätzlich:
sudo pacman -S calibre
```

Aus einem Linux-Release das AppImage, seine `.sig`, `install.py` und `icon.png`
in denselben Ordner laden. Die drei Quellen-ZIPs gehören ebenfalls zum Release. Das Installationsskript prüft die eingebettete
Herausgebersignatur mit OpenSSL, bevor es Dateien ersetzt:

```sh
python3 install.py TagExplosion-VERSION-x86_64.AppImage
```

Installation und Desktop-Eintrag liegen im Benutzerkonto. Es ist kein Root-Zugriff
für Installation oder Updates erforderlich. Originaldateien werden über dieselben
abgesicherten Schreibwege wie in der Mac-App bearbeitet.

## Updates und Rückkehr zur vorigen Version

Die App prüft auf Wunsch GitHub Releases. Ein Linux-Release benötigt das signierte
AppImage und `linux-updates.json`. Downloads werden vor dem Paketwechsel mit dem
fest eingebetteten Schlüssel geprüft. Die neue Datei wird im selben Verzeichnis
vollständig geschrieben und dann atomar eingesetzt. Während Dateioperationen ist
der Wechsel gesperrt. Offene Bearbeitungen bleiben bis zum regulären Beenden im
laufenden Prozess; Schließen fragt nach ungespeicherten Änderungen.

Die bisherige Datei bleibt als `TagExplosion.previous.AppImage` erhalten und kann
bei Startproblemen direkt geöffnet werden. Eine automatische Erkennung beliebiger
Startprobleme mit anschließendem Rollback findet nicht statt.

## Unterschiede zu macOS

SwiftUI, AppKit, Finder-Dienste und Sparkle sind Apple-spezifisch. Linux verwendet
eine lokale WebKit-Oberfläche, native Linux-Dateidialoge, Secret Service und den
signierten Tauri-Updatekanal. Fensterrahmen, Dateidialoge, Schriften und
Tastenkürzel folgen dem Desktop. Formulargruppen, Felder, Konfliktentscheidungen
und Dateiverarbeitung orientieren sich an der Mac-App.

PDF-Anhänge liest QPDF anstelle von CoreGraphics; Auswahl, Grenzen und
Rechnungsinterpretation bleiben im gemeinsamen Swift-Code. ImageMagick übernimmt
die Cover-Decodierung und -Konvertierung anstelle von ImageIO. Unterschiedliche
JPEG-/PNG-Encoder können trotz gleicher Bildgröße unterschiedliche Bytes erzeugen.

## Selbst bauen

```sh
./build.sh --linux --debug
./build.sh --linux
```

Docker kapselt Swift, Rust und Systembibliotheken auf Ubuntu 24.04. Der zweite
Aufruf erzeugt unter `build/linux/` das AppImage sowie die versionsgleichen
Quellen-ZIPs der Bibliotheken und beider Rechnungsprüfer. Der Lizenz-/Quellencheck ist eine Bausperre.
`./release.sh --linux` verlangt zusätzlich den eigenen
`TAURI_SIGNING_PRIVATE_KEY` oder `TAURI_SIGNING_PRIVATE_KEY_PATH` und erzeugt
Signatur, Updatefeed und Prüfsummen. Er veröffentlicht keine Dateien.

Die Browseroberfläche verwendet lokale JavaScript-Module ohne separaten
Frontend-Bundler. Übersetzungen werden aus dem gemeinsamen String-Catalog
abgeleitet. Die Versionsdatei `VERSION` wird vor dem Bau in Rust/Tauri übernommen.

Der Desktop-Nachrichtenvertrag begrenzt einzelne Nachrichten auf 24 MiB.
Neu importierte Cover sind auf 16 MiB begrenzt; diese Grenze verhindert große
Base64-Kopien in der Oberfläche. Größere Cover vorher mit ImageMagick verkleinern.
