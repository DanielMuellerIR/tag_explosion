# Undo-Historie: Sicherungs-Journal statt Papierkorb-Suche (seit 2026-09-02)

Trigger: Arbeit an `BackupJournal`, `BackupHistory`, `tagx history`, dem
Versionen-Blatt der App oder an der Ablage der Papierkorb-Kopien in
`TrashBackup`.

## Warum ein Journal nötig ist

`TrashBackup` ruft `trashItem` genau einmal je Sitzung und Datenträger auf —
für den leeren Sitzungsordner „Tag Explosion Sicherung <Zeit>“. Die Kopien
selbst werden danach direkt in diesen Ordner geschrieben (Unterordner = Name
des Quellordners, Namenskollision als „Name (2).ext“). Daraus folgt:

- macOS benennt nur beim `trashItem` um; die Kopien im Ordner tragen den
  Originalnamen. Vom Namen lässt sich also weder Zeitpunkt noch Herkunft
  ablesen: Zwei Ordner `Musik` aus verschiedenen Pfaden teilen sich einen
  Unterordner-Namen (Zähler nur in der Sitzung), und die Zählung „(2)“ sagt
  nichts über die Reihenfolge zwischen Sitzungen.
- Der Papierkorb liegt je Datenträger woanders (`~/.Trash`,
  `/Volumes/X/.Trashes/<uid>`); eine Suche müsste alle Volumes durchgehen.
- `clonefile` übernimmt die Änderungszeit des Originals — die Kopie sagt
  nicht, wann sie entstand.

Ohne Journal wäre die Zuordnung Original → Sicherungen Raten. Deshalb hält
`TrashBackup.serializedBackUp` direkt nach dem Klonen einen Journal-Eintrag
fest: Originalpfad (kanonisch), Sicherungspfad, Zeit, Größe, SHA-256, Auslöser.

## Regeln

- **Ort:** `BackupJournal.defaultURL` — macOS `Application Support/TagExplosion/
  backup-journal.json` (über `FileManager`, nie fester Home-Pfad), Linux
  `$XDG_DATA_HOME` bzw. `~/.local/share/TagExplosion/`. `TAGX_BACKUP_JOURNAL`
  überschreibt den Pfad (Skripte, CLI-Tests).
- **Nur `TrashBackup.shared` schreibt ins Standard-Journal.** Eine mit
  `TrashBackup()` erzeugte Instanz hat kein Journal, damit Testläufe das
  Journal des Benutzers nicht mit Einträgen füllen, deren Kopien sie gleich
  wieder löschen. Tests geben ein eigenes `BackupJournal(url:)` mit.
- **Der Papierkorb ist die Wahrheit, das Journal nur ein Index.** Ein Eintrag
  ohne Kopie (Papierkorb geleert) gilt als verfallen: `liveEntries()` filtert
  ihn, `prune` entfernt ihn aus der Datei. Weder Journal noch `tagx history
  prune` löschen je etwas aus dem Papierkorb.
- **Journal-Fehler sind nicht fehlerhart.** Die Kopie liegt sicher im
  Papierkorb; ein unschreibbares Journal verhindert das Speichern nicht — die
  Version fehlt dann nur in der Liste (`try?` in `TrashBackup`).
- **Mehrere Prozesse:** App und CLI hängen gleichzeitig an. Lesen-Anfügen-
  Schreiben läuft unter `flock` auf `<journal>.lock`, der Austausch der
  Datei per Temp-Datei + `rename`. Ein unlesbares Journal wird als
  `<journal>.corrupt` beiseitegelegt statt überschrieben.
- **Zeit mit Sekundenbruchteilen.** Speichern und sofort Undo liegen in
  derselben Sekunde; `.iso8601` ohne Bruchteile machte die Reihenfolge
  zufällig (erster Testlauf). Der Encoder schreibt Bruchteile, der Decoder
  akzeptiert beide Formen; bei Gleichstand gilt die Journal-Reihenfolge.
- **Prüfsumme mit Größenlimit.** SHA-256 nur bis 512 MiB
  (`checksumSizeLimit`); darüber prüft ein Restore nur die Größe. Das Hashen
  einer mehrere GB großen Videodatei würde sonst jedes Speichern spürbar
  bremsen. Vor dem Zurückspielen wird die Kopie gegen den Eintrag geprüft;
  eine manipulierte Kopie wird abgelehnt (Test).
- **Obergrenze 5000 Einträge**, älteste zuerst raus (`maxEntries`).
- **Restore ist ein normaler Schreibweg:** `AtomicFileRewrite.run` (Kopie
  wird zur Geschwisterdatei, Prüfung, dann `rename`), davor
  `TrashBackup.backUp(original, reason: "restore")` — so bleibt auch das Undo
  rückgängig machbar. Fehlt das Original inzwischen, legt
  `AtomicFileRewrite.create` es exklusiv neu an. Mit `expecting:` (Stempel)
  schützt der Rahmen wie beim Speichern vor fremden Änderungen.
- **Bilder mit XMP-Sidecar:** Der Bild-Schreibweg sichert die Sidecar, nicht
  das Bild. `BackupHistory.versions(of:)` nimmt für Bilder deshalb auch die
  Einträge von `<name>.xmp` mit; die App übergibt in diesem Fall keinen
  Stempel (der gehört zum Bild).
- **Versionsnummern zählen von der jüngsten Sicherung (1).** So meint
  `tagx history restore --version 1` immer „letzte Änderung“; nach jedem
  Restore verschieben sich die Nummern (der gesicherte Vorzustand wird zur 1).
- **Feld-Vergleich** läuft über die Leser der jeweiligen Medienart
  (`TagFile.read`, `ExifTool`/`EbookTool`/`DocumentTool.readCoreFields`,
  Sidecar, Playlist) und flacht Codable-Felder generisch ab (`authors` →
  „A / B“, `custom[1].key`). Cover erscheinen als „MIME Bytes“, damit ein
  Cover-Tausch sichtbar ist. Rechnungen (`invoice`) haben keine Felder.

## Grenzen

- Umbenannte Originale: Seit 0.40.0 zieht `FileRenamer.apply` die
  Journalpfade nach (`BackupJournal.relocate(from:to:)`, für Medium und
  mitbewegte Sidecar); `history list <neuer Name>` findet die alten
  Versionen. Scheitert nur das Journal, bleibt die Umbenennung bestehen und
  `Outcome.warning` nennt es. Umbenennungen von außen (Finder, `mv`) kennt
  das Journal weiterhin nicht — dann gilt nur `history list <alter Pfad>`.
- Sidecars in `versions(of:)`: neben `<name>.xmp` (Bilder) auch
  `<name>.lrc` (Audio) und `<name>.nfo` (Video); ein Restore einer solchen
  Version schreibt die Sidecar zurück, nicht das Medium. `fieldMap` zeigt
  für eine `.lrc` die Zeilen als ein Feld `SYNCEDLYRICS`.
- Ein Restore holt die ganze Datei zurück, nicht einzelne Felder — dafür
  gibt es Export/Import (`TagArchive`).
- Linux: Ohne Papierkorb entsteht keine Sicherung und damit kein Journal-
  Eintrag (AP16).

## Tests

- `BackupHistoryTests`: Journal-Roundtrip, Verfall + prune, Obergrenze,
  kaputtes Journal, Feld-Diff, Abflachen, Restore-Roundtrip (byte-gleich,
  Prüfsumme, Undo-des-Undo), manipulierte Kopie, Instanz ohne Journal.
- `HistoryCommandTests`: leere Historie, `set` → list/diff → Dry-run →
  `--apply` → Tags wie vorher, Versionsbereich-Fehler.
