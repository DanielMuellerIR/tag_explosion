# Bibliotheksprüfung

Bei Änderungen an `LibraryCheck`, `tagx check` und dem Ergebnis-Sheet lesen.
Stand: 2026-09-08.

- Gruppenschlüssel bestehen aus getrennten Album-/Interpretenwerten. Ein
  zusammengeklebter String mit Trennzeichen vermischt zulässige Tagwerte.
  Der Bericht verwendet Labels zur Zuordnung; gleiche Anzeigenamen bekommen
  deshalb einen eindeutigen Zahlenzusatz.
- Unlesbare Dateien haben keine Albumgruppe, bleiben aber in `Report.files`
  enthalten. Regelfilter ändern Befunde und Codes, nicht die Dateiliste.
- Track-/Disc-Lücken aus sortierten vorhandenen Nummern bilden, nie
  `1...Gesamtzahl` durchlaufen. Bis 20 fehlende Nummern je Lücke werden
  einzeln genannt; größere Lücken als Bereich. Auch `Int.max` bleibt begrenzt.
- Dauern für Dubletten sind sortiert; ihre Differenz trotzdem auf Überlauf
  prüfen. Fremde oder synthetische Daten können extreme Werte enthalten.
- Textausgabe und App-Abschnitte gruppieren Befunde einmal. Messung mit
  3.000 Gruppen: 1,69 s → 24 ms bei bytegleicher Textausgabe.
- CLI-Berichtstests richten eigene Fixture-Kopien über `TagFile.write` ein;
  zusätzliche `tagx set`-/Cover-Prozesse prüfen den Bericht nicht besser.
  Drei Tests benötigen dadurch neun Werkzeugstarts weniger. Die unabhängigen
  Core-/CLI-Suites laufen parallel: 25 Prüfungen zuletzt 0,10 s.
