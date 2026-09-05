# Konsistenzprüfung über Ordner (Stand 2026-09-02)

Konsultieren bei Arbeit an `LibraryCheck`, `ImagePixelSize`, `tagx check`
oder dem Sheet „Konsistenzprüfung" in der App.

## Aufbau

- `Sources/TagExplosionCore/LibraryCheck.swift`: reine Prüf-Engine.
  Eingabe sind `LibraryCheck.Item`-Werte, Ausgabe ein `Codable`-`Report`
  (Gruppen, Befunde mit Regelcode/Schweregrad/Dateien, Zusammenfassung je
  Regel, Liste je Datei). `Item.load(url:)` liest von der Platte (CLI), die
  App baut die Items aus den Bearbeitungspuffern (`FileEntry.libraryCheckItem`
  in `App/Sources/TagExplosionApp/LibraryCheckSheet.swift`) — geprüft wird
  also, was gerade in den Feldern steht, wie bei der Umbenennen-Vorschau.
- Kein Schreibweg. Die Engine korrigiert nichts; der Bericht nennt nur
  Dateien. Automatische Korrekturen bleiben bewusst Nutzerentscheidung.
- Regelcodes (Rohwerte des `RuleCode`-Enums) sind zugleich CLI-Schreibweise
  (`--only track-gap,missing-cover`) und JSON-Form; die englischen Titel
  stehen im Core, die deutschen in `libraryCheckRuleTitle` (App).

## Gruppierung — und ihre Grenze

Audio/Video mit `ALBUM` bilden je (Album, Album-Interpret) eine Gruppe,
beides normalisiert (Kleinschreibung, Randleerzeichen weg, Mehrfach-
Leerzeichen zusammengezogen). So fallen „Kind Of Blue " und „Kind of Blue"
in dieselbe Gruppe und werden dort als `album-title-inconsistent` gemeldet.
Dateien ohne `ALBUM` werden nach Ordner gruppiert; Bilder/E-Books/Dokumente
immer nach Ordner (dort greifen nur die Einzelregeln).

Grenze: Weil der Album-Interpret Teil des Gruppenschlüssels ist, landen
„Various Artists" und „VA" in zwei Gruppen — das fällt nicht als
`albumartist-inconsistent` auf, sondern höchstens indirekt über Lücken in
der Nummerierung. Nur Schreibvarianten desselben Namens (Groß/Klein,
Leerzeichen) bleiben in einer Gruppe. Umgekehrt trennt der Schlüssel zwei
Alben „Greatest Hits" verschiedener Interpreten sauber — solange beide einen
`ALBUMARTIST` tragen; ohne ihn verschmelzen sie, und die Regel
`albumartist-missing` meldet genau das.

## Track- und Disc-Nummern

- Gesamtzahl kommt aus „3/12" (ID3, MP4) **oder** aus getrennten Feldern
  `TRACKTOTAL`/`TOTALTRACKS` bzw. `DISCTOTAL`/`TOTALDISCS` (Vorbis/FLAC).
  Beide Formen gelten als „Gesamtzahl vorhanden".
- Lücken werden je Disc gegen 1…Gesamtzahl geprüft (Gesamtzahl bekannt),
  sonst gegen 1…höchste Nummer. Eine Teilauswahl eines Albums meldet deshalb
  Lücken — das ist Absicht (der Bericht beschreibt die geprüfte Menge), aber
  ein Grund, im Zweifel den ganzen Ordner zu prüfen.
- Disc-Regeln laufen nur, wenn mindestens eine Datei eine `DISCNUMBER` hat;
  ein einfaches Album ohne Disc-Nummern ist kein Befund. Disc-„Dubletten"
  gibt es nicht — mehrere Tracks teilen sich legitim eine Disc.
- Eine einzelne Datei in einer Gruppe bekommt nur `track-missing` und
  `track-exceeds-total` (Lücken/Gesamtzahl wären ohne Nachbarn Rauschen).

