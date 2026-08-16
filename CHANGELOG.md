# Changelog

Produktgeschichte von Tag Explosion. Format nach
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/), Versionierung nach
[Semantic Versioning](https://semver.org/lang/de/).

Diese Datei beginnt mit 0.16.0. Die Entwicklungsschritte davor stehen in den
Meilensteinen in [docs/PLAN.md](docs/PLAN.md); die ausführliche Begründung
jeder Entscheidung steht im jeweiligen Commit.

## [0.21.25] — 2026-08-16

### Behoben

- Präparierte Rechnungs-PDFs können die App nicht mehr ausbremsen: Anhänge
  werden vor dem Entpacken an ihrer deklarierten Größe geprüft (Filterketten
  und angekündigte Riesen-Anhänge werden übersprungen), und die Suche im
  Namensbaum hat neben der Tiefen- jetzt auch eine Knoten-Obergrenze gegen
  sich selbst referenzierende Bäume.
- Eine gültige Factur-X-/ZUGFeRD-Rechnung im AF-Array wird auch dann
  gefunden, wenn viele fremde XML-Anhänge im Namensbaum davorstehen: Das
  AF-Array wird zuerst gelesen, und die in XMP deklarierte Rechnungsdatei
  hat einen reservierten Platz im Anhangs-Budget.
- Die Profil-Erkennung (BT-24) akzeptiert bekannte URN-Stämme nur noch am
  Anfang einer #-Komponente. Eine fremde Kennung, die einen echten Stamm
  lediglich enthält, erscheint jetzt ehrlich als „EN 16931-basiert?“.
- Das Auto-Backup vor einem Batch-Speichern scheitert nicht mehr an
  fachfremden Bestandswerten (etwa von exiftool gelesenes Rating 6 oder
  GPS 91/181): Der Export sichert den Bestand, und erst der Import prüft je
  Eintrag gegen den Zielzustand — vor der Papierkorb-Sicherung und im
  Dry-run genauso wie im echten Lauf.
- EPUB-Backups sind wieder vollständig wiederherstellbar: Ein Serienindex
  ohne Serie (calibre:series_index) und GIF-/WebP-Cover — beides in fremden
  EPUBs verbreitet — können jetzt auch geschrieben werden, nicht nur
  exportiert. Für mobi/azw3/fb2 gelten unverändert JPEG/PNG und die Regel
  „Index braucht Serie“.
- Ein einzelnes fremd kodiertes Byte in einem MediaInfo-Bericht verstümmelt
  keine gültigen UTF-8-Tags (etwa Emoji) mehr, und als Surrogate-Escape
  gelieferte MacRoman-Bytes (z.B. „ä“) werden korrekt gedeutet statt als
  Steuerzeichen zu enden.
- Wird während eines reinen Feld-Speicherns das unveränderte Originalcover
  erneut ausgewählt, gilt der Eintrag nach dem Speichern wieder als sauber,
  statt beim nächsten Speichern die Datei ohne Inhaltsänderung
  auszutauschen.
- Die Installer-Sperre entsteht jetzt atomar mitsamt Besitzerangabe
  (Symlink statt Verzeichnis + Datei), und die Übernahme einer verwaisten
  Sperre prüft den Besitzer im gegenseitigen Ausschluss erneut — zwei
  Wettläufe, in denen parallele Installationen dieselbe App gleichzeitig
  verändern konnten, sind damit geschlossen.
- Der GUI-Selbsttest `scripts/dev-screenshot.sh` beendet die Test-App auch
  in allen Fehlerpfaden zuverlässig (warten, notfalls hart beenden), statt
  sie sichtbar weiterlaufen zu lassen.

## [0.21.24] — 2026-08-15

### Geprüft

- Die CodeQA-Kampagne ist mit allen 14 Bereichen und vier
  Querschnittsthemen abgeschlossen. Zwölf Bereiche wurden verbessert; zwei
  Bereiche waren nach vollständiger Prüfung bereits sauber.
- Der Abschlusslauf bestand mit 138 Core-/CLI-Tests in 13 Suites, 30
  App-Tests in vier Suites und einem App-Release-Build ohne Swift-Warnung.
- Die Schichtentrennung zwischen portablem Core, CLI und App bleibt passend.
  Als belegte spätere Teilungsgrenze bleibt `AppModel.swift`, das Laden,
  Speichern, Konflikte, Archivimporte und App-Lebenszyklus bündelt.

## [0.21.23] — 2026-08-15

### Behoben

- Die beiden Icon-Generatoren verwenden je Lauf einen eigenen Tempordner und
  können parallel ausgeführt werden, ohne sich gegenseitig das Iconset zu
  löschen.
- Ein nicht anlegbarer Ausgabeordner oder ein fehlgeschlagener `iconutil`-
  Aufruf liefert jetzt einen Fehlercode, statt trotz „FEHLER“-Text erfolgreich
  zu enden. Ein headless Regressionstest läuft auch in der macOS-CI.
- Der Screenshot-Selbsttest meldet nur noch Erfolg, wenn App-Aktivierung,
  Fensterermittlung, `screencapture`, eine nichtleere PNG-Datei und die
  abschließende App-Terminierung tatsächlich erfolgreich waren.

## [0.21.22] — 2026-08-15

### Behoben

- Cover-Drop: Bei mehreren abgelegten Dateien werden die Provider jetzt in
  Reihenfolge bis zum ersten gültigen und für den Editor erlaubten Bild
  geprüft. Eine kaputte erste Datei oder ein für E-Books unzulässiges GIF
  verdeckt kein folgendes JPEG oder PNG mehr.
- Das gemeinsame asynchrone Drop-Handling erfüllt die Swift-6-
  Nebenläufigkeitsregeln; der App-Release-Build ist dadurch frei von
  Swift-Warnungen.
- Der Cover-Export verwendet für BMP-Daten `.bmp` und für unbekannte Daten
  `.bin`, statt beide fälschlich als JPEG zu benennen.

## [0.21.21] — 2026-08-15

### Geprüft

- CodeQA: App-Szene, Finder- und Datei-Drop-Öffnen, Fenster- und
  App-Terminierung, Konfliktdialoggrenzen, Einstellungen sowie das
  Homebrew-Installationsangebot wurden vollständig geprüft. Die App-Suite,
  der Release-Build und der große Fehlerausgabe-Test des Installers bestanden
  ohne Bereichsabweichung.

## [0.21.20] — 2026-08-15

### Behoben

- E-Rechnungen: Die Profilauflösung verlangt jetzt die bekannten
  XRechnung-, Peppol-, Factur-X- oder ZUGFeRD-URN-Stämme. Ähnlich benannte
  fremde Kennungen werden nicht mehr als bekannter Standard ausgegeben.
- Bei mehreren Rechnungs-XMLs in einem PDF gewinnt der in XMP deklarierte
  Dateiname. Ohne Deklaration bleibt die PDF-Anhangsreihenfolge erhalten,
  statt unbekannte Dateinamen alphabetisch umzudeuten.
- Nur veröffentlichte Factur-X-/ZUGFeRD-XMP-Namensräume dürfen die
  Rechnungsdeklaration und damit die Anhangsauswahl bestimmen.
- CII-Datumswerte im Format 102 erhalten nur dann eine ISO-Lesehilfe, wenn
  Jahr, Monat und Tag einen wirklichen Kalendertag bilden. Der Rohwert bleibt
  bei ungültigen Angaben unverändert sichtbar.

## [0.21.19] — 2026-08-15

### Behoben

- MediaInfo: Jeder Track und sein verschachtelter Zusatzblock behalten jetzt
  ihre eigene Feldreihenfolge. Zuvor übernahm jeder weitere Track unbemerkt
  die Reihenfolge des ersten.
- Kaputtes oder strukturell falsches MediaInfo-JSON wird als Fehler gemeldet,
  statt wie ein erfolgreicher Bericht ohne Tracks auszusehen.
- Großgeschriebene Surrogate-Escapes und MacRoman-Rohbytes aus alten Tags
  werden repariert, ohne dabei häufige Latin-1-Zeichen falsch umzudeuten.
- Ein langsamer alter MediaInfo-Aufruf kann nach einem Dateiwechsel nicht mehr
  den Bericht der nun ausgewählten Datei im SwiftUI-Tab überschreiben.

## [0.21.18] — 2026-08-15

### Geprüft

- CodeQA: TagLib-Ladepfad- und Auslieferungstests wurden nach dem gemeinsamen
  Tempordner-Helfer erneut geprüft. Ein echter Release-/Property-List-Build,
  Installer-Rollback, Mindestversionen und die drei Testtreiber bestanden auch
  mit einem gesetzten, nicht vorhandenen `TMPDIR`.

## [0.21.17] — 2026-08-15

### Behoben

- Tests: TagLib-, Installer- und Mindestversions-Regressionen wählen ihren
  Arbeitsordner über einen gemeinsamen Helfer. Ein gesetztes, aber nicht mehr
  vorhandenes oder nicht beschreibbares `TMPDIR` fällt kontrolliert auf
  `/tmp` zurück, statt die Suite vor dem eigentlichen Test abzubrechen.
- Ein eigener Shell-Test hält sowohl ein gültiges benutzerdefiniertes
  `TMPDIR` als auch den Rückfall bei einem fehlenden Elternordner fest und
  läuft in der macOS-CI mit.

## [0.21.16] — 2026-08-15

### Geprüft

- CodeQA: Medienerkennung und Ordnerfilterung wurden nach der neuen
  XML-Streaming-Erkennung erneut geprüft. Vier gezielte Tests bestätigen
  lange XML-Vorspänne, fremde Namensräume, reguläre Dateien und unveränderte
  kanonische Deduplizierung.

## [0.21.15] — 2026-08-15

### Behoben

- E-Rechnungen: Die schnelle XML-Erkennung liest als Stream bis zum ersten
  Start-Element und prüft dort Wurzelname und aufgelösten Namensraum. Gültige
  Rechnungen mit mehr als 8 KiB Prolog oder Kommentaren werden nicht mehr
  übersehen; gleichnamige Fremd-XMLs gelten nicht mehr als Rechnung.
- Medienerkennung, direkte XML-Prüfung und PDF-Anhangssuche verwenden damit
  dieselbe parserbasierte Regel, ohne große XML-Dateien für einen Ordner-Scan
  vollständig in den Speicher zu laden.

## [0.21.14] — 2026-08-15

### Geprüft

- CodeQA: Die zentrale Medienerkennung wurde vollständig auf Formatzuordnung,
  reguläre Dateien, rekursive Ordnerauflösung, Symlink-Deduplizierung und
  stabile Sortierung geprüft. Die abweichende XML-Rechnungserkennung ist als
  eigener priorisierter Querschnittsfund festgehalten.

## [0.21.13] — 2026-08-15

### Geprüft

- CodeQA: Archiv-/Kollisions- und CLI-Tagregressionen wurden nach der
  Konsolidierung ihrer Prozessausgabe erneut an den Aufrufgrenzen geprüft.
  Drei beziehungsweise sieben gezielte Tests sowie die vollständige Suite mit
  130 Tests bestätigen den unveränderten Fachvertrag.

## [0.21.12] — 2026-08-15

### Behoben

- Tests: Drei CLI-Prozesshelfer sind in einer gemeinsamen Implementierung
  zusammengeführt, die Standard- und Fehlerausgabe gleichzeitig leert. Große
  Ausgaben können das Kind dadurch nicht mehr an einer vollen zweiten Pipe
  blockieren; eine Regression prüft je 1 MiB auf beiden Kanälen.

## [0.21.11] — 2026-08-15

### Behoben

- CLI: `tagx set` lehnt leere Tag-Schlüssel sowie leere Quellen oder Ziele
  beim Kopieren vor jeder Dateiänderung ab. TagLib hatte einen leeren Schlüssel
  zuvor tatsächlich gespeichert.
- CLI: `tagx cover set` prüft die Bildsignatur, bevor eine Sicherung oder
  Änderung beginnt; beliebige Nicht-Bilddaten werden nicht mehr eingebettet.
- CLI: Der Cover-Export überschreibt keine vorhandenen Dateien mehr. Alle
  Zielkollisionen werden vorab geprüft und die Ausgaben zusätzlich exklusiv
  angelegt.
- CLI: BMP-Cover erhalten `.bmp`; unbekannte Typen werden als `.bin` statt
  fälschlich als JPEG exportiert.

## [0.21.10] — 2026-08-15

### Geprüft

- CodeQA: Die gemeinsame Bildfeldvalidierung wurde an ihren Grenzen in
  App-Speicherung, Archivimport und Bild-Schreibweg erneut geprüft. Die
  gezielten Regressionen sowie die vollständigen Suiten mit 125 Core-/CLI-
  und 27 App-Tests bestätigen, dass alle drei Bereiche aktuell bleiben.

## [0.21.9] — 2026-08-15

### Behoben

- Bildmetadaten: Eine gemeinsame Core-Regel lehnt Bewertungen außerhalb
  von -1…5, unvollständige GPS-Paare, nichtnumerische Koordinaten sowie Breiten
  außerhalb -90…90° und Längen außerhalb -180…180° ab. Core, CLI, App und
  Archivimport wenden sie vor Werkzeuglauf, Sicherung oder Batch-Mutation an.
- Bereits vorhandene fachfremde Werte blockieren das Bearbeiten anderer Felder
  nicht; erst eine Änderung des betroffenen Felds wird geprüft.

## [0.21.8] — 2026-08-15

### Geprüft

- CodeQA: Der Bild-Metadatenweg über exiftool wurde vollständig auf
  Feldabbildung, Prozessargumente, atomaren Austausch, Dateistempel und
  CLI-Sicherung geprüft. Die bereichsübergreifend uneinheitliche Prüfung von
  Bewertung und GPS ist als eigenes priorisiertes Querschnittsthema erfasst.

## [0.21.7] — 2026-08-15

### Behoben

- EPUB: Eine Änderung des dargestellten Haupttitels erhält weitere Titel wie
  Untertitel samt ihren OPF-Verfeinerungen. Beim ausdrücklichen Löschen werden
  Zielknoten und Verfeinerungen dagegen gemeinsam entfernt.
- EPUB: Ersetzte Schlagwörter hinterlassen keine `refines`-Verweise auf
  entfernte XML-IDs mehr.
- EPUB: Prozentkodierte Manifest-URLs werden vor dem Zugriff auf den
  zugehörigen ZIP-Eintrag dekodiert; Coverdateien mit Leerzeichen im Namen
  lassen sich dadurch lesen und ersetzen.

## [0.21.6] — 2026-08-15

### Behoben

- Build: Ein per `SPARKLE_FEED_URL` gesetzter Testfeed wird mit `plutil`
  statt als unkodierter XML-Text in die `Info.plist` geschrieben. Gültige
  URLs mit Query-Parametern erzeugen dadurch kein unlesbares App-Bundle mehr.
- Der macOS-CI-Test baut ein echtes lokales App-Bundle mit einer solchen URL
  und prüft sowohl die Property List als auch den unveränderten Feedwert.

## [0.21.5] — 2026-08-15

### Behoben

- TagLib-Shim: Der Versionsstring wird einmalig als unveränderlicher
  C++-`static` initialisiert. Parallele Abfragen schreiben nicht mehr
  unkoordiniert in dasselbe Zeichenarray.

## [0.21.4] — 2026-08-15

### Behoben

- Archivimport: Audio-PropertyMaps mit vorhandenen, aber leeren Wertlisten
  werden als unerreichbarer Soll-Zustand vor der ersten Batch-Mutation
  abgelehnt. Zuvor änderte der Import bereits frühere Dateien und meldete den
  unrepräsentierbaren Eintrag bei jedem weiteren Lauf erneut als geändert.

## [0.21.3] — 2026-08-15

### Behoben

- App: Solange die Entscheidung über eine extern geänderte Datei offen ist,
  werden konkurrierende destruktive Aktionen wie App-Terminierung, Import
  oder Entfernen abgewiesen. Dadurch können nicht mehr zwei Konfliktdialoge
  gleichzeitig denselben Editor-Puffer behandeln.

## [0.21.2] — 2026-08-15

### Geprüft

- CodeQA: Der vollständige Dateisicherheitskern (atomarer Austausch,
  Dateistempel, Papierkorb-Sicherung und Platzprüfung) wurde samt direkten
  Grenzen und Integritätstests korrektheitsorientiert geprüft. Es bestand
  kein Änderungsbedarf.

## [0.21.1] — 2026-08-15

Einundzwanzig Funde des Code-Reviews vom 2026-08-15 behoben.

### Behoben

- E-Rechnung: Attribute mit eigener EN-16931-Zuordnung werden jetzt als
  solche ausgewiesen — `unitCode` an Mengen (BT-130/BT-150) und das
  `name`-Attribut am UBL-Zahlungsart-Code (BT-82) erscheinen in App, CLI und
  JSON (`attributeTerms`) mit BT-Nummer und Namen.
- E-Rechnung: `ChargeIndicator` akzeptiert die XML-Schema-Booleans `1`/`0`;
  unbekannte Werte bekommen bewusst keine Nachlass-/Zuschlag-Zuordnung mehr
  (vorher wurde ein Zuschlag mit Wert `1` als Nachlass beschriftet).
- E-Rechnung (UBL): Eine `AdditionalDocumentReference` mit Typcode 130
  (Rechnungsgegenstand, BT-18) wird nicht mehr fälschlich als
  rechnungsbegründende Unterlage (BG-24) gruppiert.
- E-Rechnung: Der Inhalts-Schnelltest prüft jetzt das erste Start-Element
  statt beliebiger Teilstrings (ein Kommentar macht Fremd-XML nicht mehr zur
  Rechnung) und versteht UTF-16.
- E-Rechnung (PDF): Die XMP-Deklaration wird über den aufgelösten
  Attribut-Namensraum erkannt statt über konventionelle Präfixe; die
  Extraktion eingebetteter Dateien filtert Nicht-XML-Anhänge vor dem
  Entpacken und begrenzt Anzahl und Gesamtgröße.
- App: Ein Rechnungs-PDF öffnet auch ohne exiftool (als reine
  Rechnungs-Anzeige); der E-Book-Editor extrahiert und parst ein
  Rechnungs-PDF nur noch einmal statt doppelt.
- App: Eine Cover-Auswahl während eines laufenden Speicherns geht nicht mehr
  verloren; ein Serienindex ohne Serie wird vor der Papierkorb-Sicherung
  abgelehnt statt danach.
- Archiv: `validate` lehnt v1-Archive mit Serienindex-ohne-Serie oder
  Nicht-JPEG/PNG-Covern (z.B. GIF aus bestehenden EPUBs) nicht mehr ab —
  die engeren Regeln gelten erst am tatsächlichen Schreibweg.
- CLI: `tagx invoice --json --terms-only` filtert jetzt auch die
  JSON-Ausgabe; `tagx export` zählt E-Rechnungen nicht mehr als archivierte
  Dateien und lehnt reine Rechnungs-Eingaben ab.
- Installer: Die Sperre schreibt PID **und** Prozessstartzeit (eine
  wiederverwendete PID blockiert Updates nicht mehr), Übernahme verwaister
  Sperren läuft atomar über Umbenennen, das Initialisierungsfenster hat eine
  Wartefrist, und freigegeben wird nur die eigene Sperre. Die Tests warten
  auf die vollständig initialisierte Sperre und decken PID-Wiederverwendung
  und das Initialisierungsfenster ab.
- App-Lokalisierung: Die neuen Oberflächentexte der E-Rechnungs-Anzeige sind
  im String Catalog mit englischen Übersetzungen hinterlegt; die READMEs
  präzisieren, dass die EN-16931-Feldnamen (deutsche Benennungen) in App und
  CLI sprachunabhängig gleich bleiben. Die Drittanbieter-Hinweise nennen die
  Herkunft der Feldnamen jetzt widerspruchsfrei (Benennungen wie in der
  deutschen EN 16931/XRechnung-Spezifikation der KoSIT).
- Test-Attrappe für `install_name_tool` protokolliert Argumente einzeln
  (Argumentgrenzen-Regression war vorher unsichtbar);
  `knowledge/epub-opf-struktur.md` beschreibt Autoren- und Serien-Schreibweg
  jetzt zutreffend getrennt.

## [0.21.0] — 2026-08-14

### Hinzugefügt

- **E-Rechnungen anzeigen** (nur Lesen): ZUGFeRD, Factur-X, XRechnung und
  Peppol BIS in beiden Syntaxen (UN/CEFACT CII und OASIS UBL, Rechnung und
  Gutschrift). Erkannt werden Standard und Profil aus der
  Spezifikationskennung (BT-24, z.B. MINIMUM bis EXTENDED, XRechnung-Version);
  angezeigt wird jedes befüllte Feld mit seiner EN-16931-Feldbezeichnung
  (BT-/BG-Nummer und deutschem Namen). Felder ohne Zuordnung (z.B.
  EXTENDED-Zusatzfelder) bleiben mit Rohpfad sichtbar — es geht nichts
  verloren. Häufige Codes werden entschlüsselt (Rechnungstyp, USt-Kategorie,
  Zahlungsart, Mengeneinheiten, CII-Datumsformat als ISO-Lesehilfe).
- Neues portables Modul `EInvoiceCore` (ohne TagLib-Abhängigkeit) mit
  namensraum-kanonisierendem XML-Baum und den Pfad-Tabellen der
  EN-16931-Syntax-Bindings; PDF-Extraktion (eingebettete Dateien + Factur-X-
  XMP-Deklaration) über CoreGraphics.
- App: `.xml`-Dateien werden angenommen, wenn sie tatsächlich eine
  E-Rechnung enthalten (Inhalts-Schnelltest statt Endungs-Vertrauen); die
  Ansicht ist filterbar (Wert, Element, BT-Nummer, Feldname) und auf
  EN-16931-Felder einschränkbar. PDFs mit eingebetteter Rechnung bekommen im
  E-Book-Editor den zusätzlichen Tab „E-Rechnung“.
- CLI: `tagx invoice` (Text und `--json`, `--terms-only`) für XML- und
  PDF-Rechnungen.
- ZUGFeRD 1.0 (vor EN 16931) wird erkannt und vollständig roh angezeigt,
  bewusst ohne BT-Zuordnung.

## [0.20.2] — 2026-08-11

Alle Punkte dieser Version stammen aus dem Code-Review vom 2026-08-11.

### Geändert

- `tagx ebook show` liest Felder und Cover unter einem gemeinsamen Dateistempel
  und meldet einen Cover-Lesefehler als Fehler, statt ihn als „kein Cover"
  auszugeben. `tagx exif show --all` sichert Kernfelder und Metadatengruppen
  ebenso gemeinsam ab.
- Ein Serienindex ohne Serienname wird abgelehnt, statt einen Schreibvorgang
  auszulösen, bei dem der Index nirgends landet. Coverdaten müssen an ihrer
  Dateisignatur als JPEG oder PNG erkennbar sein — CLI, App und Archivimport
  prüfen das vor der Sicherungskopie.
- Dasselbe Cover in der App erneut auszuwählen ist keine Änderung mehr: Die
  Datei behält Identität und Änderungszeit, es entsteht keine Sicherung. Dafür
  hält die App das gelesene Cover jetzt im Modell — der Editor braucht keinen
  eigenen Dateizugriff mehr.

### Behoben

- `tagx cover set` und `tagx cover remove` reichen den gelesenen Dateistempel
  bis in den atomaren Austausch weiter. Eine zwischen Sicherung und Schreiben
  untergeschobene Datei wird nicht mehr überschrieben.
- Der Archivimport der App gibt die geprüfte Zielliste auch dann verbindlich
  mit, wenn kein Ziel außerhalb des Archivordners liegt. Ein während des
  Save/Discard-Dialogs umgebogener Symlink kann dadurch keine nie angezeigte
  Datei mehr ändern und keinen fremden Editor-Puffer verwerfen.
- Eine geänderte oder gelöschte ISBN lässt den `unique-identifier` des EPUB
  nicht mehr ins Leere zeigen (siehe
  [knowledge/epub-opf-struktur.md](knowledge/epub-opf-struktur.md)).
- `tagx exif set --copy` findet die Roh-Tags einer über eine Verknüpfung
  angegebenen Datei wieder; vorher blieb der Kopierwunsch wirkungslos und der
  Befehl meldete „No changes".
- Die Mindestversionsprüfung des Release-Builds schlägt jetzt geschlossen fehl:
  Ein Fehler von `vtool`, eine fehlende Angabe oder ein zu neuer zweiter
  Architektur-Slice werden nicht mehr übersprungen.
- Der Release-Build erkennt TagLib-Ladepfade auch in Build-Verzeichnissen mit
  Leerzeichen und prüft nach dem Umbiegen, dass jede TagLib-Referenz ins Bundle
  zeigt. Vorher konnte ein formal erfolgreicher Release auf fremden Macs nicht
  starten.
- Zwei gleichzeitige Installationen auf dasselbe Ziel werden über eine Sperre
  serialisiert; der zweite Lauf bricht ab, ohne etwas zu verändern. Während des
  Rollbacks werden Abbruchsignale ignoriert statt zugelassen.
- Die Shell-Tests der Auslieferungsskripte laufen in der CI. Neu dabei:
  Regressionen für die Mindestversionsprüfung und für die TagLib-Ladepfade.

## [0.20.1] — 2026-08-10

Alle Punkte dieser Version stammen aus dem Code-Review vom 2026-08-09.

### Geändert

- Audio-, Bild- und E-Book-Leser verwenden denselben Schnappschussvertrag:
  Inhalt und Datei-Stempel werden vor und nach allen zusammengehörigen Reads
  geprüft. Bei E-Books gehören Felder und Cover zu einem gemeinsamen Stand;
  auch ein vermeintlicher No-op wird vor der Erfolgsmeldung erneut geprüft.
- Die Dokumentation beschreibt jetzt korrekt, dass auch exiftool ausschließlich
  eine Geschwisterkopie innerhalb von `AtomicFileRewrite` verändert. Ein
  zweiter Hardlink bleibt beim atomaren Austausch bewusst auf der alten
  Fassung; behoben wurde die zuvor unerkannte Ersetzung am selben Pfad.

### Behoben

- Der verteilbare macOS-Build bündelt eine gepinnte, prüfsummenverifizierte
  TagLib mit Mindestziel macOS 14 und prüft alle Mach-O-Dateien im App-Bundle.
  Ein Build auf einem neueren macOS kann dadurch nicht mehr unbemerkt eine nur
  dort lauffähige Homebrew-Bibliothek in die als macOS 14+ ausgewiesene App
  übernehmen.
- Archivimporte erfassen Zielpfad, Dateiidentität und Stempel gemeinsam in der
  Vorprüfung und tragen genau diesen Stand bis zum Read, No-op oder atomaren
  Austausch. Eine neue Inode gilt niemals allein wegen desselben Pfads als die
  zuvor geprüfte Datei.
- `tagx exif set` und `tagx ebook set` reichen den gelesenen Stempel bis in den
  atomaren Schreibweg weiter. Fremde Änderungen nach dem Lesen werden weder
  überschrieben noch fälschlich als „No changes" bestätigt.
- E-Book-Backups können Felder und Cover nicht mehr aus zwei nacheinander am
  selben Pfad gesehenen Dateifassungen mischen.
- EPUB-Cover-IDs werden gegen alle IDs des OPF-Dokuments gewählt, nicht nur
  gegen Manifest-IDs.
- Der Installer entfernt ein bei der Endprüfung abgelehntes Bundle auch bei
  einer Erstinstallation. Bei Updates bleibt die gute alte Fassung erhalten,
  falls schon das Zurückholen fehlschlägt.

## [0.20.0] — 2026-08-07

Alle Punkte dieser Version stammen aus dem Code-Review vom 2026-08-06.

### Geändert

- Bild-Metadaten schreibt exiftool nicht mehr direkt in die Originaldatei,
  sondern in eine Geschwisterkopie; erst nach der Prüfung ersetzt sie das
  Original in einem atomaren Schritt, und der Datei-Stempel wird unmittelbar
  davor noch einmal verglichen. Eine fremde Änderung während des
  exiftool-Laufs kann so nicht mehr still verworfen werden. Nebenwirkung wie
  schon bei Audio: Die Datei bekommt eine neue Inode, zusätzliche Hardlinks
  zeigen danach weiter auf den alten Stand.
- `tagx set` bricht mit einer Fehlermeldung ab, wenn ein anderes Programm die
  Datei zwischen Lesen und Schreiben verändert hat — auch dann, wenn sich aus
  Sicht des gelesenen Standes gar nichts ändern müsste. Vorher meldete der
  Befehl in diesem Fall „0 field(s) changed" und Erfolg, obwohl der gewünschte
  Wert nicht in der Datei stand.

### Behoben

- Die Rückfrage „Datei wurde außerhalb geändert" führt genau die angeklickte
  Entscheidung aus. Vorher räumte das Schließen des Dialogs die bestätigte
  Datei aus der Warteschlange: Sie wurde nicht gespeichert, und die Bestätigung
  traf stattdessen die nächste Datei ohne deren eigene Rückfrage.
- Archiv-Import: Jedes Ziel wird unmittelbar vor seiner Änderung erneut auf
  Dateiidentität geprüft. Wird eine noch nicht bearbeitete Datei während des
  laufenden Imports durch eine Verknüpfung auf eine andere Datei ersetzt,
  bleibt diese unangetastet; der Eintrag erscheint als fehlgeschlagen. Der beim
  Lesen erhobene Stempel wandert außerdem bis in den Schreibvorgang.
- Tag-Export und Tag-Sicherung erzeugen kein Archiv mehr, das der eigene Import
  später ablehnen würde (etwa eine Bildbewertung außerhalb von -1 bis 5). Eine
  solche Sicherung ließe sich nicht wiederherstellen.
- EPUB: Die id einer neu geschriebenen Serie weicht allen im OPF vergebenen ids
  aus, nicht nur denen der `<meta>`-Elemente. Vorher konnte eine doppelte
  XML-ID entstehen und die zugehörigen `refines`-Verweise mehrdeutig machen.
- E-Book-Schreibweg: Innerhalb der Geschwisterkopie entsteht keine zweite
  Vollkopie mehr, und Fehlermeldungen nennen die gewählte Datei statt des
  versteckten Zwischenpfads.
- Eine Videodatei, die zwischen Auswahl und Lesen verschwindet, landet nicht
  mehr als schreibgeschützter Platzhalter in der Liste.
- `install.sh` stellt die bisherige Installation wieder her, wenn der Austausch
  abgebrochen wird oder die abschließende Prüfung des installierten Bundles
  fehlschlägt. Vorher konnte `/Applications/TagExplosion.app` ganz verschwinden
  oder ein abgelehntes Bundle stehen bleiben.
- `build.sh --debug` behält seine Debug-Symbole; gestrippt wird nur noch der
  Release-Build.
- Die CLI-Tests erzeugen ihre Audio-Fixture selbst. Ein gefilterter Testlauf
  auf einem frischen Checkout scheiterte vorher am fehlenden `sample.mp3`.

## [0.19.0] — 2026-08-03

### Behoben

- Dateisicherheit: Der beim Lesen erhobene Datei-Stempel wird jetzt bis
  unmittelbar vor den atomaren Austausch mitgeführt und dort erneut geprüft.
  Ändert ein anderes Programm die Datei währenddessen, bricht das Speichern ab,
  statt die fremde Änderung zu verwerfen. Der Stempel enthält zusätzlich die
  Dateikennung, damit auch eine gleich große Ersetzung mit erhaltener
  Änderungszeit auffällt.
- Die App liest Inhalt und Stempel als einen zusammengehörigen Schnappschuss.
  Vorher konnten alte Daten mit dem Stempel einer neueren, fremden Dateiversion
  zusammenkommen — das nächste Speichern hätte diese Version ungefragt
  überschrieben.
- Beim Speichern mehrerer Dateien bekommt jede Datei mit fremder Änderung ihre
  eigene Rückfrage. Vorher überschrieb ein zweiter Konflikt den ersten: Der
  Dialog gehörte dann zur falschen Datei.
- EPUB: Eine Autorenänderung löscht keine Mitwirkenden mit anderer Rolle
  (Herausgeber, Übersetzer) mehr, und eine Serienänderung lässt unabhängige
  Sammlungen des Buchs stehen. Platzmangel wird wieder als solcher gemeldet.
- Archiv-Import: Wird ein freigegebenes Ziel nach der Anzeige durch eine
  Verknüpfung auf eine andere Datei ersetzt, bricht der Import ab.
  Bildbewertungen außerhalb von -1 bis 5 und Serienangaben für PDF werden vor
  jeder Änderung abgelehnt. Zwei Sicherungen desselben Ordners innerhalb einer
  Sekunde überschreiben sich nicht mehr.
- Papierkorb-Sicherung: parallele Sicherungen laufen serialisiert, ein
  gemerkter Stand gilt nur solange seine Kopie wirklich existiert, und ein
  Stapel wird vor der ersten Kopie im Ganzen gegen den freien Platz geprüft.
  Auf Nicht-APFS-Datenträgern schlägt die Platzprüfung nicht mehr grundlos fehl.
- `tagx set` schreibt nur noch, wenn sich wirklich etwas ändert, und meldet die
  echte Zahl geänderter Felder.
- `./install.sh` beendet eine laufende App nur noch regulär und bricht ab, wenn
  sie nicht beendet wird; ungesicherte Änderungen gehen dadurch nicht mehr
  verloren. Das neue Bundle wird erst vollständig geprüft und dann eingesetzt —
  eine fehlgeschlagene Aktualisierung lässt die alte Installation stehen.

### Geändert

- Die in-place arbeitenden Backend-Methoden von `TagFile` und `EbookTool` sind
  nicht mehr Teil der öffentlichen Core-Schnittstelle. Schreiben läuft von außen
  ausschließlich über den abgesicherten Transaktionsweg.
- `THIRD-PARTY-NOTICES.md` und die READMEs beschreiben jetzt genau, was beim
  Bündeln an TagLib und Sparkle verändert wird (Install-Namen, entfernter
  `XPCServices`-Ordner, Neusignierung) statt sie pauschal „unverändert" zu
  nennen.

## [0.18.0] — 2026-07-29

### Hinzugefügt

- Fehlen `mediainfo` oder `exiftool`, bietet die App bei jedem Start an, die
  fehlenden Formeln über Homebrew zu installieren (mit Fortschrittsanzeige und
  ehrlicher Fehlermeldung); ohne Homebrew verweist sie auf brew.sh. „Später"
  verschiebt auf den nächsten Start, „Nicht mehr fragen" beendet das Angebot
  dauerhaft. Calibre bleibt bewusst außen vor (optionales Extra, Cask statt
  Formel).

## [0.17.3] — 2026-07-25

### Geändert

- `docs/sparkle-release.md` um die beiden Stolpersteine des ersten echten
  Release-Laufs ergänzt: Die Umgebung `github-pages` muss neben `main` auch
  Tags (`v*`) zum Deployment zulassen, sonst lehnt sie den vom Release
  ausgelösten Lauf ab; und `sign_update --verify` braucht `--account`, um den
  Feed gegen das DMG zu prüfen.

## [0.17.2] — 2026-07-25

### Hinzugefügt

- Social-Preview-Bild für GitHub (`docs/social-preview.png`) samt
  reproduzierbarem Generator `scripts/gen-social-preview.py`.

### Geändert

- `docs/sparkle-release.md`: genaue Befehle für den Export des
  Sparkle-Schlüssels (mit `--account`, ohne ihn je auf stdout zu zeigen), der
  Release-Ablauf verweist jetzt auf `release.sh`, und es steht dort, warum
  dieses Projekt seinen eigenen Schlüssel behält, obwohl Sparkle einen
  Schlüssel für beliebig viele Apps erlaubt: Jede bereits verteilte Fassung
  akzeptiert nur Updates, die zu ihrem eingebauten `SUPublicEDKey` passen.

## [0.17.1] — 2026-07-25

### Behoben

- Die Bildvorschau ließ ein `NSImage` aus einem Hintergrund-Task auf den
  MainActor wandern. Mit älteren Swift-6-Toolchains als der lokalen ist das ein
  Übersetzungsfehler — gefunden vom ersten CI-Lauf auf GitHub. Gelesen werden
  jetzt die Bytes, das Bild entsteht auf dem MainActor.

## [0.17.0] — 2026-07-25

### Hinzugefügt

- `install.sh`: baut die App als Release, signiert sie mit Developer ID und
  Hardened Runtime, notarisiert sie bei Apple, heftet das Ticket an und
  installiert sie nach `/Applications` — aber erst, nachdem Stapler,
  Gatekeeper und Signatur die Notarisierung bestätigt haben.
  `--no-notarize` baut ein schnelles Testbundle, das im Projektordner bleibt.
- `release.sh`: erzeugt das verteilbare, notarisierte DMG mit Hintergrundbild
  und Finder-Layout.
- Beide Skripte fragen einmal nach dem lokalen notarytool-Schlüsselbundprofil
  und merken sich nur dessen Namen clone-lokal. Damit laufen sie auf jedem Mac,
  ohne dass etwas Vertrauliches im Repository landet.
- `THIRD-PARTY-NOTICES.md` mit den vollständigen Lizenztexten der
  mitgelieferten und gelinkten Komponenten (TagLib, Sparkle, ZIPFoundation,
  swift-argument-parser) und der Begründung, warum die nur aufgerufenen
  Programme lizenzrechtlich nicht durchgreifen. Ersetzt `THIRD-PARTY.md` und
  liegt auch im App-Bundle.
- READMEs: App-Symbol im Kopf und ein eigener Abschnitt darüber, wie die
  Dateien geschützt werden.

### Behoben

- AVI-Dateien ließen sich nicht öffnen, obwohl sie als „nur Anzeige"
  angekündigt sind: TagLib kann AVI nicht lesen, und der Read-only-Fallback
  griff nur beim Öffnen, nicht beim Neuladen. Er liegt jetzt an einer Stelle
  für alle Lesewege. Eine wirklich kaputte Audiodatei meldet dagegen weiterhin
  einen Fehler, statt einen leeren Editor zu zeigen.

## [0.16.1] — 2026-07-25

### Behoben

- Eine Datei aus dem Finder zu öffnen („Öffnen mit …", Ziehen aufs
  Dock-Symbol, `open -a`) funktionierte nicht, wenn die App dabei startete:
  Sie lief unsichtbar ohne Fenster weiter und lud die Datei nie. Beim Start
  mit einer Datei legt SwiftUI kein Fenster an, und macOS liefert das
  Öffnen-Ereignis nur an ein vorhandenes Fenster aus. Die App sorgt jetzt
  selbst dafür, dass ein Fenster erscheint, und nimmt die Datei über den
  App-Delegate entgegen statt über SwiftUIs `onOpenURL`.

## [0.16.0] — 2026-07-25

### Hinzugefügt

- **Abgesicherter Modus** (Standard an): Vor jeder Änderung wandert eine
  unveränderte Kopie der Datei in den Papierkorb — gesammelt in einem Ordner
  je Sitzung und je Datenträger. Zum Wiederherstellen die Kopie zurückziehen,
  zum Aufräumen den Papierkorb leeren. Auf APFS entsteht die Kopie als Klon
  und belegt zunächst keinen zusätzlichen Platz. Abschaltbar in den
  Einstellungen (⌘,) sowie per `--no-backup` bzw. `TAGX_NO_BACKUP=1` in der
  CLI.
- Warnung, wenn eine geöffnete Datei zwischenzeitlich von einem anderen
  Programm geändert wurde. Gespeichert wird erst nach ausdrücklicher
  Bestätigung; der fremde Stand liegt dann als Kopie im Papierkorb.
- Prüfung des freien Speicherplatzes, bevor eine Datei geschrieben wird.
- GitHub-Actions-Workflow, der Core, CLI und App auf macOS baut und testet.

### Geändert

- Audio- und Video-Tags werden nicht mehr in-place geschrieben: Die Änderung
  entsteht an einer Geschwisterkopie, wird geprüft (Datei wieder lesbar,
  Kanäle, Samplerate und Spielzeit unverändert) und ersetzt das Original erst
  danach in einem atomaren Schritt. Ein Absturz, ein Formatfehler oder ein
  voller Datenträger kann keine halb geschriebene Datei mehr hinterlassen.
  Nebenwirkung: Die Datei bekommt dabei eine neue Inode, zusätzliche Hardlinks
  zeigen danach weiter auf den alten Stand.
- Dateipfade gehen immer absolut an mediainfo, exiftool und `ebook-meta`,
  damit ein Dateiname mit führendem Bindestrich nicht als Option gelesen wird.

### Behoben

- Die Prüfung auf fremde Änderungen war wirkungslos, weil `URL.resourceValues`
  einmal gelesene Werte zwischenspeichert. Sie liest den Dateizustand jetzt
  ungepuffert.
