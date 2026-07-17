# Sparkle-Updates veröffentlichen

Tag Explosion bindet Sparkle 2.9.4 per SwiftPM ein (exakt gepinnt in
`App/Package.swift`). Die App prüft den Feed unter
`https://danielmuellerir.github.io/tag_explosion/appcast.xml`, lädt das ZIP aus
dem zugehörigen GitHub Release und installiert ausschließlich nach Zustimmung.

Die erste Version mit Sparkle ist der einmalige Bootstrap: Vorgängerversionen
enthalten keinen Updater und können das Update deshalb nicht selbst finden —
sie müssen einmal manuell installiert werden; erst danach greifen automatische
Updates.

Zwei voneinander unabhängige Prüfungen bleiben Pflicht:

- Developer-ID-Signatur und Apple-Notarisierung für App und Archiv
  (`./build.sh --release` erledigt beides, inklusive der Signier-Reihenfolge
  innen → außen für Sparkles Helfer).
- Sparkle-Ed25519-Signatur für das Update-Archiv sowie den Feed.

Der private Sparkle-Schlüssel gehört weder in Git noch in Logs oder Argumente.
Der projektspezifische Schlüssel liegt lokal im Login-Schlüsselbund unter dem
Sparkle-Account `io.github.danielmuellerir.tagexplosion`. Nur sein öffentlicher
Gegenpart (`SUPublicEDKey`) steht im App-Bundle.

## Einmalige GitHub-Einrichtung

1. In den Repository-Einstellungen unter **Pages** als Quelle **GitHub Actions**
   wählen.
2. Den privaten Schlüssel als Actions-Secret `SPARKLE_PRIVATE_KEY` hinterlegen.
   Sparkles `generate_keys -x` exportiert ihn vorübergehend in eine lokale
   Datei; `gh secret set SPARKLE_PRIVATE_KEY < datei` liest diese Datei über
   stdin. Die Exportdatei danach sicher entfernen. Den Schlüssel nie auf stdout
   ausgeben.
3. Den Schlüssel zusätzlich verschlüsselt sichern. Geht er verloren, ist eine
   kontrollierte Schlüsselrotation über ein Developer-ID-signiertes Archiv
   nötig.

## Ablauf pro Release

1. `VERSION` aktualisieren. `CFBundleVersion` wird daraus übernommen und muss
   monoton steigen — Sparkle vergleicht darüber.
2. `NOTARY_PROFILE=<profil> ./build.sh --release` ausführen: bündelt
   TagLib-dylibs und Sparkle.framework, signiert (Developer ID + Hardened
   Runtime), notarisiert, stapelt und erzeugt `TagExplosion-<version>.zip`.
3. Ein GitHub Release als Entwurf anlegen, genau ein ZIP anhängen, Release
   Notes eintragen und erst danach veröffentlichen.
4. `.github/workflows/publish-appcast.yml` lädt dieses ZIP, erzeugt mit
   Sparkles `generate_appcast` einen signierten Feed, bettet die Release Notes
   ein und veröffentlicht `appcast.xml` über GitHub Pages.
5. Den Workflow und anschließend
   `https://danielmuellerir.github.io/tag_explosion/appcast.xml` prüfen. Im
   App-Menü **„Nach Updates suchen …“** muss eine ältere, notarisiert
   installierte und bereits Sparkle-fähige Testversion das neue Release finden,
   installieren und neu starten. Für den Bootstrap-Test einen signierten
   Test-Build mit kleinerer `CFBundleVersion` und demselben Schlüssel verwenden;
   Versionen ohne Updater eignen sich nicht.

Für einen Upgrade-Test gegen einen lokalen Feed kann `SPARKLE_FEED_URL` beim
Build gesetzt werden (siehe `build.sh`); normale Builds verwenden immer den
öffentlichen GitHub-Pages-Feed.

Der Workflow kann für ein bereits veröffentlichtes Tag manuell gestartet
werden. Er erwartet genau ein `*.zip` im Release. Der Feed führt nur das
aktuelle Vollupdate; Delta-Updates sind bewusst deaktiviert, bis der
Pages-Workflow mehrere historische Archive mit ihren jeweiligen Download-URLs
verwaltet.
