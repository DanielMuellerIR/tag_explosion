# Laden: Messung 2026-09-05

Verglichen: 0.41.0 und die inkrementelle Übernahme für 0.42.0, Debug-Build,
macOS, Apple M5. `LoadingTests.benchmark` kopiert die generierte FLAC-Fixture
1.000-mal in einen temporären Ordner und verwendet den Produktionsleser.
Ein MainActor-Beobachter prüft alle 1 ms auf den ersten Eintrag.

Aufruf nach dem Build: `TAGX_LOAD_BENCHMARK=1 /usr/bin/time -l swift test
--package-path App --skip-build --filter benchmark`.

| Messgröße | vorher | nachher |
| --- | ---: | ---: |
| Erster Eintrag | 0,143 s | 0,063 s |
| Vollständig geladen | 0,143 s | 0,301 s |
| Maximaler RSS des Testaufrufs | 97.435.648 B | 62.259.200 B |

Einzelmessungen mit warmen Dateicaches, keine statistische Aussage. Der RSS
betrifft den headless Testaufruf, keine laufende GUI-App. Frühe Anzeige ist
schneller, das vollständige Laden durch die einzelnen MainActor-Übernahmen
langsamer. Covergröße und Dateiformat verändern Speicherbedarf und Laufzeit.

`incrementalAndCancel` hält acht Testleser gezielt an: ein späterer Eintrag
erscheint vor Abschluss, ein überlappender Auftrag startet keine Dubletten,
Abbruch bewahrt den bearbeiteten Puffer und ein erneutes Öffnen erreicht alle
Dateien. Die Begrenzung gilt wie bisher pro Öffnen-Auftrag (acht Leser).
Synchron laufende Backends und die Ordnerexpansion werden nicht unterbrochen;
Abbruch verwirft deren ausstehende Ergebnisse und startet keine weiteren Leser.
