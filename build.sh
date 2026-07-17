#!/bin/sh
# Baut tagx (CLI) und TagExplosion.app (GUI). Headless, ohne Xcode-Projekt.
# Version kommt aus der VERSION-Datei. Optionen:
#   --cli-only   nur tagx bauen
#   --debug      Debug- statt Release-Build
#   --release    Distribution: TagLib-dylibs bündeln, Developer-ID-Signatur
#                (Hardened Runtime), Notarisierung + Stapling. Benötigt die
#                Umgebungsvariable NOTARY_PROFILE (notarytool-Keychain-Profil).
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
version="$(tr -d '[:space:]' < "$here/VERSION")"
config="release"
cli_only=0
release=0

for arg in "$@"; do
    case "$arg" in
        --cli-only) cli_only=1 ;;
        --debug) config="debug" ;;
        --release) release=1 ;;
        *) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
    esac
done

echo "== Tag Explosion $version ($config) =="

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
cp "$here/THIRD-PARTY.md" "$app/Contents/Resources/Third-Party-Licenses.md"

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
    <!-- Sparkle prüft automatisch auf Updates, installiert aber erst nach
         Zustimmung. Archiv und Feed werden mit dem projektspezifischen
         Ed25519-Schlüssel geprüft; CFBundleVersion muss dafür monoton steigen. -->
    <key>SUFeedURL</key><string>${sparkle_feed_url}</string>
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

if [ "$release" = "0" ]; then
    # 4) Ad-hoc-Signatur (lokaler Testbuild)
    codesign --force --sign - "$app/Contents/MacOS/TagExplosion"
    codesign --force --sign - "$app"
    echo "App: $app"
    exit 0
fi

# ---- Distribution (--release) -----------------------------------------------
# TagLib wird im Dev-Build dynamisch aus Homebrew geladen. Für die verteilbare
# App: dylibs nach Contents/Frameworks bündeln (läuft dann ohne Homebrew) und
# Install-Namen umbiegen — Pflicht auch wegen Library Validation der Hardened
# Runtime (fremd signierte Homebrew-dylibs würden beim Laden geblockt).
: "${NOTARY_PROFILE:?NOTARY_PROFILE muss gesetzt sein (notarytool-Keychain-Profil)}"
identity="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')"
[ -n "$identity" ] || { echo "Kein Developer-ID-Zertifikat im Schlüsselbund" >&2; exit 1; }
echo "== Signiere als: $identity =="

bin="$app/Contents/MacOS/TagExplosion"
# $fw (Contents/Frameworks) existiert bereits — Sparkle liegt schon dort.

# 1) Direkt gelinkte Homebrew-dylibs einsammeln und im Binary umbiegen
for dep in $(otool -L "$bin" | awk '$1 ~ /^\/opt\/homebrew\/.*\.dylib$/ {print $1}'); do
    base="$(basename "$dep")"
    cp -f "$dep" "$fw/$base"
    chmod u+w "$fw/$base"
    install_name_tool -id "@executable_path/../Frameworks/$base" "$fw/$base"
    install_name_tool -change "$dep" "@executable_path/../Frameworks/$base" "$bin"
done
# 2) Querverweise der gebündelten dylibs untereinander umbiegen (z.B.
#    libtag_c -> libtag, referenziert über den Cellar-Pfad)
for lib in "$fw"/*.dylib; do
    for sub in $(otool -L "$lib" | awk 'NR>1 && $1 ~ /^\/opt\/homebrew\/.*\.dylib$/ {print $1}'); do
        subbase="$(basename "$sub")"
        if [ ! -f "$fw/$subbase" ]; then
            cp -f "$sub" "$fw/$subbase"
            chmod u+w "$fw/$subbase"
            install_name_tool -id "@executable_path/../Frameworks/$subbase" "$fw/$subbase"
        fi
        install_name_tool -change "$sub" "@executable_path/../Frameworks/$subbase" "$lib"
    done
done
echo "Gebündelte Bibliotheken:"; ls "$fw"

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

# 4) Notarisieren + Ticket anheften
zip="$here/TagExplosion-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
echo "== Notarisierung eingereicht (dauert 1-10 min) =="
xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute -vv "$app"
# ZIP der GESTAPELTEN App neu packen (das ist das verteilbare Artefakt)
ditto -c -k --keepParent "$app" "$zip"

echo "App (notarisiert): $app"
echo "Verteilbares ZIP:  $zip"
