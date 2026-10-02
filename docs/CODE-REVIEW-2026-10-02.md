# Code-Review vom 2026-10-02

Projektweiter, risikobasierter Review mit einer Stunde Zeitbudget, ausgehend
von Version 0.46.92 (`993a789`). Neun Fehlergruppen wurden in 0.46.93 korrigiert.
Der Schwerpunkt lag auf Datenverlust, konkurrierenden Schreibvorgängen,
Formatgrenzen und Installation. Die Änderungen wurden getrennt nachgeprüft.
Eine vollständige Prüfung jeder Quellzeile ist damit nicht behauptet.

## Behobene Befunde

P1 bezeichnet möglichen Datenverlust oder eine verletzte Schreibsperre;
P2 bezeichnet falsche Ergebnisse oder verlorene Bedienaktionen.

| Priorität | Auslöser und vorheriges Verhalten | Korrektur und Beleg |
| --- | --- | --- |
| P1 | Während Untertitelverschiebung, Schichtentfernung oder Versionswiederherstellung eingegebene Änderungen wurden beim anschließenden `acceptNew` verworfen. | [AppModel](../App/Sources/TagExplosionApp/AppModel.swift) erfasst den Startzustand und übernimmt das Leseergebnis über `acceptSaved`. Gesteuerte asynchrone Tests prüfen saubere und bereits geänderte Puffer mit und ohne weitere Eingabe. Der Wiederherstellungsweg für schreibgeschützte Rechnungen bleibt erhalten. |
| P1 | XML-Leser und -Schreiber verglichen nur lokale Namen. Ein fremdes `vendor:title` konnte als Titel gelesen oder beim Leeren zusammen mit dem eigentlichen Titel gelöscht werden. | [XMLTools](../Sources/TagExplosionCore/XMLTools.swift), Office-, OpenDocument- und EPUB-Backend vergleichen auch die URI. Regressionen für DOCX, ODT, EPUB, CBZ, NFO und XSPF erhalten Fremdfelder. Lokale Präfixumbindung, präfigiertes OPF und neu registrierte DOCX-Metadaten sind zusätzlich geprüft. |
| P1 | Bereits eine Titeländerung setzte alle USLT-Sprachen auf die Sprache des ersten Frames. Einzelne Liedtextänderungen hatten denselben Effekt. Bei identischen Beschreibungen konnte TagLib die USLT-Frames sogar in andere Tag-Felder umwandeln. | [CTagShim](../Sources/CTagShim/shim.cpp) erhält die Sprache eindeutig zuordenbarer Frames. [TagFile](../Sources/TagExplosionCore/TagFile.swift) ändert alle Sprachen nur auf ausdrückliche Anforderung. Nicht eindeutig darstellbare Mehrsprachigkeit wird vor der Property-Mutation abgelehnt. Tests lesen rohe ID3-Frames und prüfen beim Abbruch die Bytegleichheit der Originaldatei. |
| P1 | Zwei Übernehmer einer verwaisten Installationssperre konnten zwischen Besitzerprüfung und Entfernen einer Hilfssperre deren Besitzer wechseln. Ein Prozess konnte dadurch die frisch erworbene Sperre des anderen entfernen. | [Installer](../scripts/install-verified-app.sh) entfernt fremde Übernahme-Hilfssperren nicht mehr automatisch. Die Shelltests prüfen alte Verzeichnisse und Symlinks, lebende Besitzer, Konkurrenz und Rollback. Die konkrete zeitliche Überschneidung wurde statisch belegt; der Regressionstest prüft das sichere Abbruchverhalten. |
| P2 | Mehrere kurz nacheinander angeforderte neue Fenster sammelten alle Dateisätze in einer Warteschlange für das erste Fenster; weitere Fenster blieben leer. | [WindowSessions](../App/Sources/TagExplosionApp/WindowSessions.swift) hält einen Dateisatz pro expliziter Fensteranforderung. Ein Test liefert zwei Aufträge an zwei Modelle; vor der Korrektur scheiterte er. |
| P2 | Das Bearbeiten von LRC-Zeilen entfernte Metadaten wie Interpret, Titel und `offset`. Ein vorhandener Zeitversatz ging damit verloren. | [LyricsFormats](../Sources/TagExplosionCore/LyricsFormats.swift) liest Metadaten unter Stempelprüfung und erhält sie beim atomaren Austausch. Der Test prüft Inhalt und Dateirechte. Explizites Löschen aller Zeilen entfernt weiterhin die Sidecar. |
| P2 | Fremde XML-Namensräume konnten über ein bekanntes Präfix oder ähnliche URI-Teile echte Rechnungsfelder und BT-Zuordnungen vortäuschen. | [XMLTree](../Sources/EInvoiceCore/XMLTree.swift) kanonisiert nur passende Namensräume. Unbekannte Präfixe können auch dynamische Pfadvergleiche nicht mehr treffen. Tests prüfen gefälschte UBL-/UNCEFACT-URIs und zusammengesetzte Präfixe mit echten Kindelementen. |
| P2 | Dokument-Metadaten akzeptierten beispielsweise `99:99:99+99:99` als Uhrzeit. | [DocumentTool](../Sources/TagExplosionCore/DocumentTool.swift) prüft Stunden-, Minuten-, Sekunden- und Offsetbereiche. Die DOCX-/ODT-Tests prüfen die Ablehnung vor jeder Dateiänderung. |
| P2 | Ein vollständiger Online-Treffer für eine CD ließ beim Überschreiben eine alte CD-Nummer wie `2/2` stehen. | [LookupPlanner](../Sources/TagExplosionCore/OnlineLookup/LookupPlanner.swift) korrigiert vorhandene CD-Nummern auch für vollständige Einzel-CD-Treffer. Tests sichern zugleich „nur leere Felder ergänzen“ und unvollständige Treffer ab. |

