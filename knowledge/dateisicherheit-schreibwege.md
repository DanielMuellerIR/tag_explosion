# Dateisicherheit der Schreibwege (Stand 2026-07-25)

Konsultieren bei Arbeit an `TagFile.write`, `AtomicFileRewrite`, `TrashBackup`
oder `FileStamp` — und bevor irgendwo ein neuer Schreibweg entsteht.

## Zwei Schichten, die zusammengehören

1. **Atomar schreiben (immer):** Jede Änderung entsteht an einer
   Geschwisterkopie, wird geprüft und ersetzt das Original erst per `rename`.
   Gilt für Audio/Video (TagLib), EPUB und Calibre-Formate. Bilder erledigt
   exiftool selbst über `-overwrite_original` (Temp + Rename).
2. **Papierkorb-Sicherung (`TrashBackup`, abgesicherter Modus):** Vor der
   Änderung wandert eine unveränderte Kopie in den Papierkorb.

Schicht 1 verhindert kaputte Dateien, Schicht 2 verhindert *falsche* Dateien
(erfolgreich geschrieben, aber ungewollt).

## Fallen

- **`URL.resourceValues` cached.** Eine URL-Instanz merkt sich einmal
  abgefragte Werte. Wer damit prüft, ob sich eine Datei seit dem Öffnen
  geändert hat, bekommt beim zweiten Aufruf denselben alten Wert zurück und
  sieht die Änderung nie. `FileStamp` benutzt deshalb bewusst
  `FileManager.attributesOfItem`. Das war real: Der erste Entwurf der
  Stale-Prüfung war wirkungslos und fiel nur durch den zugehörigen Test auf.
- **Neue Inode nach jedem Schreiben.** Der atomare Weg ersetzt die Datei.
  Zusätzliche Hardlinks zeigen danach weiter auf den alten Stand. Bewusst in
  Kauf genommen; erweiterte Attribute, Finder-Tags und Rechte übernimmt
  `copyItem`.
- **Der Papierkorb ist pro Datenträger.** Eine Kopie muss auf demselben
  Volume entstehen wie das Original, sonst schreibt die Sicherung einer
  externen Platte die Systemplatte voll. `TrashBackup` legt den Ordner deshalb
  über `.itemReplacementDirectory` (immer auf dem Volume der Datei) an und
  verschiebt ihn sofort per `trashItem` in den Papierkorb desselben Volumes;
  danach wird direkt weiter hineinkopiert.
- **APFS klont.** `clonefile` macht die Sicherung praktisch kostenlos; Platz
  kostet erst, was sich danach wirklich ändert. Auf Nicht-APFS-Volumes prüft
  `VolumeSpace.requireRoom` vorher den freien Platz — sonst endet ein voller
  Datenträger mitten im Schreibvorgang.
- **Der Core sichert standardmäßig NICHT.** `TrashBackup.shared.isEnabled` ist
  aus; App (`AppModel.applySafeMode`) und CLI (`SafeModeOptions.apply`)
  schalten ihn beim Start ein, wo er per Default aktiv ist. Sonst würden
  Testläufe und fremde Programme, die den Core einbinden, ungefragt in den
  Papierkorb schreiben. Ein Test hält diesen Default fest.
- **Externe Programme lesen führende Bindestriche als Optionen.** mediainfo,
  exiftool und `ebook-meta` bekommen Pfade daher immer über
  `MediaInfoReader.toolArgument(for:)` — absolut, damit eine Datei namens
  `-etwas.jpg` nicht als Option ankommt.

## Wenn ein neuer Schreibweg entsteht

Vor der ersten Mutation `TrashBackup.shared.backUp(url)` aufrufen und die
Änderung über `AtomicFileRewrite.run` führen. Die Sicherung ist bewusst
fehlerhart: Schlägt sie fehl, wird nicht geschrieben.
