# Verbesserungen gegenüber 0.40.0

Stand: 2026-09-05. Ausgangspunkt: `1b903ab`. Die sechs Pakete wurden in
Prioritätsreihenfolge umgesetzt; Prozess-Extraktion und neue Prozesslogik
liegen in getrennten Commits.

| Paket | Ergebnis | Version / Commit |
| --- | --- | --- |
| Mehrwertige Regeln | Wertelisten für Audio, vollständige Vorschau und kompatible JSON-Ergänzungen | 0.41.0 / `7792568` |
| Laden | Frühe Einträge, Fortschritt, Abbruch, Reservierungen und Pufferschutz | 0.42.0 / `559faec` |
| Speicheraufträge | Dateiergebnisse, Fehlerursachen, Retry, Abbruch zwischen Schreibvorgängen, Teilerfolg bei Sidecars | 0.43.0 / `4291818` |
| Dateiliste / Prüfung | Suche, Filter, stabile Sortierung, versteckte Auswahl, verzögerte Hintergrundprüfung | 0.44.0 / `5445b6e` |
| Werkzeugmechanik | Verhaltensgleiche Extraktion | 0.44.1 / `092070d` |
| MediaInfo | Bedarfsgerechte Aufrufe, begrenzter Cache, geteilte Anfragen, Prozessgruppen-Abbruch | 0.45.0 / `e76e9ad` |
| AppModel | FileEntry, Ladedaten, Laden und IO mit getrennten Zuständigkeiten | 0.46.0 / `640afa2` |

0.46.1 ergänzt den Schutz des gesamten laufenden Speicherauftrags gegen
konkurrierende destruktive Aktionen. Bestätigte Konfliktwiederholungen warten
auf das Auftragsende. Der Fortschritt steht auch direkt unter der Dateiliste.

## Nachweise

- Der erste Regeltest war auf dem alten Adapter rot: Eine Änderung ausschließlich
  am zweiten Interpreten tauchte im Plan nicht auf. Engine-Tests prüfen Listen,
  leere Elemente und Regelketten; CLI-Roundtrips prüfen FLAC, MP3 und M4A sowie
  vollständige `oldValues`/`newValues`. App und Core erzeugen identische Pläne.
- Gesteuerte Leser beweisen frühe Übernahme vor dem letzten Leser, acht Leser
  pro Öffnen-Auftrag, keine Dubletten bei Überlappung, freie Reservierungen nach
  Abschluss des Abbruchs und erhaltene Puffer beim erneuten Öffnen.
- Der gemischte Speicherauftrag enthält Erfolg, IO-Fehler und Sidecar-Konflikt.
  Fehlerpuffer, Konfliktentscheidung, selektives Retry und serielle Wiederholung
  sind geprüft. Der Entfernen-Konflikt während eines laufenden Auftrags wurde
  mit einem roten Test reproduziert und anschließend gesperrt.
- Listen-/Modelltests prüfen Suche, Sortiergleichstände, versteckte Auswahl,
  Puffererhalt, Nummerierung und das Verwerfen verspäteter Prüfberichte.
- Fake-Werkzeuge zählen tatsächliche Prozesse. Tests prüfen Ausgabeidentität,
  Cache-Invalidierung und Verdrängung, A–B–A, Abbruch einzelner Abonnenten,
  volle stdout-/stderr-Pipes, Werkzeugfehler, ignoriertes SIGTERM und Nachkommen
  mit offenen bzw. geschlossenen Pipes. CLI-Starts mit geschlossenem stdin oder
  stderr prüfen die Dateideskriptor-Behandlung.
- Abschließender Core-/CLI-Lauf: 463 Tests in 49 Suites bestanden. App-Lauf:
  111 Tests in 21 Suites gemeldet; der optionale Lasttest lief separat aktiviert.
  Bestehende Save-, Rename-, Rules-, WindowSessions- und Konflikttests bleiben grün.
- `build.sh --debug` baut CLI und App-Bundle headless einschließlich
  Übersetzungen und Sparkle-Bündelung. Keine Installation oder Distribution.

## Messwerte und Grenzen

Die vollständige 1.000-Dateien-Messung steht in
[loading-performance.md](loading-performance.md): erster Eintrag 0,143 →
0,063 s, vollständig geladen 0,143 → 0,301 s. Die frühe Anzeige verbessert sich,
die gesamte Ladezeit steigt. Der dort ausgewiesene RSS gehört zum Testaufruf,
nicht zu einer laufenden GUI-App.

Der kontrollierte MediaInfo-Vergleich ist in
[mediainfo-exiftool-wrapper.md](../knowledge/mediainfo-exiftool-wrapper.md)
dokumentiert. Die belastbaren Größen sind Prozessanzahl (2 → 1 bei CLI-Bedarf,
0 bei Cache-Treffer) und identische Ausgabe. Die Zeiten eines Fake-Werkzeugs mit
50 ms Pause sind keine allgemeine Prognose für reale Medien.

- Kein GUI-Fokus-/Bedienbarkeitstest und kein neuer Linux-Lauf in dieser Prüfung.
- Ordnerexpansion und bereits laufende synchrone Medienleser dürfen bei Abbruch
  auslaufen. Weitere Starts und Ergebnisübernahmen enden; Reservierungen werden
  nach dem Auslaufen freigegeben. Acht Leser gelten pro Auftrag, nicht global.
- Audio-Regeln erhalten Listen. Andere Medien behalten ihre bisherigen Adapter;
  Backend-Normalisierung leerer Tags bleibt möglich. Bedingungen und Platzhalter
  verwenden aus Kompatibilitätsgründen den ersten Wert, siehe
  [batch-regeln.md](../knowledge/batch-regeln.md).
- Ein Container-/Sidecar-Schreibvorgang ist keine dateiübergreifende Transaktion.
  Ein bereits ausgetauschter Container wird bei späterem Sidecar-Fehler ausdrücklich
  genannt; der Puffer bleibt erhalten und ein Retry durchläuft die Stempelprüfung.
- Die Ergebnisansicht hält den letzten Auftrag einschließlich gezielter Retries
  im jeweiligen Fenster. Sie ist kein dauerhaft gespeichertes Auftragsjournal.

## Weitere Kandidaten

- `tagx check` liest in `CheckCommand.run` weiter seriell über
  `LibraryCheck.Item.load`. Nächster Schritt: einen bedarfsgerechten Audio-Leseweg
  ohne Kapitel/Lyrics/Tag-Schichten entwerfen und Befunde mit dem vollständigen
  Leser vergleichen; erst danach Parallelität begrenzen und messen.
- EPUB öffnet den OPF-/ZIP-Kontext weiterhin in mehreren Operationen;
  Calibre-Felder und Cover verwenden getrennte Aufrufe. Nächster Schritt:
  Lese-/Schreibabläufe mit generierten E-Books instrumentieren, Archivzugriffe und
  Prozesse zählen sowie Output-Diffs sichern, bevor Operationen gebündelt werden.
- JSONL ist noch nicht implementiert. Nächster Schritt: separates optionales
  Ausgabeformat mit einem Erfolgs-/Fehlerdatensatz pro Datei spezifizieren und
  frühes Flushen prüfen; der bisherige `--json`-Vertrag bleibt bestehen.
- Finder/Quick Look bleibt ein eigenes Paket. Nächster Schritt: headless Build
  und signierte Extension-Verteilung klären, bevor UI-Funktionen entstehen.
- Der veraltete ID3v2.3-Backlog wurde in `PLAN.md` berichtigt; die Funktion
  existiert bereits seit AP6.
