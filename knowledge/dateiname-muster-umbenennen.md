# Dateiname ↔ Tags mit Mustern (Stand 2026-09-02)

Konsultieren bei Arbeit an `FilenamePattern`, `FileRenamer`, `tagx rename`,
`tagx parse` oder den Dialogen „Umbenennen aus Tags" / „Tags aus Dateiname".

## Warum Umbenennen ohne Papierkorb-Sicherung läuft

Die Regel „vor jeder Mutation `TrashBackup`" (siehe
[dateisicherheit-schreibwege.md](dateisicherheit-schreibwege.md)) schützt vor
kaputten oder ungewollt veränderten **Inhalten**. Ein Umbenennen ändert kein
Byte des Inhalts: `FileManager.moveItem` innerhalb desselben Ordners ist ein
`rename(2)` — dieselbe Operation, mit der `AtomicFileRewrite` eine geprüfte
Kopie einsetzt. Inode und Änderungszeit bleiben, ein offener Editor behält
seinen `FileStamp`. Rückgängig heißt: zurückbenennen. Eine Kopie im Papierkorb
wäre bei großen Ordnern reine Plattenlast ohne Sicherheitsgewinn.

Was stattdessen schützt: `FileRenamer.plan` lehnt jeden Konflikt vorher ab,
`apply` prüft direkt vor jedem `moveItem` noch einmal, und `moveItem`
überschreibt nie (ein vorhandenes Ziel ist ein Fehler). Der einzige Weg, der
Inhalte anfasst — Tags aus dem Dateinamen — läuft weiter über Sicherung und
atomaren Austausch (`tagx parse --apply` bzw. normales Speichern in der App).

## Fallen

- **Alles oder nichts.** Ein Plan mit einem Konflikt wird komplett
  verweigert (CLI Exit 2, App-Hinweis). Ein halb umbenanntes Album ist
  schlimmer als keins. Tausch (A→B, B→A) und Ketten (A→B, B→C) gelten deshalb
  bewusst als Konflikt „Ziel existiert schon", nicht als lösbare Reihenfolge.
- **Groß-/Kleinschreibung.** Auf APFS ohne Case-Sensitivity (Standard) sind
  `song.mp3` und `Song.mp3` dieselbe Datei. Der Plan vergleicht Zielnamen dort
  klein geschrieben; unbekannte Datenträger gelten als nicht unterscheidend
  (strengere Annahme). Nur die Schreibweise EINER Datei zu ändern
  (`song.mp3` → `Song.mp3`) ist erlaubt — `moveItem` schafft das auf APFS
  direkt, der Test „auch nur die Schreibweise" hält das fest.
- **`%{` in lokalisierten Texten.** `String(localized:)` und
  `LocalizedStringKey` laufen durch die Format-Auswertung; ein `%{` darin ist
  kein gültiger Format-Bezeichner. Platzhalterlisten in der UI stehen deshalb
  als `Text(verbatim:)` beziehungsweise wörtlich angehängter String, die
  Fehlertexte nennen keine Platzhalter im Wortlaut.
- **`Set` ist im CLI-Target der Befehl.** In `Sources/tagx` heißt der
  Mengentyp `Swift.Set`, sonst greift der Compiler den `set`-Unterbefehl.
- **Muster beschreiben nur den Dateinamen.** Ein `/` im Muster wird
  abgelehnt; Ordner aus Tags anzulegen (kid3 kann das) ist bewusst außen vor,
  weil dann `moveItem` über Ordnergrenzen und leere Restordner dazukämen.
- **Parsen ist nicht-gierig.** `%{artist} - %{title}` auf
  `A - B - C` liefert Artist `A`, Titel `B - C`. Zahlenfelder (`track`,
  `disc`) erwarten nur Ziffern, `year` genau vier — so trennt
  `%{track} %{title}` eindeutig. Führende Nullen fallen beim Parsen weg.
- **`FileEntry.url` ist die Identität** (Liste, Auswahl, `.id(entry.url)` in
  der Detailansicht). Nach dem Umbenennen entsteht deshalb ein neuer Eintrag
  (`FileEntry(relocating:to:)`) an derselben Listenposition; Puffer, Original
  und Stempel ziehen mit. `WindowSessions` kennt keine Pfade, Fenstertitel
  und `representedURL` folgen dem Eintrag automatisch.
- **Namensgebundene Sidecars wandern mit** (`FileRenamer.companionSidecar`,
  seit 0.40.0): `.xmp` bei Bildern, `.lrc` bei Audio, `.nfo` bei Videos —
  je Eintrag höchstens eine, Sprachsuffix-Sidecars (`film.de.srt`) bewusst
  nicht (Zuordnung nicht eindeutig). Scheitert das Verschieben der Sidecar,
  geht das Medium zurück; scheitert AUCH dieser Rückweg, meldet
  `RenameError.sidecarRollbackFailed` den getrennten Zustand statt ihn per
  `try?` zu verschlucken. Nach jedem gelungenen Eintrag zieht
  `BackupJournal.relocate` die Historie nach; ein Journalfehler landet in
  `Outcome.warning`, die Umbenennung bleibt. Test-Falle: Auf
  case-insensitivem APFS gilt `film.nfo` als vorhanden, solange `Film.nfo`
  existiert — Zielnamen in Tests deshalb wirklich anders wählen.
