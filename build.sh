#!/bin/sh
# Baut tagx (CLI) und TagExplosion.app (GUI). Headless, ohne Xcode-Projekt.
# Version kommt aus der VERSION-Datei. Optionen:
#   --cli-only   nur tagx bauen
#   --debug      Debug- statt Release-Build
#   --release    Distribution: TagLib-dylibs bündeln, Developer-ID-Signatur
#                (Hardened Runtime), Notarisierung + Stapling, verteilbares DMG.
#                Benötigt die Umgebungsvariable NOTARY_PROFILE
#                (notarytool-Keychain-Profil).
#   --no-finder-layout  DMG ohne AppleScript-Finder-Layout bauen (headless/CI;
#                das DMG funktioniert, das Fenster sieht nur schlichter aus).
#   --no-dmg     nur die notarisierte App erzeugen, kein DMG (nutzt install.sh).
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
version="$(tr -d '[:space:]' < "$here/VERSION")"
config="release"
cli_only=0
release=0
finder_layout=1
build_dmg=1
portable_taglib_root=""

for arg in "$@"; do
    case "$arg" in
        --cli-only) cli_only=1 ;;
        --debug) config="debug" ;;
        --release) release=1 ;;
        --no-finder-layout) finder_layout=0 ;;
        --no-dmg) build_dmg=0 ;;
        *) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
    esac
done

echo "== Tag Explosion $version ($config) =="

# Ein Release darf die aktuelle Homebrew-TagLib nicht blind übernehmen: Auf
# einem neueren Build-Mac kann deren eigenes LC_BUILD_VERSION neuer sein als
# das von der App versprochene macOS 14. Die gepinnte, verifizierte Flasche wird
# sowohl zum Übersetzen als auch zum Bündeln verwendet. Saubere SwiftPM-Builds
# verhindern, dass Objekte aus einem früheren Homebrew-Build wiederverwendet
# werden.
if [ "$release" = "1" ]; then
    portable_taglib_root="$("$here/scripts/prepare-portable-taglib.sh")"
    PKG_CONFIG_PATH="$portable_taglib_root/lib/pkgconfig"
    PKG_CONFIG_LIBDIR="$portable_taglib_root/lib/pkgconfig"
    DYLD_LIBRARY_PATH="$portable_taglib_root/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    export PKG_CONFIG_PATH PKG_CONFIG_LIBDIR DYLD_LIBRARY_PATH
    swift package --package-path "$here" clean
    swift package --package-path "$here/App" clean
fi

# Update-Feed: normale und Release-Builds nutzen immer den öffentlichen
# GitHub-Pages-Feed; für einen echten Upgrade-Test kann per Umgebungsvariable
# ein separater HTTPS-Testfeed gesetzt werden.
sparkle_feed_url="${SPARKLE_FEED_URL:-https://danielmuellerir.github.io/tag_explosion/appcast.xml}"

# 1) CLI + Core
swift build -c "$config" --package-path "$here"
echo "tagx: $here/.build/$config/tagx"

[ "$cli_only" = "1" ] && exit 0

# 2) App-Binary
swift build -c "$config" --package-path "$here/App"

# 3) App-Bundle zusammensetzen
app="$here/TagExplosion.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$here/App/.build/$config/TagExplosionApp" "$app/Contents/MacOS/TagExplosion"
printf 'APPL????' > "$app/Contents/PkgInfo"

# Sparkle.framework ins Bundle: SwiftPM linkt es, verpackt ein manuell gebautes
# .app aber nicht selbst. ditto erhält die für macOS-Frameworks wesentlichen
# Symlinks und Rechte. Ohne das Framework startet die App nicht (rpath zeigt
# auf Contents/Frameworks).
sparkle_src="$(find "$here/App/.build/artifacts/sparkle" -type d -name Sparkle.framework -print -quit 2>/dev/null || true)"
[ -n "$sparkle_src" ] || { echo "FEHLER: Sparkle.framework fehlt nach dem SwiftPM-Build." >&2; exit 1; }
fw="$app/Contents/Frameworks"
mkdir -p "$fw"
ditto "$sparkle_src" "$fw/Sparkle.framework"
# Die App läuft ohne Sandbox; Sparkles XPC-Dienste sind dafür weder nötig noch
# aktiviert. Ohne sie wird das Bundle kleiner und die Signierfläche enger.
rm -rf "$fw/Sparkle.framework/Versions/B/XPCServices" "$fw/Sparkle.framework/XPCServices"

# Lizenzhinweise der Dritt-Komponenten gehören auch ins ausgelieferte
# Binärpaket (LGPL-/Apache-Hinweispflicht), nicht nur in den Quelltext.
cp "$here/THIRD-PARTY-NOTICES.md" "$app/Contents/Resources/Third-Party-Licenses.md"

