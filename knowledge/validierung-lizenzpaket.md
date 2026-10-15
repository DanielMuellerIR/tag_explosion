# Lizenz- und Quellenpaket der Validierung

Stand: 2026-10-16. Trigger: Änderungen an KoSIT, Runtime, Regeln oder deren
Verpackung. Vollständige Matrix: [Validierungslizenzen](../docs/validation-licenses.md).

- KoSITs Standalone-JAR ist nicht insgesamt Apache-only. 4.954 tatsächlich
  enthaltene Java-Klassen wurden bytegenau 17 Original-Maven-Artefakten
  einschließlich des Resolver-Daten-Artefakts zugeordnet. Versionen und
  Original-Hashes stehen unter `licenses/validation/components.lock.json`.
- Saxon-HE 12.9 trägt MPL-2.0 und einen Incompatible-With-Secondary-Licenses-
  Hinweis in seinen Quellen. Quellen und MPL-Lizenz erhalten; nicht in MIT
  umdeklarieren. JAXB/Angus/Istack/Jakarta nutzen EDL-1.0 (BSD-3-Clause).
  Manche Maven-POMs erben ihre Lizenz aus dem Eltern-POM; dessen URL ist belegt.
- Die nativen Jansi-Konsolenbibliotheken und die ungenutzten Daemon-Webressourcen
  unter `ui/` werden entfernt. Der restliche Java-Code und die Regeln bleiben
  unverändert. Originalquellen und Änderungsvermerk werden mitgeliefert.
- Die Runtime bleibt als eigenes Herstellerpaket einschließlich sämtlicher
  Modul-Lizenzen erhalten. Das passende OpenJDK-Quellarchiv wird im separaten
  Quellenpaket angeboten. Ein bloßer Upstream-Link ist nicht der gewählte
  Weg zur Erfüllung der Quellcodepflichten.
- Für kompilierte EN-/XRechnung-XSLT auch die bevorzugten Schematron-Quellen
  sowie SchXslt-Quellen/Lizenz liefern; nur die erzeugten XSLT-Dateien reichen
  für diese Paketstrategie nicht. Schemata sind bereits in Quellform enthalten;
  OASIS-/UNCEFACT-Copyright-/Permission-Kommentare unverändert lassen.
- `prepare-xrechnung-validator.py` erzeugt Binär- und Quellenpaket zusammen.
  `validation_compliance.py` vergleicht die gesamte Runtime und Regeln mit dem
  geprüften Stand und bindet alle erforderlichen Lizenz-/Source-Dateien ein.
  Die Probe-Verpackung verweigert fehlende oder veränderte Bestandteile vor
  Signierung/Notarisierung. Der reguläre Produkt-Build wird erst in einem
  späteren Meilenstein daran angeschlossen.
- Zwölf reale Fehler-/Vollständigkeitstests bestehen; 14 KoSIT-CLI-Fälle bestehen
  mit dem neuen JAR. Die neue App-Hülle wurde erneut notarisiert, gestapelt und
  von Gatekeeper angenommen. Intel-Runtime wurde inventarisiert, nicht gestartet.
- ZUGFeRD-/Factur-X-Schema/Schematron: FeRD nennt Apache-2.0. Das gilt nicht
  automatisch für Spezifikations-PDFs oder Logos. Aktuell: 2.5.2 / 1.09.2.
- Peppol: Wrapper-Lizenz, technische Regelartefakte und geschütztes BIS-Dokument
  auseinanderhalten. Vor dem konkreten Paketpin dessen Rechte gesondert belegen.
  veraPDF ist als MPL-Kandidat vorgesehen, aber noch nicht gebündelt; dessen
  transitive Bestandteile erst am konkret gewählten Artefakt prüfen.

Bei jedem Versionswechsel Inventar und Quellen aktualisieren, nicht nur einen
Download-Hash ersetzen. Eine unbekannte Lizenz oder zusätzliches Bytecode-Artefakt
ist keine still akzeptierte Abweichung. Der eigene Gewährleistungshinweis darf
die Rechte an fremden Komponenten nicht einschränken.
