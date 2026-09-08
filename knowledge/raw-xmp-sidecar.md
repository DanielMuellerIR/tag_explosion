# Kamera-RAW und XMP-Sidecar: Fallen (Stand 2026-09-02)

Konsultieren bei Arbeit an `ExifTool.readCoreReading`, `writeDestination`,
`AtomicFileRewrite.create` oder an den Sidecar-Hinweisen der Bild-Editoren.

## Regeln

- **RAW wird nie direkt beschrieben.** `ExifTool.writeDestination` ist die
  einzige Stelle, die das Schreibziel bestimmt; `ImageWriteDestination` hat
  keinen öffentlichen Initialisierer. Reihenfolge der Gründe: `.xmp` ist selbst
  das Ziel → Kamera-RAW (`MediaFormats.rawImage`) → Formate ohne
  exiftool-Schreibweg (`imageEmbeddedReadOnly`: bmp, svg) → vorhandene Sidecar
  → Einstellung `preferSidecar` → Original. Auch ein Aufrufer ohne
  Sidecar-Wissen (`to: nil`) landet bei RAW in der Sidecar.
- **Vorhandene Sidecar gewinnt beim Lesen feldweise** (Lightroom/Bridge).
  Deshalb geht eine Änderung an einem JPEG mit Sidecar IMMER in die Sidecar,
  auch wenn die Einstellung aus ist: Ins Original geschrieben bliebe sie
  hinter dem überlagernden Sidecar-Wert unsichtbar. Grund `.existingSidecar`.
- **„Tag fehlt" ist nicht „Tag leer".** exiftool `-j` lässt fehlende Tags
  weg; nur dieses Fehlen entscheidet, ob die Sidecar ein Feld überlagert
  (`readCoreFieldsWithPresence`). GPS zählt als EIN Feld (Breite+Länge).
- **Löschen über die Sidecar löscht nichts im Original.** Wer bei einem RAW
  mit eingebettetem GPS die Koordinaten leert, entfernt nur das Sidecar-Tag;
  der Read-back zeigt danach den eingebetteten Wert mit Herkunft „Original".
  Das ist ehrlich (das RAW trägt den Wert weiterhin) und bewusst so belassen.
  Beim Archivimport scheitert genau dieser Fall am exakten Read-back mit
  `saveFailed`, ohne dass etwas ausgetauscht wird.
- **exiftool legt eine fehlende `.xmp` beim Schreiben selbst an** — kein
  `-o`, keine Vorlage nötig (`exiftool -XMP-dc:Title=x neu.xmp` → „1 image
  files created"). Die Temp-Datei `.name.tagx-<uuid>.xmp` entsteht so, wird
  geprüft und per `link()` exklusiv auf den Zielnamen gesetzt
  (`AtomicFileRewrite.create`); `EEXIST` heißt „jemand anderes war schneller"
  und wird als `fileChangedOnDisk` gemeldet.
- **Konfliktschutz braucht den Sidecar-Zustand des Lesevorgangs**
  (`SidecarState`: `.absent`/`.present(stamp)`), nicht nur den Stempel des
  Bildes. Der App-Speicherpfad trägt ihn im `SaveSnapshot.image(sidecar:)`
  mit; CLI und Archiv nehmen ihn aus `readCoreFieldsSnapshot`.
- **Gesichert wird die Datei, die sich ändert:** bei Sidecar-Ziel die `.xmp`
  (`TrashBackup.backUp` überspringt eine noch fehlende Datei still), sonst
  das Bild.
- **RAW+JPEG-Paare teilen sich eine Sidecar:** `foto.cr2` und `foto.jpg`
  schreiben beide in `foto.xmp` (Adobe-Konvention). Ordner-Drops verstecken
  eine `.xmp`, deren Bild mitgelistet ist (`MediaFormats.hidingSidecars`);
  direkt angegeben öffnet sie sich als eigenes Format.
- **Sidecar-Name ist immer kleingeschrieben `.xmp`.** Auf
  Groß-/Kleinschreibung-sensiblen Dateisystemen (Linux) wird eine fremde
  `IMG.XMP` nicht gefunden; macOS-APFS ist standardmäßig unempfindlich.
  Die Ordnererkennung blendet abweichend geschriebene XMP-/NFO-Sidecars
  deshalb nur aus, wenn der Backend-Pfad dieselbe Datei bezeichnet.

## Testersatz für RAW

Keine echten RAW-Dateien im Repo. NEF/ARW/DNG sind TIFF-Container: Das
8×8-TIFF aus `generate_fixtures.sh` unter RAW-Endung kopiert wird von
exiftool als `FileType: NEF` erkannt und ist für Sidecar-Tests ausreichend.
`exiftool -listwf` liefert die Schreibfähigkeit der installierten Version;
`imageWritabilityMatchesExifTool` hält `imageEmbeddedReadOnly` dagegen.

## Gemeinsamer Lesestand (2026-09-08)

Bild und Sidecar gehören zu einem Lesestand, auch wenn nur die Sidecar
beschrieben wird. `readCoreFieldsSnapshot` prüft deshalb nach dem Lesen beide
Dateien. `ImageCoreReading.requireUnchangedSidecar` verwendet `FileState`
und erkennt auch eine nachträglich angelegte Sidecar. Der Schreibkern prüft
beide Dateien vor der Arbeit, nach der Validierung und unmittelbar vor dem
Austausch; der Archiv-Probelauf endet ebenfalls nach der Prüfung.

Die ExifTool-Tests benutzen ausschließlich eigene Arbeitskopien und entfernen
deren Ordner. Sie benötigen keine serielle Suite: Der gezielte Lauf mit
20 Tests sank lokal von 3,816 auf 0,670 Sekunden (2026-09-08); die konkreten
Werkzeugaufrufe und Prüfungen der geschriebenen Dateien bleiben erhalten.