# Lokalisierung: Der String Catalog (Quelle Deutsch, Übersetzung Englisch)
# wird zu .lproj/Localizable.strings kompiliert. swift build kann .xcstrings
# nicht selbst kompilieren (nur Xcodes Build-System), deshalb hier explizit.
# Die Strings landen im Main-Bundle — genau dort sucht SwiftUI sie.
xcrun xcstringstool compile \
    "$here/App/Sources/TagExplosionApp/Resources/Localizable.xcstrings" \
    --output-directory "$app/Contents/Resources"

# Icon nur kopieren, wenn vorhanden
icon_key=""
if [ -f "$here/App/Resources/AppIcon.icns" ]; then
    cp "$here/App/Resources/AppIcon.icns" "$app/Contents/Resources/"
    icon_key="    <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tag Explosion</string>
    <key>CFBundleDisplayName</key><string>Tag Explosion</string>
    <key>CFBundleExecutable</key><string>TagExplosion</string>
    <key>CFBundleIdentifier</key><string>io.github.danielmuellerir.tagexplosion</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>CFBundleVersion</key><string>${version}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDevelopmentRegion</key><string>de</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>de</string>
        <string>en</string>
    </array>
    <!-- Sparkle prüft automatisch auf Updates, installiert aber erst nach
         Zustimmung. Archiv und Feed werden mit dem projektspezifischen
         Ed25519-Schlüssel geprüft; CFBundleVersion muss dafür monoton steigen. -->
    <!-- Der konkrete Feed wird nach dem Heredoc mit plutil eingesetzt. So
         bleiben XML-Sonderzeichen in gueltigen URLs mit Query-Parametern
         korrekt kodiert. -->
    <key>SUFeedURL</key><string></string>
    <key>SUPublicEDKey</key><string>Cpy6kemyP4778hptrUs0+guZgU3dXFzvNh7bE1xnRME=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><false/>
    <key>SUAllowsAutomaticUpdates</key><false/>
    <key>SUEnableSystemProfiling</key><false/>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SURequireSignedFeed</key><true/>
${icon_key}
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Audio-Datei</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.audio</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Bild</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Video</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>E-Book/Dokument</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.idpf.epub-container</string>
                <string>com.adobe.pdf</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Ordner</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Nicht per Textersetzung in XML schreiben: Ein gueltiger Testfeed darf Query-
# Parameter enthalten. plutil übernimmt deren XML-Kodierung und prüft danach
# zugleich, dass das erzeugte Bundle eine lesbare Property List besitzt.
plutil -replace SUFeedURL -string "$sparkle_feed_url" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

# Debug-Symbole aus der eigenen Binärdatei entfernen, BEVOR signiert wird (strip
# macht eine vorhandene Signatur ungültig). `swift build -c release` legt eine
# Debug-Map hinein: für jede übersetzte Quelldatei einen Eintrag mit dem vollen
# Pfad ihrer .o-Datei auf DIESEM Mac. Die App braucht das nicht, es verrät nur
# Benutzernamen und Projektaufbau (gefunden am 2026-08-04). `strip -S` nimmt
# genau diese Debug-Symbole und lässt die normale Symboltabelle stehen, damit
# Absturzberichte lesbar bleiben. Xcode tut das bei Release-Builds von sich aus
# (STRIP_STYLE=debugging), SwiftPM nicht.
#
# Nur die eigene Binärdatei: Sparkle und die gebündelten Bibliotheken kommen
# fertig gebaut von außen und tragen keinen Pfad dieses Macs.
strip_eigene_binary() {
    strip -S "$app/Contents/MacOS/TagExplosion"
}

if [ "$release" = "0" ]; then
    # 4) Ad-hoc-Signatur (lokaler Testbuild)
    # Ein ausdrücklich mit --debug angeforderter Build behält seine
    # Debug-Symbole: Ohne sie gäbe es kein verlässliches Quellzeilen-Debugging,
    # und genau dafür baut man debug. Gestrippt wird nur die Release-Konfiguration.
    if [ "$config" = "release" ]; then
        strip_eigene_binary
    fi
    codesign --force --sign - "$app/Contents/MacOS/TagExplosion"
    codesign --force --sign - "$app"
    echo "App: $app"
    exit 0
fi

