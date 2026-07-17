#!/bin/sh
# Baut tagx (CLI) und TagExplosion.app (GUI). Headless, ohne Xcode-Projekt.
# Version kommt aus der VERSION-Datei. Optionen:
#   --cli-only   nur tagx bauen
#   --debug      Debug- statt Release-Build
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
version="$(tr -d '[:space:]' < "$here/VERSION")"
config="release"
cli_only=0

for arg in "$@"; do
    case "$arg" in
        --cli-only) cli_only=1 ;;
        --debug) config="debug" ;;
        *) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
    esac
done

echo "== Tag Explosion $version ($config) =="

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

# 4) Ad-hoc-Signatur (lokaler Testbuild; Distribution siehe docs/PLAN.md)
codesign --force --sign - "$app/Contents/MacOS/TagExplosion"
codesign --force --sign - "$app"

echo "App: $app"
