# Abbrechbare Ladeaufträge eines Fensters

Bei Arbeit an `AppModel+Loading.swift` und `LoadingTests.swift` lesen.
Stand: 2026-09-08.

`loading.generation` ist der Zähler des gültigen Ladevorgangs. Abbrechen
erhöht ihn und setzt dessen Fortschritt zurück. Laufende Leser dürfen
fertig werden; ihre Ergebnisse und Fehlermeldungen werden verworfen.
`operationCount` zählt weiterhin alle noch laufenden Aufträge.

Reservierungen in `loading.urls` tragen diesen Zähler mit. Ein neuer
Ladevorgang kann deshalb dieselbe Datei sofort übernehmen. Beim Abschluss
entfernt ein Auftrag nur Reservierungen mit seinem eigenen Zähler. Sonst
könnte ein alter Leser die neue Reservierung löschen und einen dritten
Leseauftrag auf dieselbe Datei zulassen. Bereits sichtbare Einträge behalten
ihre Identität und ihre Bearbeitungspuffer.

Die Einfügereihenfolge folgt den Eingabepositionen des jeweiligen Auftrags,
auch wenn spätere Leser früher fertig werden. Vorhandene Einträge bleiben
stehen. Ein globaler Indexcache müsste zusätzlich andere Öffnen-Aufträge
und zwischenzeitliche Listenänderungen berücksichtigen; die direkte Suche
bleibt deshalb bewusst einfach. Automatische Auswahl wartet auf den ersten
lesbaren Eingabepfad; eine Benutzerauswahl hat Vorrang.

Die Tests steuern Abschlüsse und Fehler über eigene Leser. Sie prüfen
Abbruch mit sofortigem Neustart, fremde Hinweise, doppelte Reservierungen,
Reihenfolge und erhaltene Puffer; die unabhängigen Modelle laufen parallel.
Der auf Wunsch aktivierte Test `TAGX_LOAD_BENCHMARK=1` lädt 1000 generierte
FLAC-Dateien. Am 2026-09-08 erschien das erste Ergebnis nach 55 ms; alle
1000 Dateien waren nach 238 ms geladen. Dieser Test bleibt außerhalb des
normalen Testlaufs.
