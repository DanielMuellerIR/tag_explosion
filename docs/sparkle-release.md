# Sparkle-Updates veröffentlichen

Tag Explosion bindet Sparkle 2.9.4 per SwiftPM ein (exakt gepinnt in
`App/Package.swift`). Die App prüft den Feed unter
`https://danielmuellerir.github.io/tag_explosion/appcast.xml`, lädt das DMG aus
dem zugehörigen GitHub Release und installiert ausschließlich nach Zustimmung
(Sparkle mountet das DMG selbst und kopiert die App daraus).

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
   wählen. ✅ eingerichtet.
2. Den privaten Schlüssel als Actions-Secret `SPARKLE_PRIVATE_KEY` hinterlegen.
   Der zum Bundle passende Schlüssel liegt bereits im Login-Schlüsselbund; sein
   öffentlicher Gegenpart lässt sich jederzeit gefahrlos nachsehen:

   ```sh
   tool="$(find App/.build/artifacts/sparkle -name generate_keys -print -quit)"
   "$tool" --account io.github.danielmuellerir.tagexplosion -p
   # muss SUPublicEDKey aus build.sh ergeben
   ```

   Export und Übergabe an GitHub in einem Rutsch, ohne den Schlüssel je auf
   stdout zu zeigen:

   ```sh
   umask 077
   key="$(mktemp)"
   "$tool" --account io.github.danielmuellerir.tagexplosion -x "$key"
   gh secret set SPARKLE_PRIVATE_KEY --repo <owner>/<repo> < "$key"
   rm -P "$key"
   ```
3. Den Schlüssel zusätzlich verschlüsselt sichern. Geht er verloren, ist eine
   kontrollierte Schlüsselrotation über ein Developer-ID-signiertes Archiv
   nötig.

### Warum dieses Projekt einen eigenen Schlüssel behält

Sparkle selbst schreibt, ein Schlüssel reiche für beliebig viele Apps. Für ein
neues Projekt kann man den Schlüssel eines anderen also mitbenutzen. Hier
verbietet sich der Wechsel trotzdem: Jede bereits verteilte Fassung trägt den
`SUPublicEDKey` in ihrer `Info.plist` und akzeptiert später **nur** Updates, die
zu genau diesem Schlüssel passen. Ein Umstieg auf einen fremden Schlüssel wäre
eine Rotation und würde jede installierte Version von Updates abschneiden. Der
projekteigene Schlüssel existiert bereits — es gibt also auch nichts zu sparen.


## Ablauf pro Release

1. `VERSION` aktualisieren. `CFBundleVersion` wird daraus übernommen und muss
   monoton steigen — Sparkle vergleicht darüber.
2. `./release.sh` ausführen (klärt das Notary-Profil selbst; darunter läuft
   `build.sh --release`): bündelt
   TagLib-dylibs und Sparkle.framework, signiert (Developer ID + Hardened
   Runtime), notarisiert und stapelt die App, baut daraus das DMG mit
   /Applications-Symlink und Hintergrundbild (Finder-Layout per AppleScript;
   auf headless-Maschinen `--no-finder-layout`), signiert, notarisiert und
   stapelt auch das DMG und erzeugt `TagExplosion-<version>.dmg`.
3. Ein GitHub Release als Entwurf anlegen, genau ein DMG anhängen, Release
   Notes eintragen und erst danach veröffentlichen.
4. `.github/workflows/publish-appcast.yml` lädt dieses DMG, erzeugt mit
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
werden. Er erwartet genau ein `*.dmg` im Release. Der Feed führt nur das
aktuelle Vollupdate; Delta-Updates sind bewusst deaktiviert, bis der
Pages-Workflow mehrere historische Archive mit ihren jeweiligen Download-URLs
verwaltet.
