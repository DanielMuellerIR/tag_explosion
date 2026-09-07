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

## Gemeinsame Medien-Fixtures

`Tests/Support/MediaFixtures.swift` erzeugt den Satz einmal pro Testprozess.
Eine `flock`-Sperre im generierten Ordner koordiniert alle Testprozesse, die
diesen Helfer verwenden. Die Sperre wird beim Schließen des Deskriptors auch
nach einem Prozessabbruch freigegeben. Das separate App-Testtarget bindet das
Test-Support-Produkt ein; das App-Produkt selbst benötigt es nicht.

Ein kontrollierter Generator prüft über ein exklusives Arbeitsverzeichnis,
dass sich drei gleichzeitige Aufträge nicht überschneiden. Ohne Dateisperre
scheitert diese Gegenprobe. Ein weiterer Test prüft den echten Shell-Generator:
Fehlende `doc-nocore.docx` und `comic-noinfo.cbz` werden ergänzt, während die
schon vorhandenen Basisdateien bytegleich bleiben. Ein vollständiger Satz
funktioniert auch mit einem PATH ohne ffmpeg (separat ausgeführt).

Die Sperre liegt im Swift-Testhelfer. Direkte manuelle Aufrufe des Shell-
Generators dürfen nicht gleichzeitig in denselben Ausgabeordner schreiben.

`Tests/Support/TestFiles.swift` enthält auch die gemeinsame Simulation eines
fremden atomaren Dateiaustauschs: Foundation unter macOS, `rename(2)` unter
Linux. Die bisherigen Core- und CLI-Konflikttests prüfen diesen Helfer über
die tatsächlich geänderte Dateiidentität. Die Fixture-Sperre verwendet
`O_CLOEXEC`, damit gestartete Werkzeuge ihren Deskriptor nicht erben.
