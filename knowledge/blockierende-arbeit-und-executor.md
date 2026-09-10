# Blockierende Arbeit und der Swift-Executor

Stand: 2026-09-10.

`BlockingWork.run` (Core) führt blockierende Arbeit auf einer GCD-Queue aus
und wartet angehalten darauf.

- Der Swift-Executor hat so viele Threads, wie die Maschine Kerne hat. Wer auf
  ein externes Werkzeug (mediainfo, exiftool) oder auf TagLib wartet, belegt
  einen davon vollständig, ohne zu rechnen. Ein `Task.detached`, das solche
  Arbeit tut, deckelt damit still jeden Fächer auf die Kernzahl und stellt alle
  übrige Aufgabenarbeit dahinter an.
- Gemessen: 64 blockierende Leser auf 18 Kernen brauchen über den Executor
  1,23 s, über eine GCD-Queue 0,31 s. Mit einem einzigen Executor-Thread
  (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`) sind es 19,62 s gegen 0,31 s.
- `Tests/TagExplosionCoreTests/BlockingWorkTests.swift` prüft die Eigenschaft
  ohne Zeitmessung: `Kerne + 4` Leser müssen alle gleichzeitig an einer
  Sammelstelle ankommen. Mit `Task.detached` erreichten dort nur 13 von 22 die
  Sammelstelle.
- Nutzer: `MediaInfoCache` (Prozessleser), `AppModel.open(urls:)` (Ladefächer,
  bis zu acht gleichzeitig). Reine Rechenarbeit gehört weiterhin auf den
  Executor — GCD legt für blockierte Threads zusätzliche Threads an, und das
  ist nur für Wartezeit sinnvoll.
- Frist und Signale von `ExternalToolRunner` liegen auf eigenen GCD-Queues und
  sind deshalb von der Auslastung des Executors unabhängig.

## Falle: neue Core-Datei erreicht das App-Paket nicht

Das App-Paket (`App/`) bindet den Core als Pfad-Abhängigkeit. Eine **neu
angelegte** Core-Datei taucht in dessen zwischengespeichertem Bauplan
`App/.build/debug.yaml` nicht auf; der Build bricht mit `cannot find '<Typ>' in
scope` ab, obwohl `swift build` im Wurzelverzeichnis durchläuft. Abhilfe:
`rm -f App/.build/debug.yaml` (oder `App/Package.swift` anfassen), dann erneut
bauen.
