# XML-Namensräume beim Lesen und Schreiben

Bei Änderungen an Dokument-, EPUB-, Playlist-, NFO- oder Rechnungs-XML:
Ein lokaler Name ist keine Feldidentität. `dc:title` und `vendor:title`
können denselben lokalen Namen und unterschiedliche Bedeutung haben.

Seit 0.46.93 vergleichen die Auswahlhelfer lokale Namen und Namespace-URI.
`XMLTools` verwendet ohne explizite URI den Namensraum des Elternknotens;
Attribute sind ohne explizite URI namespacefrei. Ein Standardnamensraum gilt
für Elemente, nicht für unpräfigierte Attribute.

Neue Elemente brauchen ebenfalls den richtigen Namensraum. Ein bloßes
`XMLElement(name: "meta")` ist in einem vollständig präfigierten OPF ohne
Standardnamensraum falsch. Dasselbe gilt für DOCX-Registrierungseinträge
`Override` und `Relationship`. Präfixe am tatsächlichen Elternknoten
auflösen: ODF kann `dc` lokal auf einen anderen Namensraum umgebunden haben.

Rechnungsfelder erhalten nur bei passenden UBL-/UNCEFACT-URIs die kanonischen
Präfixe der Zuordnungstabellen. Unbekannte Präfixe bekommen intern das Suffix
`-unmapped`; die ursprüngliche URI bleibt erhalten. Das verhindert auch
falsche dynamische Zuordnungen durch Teiltreffer wie `evil-cac:Party`.

Regressionen prüfen gleichnamige Fremdfelder vor dem eigentlichen Feld,
deren Erhalt beim Löschen, lokal umgebundene Präfixe und gültige neue Elemente
in vollständig präfigierten Paketdateien. Ein Feld-Roundtrip allein erkennt
fehlerhafte Paketregistrierungen nicht.
