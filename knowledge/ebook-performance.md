# Gemeinsame E-Book-Zugriffe

**Trigger:** Änderungen an EPUB-Schnappschüssen, gemeinsamen Feld-/Cover-
Schreibvorgängen oder Calibres `ebook-meta`-Prozessaufrufen.

Seit 0.46.98 teilen EPUB-Felder und Cover beim Lesen eine OPF und ein Archiv.
Der Dateistempel umschließt weiterhin den gesamten Lesevorgang. Die Prüfung
nach einer gemeinsamen Änderung liest ebenfalls einmal und kontrolliert dabei
`mimetype`, Coverdeklaration und die gewünschten Coverbytes.

Beim Schreiben sammeln Feld- und Coveränderungen ihre Änderungen an derselben
XMLDocument-Instanz. Die OPF wird nur einmal ersetzt. ZIPFoundation benötigt
für OPF und vorhandenes Cover weiterhin zwei `remove`-Durchläufe; zuvor waren
bei einem Wechsel des Bildformats drei nötig. Die unveränderten Einträge werden
komprimiert kopiert. Metadatenänderungen ohne Cover benötigen einen Durchlauf.

Ein vollständiger Neuaufbau über `ZipContainer.rewrite` wurde verworfen: Er
entpackt und komprimiert die unveränderten Inhalte erneut. Ein lokaler Vergleich
vom 2026-10-04 mit 32 MiB komprimiertem Text maß für die reine Mutation etwa
6,6 ms bisher und 66,1 ms beim Neuaufbau. Mit 32 MiB unkomprimiertem Inhalt
benötigte der bisherige dreifache Ersatz 84,5 ms, der gebündelte zweifache Ersatz
45,7 ms. Ein Covertausch ohne Änderung der Felder oder des Bildformats lässt
auch die OPF-Bytes unverändert und benötigt weiterhin nur einen Durchlauf.
Einzelmessungen ohne Build, Backup und äußeren atomaren Austausch;
kein allgemeines Geschwindigkeitsversprechen. Neue Testdateien waren Kopien
der synthetischen EPUB-2-Fixture mit einem zusätzlichen ZIP-Eintrag.

Calibre nutzt `--get-cover` zusammen mit der normalen Feldausgabe und `--cover`
zusammen mit den geänderten Feldern. Deshalb benötigt jeder kombinierte Lese-
oder Mutationsschritt einen Prozess. Der echte Schreibweg prüft das Ergebnis
weiterhin separat vor dem atomaren Austausch. Coverentfernung bleibt bei
Calibre ausdrücklich nicht unterstützt.

Die Tests kontrollieren gemeinsamen Tag-/Cover-Roundtrip, unveränderte
Nutzdaten und `mimetype`, Prozessanzahl, Löschung temporärer Coverdateien,
einen echten Calibre-Roundtrip sowie bereits bestehende Konflikt- und
Fehlerpfade. Dateisicherheitsrahmen und Papierkorb-Sicherung der Aufrufer
bleiben unverändert.