# ---- Distribution (--release) -----------------------------------------------
# TagLib wird im Dev-Build dynamisch aus Homebrew geladen. Für die verteilbare
# App: die oben gepinnte macOS-14-Fassung nach Contents/Frameworks bündeln und
# Install-Namen umbiegen — Pflicht auch wegen Library Validation der Hardened
# Runtime (fremd signierte dylibs würden beim Laden geblockt).
: "${NOTARY_PROFILE:?NOTARY_PROFILE muss gesetzt sein (notarytool-Keychain-Profil)}"
identity="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')"
[ -n "$identity" ] || { echo "Kein Developer-ID-Zertifikat im Schlüsselbund" >&2; exit 1; }
echo "== Signiere als: $identity =="

bin="$app/Contents/MacOS/TagExplosion"
# $fw (Contents/Frameworks) existiert bereits — Sparkle liegt schon dort.

# 1) Die beiden gepinnten TagLib-dylibs ausdrücklich einsammeln. Dadurch hängt
# der Release weder vom Homebrew-Stand noch vom Installationspfad dieses Macs ab.
for base in libtag.2.dylib libtag_c.2.dylib; do
    cp -f "$portable_taglib_root/lib/$base" "$fw/$base"
    chmod u+w "$fw/$base"
    install_name_tool -id "@executable_path/../Frameworks/$base" "$fw/$base"
done

# 2) Direkte und gegenseitige TagLib-Verweise auf die Bundle-Pfade umbiegen.
# Das Auslesen und Prüfen der Ladepfade liegt in einer eigenen, einzeln
# getesteten Datei (Tests/taglib-refs-tests.sh).
. "$here/scripts/taglib-refs.sh"

