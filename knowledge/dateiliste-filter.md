# Dateiliste: Metadaten, Filter und Sortierung

Bei Arbeit an `FileList.swift`, `FileEntry` oder den Dateinamenmustern lesen.
Stand: 2026-09-08.

`FileEntry.metadataTitle` liefert den aktuellen Titel ohne Dateinamen-Ersatz.
`displayTitle` ergänzt diesen Ersatz nur für die Anzeige. Suche und Sortierung
verwenden dadurch auch bearbeitete VTT-/Playlist-Titel und Rechnungsnummern.
Dateinamenmuster besitzen einen anderen Geltungsbereich und dienen nicht als
Datenquelle der Liste. VTT-Muster übernehmen ihren Titel aus `subtitleFields`;
Sprache und Flags im Muster stammen weiterhin aus dem Dateinamen.

`FileList.filteredEntries` behält die Eingabereihenfolge. Die sichtbare
Auswahl und die Zahl ausgeblendeter Einträge benötigen nur diesen Filter,
keine Sortierung. `visibleEntries` bildet einen Sortierschlüssel je Treffer;
bei gleichen Schlüsseln bleibt die Eingabereihenfolge erhalten. Ohne Filter
und bei Eingabereihenfolge wird das vorhandene Array direkt zurückgegeben.
Für Audiodateien sucht die Liste in allen ARTIST-Werten, sortiert aber wie
bisher nach dem ersten. Andere Formate verwenden Autoren, Ersteller, Regie
beziehungsweise den Playlist-Interpreten.

Messung mit 10.000 synthetischen Audioeinträgen am 2026-09-08:
Eingabereihenfolge 57,6 → 0,05 ms, Titelsortierung 118,4 → 10,3 ms,
Suche nach einem weiteren Interpreten 77,6 → 41,2 ms, Titelsuche mit
Interpretensortierung 86,0 → 40,3 ms. Die Ergebnislisten waren identisch.
Es gibt keinen dauerhaft gespeicherten Filtercache, der bei späteren
Feldänderungen zusätzlich invalidiert werden müsste.
