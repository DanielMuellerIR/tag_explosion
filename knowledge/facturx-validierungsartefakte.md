# Factur-X: Profilregeln und KoSIT-Auswahl

Geprüft: 2026-10-16, ZUGFeRD 2.5.2 / Factur-X 1.09.2.

- Die fünf D22B-Profile besitzen eigene XSD, Schematron und Codelisten.
  MINIMUM, BASIC WL und BASIC bestätigen keine vollständige EN-16931-Konformität.
- Profil-URNs nennen keine eindeutige Releaseversion. Bericht und Oberfläche
  beschreiben den tatsächlich angewendeten aktuellen Regelstand; alte Aliase
  werden nicht automatisch angenommen.
- `urn:cen.eu:en16931:2017` trifft auch den allgemeinen CII-Fallback im originalen
  XRechnung-Paket. KoSIT wählt bei Mehrfachtreffern kein Szenario. Die erzeugte
  gemeinsame Konfiguration ersetzt diesen Fallback durch das konkrete aktuelle
  Factur-X-EN16931-Profil. XRechnung-Szenarien bleiben erhalten.
- Die Root-XSLTs des verwendeten technischen Spiegels sind bearbeitet.
  Verwendet werden die unveränderten `_XSLT_*`-Dateien samt nebenliegender
  `_codedb.xml`, außerdem die ursprünglichen `.sch`-Quellen und XSD-Dateien.
- Das originale KoSIT-Berichtstemplate wertet auch Schematron-Warnungen als
  ungültigen Schritt. Die eigene Factur-X-Berichtsschicht erlaubt nichtfatale
  Warnungen, erhält Schweregrad/Originaltext und lehnt fehlenden SVRL-Output ab.
  Die Profilregeln selbst werden nicht verändert.
- MINIMUM enthält keine Steueraufschlüsselung. Die lesende Grundprüfung darf
  eine fehlende BT-117-Liste dort nicht gegen einen erfundenen Betrag null
  vergleichen. Die übrige Summenkette bleibt prüfbar.
- Technische Artefakte stehen nach FeRD unter Apache-2.0. Norm-PDFs, Tabellen
  und Logos nicht pauschal übernehmen. Der FeRD-/CEN-/DIN-Nutzungshinweis bleibt
  in Bundle und App zugänglich; Quellen und Hashes sind im Lizenzinventar.

Quellen: [FeRD-Release](https://www.ferd-net.de/publikationen-produkte/publikationen/detailseite/zugferd-252-deutsch),
[FeRD-Nutzungsrechte](https://www.ferd-net.de/ueber-uns/ressourcen-1/veroeffentlichungen/haftungsausschluss-und-nutzungsrechte).
Technischer Spiegel: `LandrixSoftware/validator-configuration-zugferd`,
Commit `8399f5459df34b2af9cae0d613870649b3f17a58`. Jede der 40 Originaldateien ist
separat gepinnt und im Sources-Paket enthalten.
