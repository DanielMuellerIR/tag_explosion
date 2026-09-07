# Journal-Versionen und Wiederherstellungsziele

`BackupJournal.readUnlocked` prüft zuerst nur das Versionsfeld. Eine unbekannte
Version kann ihre Einträge anders speichern; sie wird weder als Defekt
verschoben noch beim nächsten Anfügen auf das alte Schema zurückgeschrieben.
Schreibende Operationen melden `backupFailed`. Der bestehende nicht werfende
Leseeinstieg liefert in diesem Fall eine leere Liste.

Defekte Dateien des bekannten Formats werden weiter beiseitegelegt. Existiert
schon eine `.corrupt`-Datei, erhält der nächste Defekt eine UUID im Namen.
Scheitert das Verschieben, bricht der Schreibauftrag ab; er darf den Index
nicht anschließend still ersetzen. Die Regression prüft beide unbekannten
Varianten (altes und neues Eintragslayout) sowie zwei aufeinanderfolgende Defekte.

`tagx history restore` ermittelt den Zielstempel aus `chosen.entry.originalPath`.
Die Historie eines Mediums enthält auch seine Sidecars. Deren Wiederherstellung
mit dem Stempel des Mediums meldete zuvor stets einen falschen Konflikt.
Ein echter CLI-Test stellt eine LRC über den FLAC-Pfad wieder her und prüft,
dass die Medienbytes unverändert bleiben.

Die Restore-Roundtrips sind auf beiden Plattformen aktiviert. Linux-Tests
verwenden einen eigenen XDG-Papierkorb im temporären Testordner, macOS-Tests
entfernen ihre eigenen Sitzungsordner im Systempapierkorb.

## Lesestand beim Restore

`FileEntry.restoreState` ordnet eine Version der Originaldatei oder einer
zugehörigen Sidecar zu. LRC-, NFO- und XMP-Stände gehen mit in den Core-Restore.
Sechs App-Regressionfälle prüfen fremdes Anlegen und Ändern dieser drei
Sidecar-Arten; zuvor wurden die fremden Bytes in allen sechs Fällen ersetzt.
Nicht gelesene Sidecars behalten den Zustand „unbekannt“, statt Abwesenheit
vorzutäuschen. Eine lesefehlerhafte NFO ohne Stempel bleibt ebenfalls unbekannt.

Der gemeinsame Typ heißt nun `FileState` (`SidecarState` bleibt als Alias
quellkompatibel). `BackupHistory.restore` prüft bekannte Zustände vor dem
Hashen der Sicherung und nochmals über den atomaren Austausch. Bekannte
Abwesenheit verwendet exklusives Anlegen; ein inzwischen verschwundenes
bekanntes Ziel ist ein Konflikt. Die Core-Prüfung deckt fremdes Anlegen,
fremdes Löschen und die zulässige Wiederherstellung eines weiterhin fehlenden
Ziels ab. Der alte optionale `FileStamp`-Einstieg bleibt verfügbar.
