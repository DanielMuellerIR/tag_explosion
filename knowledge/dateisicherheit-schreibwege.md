# Dateisicherheit der Schreibwege (Stand 2026-07-25)

Konsultieren bei Arbeit an `TagFile.write`, `AtomicFileRewrite`, `TrashBackup`
oder `FileStamp` — und bevor irgendwo ein neuer Schreibweg entsteht.

## Zwei Schichten, die zusammengehören

1. **Atomar schreiben (immer):** Jede Änderung entsteht an einer
   Geschwisterkopie, wird geprüft und ersetzt das Original erst per `rename`.
   Gilt für Audio/Video (TagLib), Bilder (exiftool), EPUB und Calibre-Formate.
   exiftools `-overwrite_original` wirkt nur intern auf dieser
   Geschwisterkopie; den verbindlichen Austausch erledigt auch dort
   `AtomicFileRewrite`.
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
- **Neue Inode nach jedem Schreiben.** Der atomare Weg ersetzt nur den
  gewählten Verzeichniseintrag. Ein zweiter Hardlink bleibt bytegleich auf der
  alten Inode; das ist die bewusste Folge des sicheren Austauschs. Der
  bestätigte Fehler war ein anderer: Eine atomare Ersetzung am **gleichen
  Pfad** galt wegen der Pfadgleichheit fälschlich als dieselbe Datei. Deshalb
  vergleicht `FileStamp` für Identität immer Datenträger und Inode;
  Pfadgleichheit dient nur der Zielauflösung. Erweiterte Attribute,
  Finder-Tags und Rechte übernimmt `copyItem`.
- **Reads bilden einen Schnappschuss.** `FileSnapshot` erhebt den Stempel vor
  den zusammengehörigen Leseoperationen und prüft ihn danach erneut. Der
  Stempel wird außerdem vor einem No-op und direkt vor `rename` geprüft. Bei
  E-Books gehören Kernfelder und Cover in denselben Schnappschuss, damit ein
  Backup keinen Mischzustand aus zwei Dateifassungen enthält.
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
- **Auch ein Export ist ein Schreibweg.** `tagx cover export` prüft sämtliche
  Zielnamen vor dem ersten Schreiben und legt jede Datei zusätzlich mit
  `Data.WritingOptions.withoutOverwriting` exklusiv an. Eine bloße
  `fileExists`-Prüfung genügt nicht, weil zwischen Prüfung und Schreiben eine
  andere Datei entstehen kann. Unbekannte Covertypen bekommen `.bin` statt
  einer irreführenden `.jpg`-Endung.
- **CLI-Eingaben vor Sicherung und Mutation prüfen.** Ein leerer Tag-Schlüssel
  wird von TagLib tatsächlich gespeichert; beliebige Bytes lassen sich dort
  ebenfalls als Cover einbetten. `tagx set` lehnt deshalb leere Schlüssel ab,
  und `tagx cover set` prüft die Magic Bytes mit `Artwork.sniffMimeType`, bevor
  die Papierkorb-Sicherung beginnt.

- **Jede Sicherung wird im Journal verzeichnet.** `TrashBackup.shared`
  schreibt nach dem Klonen einen Eintrag in `BackupJournal.standard`
  (Originalpfad, Pfad im Papierkorb, Zeit, Größe, SHA-256, Auslöser); daraus
  speist sich die Undo-Historie (`BackupHistory`, `tagx history`, Knopf
  „Versionen …“). Das Journal ist nur ein Index — verfallene Einträge ohne
  Kopie werden ausgefiltert, und nichts löscht je aus dem Papierkorb. Ein
  Restore ist selbst ein Schreibweg (Sicherung des jetzigen Stands mit
  Auslöser `restore`, dann `AtomicFileRewrite`). Details und Fallen:
  [undo-historie-journal.md](undo-historie-journal.md).
- **Die Sicherung muss einen konsistenten Dateistand abbilden.** `TrashBackup`
  prüft den Quellstempel unmittelbar vor und nach der Kopie. Ändert ein anderer
  Prozess die Quelle währenddessen, wird die Kopie weder als gesicherter Stand
  noch mit einer falschen Größe im Journal verbucht. Bereits entstandene
  Sicherungskopien bleiben erhalten.
- **Neue Dateien auf Dateisystemen ohne Hardlinks:** `AtomicFileRewrite.create`
  braucht für die atomare, exklusive Veröffentlichung `link`. Unter macOS
  liefert exFAT sowohl dafür als auch für `renamex_np(RENAME_EXCL)` `ENOTSUP`
  (auf einem eigenen 64-MiB-Testvolume geprüft, 2026-09-08). Erste Sidecars,
  Cover und Playlist-Exporte werden dort deshalb derzeit abgelehnt; vorhandene
  Dateien können weiterhin über `run` ersetzt werden. Ein gewöhnliches
  `rename` nach Existenzprüfung wäre kein sicherer Ersatz. Eine Erweiterung
  braucht einen eigenen Vertrag für diese Dateisysteme.

