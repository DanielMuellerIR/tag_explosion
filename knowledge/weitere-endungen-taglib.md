# Weitere Endungen über TagLib: Tracker-Module, AIFF-C, MP2, 3GP, MKA, AU, OGV

Stand 2026-09-02, TagLib 2.3.1 (Homebrew), geprüft mit einer kleinen C++-Probe
direkt gegen `FileRef` und danach über die Roundtrip-Tests
(`Tests/TagExplosionCoreTests/RoundtripTests.swift`).

## Was TagLib von selbst erkennt

`TagLib::FileRef` erkennt zuerst an der Endung, dann am Inhalt. Für alle hier
ergänzten Formate reicht der bestehende Weg in `Sources/CTagShim/shim.cpp`
(`tx_open`) — ein Endungs-Hint im Shim war nicht nötig:

| Endung | TagLib-Leser | Tags | Cover | Bemerkung |
|--------|--------------|------|-------|-----------|
| aifc | `RIFF::AIFF::File` | ID3v2, voll | ja | `FORM`/`AIFC`-Container wie AIFF |
| mp2 | `MPEG::File` | ID3v2, voll | ja | wie mp3 |
| 3gp, 3g2 | `MP4::File` | voll | ja | Erkennung am `ftyp`-Brand (`3gp4`), nicht an der Endung |
| mka | `Matroska::File` | voll | **nein** | `setComplexProperties("PICTURE")` meldet Erfolg, `save()` auch — beim Wiederlesen ist kein Bild da. Gilt genauso für mkv/webm. |
| mod, s3m, xm, it | `Mod::File` usw. | nur TITLE, COMMENT, TRACKERNAME | nein | siehe unten |
| au | keiner | — | — | TagLib hat kein AU-Modul; nur Anzeige über mediainfo |
| ogv | keiner | — | — | siehe unten |

Deshalb gibt es in `MediaFormats` drei Regeln, die App und Tests gemeinsam
nutzen: `writableTagKeys(for:)` (Tracker: feste Feldliste), `supportsEmbeddedArtwork`
(Tracker, Matroska, Anzeige-Formate: nein) und `toleratesMissingTagReader`
(Video-Container plus `au`/`ogv`: ohne TagLib-Leser trotzdem öffnen, schreibgeschützt).

## Tracker-Module (mod, s3m, xm, it)

- TagLibs `Mod::Tag` liefert `TITLE`, `COMMENT` und `TRACKERNAME`. Der Kommentar
  ist die Liste der Sample- bzw. Instrumentnamen, **eine Zeile je Name** (bei MOD
  also 31 Zeilen, viele leer). Beim Schreiben verteilt TagLib den Kommentar
  zeilenweise zurück auf die Sample-Namen — Zeile 1 landet in Sample 1.
- Alle anderen Schlüssel kommen aus `setProperties` als abgelehnt zurück. Unser
  Shim zählt sie, `TagFile.setProperties` wirft `propertiesRejected`, und weil
  das innerhalb von `AtomicFileRewrite` passiert, bleibt das Original byteweise
  unverändert (Test „Unbekannte Felder werden abgelehnt“). Die App sperrt die
  betroffenen Felder im Editor vorab (`EditorView.isWritable`), damit der
  Fehler gar nicht erst entsteht; die CLI meldet ihn mit Exit-Code.
- Texte sind **Latin1 und fest begrenzt**: MOD/XM 20 Byte Titel, IT 26, S3M 28;
  Sample-Namen 22 (MOD/XM) bzw. 26/28 Byte. Längeres und Zeichen außerhalb
  Latin1 (z. B. „№“, Emoji) kürzt bzw. verwirft TagLib **stumm**. Die Tests
  benutzen deshalb kurze Umlaut-Werte; für echte Dateien gilt: Titel kurz halten.
- `TRACKERNAME` ist bei MOD und S3M aus der Kennung abgeleitet (nicht gespeichert);
  nur XM trägt den Namen in der Datei. Fehlt der Schlüssel beim Schreiben, leert
  TagLib das XM-Feld.
- Audio-Eigenschaften: Länge 0 ms (ohne Sample-Daten nicht berechenbar),
  Kanalzahl aus dem Kopf. `validateWriteResult` überspringt deshalb den
  Spielzeit-Vergleich (Bedingung `lengthMilliseconds > 0`).
- Fixtures sind synthetisch (`generate_fixtures.sh`, nur Kopf + leere Pattern,
  keine Sample-Daten, kein fremdes Material). Die Byte-Layouts stehen im Skript
  kommentiert; sie wurden gegen eine Python-Referenz byteweise verglichen.
- mediainfo liest den Titel von xm/s3m/it, nicht aber von mod; ffprobe kennt die
  Module nur mit libopenmpt.

## Ogg-Video (ogv)

TagLibs Ogg-Leser (`Ogg::Vorbis::File` usw.) erwarten einen **einzelnen**
logischen Strom. Ein ogv multiplexed Video (Theora/VP8) und Audio; der erste
BOS-Header gehört zum Video, die Kommentar-Erkennung schlägt fehl → `FileRef`
ist `isNull()`. Auch ein Endungs-Hint hilft nicht. mediainfo zeigt bei
VP8-in-Ogg nur den General-Track.

## MP4-Cover brauchen echte Bilddaten

Beim Probieren mit einem Fake-JPEG (nur Magic Bytes) schrieb TagLib das
`covr`-Atom, las beim Wiederöffnen aber **kein** Bild zurück. Mit einem echten
JPEG (Fixture `cover.jpg`) funktioniert der Roundtrip für m4a, 3gp und 3g2.
Folge für Tests: nie mit Pseudo-Bilddaten gegen MP4 testen.

## Fixtures per ffmpeg

- `aifc`: `-codec:a pcm_s16le -f aiff` — ffmpeg schreibt bei Little-Endian-PCM
  automatisch den AIFC-Container.
- `ogv`: Homebrew-ffmpeg hat keinen Theora-Encoder; VP8 (`libvpx`) plus der
  eingebaute Vorbis-Encoder (`-strict experimental`, nur Stereo → `-ac 2`).
- `3gp`/`3g2`: `-f 3gp` bzw. `-f 3g2` mit AAC-Ton; Brand `3gp4`/`3g2a`.
