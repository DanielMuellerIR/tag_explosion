# Hybride PDF-Validierung

Stand: 2026-10-16. XML-/PDF/A-/Einbettungsergebnisse sind unabhängig. Ein
technischer PDF/A-Fehler darf wegen nationaler rechtlicher Ausnahmen nicht
stillschweigend Erfolg werden; die App kann deren Voraussetzungen nicht prüfen.

CoreGraphics-Dictionary-Identität über `CGPDFDictionaryRef` als Hashable halten:
neue SDKs verwenden einen Wrapper statt eines direkt konvertierbaren Pointers.
AF und EmbeddedFiles können dieselbe FileSpec referenzieren; nicht doppelt zählen.
Begrenzte Inspektion bei erreichter Grenze ausdrücklich unvollständig melden.

veraPDF Exit 1 enthält reguläre negative Prüfberichte. Deshalb den bestehenden
begrenzten Prozessläufer mit `runResult` verwenden und Exit/Report-Konsistenz
prüfen; `run` behält seine bisherige Nonzero-Fehlersemantik. Die unveränderte
CLI 1.30.3 enthält 15 Profile, deren bevorzugte Quellen aus `rel/1.30` kommen;
der neuere Integrationszweig stimmt nicht vollständig mit diesen Binärressourcen
überein. Alle 15 XML-Dateien vor Verpackung byteweise nachweisen.

Factur-X 1.09.2 Kapitel 6.3.1 definiert die URI einschließlich `:invoice:1p0#`.
Der Anhang enthält eine abweichende Schreibweise. Eigene Regeln folgen der
klaren Definition und den Beispielen. Legacy-ZUGFeRD-XMP unterstützt kein
XRechnung-Referenzprofil. Fehler und Empfehlungen aus der Hybridtabelle nicht
pauschal auf dieselbe Schwere hochstufen.