## Cover

- `covers == nil` heißt „Format kann kein Cover tragen" (Tracker-Module,
  Matroska — siehe `MediaFormats.supportsEmbeddedArtwork`); dann gibt es kein
  `missing-cover`. Eine leere Liste heißt „Cover fehlt".
- Größe und Format kommen aus `ImagePixelSize` (Header-Bytes von JPEG, PNG,
  GIF, BMP, WebP; kein CoreGraphics, damit der Core Linux-fähig bleibt).
  Progressive JPEGs (SOF2) werden gelesen; ein JPEG ohne Frame-Marker im
  Kopf liefert nil, dann steht im Vergleich nur der MIME-Typ.
- E-Books: `hasCover` nil bei PDF (kein Cover-Speicherort), sonst Bool. In der
  App zählt ein im Puffer gewähltes Cover (`ebookCoverReplacement`) schon als
  vorhanden.

## Dubletten und Dateinamen

- `duplicate-title`: Titel + Interpret normalisiert, Dauer ±2 s, über die
  gesamte Auswahl (Gruppe leer, im Klartext unter „Across all files").
  Dateien ohne bekannte Dauer werden nicht verglichen — zwei „Intro"
  desselben Interpreten auf zwei Alben wären sonst nicht von echten Dubletten
  zu unterscheiden. Die Kette entsteht sortiert nach Dauer: Nachbarn
  innerhalb der Toleranz bilden einen Befund.
- `filename-mismatch` nur mit Muster (`--pattern`, Schalter im Sheet);
  verglichen wird `FilenamePattern.renderFileName` exakt (auch
  Groß-/Kleinschreibung) mit dem echten Dateinamen.

## CLI-Fallen

- `--only` nimmt bewusst **einen** Wert je Nennung (kommagetrennt,
  wiederholbar). Mit `.upToNextOption` hätte ArgumentParser den nachfolgenden
  Pfad als Regelcode gelesen — genau so ist der erste CLI-Test gescheitert.
- Exit 4 („Befunde") ist von 1 (Fehler), 2 (Umbenennen-Konflikt) und 3
  (Rechnungsvalidierung) unterscheidbar; ohne `--fail-on` bleibt es bei 0.
- Container ohne Tag-Leser (AVI, MOV ohne Tags, au, ogv) werden still
  ausgelassen (`toleratesMissingTagReader`), Lesefehler anderer Dateien
  erscheinen als `unreadable`, damit ein Ordnerlauf nicht abbricht.

## App-Falle: Sheet und Auswahlwechsel

Das Sheet hängt an `ContentView` und wird über `AppModel.libraryCheckTargets`
geöffnet — nicht am Batch-Editor. Der Batch-Editor bekommt `.id(model.selection)`
und wird bei jedem Auswahlwechsel neu aufgebaut; ein dort angehängtes Sheet
würde beim Klick auf eine Datei (der die Auswahl setzt) sofort verschwinden.

## App: Filter und Berechnung (2026-09-05)

`FileList.swift` filtert die Ansicht nach Dateiname/Titel/Interpret, Medienart,
Pufferänderung und Fehler; die ursprüngliche Eintragsliste bleibt unverändert.
Sortiergleichstände folgen der Öffnungsreihenfolge. Versteckte Auswahl zählt
weiter für Stapelaktionen und wird sichtbar gezählt. Die Auswahl lässt sich
auf eine Medienart begrenzen. Stapel verwenden die Modell-/Öffnungsreihenfolge;
`number` in Regeldateien verwendet ausdrücklich seine eigene `sortBy`-Sortierung.

`LibraryCheckState` wartet 250 ms Eingabepause, übergibt unveränderliche Items
an einen Hintergrund-Task und nimmt nur das Ergebnis der aktuellen Anforderung
an. Ungültige Muster entfernen den Bericht sofort. Bereits rechnende synchrone
Prüfungen dürfen auslaufen; ihr veraltetes Ergebnis wird verworfen.
