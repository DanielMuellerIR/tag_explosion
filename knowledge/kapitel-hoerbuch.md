# Kapitel für Hörbücher und Podcasts (Stand 2026-09-02, TagLib 2.3.1)

Konsultieren bei Arbeit an `tx_get_chapters`/`tx_set_chapters` im Shim, an
`TagFile.chapters`, `ChapterList`, `tagx chapters` oder am Kapitel-Abschnitt
des Editors.

## Was TagLib 2.3 kann (und was wir daraus machen)

| Container | Lesen | Schreiben | TagLib-Klassen |
|-----------|-------|-----------|----------------|
| MP3 (ID3v2) | ja | ja | `ID3v2::ChapterFrame`, `TableOfContentsFrame` |
| MP4/M4A/M4B/M4V | ja | ja | `MP4::File::qtChapters()/neroChapters()` + Setter (neu in 2.3) |
| Matroska/WebM | ja | ja | `Matroska::File::chapters()`, `ChapterEdition`, `Chapter` (neu in 2.2) |
| FLAC, Ogg, WAV, AIFF, … | — | — | kein Kapitelmodell; `tx_chapters_supported` liefert 0 |

Die MP4- und Matroska-Header werden im Shim per `__has_include` eingebunden.
Mit einer älteren System-TagLib baut der Shim weiter, meldet für diese beiden
Formate aber „keine Kapitel“.

## Fallen

- **Einheiten unterscheiden sich.** ID3v2 `CHAP` rechnet in Millisekunden
  (32 Bit, ohne Vorzeichen — der Shim kappt größere Werte), `MP4::Chapter`
  ebenfalls in Millisekunden, Matroska in **Nanosekunden**. Der Shim
  normalisiert alles auf Millisekunden; `Chapter` im Modell kennt nur ms.
- **MP4 speichert kein Kapitelende.** `MP4::Chapter` hat nur `startTime()`.
  Der Shim liefert `end_ms = -1`; `TagFile.chapters()` ergänzt das Ende aus
  dem nächsten Beginn bzw. der Spielzeit. Deshalb vergleicht die Prüfung nach
  dem Schreiben (`validateWriteResult`) nur Titel und Beginn, nie das Ende —
  und ein MP4-Roundtrip liefert für das letzte Kapitel die Spielzeit statt
  des geschriebenen Endwerts (AAC-Encoder-Delay: 2000 ms werden 2038 ms).
- **MP4 hat zwei Kapitelsysteme.** Nero `chpl` (udta-Atom) lesen die meisten
  Player; Apple Books/iTunes verlangen die QuickTime-Kapitelspur (Text-Track
  mit `chap`-Referenz). Wir schreiben immer **beide** mit derselben Liste und
  lesen zuerst die QuickTime-Spur, hilfsweise `chpl`. ffprobe zeigt danach
  eine dritte Spur `bin_data` — das ist die Kapitelspur, kein Fehler.
- **Kapitel, die über die Spielzeit hinausreichen,** zeigt ffprobe bei MP4
  gekappt bzw. mit Nullänge an — ein Fehler der Eingabedaten, nicht des
  Schreibers. Die Prüfung `ChapterList.validate` prüft nur Reihenfolge und
  Ende ≥ Beginn, bewusst nicht die Spielzeit (Streams mit ungenauer Dauer).
- **ID3: CTOC bestimmt die Reihenfolge.** Wir schreiben ein Top-Level-CTOC
  (`toc`, geordnet) mit Element-IDs `chp0…chpN`. Beim Lesen gilt die CTOC-
  Reihenfolge; fehlt ein brauchbares CTOC, werden alle CHAP-Frames nach
  Beginn sortiert. Fremde Unter-Frames (z. B. APIC je Kapitel) gehen beim
  Neuschreiben verloren — wir tragen nur TIT2.
- **`setProperties` lässt Kapitel stehen.** CHAP/CTOC gelten in TagLib als
  „unsupported data“ und überleben ein Tag-/Cover-Schreiben; bei MP4 und
  Matroska liegen die Kapitel außerhalb der Tag-Atome/-Elemente. Ein Test
  (`chaptersSurviveTagWrite`) hält das je Format fest.
- **Matroska braucht UIDs ≠ 0.** Jedes `Chapter` und jede `ChapterEdition`
  bekommt eine zufällige 64-Bit-UID (Mutex-geschützter Generator). Beim
  Schreiben ersetzen wir alle Editionen durch genau eine Standard-Edition;
  mehrere Editionen (z. B. „Director's Cut“) gehen dabei verloren. Titel
  bekommen die Sprache `und` (undefiniert).
- **Was Fremdwerkzeuge sehen (verifiziert):** ffprobe liest alle drei
  Formate; kid3 zeigt CHAP/CTOC in MP3; mediainfo zeigt Kapitel als „Menu“
  bei MP4 und Matroska, aber **nicht** ID3-CHAP in MP3 — das ist eine
  mediainfo-Grenze, keine Schreiblücke.
- **Textformat ohne Enden.** `HH:MM:SS.mmm Titel` trägt nur den Beginn; das
  Ende jedes Kapitels ist der nächste Beginn, das letzte endet bei der
  Spielzeit (`totalLength`), sonst bei seinem Beginn. Beim Import prüft
  `ChapterList.validate` vor Sicherung und Kopie — eine unstimmige Liste
  erzeugt keine Papierkorb-Kopie.
