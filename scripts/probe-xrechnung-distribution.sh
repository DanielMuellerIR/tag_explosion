#!/bin/sh
# Signierte headless App-Hülle zum Prüfen der privaten KoSIT-/Java-Laufzeit.
# Keine Installation. Notarisierung nur mit --notarize.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || {
    echo "Aufruf: probe-xrechnung-distribution.sh <prüfpaket> <neuer-ausgabeordner> [--notarize]" >&2
    exit 2
}
notarize=0
if [ "$#" = 3 ]; then
    [ "$3" = "--notarize" ] || exit 2
    notarize=1
fi
bundle="$(cd "$1" && pwd)"
[ -f "$bundle/manifest.json" ] && [ -x "$bundle/runtime/Contents/Home/bin/java" ] || exit 1
[ ! -e "$2" ] || { echo "Ausgabeordner existiert bereits." >&2; exit 1; }
mkdir -p "$2"
output="$(cd "$2" && pwd)"
app="$output/XRechnungRuntimeProbe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto "$bundle" "$app/Contents/Resources/XRechnungValidator"
cp "$here/LICENSE" "$app/Contents/Resources/LICENSE.txt"
cp "$here/THIRD-PARTY-NOTICES.md" "$app/Contents/Resources/Third-Party-Licenses.md"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.danielmuellerir.tagexplosion.xrechnung-runtime-probe</string>
<key>CFBundleName</key><string>XRechnung Runtime Probe</string>
<key>CFBundleExecutable</key><string>XRechnungRuntimeProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun clang -mmacosx-version-min=14.0 "$here/Tests/Support/XRechnungRuntimeProbe.c" \
    -o "$app/Contents/MacOS/XRechnungRuntimeProbe"
identity="${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -F '"' '/Developer ID Application/ { print $2; exit }')}"
[ -n "$identity" ] || { echo "Developer-ID-Zertifikat fehlt." >&2; exit 1; }
# Die unveränderte Temurin-Runtime behält ihre Hersteller-Signatur und ihre
# JVM-Entitlements. Sie läuft als eigener Prozess; kein Nachsignieren mit --deep.
codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/MacOS/XRechnungRuntimeProbe"
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --strict --deep "$app"
ditto -c -k --keepParent "$app" "$output/XRechnungRuntimeProbe.zip"
if [ "$notarize" = 1 ]; then
    . "$here/scripts/notary-profile.sh"
    tagx_require_notary_profile
    xcrun notarytool submit "$output/XRechnungRuntimeProbe.zip" \
        --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$output/notary-result.json"
    python3 - "$output/notary-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get("status") != "Accepted":
    raise SystemExit("Notarisierung fehlgeschlagen; siehe notary-result.json")
PY
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
    ditto -c -k --keepParent "$app" "$output/XRechnungRuntimeProbe-notarized.zip"
fi
echo "$app"
