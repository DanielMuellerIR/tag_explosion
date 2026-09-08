# Feste Felder: Lyrics, Lautheit, Podcast (Stand 2026-09-02, TagLib 2.3.1)

Konsultieren bei Arbeit an `FixedFields`, `LyricsFormats`, den Lyrics-/
Native-Feld-Funktionen im Shim, `tagx lyrics` oder den Editor-Abschnitten
„Lyrics", „Lautheit", „Podcast".

## Was TagLibs PropertyMap kann — und was nicht

Empirisch geprüft (Probe gegen die Fixtures, TagLib 2.3.1):

| Schlüssel | ID3v2 | MP4 | Vorbis/APE |
|-----------|-------|-----|------------|
| `LYRICS` | USLT (Sprache "XXX", Beschreibung "LYRICS") | `©lyr` | Kommentar `LYRICS` |
| `REPLAYGAIN_*` | TXXX | `----:com.apple.iTunes:REPLAYGAIN_*` (Großschreibung; Kleinschreibung anderer Tools wird beim Lesen erkannt) | Kommentar |
| `PODCASTURL`, `PODCASTID`, `PODCASTCATEGORY`, `PODCASTDESC` | WFED, TGID, TCAT, TDES | purl, egid, catg, desc | Kommentar |
| `PODCAST` | PCST — **nur schreibend**; beim Lesen liefert `asProperties()` den Schlüssel ohne Wert, und beim nächsten `setProperties` ohne den Schlüssel löscht TagLib den Frame | pcst (Bool) | Kommentar |
| `TVSEASON`, `TVEPISODE` | nicht abgebildet (TXXX) | tvsn/tves (Int) | Kommentar |
| `KEYWORDS`, `LONGDESCRIPTION` | nicht abgebildet (TXXX) | nicht abgebildet (Freeform) | Kommentar |

Deshalb laufen die Felder aus `FixedFields.nativeSlots` (PCST/pcst, TKWD/keyw,
ldes, TVSN, TVEP) über `tx_get_/tx_set_native_field` direkt als Frame/Atom.
Reihenfolge im Schreibweg: erst `tx_set_properties` (TagLib räumt dabei
Frames ab, deren Schlüssel in der neuen Map fehlt — das PCST-Flag), dann die
nativen Felder. Frames, die die PropertyMap nicht kennt (TKWD, TVSN, SYLT),
lässt TagLib beim `setProperties` stehen („Unsupported Data").

- `TVSN`/`TVEP` sind keine ID3-Standardframes; kid3 zeigt sie als „Unknown",
  MP4 `tvsn`/`tves` liest jedes Werkzeug. Für ID3 gibt es keine bessere
  Konvention — bewusst so gewählt (Auftrag AP7).
- Die PropertyMap-Schreibung von `PODCAST=1` auf MP3 sieht nach Erfolg aus,
  der nächste Tag-Save ohne den Schlüssel entfernt PCST wieder. Bei Rätseln
  um verschwundene Podcast-Flags zuerst hier nachsehen.

## Lyrics

- Nach jedem Textwechsel legt TagLib ein **neues USLT mit Sprache "XXX"** an.
  `TagFile.write` setzt deshalb die bisherige (oder übergebene) Sprache nach
  `setProperties` erneut. Sprache leer = "XXX" = unbekannt.
- SYLT (`tx_set_synced_lyrics`) schreibt immer Millisekunden-Zeitstempel
  (Format 2) und Typ „Lyrics"; SYLT-Frames mit MPEG-Frame-Zeitstempeln
  (Format 1) werden gelesen als „keine Zeilen", weil die Umrechnung die
  Frame-Dauer bräuchte.
- **kid3-cli gibt SYLT-Zeilen nicht aus** (`get SYLT` zeigt nur die
  Beschreibung); kid3s eigenes `set SYLT "[00:01.00]…"` schreibt den LRC-Text
  sogar in die Beschreibung. Als Fremdprüfung bleibt nur: der Frame erscheint
  als „Synchronized Lyrics". ffprobe und mediainfo zeigen SYLT gar nicht.
  mediainfo zeigt USLT mit Latin1-Mojibake — ein Anzeigefehler von mediainfo,
  die Bytes sind UTF-8.
- LRC-`[offset:]` wird gelesen und beim Rendern zurückgeschrieben, aber
  **nicht auf die Zeiten angewendet** — Player deuten das Vorzeichen
  unterschiedlich. Wort-Zeitstempel `<mm:ss.xx>` (Enhanced LRC) werden
  entfernt; mehrere `[..]` vor einer Zeile ergeben mehrere Zeilen.
- Sidecar `<name>.lrc`: In der App nur für Formate ohne ID3v2 (FLAC, Ogg,
  Opus, MP4, Matroska …); `readLoaded` liest sie in `syncedLyrics` ein und
  merkt sich ihren Stempel (`AudioSidecars.lrcStamp`). Ändert sich nur die
  Sidecar, wird die Mediendatei nicht neu geschrieben
  (`AudioSnapshot.mediaChanged`). Seit 0.40.0 gilt der Stempel-Konfliktschutz
  auch für die Sidecar: `LRC.writeSidecar(_:for:expecting:backUp:)` prüft
  ihn vor dem Austausch, „Trotzdem überschreiben“ setzt ihn per
  `AudioSnapshot.ignoringSidecarStamps()` zurück. Der App-Schreibweg ist
  zweiphasig (Sidecar-Stempel und -Sicherung VOR dem Container, Austausch
  danach), damit nie Containerfelder übernommen sind, während die Lyrics an
  einem Sicherungsfehler scheitern. Beim Umbenennen nimmt
  `FileRenamer.companionSidecars` die `.lrc` mit.
- CLI-Vorrang (`loadSyncedLyrics` in `LyricsCommand.swift`): eingebettete
  SYLT-Zeilen zuerst, sonst die Sidecar — auch bei MP3, denn `lyrics set
  --sidecar` legt sie dort bewusst an. Neben vorhandenem SYLT wird
  `--sidecar` abgelehnt (sonst wäre der Import für show/export unsichtbar);
  `clear` räumt beide Speicherorte. `FixedFields.supportsLyrics` ist an
  `MediaFormats.kind == .audio` gebunden — `writableTagKeys == nil` allein
  hieße nur „keine Tracker-Einschränkung“ und ließe `.jpg`/`.docx` durch.

## Lautheit

- ReplayGain-Speicherform ist `-6.50 dB` / `0.987654`; `FixedFields.normalized`
  bringt Eingaben wie `-6,5` dorthin. Grenzen: Gain −60…+60 dB, Peak 0…10.
- R128 (nur Opus, RFC 7845) ist eine Q7.8-Ganzzahl: Wert/256 = dB;
  −32768…32767. Anzeige rechnet um, gespeichert wird die Ganzzahl.
- Geprüft werden nur **geänderte** Werte (`validate(changedFrom:)`): eine
  Datei mit `REPLAYGAIN_TRACK_GAIN=kaputt` aus einem fremden Werkzeug lässt
  sich weiterhin retaggen; wer den kaputten Wert anfasst, bekommt den Fehler.
- Keine Berechnung aus dem Audio (kein loudgain/r128gain) — bewusst nicht
  Teil des Pakets.
