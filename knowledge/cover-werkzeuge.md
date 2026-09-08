# Cover-Werkzeuge (Stand 2026-09-08)

Konsultieren bei Arbeit an `Sources/TagExplosionCore/CoverTools.swift`,
`Sources/tagx/CoverToolCommands.swift` (`tagx cover info|convert|from-folder|
to-folder`) oder `App/Sources/TagExplosionApp/CoverToolsMenu.swift`.

## Aufbau

- **Analyse über eigene Header-Parser.** Maße, Komponentenzahl (Gray/RGB/
  CMYK) und das Progressiv-Flag eines JPEG stehen im SOF-Segment; bei PNG in
  IHDR (plus `tRNS` für Transparenz bei Palettenbildern). `JPEGHeader` und
  `PNGHeader` lesen das ohne ImageIO, damit der Core unter Linux dasselbe
  Ergebnis liefert und die Tests mit synthetischen Headern (ohne Bilddaten)
  auskommen. Nur GIF/BMP/WebP gehen über `CGImageSourceCopyPropertiesAtIndex`
  und liefern unter Linux keine Maße (→ `unknown-format`).
- **Neu kodieren nur mit ImageIO.** Verkleinern und Formatwechsel laufen über
  `CGImageSourceCreateThumbnailAtIndex` (skaliert hochwertig in einem Schritt
  und wendet die EXIF-Ausrichtung an) und einen sRGB-`CGContext`: Der wandelt
  CMYK nach RGB und flacht Transparenz für JPEG auf Weiß ab. Unter Linux wirft
  `reencode` `CoverToolError.conversionUnavailable` — bewusst kein stilles
  „unverändert“.
- **`Conversion.format` gesetzt heißt immer neu kodieren**, auch wenn das
  Bild das Format schon hat; nur so lässt sich ein JPEG per `--jpeg 0.7`
  nachkomprimieren. `maxPixelSize` allein kodiert dagegen nur neu, wenn das
  Bild wirklich größer ist — kleine Cover bleiben byteidentisch.

## Fallen

- **Metadaten-Strip darf nicht alle APP-Segmente entfernen.** APP2 trägt das
  ICC-Profil (sonst Farbstich), APP14 das Adobe-Segment mit dem Farbtransform-
  Flag (ohne es dekodieren viele Leser CMYK/YCCK-JPEGs falsch), APP0 den
  JFIF-Kopf. Entfernt werden APP1 (EXIF/XMP), APP13 (Photoshop/IPTC), die
  übrigen APPn und COM. Ab SOS werden die Bytes unverändert übernommen —
  Entropiedaten enthalten `FF` nur als `FF00` oder RST-Marker, ein Segment-
  Parser darf dort nicht weiterlaufen.
- **PNG-Chunk-CRCs bleiben gültig**, weil die behaltenen Chunks byteidentisch
  kopiert werden; entfernt werden `tEXt`, `zTXt`, `iTXt`, `eXIf`, `tIME`.
  Die Tests fügen einen `tEXt`-Chunk mit Null-CRC ein — der Strip prüft
  keine CRCs, ImageIO würde einen falschen CRC beim Dekodieren aber
  tolerieren oder ablehnen, je nach Chunk.
- **Ordner-Cover ist case-insensitiv, die Priorität fest:** `folder.*` vor
  `cover.*` vor `front.*`, jeweils jpg/jpeg vor png. `FolderCover.find`
  listet das Verzeichnis und vergleicht kleingeschrieben; auf Dateisystemen
  mit Groß-/Kleinschreibung können `Folder.jpg` und `folder.jpg` nebeneinander
  liegen — dann gewinnt die alphabetisch erste, damit CLI und App dasselbe
  wählen. Eine Cover-Datei, die kein Bild ist, wird abgelehnt (Magic Bytes),
  nicht übersprungen.
- **Export nach `folder.<ext>` ist ein Schreibweg.** Die Endung folgt den
  Magic Bytes (`folder.png` für PNG, nie `folder.jpg` mit PNG-Inhalt). Ohne
  `force` legt `AtomicFileRewrite.create` die geprüfte Geschwisterkopie
  exklusiv an; auf APFS blockiert auch ein vorhandenes `Folder.JPG`. Mit `force` läuft
  der Austausch wie überall: `TrashBackup.backUp` → `AtomicFileRewrite`
  (Kopie, Prüfung der Magic Bytes, rename).
- **Convert schreibt nur das erste Bild zurück.** Booklet/Rückseite bleiben
  unangetastet; die App zeigt im Cover-Feld ebenfalls nur das erste Bild.
  E-Books laufen über `EbookTool.write(... coverUpdate: .set)` mit den
  unveränderten Kernfeldern desselben Schnappschusses.
- **App-Aktionen ändern nur den Puffer.** Verkleinern, Wandeln, Strip und
  „Ordner-Cover übernehmen“ setzen `entry.artworks[0]`; gespeichert wird über
  den normalen Speicherweg (Sicherung, atomarer Austausch). Nur „Als
  folder.jpg exportieren“ schreibt sofort — über `FolderCover.export` mit
  NSAlert-Rückfrage vor `force`.

## QA 2026-09-08

- JPEG-/PNG-Analyse verwendet Ausschnitte der bereits gelesenen Bytefolge.
  Frühere `Data.subdata`-Bereiche begannen fälschlich bei null; ein Bild als
  Ausschnitt mit Startindex 64 ließ den Prozess mit Signal 5 abstürzen.
  Der parameterisierte Test prüft beide Formate samt Metadatenentfernung.
- PNG-Bereinigung verlangt einen vollständigen IEND-Chunk. Ein fehlender
  oder abgeschnittener End-Chunk führte vorher zu einem scheinbaren Erfolg;
  Bytes hinter IEND bleiben erhalten. CRC-Prüfung gehört weiterhin nicht
  zu dieser verlustfreien Byteoperation.
- Die Ordnersuche überspringt Verzeichnisse mit Cover-Dateinamen. Export
  bestimmt Dateiendung und Prüfung anhand der Bildbytes, auch wenn das
  Artwork einen falschen MIME-Type mitbringt. Beim Ersetzen wird der Stempel
  vor der Sicherung aufgenommen und beim atomaren Schreiben geprüft.
- Die Prüfung auf zurückgelassene Export-Tempdateien ist in den vorhandenen
  Export-Roundtrip integriert. Unabhängige CLI-Cover-Tests laufen parallel.
  App-Bildtests behalten ihre Serialisierung für den Grafik-Kontext.
- `ImagePixelSize` bleibt ein schneller Größenleser ohne Farb-/Transparenz-
  analyse. Sein JPEG-Weg liest bis zum ersten Frame direkt aus Data; ein
  Aufruf der ausführlichen Cover-Analyse würde mehr Arbeit und Kopien erzeugen.
