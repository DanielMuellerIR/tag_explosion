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
- Sidecar `<name>.lrc` gilt nur für Formate ohne ID3v2 (FLAC, Ogg, Opus,
  MP4, Matroska …). Die App liest sie in `readLoaded` in `syncedLyrics` ein;
  ändert sich nur die Sidecar, wird die Mediendatei nicht neu geschrieben
  (`AudioSnapshot.mediaChanged`). Der Stempel-Konfliktschutz gilt für die
  Mediendatei, nicht für die Sidecar. Beim Umbenennen wird die Sidecar
  (noch) nicht mitgenommen — offener Punkt.

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
