# Unveränderte Rechnungsquellen und aktuelle Prüfergebnisse

Stand: 2026-10-16. Trigger: `EInvoicePayload`, `InvoiceValidationInput`,
`InvoiceValidationService`, `InvoiceValidationSession` oder ihre App-Anbindung.

- XML aus dem Anzeigemodell zu serialisieren wäre eine Prüfung anderer Bytes.
  `EInvoicePayload` bewahrt das Original; `document()` und KoSIT verwenden
  dieselbe Quelle. Bei PDF die eingefrorenen Trägerbytes extrahieren, nicht
  nach dem Dateistempel erneut den veränderlichen Originalpfad öffnen.
- Ein bestandener PDF-Anhang bestätigt den Container nicht. Das gemeinsame
  Ergebnis ist bis zur PDF-Prüfung `partial`, mit gesondertem `xmlStatus` und
  explizit ungeprüften PDF/A-/Einbettungsschritten.
- Größe/Zeit/Inode allein erkennen gleich große In-place-Änderungen mit
  erhaltener Änderungszeit nicht. Quelle und Ergebnis zusätzlich an SHA-256
  binden; bei Auswahlwechsel die Session invalidieren. Ein alter Auftrag darf
  nach neuer Auswahl kein Ergebnis mehr publizieren. Das gilt auch für einen
  kurz vor Abbruch bereits berechneten Erfolg.
- Foundation kann bei Verzeichnissen `/var` beibehalten, während der
  Dateibaum-Enumerator `/private/var` liefert. Blindes Abschneiden der
  ursprünglichen Pfadlänge ergab falsche relative Namen und wies bytegleiche
  Paketkopien ab. `InvoiceValidationPackage.treeDigest` nutzt POSIX-`realpath`
  als gemeinsame Basis und prüft den Präfix vor dem Abschneiden. Hersteller-
  Symlinks im Dateibaum werden weiterhin nur als Verweise inventarisiert.
- JVM-Umgebungsoptionen können feste Prozessargumente ändern oder fremden
  Code laden. Die KoSIT-Ausführung übernimmt sie nicht. Test: absichtlich
  ungültige Optionen in allen drei JVM-Variablen stören die Prüfung nicht.

Belege: `InvoiceValidationServiceTests`, `InvoiceValidationRuntimeTests`,
`XRechnungValidatorTests`; Schnittstelle und Grenzen:
[e-invoice-validation-core.md](../docs/e-invoice-validation-core.md).