rewrite_taglib_refs "$bin"
for lib in "$fw"/*.dylib; do
    rewrite_taglib_refs "$lib"
done

# Die App lädt TagLib über den C-Shim, libtag_c wiederum libtag: Beide Verweise
# müssen existieren und ins Bundle zeigen.
verify_taglib_refs "$bin" 1
verify_taglib_refs "$fw/libtag_c.2.dylib" 1
for lib in "$fw"/*.dylib; do
    verify_taglib_refs "$lib" 0
done
echo "Gebündelte Bibliotheken:"; ls "$fw"

# Letzter maschinenlesbarer Vertrag vor der Signatur: Jede ausführbare Datei
# und Bibliothek im Bundle muss die in Info.plist genannte Mindestversion halten.
"$here/scripts/verify-macos-minimums.sh" "$app"

# Erst jetzt strippen: install_name_tool oben hat die Binärdatei noch verändert,
# und strip muss vor dem Signieren laufen (siehe Erklärung bei
# strip_eigene_binary weiter oben).
strip_eigene_binary

# 3) Signieren: innere Binaries ZUERST (kein --deep), dann das Bundle.
#    Sparkles Helfer müssen dieselbe Team-ID wie die App tragen, sonst lehnt
#    die Notarisierung ab ("binary is not signed with a valid Developer ID").
codesign --force --options runtime --timestamp --sign "$identity" \
    "$fw/Sparkle.framework/Versions/B/Autoupdate"
codesign --force --options runtime --timestamp --sign "$identity" \
    "$fw/Sparkle.framework/Versions/B/Updater.app"
codesign --force --options runtime --timestamp --sign "$identity" \
    "$fw/Sparkle.framework"
for lib in "$fw"/*.dylib; do
    codesign --force --options runtime --timestamp --sign "$identity" "$lib"
done
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app"

# 4) App notarisieren + Ticket anheften. Das ZIP ist nur der Upload-Container
#    für notarytool; verteilt wird das DMG aus Schritt 5.
zip="$here/TagExplosion-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
echo "== Notarisierung der App eingereicht (dauert 1-10 min) =="
xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute -vv "$app"

# 5) DMG bauen: schreibbares HFS+-Image (nicht APFS — AppleScript-Bounds sind
#    in APFS-DMGs auf älteren macOS unzuverlässig), App + /Applications-Symlink
#    + Hintergrundbild rein, Finder-Layout per AppleScript, dann zu UDZO
#    komprimieren. Zum Schluss das DMG selbst signieren, notarisieren, stapeln.
if [ "$build_dmg" = "0" ]; then
    echo "App (notarisiert): $app"
    exit 0
fi

echo "== DMG bauen =="
dmg="$here/TagExplosion-$version.dmg"
rm -f "$dmg"
vol_name="Tag Explosion"
mount_dir="/Volumes/$vol_name"
staging="$(mktemp -d)"
rw_dmg="$staging/rw.dmg"
# Aufräumen auch bei Fehlern: evtl. gemountetes Volume aushängen, Staging löschen.
trap 'hdiutil detach "$mount_dir" -quiet 2>/dev/null || true; rm -rf "$staging"' EXIT

# a) Hintergrundbild: Der Finder zeigt auf Retina-Displays nur dann ein scharfes
#    Bild, wenn das TIFF beide Auflösungen enthält (1x = 600×420 Punkte bei
#    72 dpi, 2x = 1200×840 Pixel bei 144 dpi).
swift "$here/scripts/generate-dmg-background.swift" "$staging/DmgBackground.png"
sips -s format png -s dpiWidth 72  -s dpiHeight 72  -z 420 600 \
    "$staging/DmgBackground.png" --out "$staging/DmgBg_1x.png" >/dev/null
sips -s format png -s dpiWidth 144 -s dpiHeight 144 -z 840 1200 \
    "$staging/DmgBackground.png" --out "$staging/DmgBg_2x.png" >/dev/null
tiffutil -cathidpicheck "$staging/DmgBg_1x.png" "$staging/DmgBg_2x.png" \
    -out "$staging/DmgBackground.tiff"

# b) RW-Image erzeugen und mounten. Größe großzügig (App + 30 MB) — die
#    UDZO-Konvertierung schrumpft ohnehin auf die echte Größe. Hängt von einem
#    abgebrochenen Lauf noch ein gleichnamiges Volume, erst aushängen.
size_mb=$(( $(du -sm "$app" | cut -f1) + 30 ))
if [ -d "$mount_dir" ]; then
    hdiutil detach "$mount_dir" -quiet 2>/dev/null || true
fi
hdiutil create -size "${size_mb}m" -fs HFS+ -volname "$vol_name" -ov -quiet "$rw_dmg"
hdiutil attach -readwrite -noverify -noautoopen -quiet \
    -mountpoint "$mount_dir" "$rw_dmg"

# c) Inhalt: App, Drag-&-Drop-Ziel, verstecktes Hintergrund-Verzeichnis.
cp -R "$app" "$mount_dir/TagExplosion.app"
ln -s /Applications "$mount_dir/Applications"
mkdir "$mount_dir/.background"
cp "$staging/DmgBackground.tiff" "$mount_dir/.background/DmgBackground.tiff"
chflags hidden "$mount_dir/.background"

# d) Finder-Layout: Icon-Ansicht, Inhaltsfläche 600×420 Punkte; der
#    Finder-Chrome braucht seit macOS 26 ca. 68 Punkte zusätzlich → Fenster
#    600×488. Die Einstellungen landen in der .DS_Store des Volumes und bleiben
#    im fertigen DMG erhalten. Öffnet kurz ein Finder-Fenster —
#    mit --no-finder-layout überspringbar.
if [ "$finder_layout" = "1" ]; then
    osascript <<EOF
tell application "Finder"
    tell disk "$vol_name"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set background picture of viewOptions to file ".background:DmgBackground.tiff"
        -- Icons auf die gestrichelten Kreise im Hintergrundbild setzen
        -- (y=285: die Beschriftungen sollen nicht in die Hinweiszeile laufen)
        set position of item "TagExplosion.app" of container window to {150, 285}
        set position of item "Applications" of container window to {450, 285}
        -- Versteckte Einträge offscreen parken: bei eingeblendeten versteckten
        -- Dateien (AppleShowAllFiles) lägen sie sonst mitten im Fenster
        repeat with hiddenName in {".background", ".fseventsd", ".Trashes", ".TemporaryItems"}
            try
                set position of item hiddenName of container window to {900, 900}
            end try
        end repeat
        -- Fensterrechteck mit Read-back-Retry: ein einmaliges "set bounds"
        -- übernimmt der Finder nicht zuverlässig (erbt sonst die Größe eines
        -- vorhandenen Fensters).
        repeat with i from 1 to 5
            set the bounds of container window to {200, 120, 800, 608}
            delay 1
            if (bounds of container window) = {200, 120, 800, 608} then exit repeat
        end repeat
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF
else
    echo "--no-finder-layout gesetzt: Finder-Layout uebersprungen"
fi

# e) Aushängen und komprimieren. sync + Pause: dem Finder Zeit geben, die
#    .DS_Store fertig zu schreiben, bevor ausgehängt wird.
sync
sleep 2
hdiutil detach "$mount_dir" -quiet || hdiutil detach -force "$mount_dir"
hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 -quiet -o "$dmg"

# f) Auch das DMG selbst signieren (sonst meckert Quarantine beim Öffnen),
#    notarisieren und stapeln — dann läuft es auch offline ohne Gatekeeper-
#    Warnung. Geht schnell, die App darin ist bereits notarisiert.
codesign --force --timestamp --sign "$identity" "$dmg"
echo "== Notarisierung des DMG eingereicht =="
xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"

echo "App (notarisiert): $app"
echo "Verteilbares DMG:  $dmg"