- **Sidecars haben eigene Stempel, und ein Save mit zwei Zieldateien ist
  zweiphasig.** Der App-Audio-Schreibweg (`AppFileIO.write`) schreibt bei
  Formaten ohne SYLT die `.lrc` und bei Videos die `.nfo` zusätzlich zum
  Container. Beide behalten beim Lesen ihren eigenen Zustand
  (`AudioSidecars`), der vor dem Austausch geprüft wird — sonst
  überschriebe die App eine zwischenzeitlich fremd geänderte Sidecar ohne
  Konfliktdialog. Reihenfolge: erst alles, was an den Sidecars scheitern
  kann (Stempel, Feldprüfung, Papierkorb-Sicherung), dann der Container,
  zuletzt der Sidecar-Austausch mit `backUp: false`. So kann ein Save nie
  Containerfelder dauerhaft übernehmen, während die Sidecar an einem
  Sicherungsfehler scheitert (Review 2026-09-02). Auch Nebenwege wie
  `tagx playlist export --force` und das erste `folder.jpg` laufen über
  `TrashBackup` und `AtomicFileRewrite.run`/`.create` — ein direkter
  `Data.write` ist kein Schreibweg dieses Projekts.

## Wenn ein neuer Schreibweg entsteht

Vor der ersten Mutation `TrashBackup.shared.backUp(url, reason:)` aufrufen
(Auslöser aus `BackupReason`, damit die Historie ihn anzeigen kann) und die
Änderung über `AtomicFileRewrite.run` führen. Die Sicherung ist bewusst
fehlerhart: Schlägt sie fehl, wird nicht geschrieben.

## Editoränderungen während des Speicherns

`FileEntry.acceptSaved` ersetzt Originaldaten durch den zurückgelesenen Stand,
übernimmt ihn aber nur in unveränderte Bearbeitungspuffer. Bei optionalen
Audio-Änderungen bedeutet `nil` im Auftrag „beim Start unverändert“. Der
Vergleich muss dann die damaligen Originalwerte verwenden. Ein bedingungsloses
Übernehmen bei `nil` verwirft Lyrics, deren Sprache und Video-NFO-Felder, die
erst während des laufenden Speicherns eingegeben wurden.

`AppModelSaveTests.optionalAudioChangesDuringSave` hält den Schreibauftrag
gezielt an und prüft vier Kombinationen: schon beim Start geändert oder noch
unverändert, anschließend weiterbearbeitet oder nicht. Ohne Korrektur gehen
im Fall „erst anschließend bearbeitet“ alle drei Felder verloren und der
Eintrag erscheint fälschlich sauber.

## Fehlende Sidecars als Lesestand

`FileState` liegt in einer eigenen Core-Datei; der kompatible Alias
`SidecarState` wird für XMP und LRC verwendet. `.absent` schützt eine beim Lesen fehlende Sidecar vor fremdem
Anlegen; `.present` erkennt auch ihr späteres Verschwinden. Nur `.unknown`
verzichtet auf den Abgleich mit dem früheren Lesestand. Die App setzt diesen
Wert erst beim bestätigten Überschreiben. Der kompatible LRC-Einstieg mit
`expecting: FileStamp?` behandelt nil weiterhin als unbekannten Lesestand.

Die App-Regressionsprüfung kombiniert vorhandene/fehlende Sidecars mit
reinen Lyrics-Änderungen bzw. zusätzlichen Medien-Tags. Vor der Korrektur
überschrieb sie eine inzwischen angelegte Sidecar in beiden Schreibzweigen;
im zweiten Fall waren auch die Medien-Tags bereits geändert. Die Core-Tests
prüfen zusätzlich, dass bekannte Abwesenheit nicht zum Löschen fremder
Dateien führt und ein fremd gelöschter bekannter Stand nicht neu entsteht.

`AppFileIO.prepareAudioSidecars` und `writeAudioSidecars` gelten für beide
Audio-Speicherzweige. Früher schrieb der reine Sidecar-Zweig die LRC schon
vor der NFO-Feldprüfung; ein ungültiges Jahr verhinderte nur noch die zweite
Datei. Der unverändert gebliebene Editorstand erkannte beim nächsten Versuch
seine eigene neue LRC als fremd. Die MP4-Regressionsprüfung deckt diesen
Ablauf samt erfolgreicher Wiederholung nach Feldkorrektur ab. Ein weiterer
Test verändert die NFO gezielt nach der gemeinsamen Vorbereitung: Der
Schreibweg erhält den fremden Inhalt und meldet die schon fertige LRC über
`PartialSaveError`. Mehrere Dateiaustausche bilden keine atomare Transaktion.

`FileEntry.init` und `acceptNew` teilen seit 0.46.11 die Übernahme gelesener
Daten. Die Relokation auf einen neuen Pfad kopiert zusätzlich sämtliche
Audio-Puffer. Der normale App-Umbenennungsdialog verlangt zuvor Speichern
oder Verwerfen; der separate Konstruktor erfüllt nun ebenfalls seinen
Vertrag für noch bearbeitete Kapitel, Lyrics und Sprache. Der Regressionstest
prüft Originalerhalt, eigenständiges Verwerfen und den unveränderten Quellpuffer.

## Exporte aus dem Editor

`FileExport.write` übernimmt bereits gerenderte Bytes für Cover, Kapitel und
LRC. Es prüft die Geschwisterdatei bytegenau und verwendet
`AtomicFileRewrite.run` beziehungsweise `create`. Vor dem Austausch liegt
die Sicherung über `TrashBackup`; Stempelprüfungen schützen fremde Änderungen.
Die drei Panels rufen `AppModel.exportData` auf: IO im Hintergrund, Fehler
im App-Dialog. Ein Export darf Fehler nicht per `try?` verschlucken.
Tests prüfen Neuanlage, erhaltenen Hardlink auf den alten Stand, Sicherung,
Backupfehler und sichtbare Fehleranzeige ohne echte Fenster.
