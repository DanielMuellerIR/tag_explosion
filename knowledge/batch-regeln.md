# Batch-Regeln als Skript (Stand 2026-09-02)

Konsultieren bei Arbeit an `Sources/TagExplosionCore/TagRules.swift`,
`tagx apply` (`Sources/tagx/ApplyCommand.swift`) oder dem Regel-Editor der
App (`TagRulesSheet.swift`, `TagRulesActions.swift`).

## Aufbau

- **Engine ist eine reine Funktion.** `TagRuleEngine.plan` bekommt je Datei
  Wertelisten (`TagRuleFields.values(from:)` für Audio, Schlüssel wie
  `TITLE`) und liefert je Datei die Änderungen alt → neu. Geschrieben wird
  ausschließlich über die bestehenden Wege: CLI über `Parse.write` (derselbe
  Weg wie `tagx parse`), App über `applyParsedFields` in die Puffer und dann
  `AppModel.saveEntries` (Auto-Backup, Papierkorb-Sicherung, atomarer
  Austausch). Ein neuer Schreibweg ist bewusst nicht entstanden.
- **Regelmodell ist flach.** `TagRule` hat alle Parameter als optionale
  Eigenschaften statt eines Enums mit zugeordneten Werten, damit SwiftUI
  direkt daran binden kann. `encode(to:)` schreibt nur die Parameter der
  jeweiligen Aktion, sonst landen Editor-Reste in gespeicherten Dateien.
  `validate()` prüft Pflichtparameter und kompiliert reguläre Ausdrücke.

## Fallen

- **Mehrwertige Audiofelder bleiben Listen.** `trim`, `case` und `replace`
  bearbeiten jeden Wert einzeln, erhalten Reihenfolge, Duplikate und leere
  Elemente. `copy` ersetzt das Ziel durch die ganze Quellliste; eine vollständig
  leere Quelle verändert nichts. `onlyIfEmpty` prüft alle Zielwerte (Whitespace
  zählt als leer). `set` und `number` ersetzen durch einen Wert; `set` mit leerem
  Text und `remove` entfernen das Feld. Backend-spezifische Normalisierung
  leerer Tags bleibt möglich. Bedingungen, Platzhalter und Nummernsortierung
  verwenden weiterhin den ersten Wert. Regeldateien bleiben Schema 1.
  Die Vorschau zeigt Listen als JSON-Arrays. CLI-JSON erhält `old`/`new` als
  ersten Wert und ergänzt bei Mehrwertigkeit oder einem leeren Element
  `oldValues`/`newValues`; fehlende Listen bedeuten die bisherige Skalarform.
  Dateinamenmuster bleiben absichtlich einwertig. Andere Medienarten behalten
  ihre bisherigen Feldadapter (etwa kommaseparierte E-Book-Autoren).
- **Medienart-Grenzen greifen erst beim Schreiben.** Die Engine setzt auch
  `ALBUM` für ein Bild; erst `PatternFields.apply(_:to: &image)` lehnt den
  Schlüssel ab. CLI meldet das als `FAILED` (Exit 1), die App als „Nicht
  übernommen". Wer das vorher sehen will, filtert die Regel mit `kinds`.
- **`number` ist die einzige Regel über alle Dateien.** Sie sortiert die
  betroffenen Dateien (Filter auf dem aktuellen Stand, also nach früheren
  Regeln) und vergibt Nummern; alle anderen Regeln laufen je Datei. Die
  Ausgabereihenfolge des Plans bleibt die Eingabereihenfolge, nur die
  Nummern folgen der Sortierung. Dateiname natürlich (`localizedStandardCompare`,
  „2" vor „10"), Feld zahlenbewusst („3/12" → 3), Gleichstand nach Dateiname.
  Keine CD-Trennung: bei mehreren Discs vorher nach `DISCNUMBER` filtern
  oder je Ordner laufen lassen.
- **Titel-Schreibweise senkt zuerst alles.** „DJ", „USA" werden zu „Dj",
  „Usa" — bekannte Grenze, im Test festgehalten. Kleine Wörter bleiben klein
  außer am Anfang, am Ende und nach einem Satzzeichen (`:`, `?`, `!`, `.`,
  Gedankenstrich, `(`); Bindestrich-, Schrägstrich- und Klammerteile zählen
  als eigene Wörter, ein Apostroph dagegen nicht („Don't"). Umlaute laufen
  über `Character.uppercased()`, „ß" wird bei `upper` zu „SS" (Unicode).
- **Zeilenangabe im JSON kommt aus einem eigenen Scanner.** `JSONDecoder`
  kennt keine Zeilen; `TagRulesIO.lineOfRule` zählt Klammern (Strings
  überspringend) bis zur n-ten Regel im `rules`-Array. Syntaxfehler nennen
  die Zeile aus Foundations `NSDebugDescription` („around line 12"); unter
  Linux kann sie fehlen (dann `line: nil`). Unbekannte Aktionen/Bedingungen
  fängt ein handgeschriebener `init(from:)` ab, damit der Name in der
  Meldung steht.
- **`%{` in lokalisierten Texten.** Der Hinweistext zu Platzhaltern im
  Formular wird aus einem lokalisierten Satz plus wörtlicher Platzhalterliste
  zusammengesetzt (`Text(verbatim:)`), wie in `FilenamePatternSheets` — ein
  `%{artist}` im xcstrings-Schlüssel liefe durch die Format-Auswertung.
- **Platzhalter ohne Dateinamen-Entschärfung.** `TagRuleText.expandPlaceholders`
  benutzt die Kurznamen und `formatValue` (Breite, Jahr, „3/12" → „3") aus
  `FilenamePattern`, aber nicht `renderStem`: In einem Tag darf „AC/DC"
  stehen bleiben.
- **Exit 64 für die Regeldatei.** Derselbe Code, den ArgumentParser für
  Eingabefehler nutzt — aber bewusst kein `ValidationError`, weil der die
  Befehlshilfe anhängt, die bei einer kaputten Regeldatei nicht hilft.
  Lese- und Schreibfehler an Dateien sind Exit 1, ein Probelauf mit
  unlesbarer Datei ebenfalls.
