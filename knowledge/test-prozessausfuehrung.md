# Prozesse in Integrationstests

Stand: 2026-09-08. Core- und CLI-Testtargets verwenden
`Tests/Support/ProcessSupport.swift` über `TagExplosionTestSupport`.

- `runTagx` startet das CLI neben dem tatsächlich geladenen Testbundle. Die
  Testtargets hängen ausdrücklich von `tagx` ab; auch ein gefilterter Lauf
  baut deshalb das benötigte Produkt. Ein neuer SwiftPM-Prozess pro Aufruf
  ist unnötig und kann die falsche Buildkonfiguration auswählen.
- Unter macOS kann `CommandLine.arguments[0]` auf `swiftpm-testing-helper`
  zeigen. Eine Markerklasse ermittelt das geladene XCTest-Bundle. Unter Linux
  liefert Foundation bereits dessen Verzeichnis, unter macOS das Bundle.
  Beide Fälle wurden ausgeführt; auch ein macOS-Release-Testlauf ist geprüft.
- `runCapturedProcess` erfasst stdout und stderr in einem privaten temporären
  Verzeichnis. Volle oder geerbte Pipes können diesen Teststarter nicht
  blockieren. Der Aufrufer erhält weiterhin Exit-Code und beide Texte.
- Die Standardfrist beträgt 30 Sekunden. Bei Überschreitung beendet der Helfer
  seinen gestarteten Prozess und wirft einen Fehler. Die Frist betrifft den
  direkten Prozess, nicht beliebige von diesem abgekoppelte Hintergrunddienste.
- Umgebungswerte werden als `Process.environment` übergeben, nicht als
  Argumente an `/usr/bin/env`. So bleiben auch private Testparameter aus argv.

Die 51 CLI-Verhaltenstests liefen vor der Zusammenführung in 6,926 Sekunden,
danach in 1,115 Sekunden (jeweils reine Testzeit eines lokalen Debug-Laufs).
Das ist eine lokale Vergleichsmessung, keine feste CI-Laufzeitgarantie.
Der große Ausgabetest wurde in `ProcessSupportTests.swift` verschoben; dort
prüft zusätzlich ein kurzer Schlafprozess die Abbruchfrist.
