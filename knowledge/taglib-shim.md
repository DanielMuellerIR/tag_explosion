# TagLib-Shim: Erkenntnisse (Stand 2026-07-17, TagLib 2.3)

- **ID3v2-Default-Encoding ist Latin1!** Ohne
  `ID3v2::FrameFactory::instance()->setDefaultTextEncoding(String::UTF8)`
  schreibt TagLib Umlaute als Latin1 → Mojibake in mediainfo/anderen Tools.
  Wir setzen UTF-8 in `tx_open()` (idempotent). kid3 macht dasselbe.
- **Die offizielle C-API (`tag_c.h`) reicht nicht** für Kapitel/Frame-Zugriff;
  eigener C++-Shim (`Sources/CTagShim`) ist der stabile Weg. Complex properties
  ("PICTURE") decken Cover ab — inkl. `pictureType`/`description`.
- **PropertyMap deckt fast alles ab**, auch Custom-Keys (werden TXXX in ID3,
  Freeform in MP4). Mehrwertige Felder = StringList pro Key. kid3 liest unsere
  Custom-Felder problemlos (verifiziert), Lyrics = Key `LYRICS`.
- **TagLib ist beim Öffnen tolerant:** Müll-Datei mit .mp3-Endung öffnet ohne
  Fehler (leerer Tag). `FileRef.isNull()` schlägt nur bei fehlender Datei oder
  komplett unbekanntem Container an. `.mov` liest TagLib 2.3 (MP4-Parser).
- **Matroska (mkv/webm) ist seit TagLib 2.x tagbar** — TITLE/GENRE etc.
  funktionieren im Roundtrip; Cover für Matroska nicht über complex properties.
- TagLib schreibt **ID3v2.4**; für v2.3 bräuchte es den
  `MPEG::File::save(tags, stripOthers, id3v2Version)`-Overload im Shim (Backlog).
- Beim Schreiben von MP3 entsteht zusätzlich **ID3v1.1** (TagLib aktualisiert
  vorhandene v1-Tags mit; bei frischen Dateien schreibt save() beide).
