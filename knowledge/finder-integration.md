# Finder-Integration ohne Xcode-Projekt

**Trigger:** Quick-Look-Vorschau, Finder-Dienst, Erweiterungsbuild oder
Signierung von `TagExplosionPreview.appex`.

Seit 0.47.0 baut das App-SwiftPM-Paket ein zusätzliches Executable mit
`-parse-as-library`, `-application-extension` und dem Foundation-Einstieg
`NSExtensionMain`. `build.sh` verpackt es als moderne `.appex` unter
`Contents/PlugIns`. Das Projekt benötigt weiterhin kein Xcode-Projekt.

## Quick Look

Die sandboxed Erweiterung liest über den bestehenden Core Tags, Audiodaten,
Kapitel und Cover für die in `App/Extensions/Preview-Info.plist` ausdrücklich
registrierten Audio-/MP4-/Matroska-Typen sowie EPUB. Sie startet keine externen
Werkzeuge und schreibt keine Dateien. Formate, die exiftool, MediaInfo oder
Calibre benötigen, behalten ihre bisherige Systemvorschau. Die Metadaten-
Vorschau ersetzt für ihre registrierten Typen die übliche Inhaltsvorschau.

Die Stammansicht des `NSViewController` muss bestehen bleiben: Der Quick-Look-
Host bettet sie vor dem asynchronen Lesen ein. Ein späterer Austausch von
`controller.view` hinterließ im echten Lauf eine leere Vorschau. Deshalb wird
nur eine gehostete SwiftUI-Ansicht in den vorhandenen Container eingefügt.
Blockierendes Lesen läuft über `BlockingWork`, die UI-Aktualisierung auf dem
MainActor. Die Datei bleibt während der Anzeige nicht geöffnet.

Die Erweiterung hat eigene TagLib-dylibs in `Contents/Frameworks`, weil ihr
`executable_path` ein anderer ist als derjenige der App. Der Release signiert
Bibliotheken, Erweiterung und App in dieser Reihenfolge. Die Prüfung auf
macOS 14 umfasst auch `Contents/PlugIns`.

## Finder-Dienst

„In Tag Explosion öffnen“ steht unter Dienste im Finder-Kontextmenü. Der Dienst
übernimmt Datei-URLs und ältere `NSFilenamesPboardType`-Listen; Text und
Netzwerk-URLs werden abgelehnt. Die vorhandene `WindowSessions`-Verwaltung
übernimmt Öffnen, Mehrfachauswahl und Kaltstart. macOS kann die Anzeige eines
Dienstes oder einer Quick-Look-Erweiterung pro Benutzer deaktivieren; die
Systemeinstellungen erlauben deren Auswahl.

Ein eigener Finder-Sync-Prozess entfällt: Apple sieht Finder Sync für
Synchronisationsordner vor, nicht als allgemeine Finder-Oberflächen-Erweiterung.
Grundlagen: [Finder Sync](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html),
[Services Properties](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html),
[QLPreviewingController](https://developer.apple.com/documentation/quicklookui/qlpreviewingcontroller).

## Prüfstand 2026-10-04

- Native EPUB-Vorschau im echten `QLPreviewView`-Host einschließlich Cover,
  Feldern und Scrollbereich visuell geprüft, ohne Fokusübernahme.
- Native MP3-/EPUB-Leser auf synthetischen Dateien geprüft; Originalbytes
  bleiben unverändert. Finder-Dienst prüft Unicode, Leerzeichen,
  Mehrfachauswahl, alte Dateilisten und abgelehnte Nicht-Datei-URLs.
- 143 App-/Vorschau-Tests und Shell-Regressionen für die Mindestversion bestehen.
  Die macOS-Diensteregistrierung enthält den richtigen Selector und den
  deutschen Menütext; dies wurde an der tatsächlichen `pbs`-Registrierung geprüft.
- Release-Bundle einschließlich Erweiterung signiert, notarisiert und von
  Gatekeeper akzeptiert; 9 Mach-O-Dateien erfüllen macOS 14.
- Der tatsächliche Aufruf aus dem Finder-Kontextmenü wurde noch nicht geprüft;
  er übernimmt den Fensterfokus und benötigt dafür eine Testfreigabe.