Die Gegenproben für Fensteraufträge, XML-Fremdfelder, LRC-Metadaten,
USLT-Sprachen, Rechnungsnamensräume und Datumswerte scheiterten mit dem
jeweiligen alten Verhalten. Für die App-Puffer wurde der vorhandene Fehler
am Aufrufweg belegt und der gemeinsame korrigierte Ablauf mit einem gezielt
angehaltenen Schreibauftrag geprüft.

## Abdeckung und Architektur

Das bestehende Schichtenmodell aus C-Shim, portablem Core, CLI und
SwiftUI-App bleibt passend. Zwei gemeinsame Grenzen wurden verstärkt:
XML-Auswahl nach URI und die Übernahme von Dateiänderungen in Editorpuffer.
Ein Architekturwechsel ist aus den Befunden nicht begründet.

| Bereich | Prüftiefe |
| --- | --- |
| Dateisicherheit, Backups, Export, Umbenennen | Atomare Schreibwege, Stempel, Papierkorb, Journal, Wiederherstellung, Archivvalidierung und deren Aufrufer vertieft gelesen. Kein weiterer eindeutiger Fehler bestätigt. |
| App-Zustand und Fenster | Laden, Speichern, Puffer, Versionshistorie, Fensterrouting und die zentralen Editor-/Batch-Aufrufer vertieft geprüft. Einige größere Views nur entlang ihrer Datenflüsse gelesen. |
| Audio, Liedtexte und Kapitel | TagFile-Schreibgrenzen, zentrale Shim-Wege, feste Felder, LRC/SYLT/USLT und Kapitel geprüft. Kein vollständiger Audit aller externen TagLib-Implementierungen. |
| Dokumente, E-Books, Playlists und Sidecars | XML-/ZIP-Helfer, Office/ODF/Comic/Markdown, EPUB, Calibre-Anbindung, Playlist- und Sidecar-Schreibwege vertieft geprüft. ExifTool- und Modellcode teilweise gelesen. |
| E-Rechnungen | XML-Erkennung, Parsergrenzen, UBL-Zuordnung, dynamische BT-Auflösung, Validierung und PDF-Extraktionsschutz geprüft. Umfangreiche CII-/Order-Feldtabellen nur teilweise fachlich geprüft. |
| Online-Suche | Clients, Parser, Planung und CLI-Anbindung gelesen; keine Live-Anfragen an Anbieter. |
| CLI und Prozesse | Mutierende Befehle nach Sicherheitswegen durchsucht, zentrale Aufrufer sowie Prozessausführung und Cache vertieft gelesen. Nicht jeder reine Anzeigebefehl vollständig geprüft. |
| Build und Entwicklung | Build-/Installations-/Release-Skripte, portable Abhängigkeiten, Mindestversionsprüfung und CI gelesen. Grafikgeneratoren und einzelne Hilfsbefehle nur teilweise gelesen und durch vorhandene Tests geprüft. |

Die Versionshistorie in `.codeqa/coverage.json` bleibt erhalten. Dieser
zeitbegrenzte Durchgang ist dort separat mit seinen Nachweisen vermerkt;
ältere vollständige Bereichsprüfungen werden nicht nachträglich umdatiert.

## Prüfungen und Grenzen

- Ausgangszustand: 459 Core-, 61 CLI- und 137 App-Tests bestanden.
- Abschluss: 468 Core-, 61 CLI- und 140 App-Tests bestanden, zusammen 669 Tests.
- Shelltests für Installer/Rollback, Testverzeichnisse, TagLib-Ladepfade,
  macOS-Mindestversionen und Icon-Generatoren bestanden.
- Der Build-Plist-Test mit echtem lokalen Debug-Bundle-Build bestand ohne App-Start.
- `git diff --check` bestand ohne Whitespace-Fehler.

Die Ausführung erfolgte auf macOS. Linux, echter GUI-Betrieb,
Live-Online-Dienste, Notarisierung, Installation und Sparkle-Update wurden
in diesem Durchgang nicht ausgeführt. Die App-Korrekturen betreffen
Modellzustände und wurden mit den echten App-Modellen headless geprüft;
ein visueller Layouttest ist damit nicht ersetzt.

Bereits der Ausgangsstand meldet beim lokalen Linken, dass die installierte
Homebrew-TagLib für ein neueres macOS als das Projektziel 14 gebaut wurde.
Die erfolgreichen lokalen Tests belegen deshalb keine Lauffähigkeit dieses
Debug-Bundles auf macOS 14. Der portable Release-Build wurde nicht ausgeführt.

Zwei bewusst sichtbare Grenzen bleiben: Tag-Änderungen bei USLT-Frames mit
gleicher Beschreibung und verschiedenen Sprachen werden abgelehnt, weil die
PropertyMap sie nicht verlustfrei unterscheiden kann. Ein verwaistes
Installations-Übernahme-Hilfslock muss nach Prüfung auf noch laufende
Installationen manuell entfernt werden. Ein umfassender Mehrspracheneditor
und eine neue plattformübergreifende Sperrarchitektur waren nicht Teil
dieses Reviews.
