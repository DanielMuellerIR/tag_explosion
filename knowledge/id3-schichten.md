# Tag-Schichten und ID3v2.3 (Stand 2026-09-02, TagLib 2.3.1)

Konsultieren bei Arbeit an `tx_layers_get`/`tx_layers_strip`/`tx_save_id3v2`
im Shim, an `TagFile.layers`/`stripLayers`, `tagx layers`, `tagx set --id3v23`
oder am Abschnitt „Tag-Schichten" des Editors.

## Welche Schichten TagLib je Format kennt

| Format (TagLib-Klasse) | Schichten | Strip |
|------------------------|-----------|-------|
| mp3/mp2 (`MPEG::File`) | ID3v1, ID3v2, APEv2 | `strip(int)` — schreibt **sofort** in die Datei |
| wav (`RIFF::WAV::File`) | ID3v2, RIFF INFO | `strip(TagTypes)` — entfernt die Chunks sofort |
| aiff/aifc (`RIFF::AIFF::File`), dsf (`DSF::File`) | nur ID3v2 | kein `strip()`; der Shim leert den Tag, `save()` entfernt den Chunk |
| flac (`FLAC::File`) | Vorbis, ID3v1, ID3v2 | `strip(int)` + `save()`; der Vorbis-Block bleibt mit Vendor-String stehen |
| ape, mpc, wv (`APE::`, `MPC::`, `WavPack::File`) | APEv2, ID3v1 | `strip(int)` + `save()` |
| tta (`TrueAudio::File`) | ID3v1, ID3v2 | `strip(int)` + `save()` |
| m4a/mp4, ogg/opus, mkv, wma … | — | `tx_layers_get` liefert 0 Schichten; der Editor zeigt keinen Abschnitt |

Die `TagTypes`-Enums haben je Klasse **andere Bitwerte** (WAV: ID3v2 = 1,
Info = 2; MPEG: ID3v1 = 1, ID3v2 = 2, APE = 4). Der Shim hat deshalb eine
eigene Maske (`tx_layer_kind`) und übersetzt pro Format.

## Fallen

- **`strip()` schreibt bei MPEG und WAV sofort.** Deshalb läuft
  `TagFile.stripLayers` nie auf dem Original, sondern wie `write` über
  `AtomicFileRewrite` auf der Geschwisterkopie — und ruft danach **kein**
  `save()`: `MPEG::File::save()` (Standard `Duplicate`) würde eine gerade
  entfernte ID3v2-Schicht aus ID3v1 sofort wieder erzeugen.
- **`TagLib::List::erase()` löst die geteilte Liste nicht ab.** Wer die
  `frameList()` eines ID3v2-Tags als `FrameList` kopiert und dann
  `removeFrame()` aufruft, iteriert über dieselbe schrumpfende Liste →
  Absturz (so passiert beim AIFF-Strip). Der Shim kopiert die Zeiger in
  einen `std::vector`.
- **Vorhanden ≠ Tag-Objekt.** `WAV::File::ID3v2Tag()` liefert immer einen
  (ggf. leeren) Tag; nur `hasID3v2Tag()`/`hasInfoTag()` sagen, ob er in der
  Datei steht. Der Shim liest Schlüssel nur bei `present`.
- **`DSF::File` kennt kein `hasID3v2Tag()`.** Vorhanden = Tag nicht leer.
- **FLAC-Vorbis lässt sich nicht ganz entfernen.** Nach dem Strip bleibt der
  Block mit Vendor-String; `present` bleibt true, `fields` ist leer. Die
  Prüfung nach dem Schreiben verlangt für `.vorbis` deshalb „keine Felder",
  für alle anderen Schichten „nicht vorhanden".
- **Beim MP3-Schreiben entsteht immer ID3v1.1** (TagLib `Duplicate`). Wer
  nur ID3v2 will, muss nach dem Speichern strippen; ID3v1 kann weder Umlaute
  außerhalb Latin1 noch Emoji tragen (TagLib lässt solche Werte weg).
- **kid3-cli** legt mit `set title X 1` ein ID3v1 auch auf WavPack an —
  damit lassen sich Zwei-Schichten-Testdateien ohne echte Musik bauen.

## ID3v2.3 statt v2.4

`tx_save_id3v2(f, 3)` ruft die Versions-Overloads: `MPEG::File::save(AllTags,
StripOthers, v3, Duplicate)` (dieselben Argumente wie das parameterlose
`save()`, nur die Version weicht ab), `RIFF::WAV::File::save(AllTags,
StripOthers, v3)`, `RIFF::AIFF::File::save(v3)`, `DSF::File::save(v3)`,
`DSDIFF::File::save(…, v3)`. Andere Formate speichern wie `tx_save()`.

Was TagLib dabei umbaut — und was beim Zurücklesen bleibt (geprüft in
`TagLayerTests`, Gegenprobe kid3-cli „ID3v2.3.0"):

- **UTF-8 → UTF-16.** v2.3 kennt kein UTF-8; Umlaute und Emoji überleben.
- **TDRC → TYER/TDAT/TIME.** `2024-03-15` kommt unverändert zurück;
  `2024-03-15T10:20:30` wird zu `2024-03-15 10:20` — TIME kennt nur HHMM,
  die Sekunden gehen verloren.
- **TDOR → TORY.** ORIGINALDATE behält nur das Jahr (`2001-05-06` → `2001`).
- **Die Option gilt je Schreibvorgang, nicht je Datei.** Der nächste Save
  ohne Option schreibt wieder v2.4. In der App ist die Einstellung global,
  in der CLI muss `--id3v23` bei jedem `set` stehen.
