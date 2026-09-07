#!/usr/bin/env bash
# Regression fuer die Erzeugung der Bundle-Info.plist. Ein echter lokaler
# Build prueft die Grenze vollstaendig, ohne App-Start oder Installation.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
feed='https://example.invalid/appcast.xml?channel=test&arch=arm64'

# Die Plist entsteht unabhängig von der Optimierungsstufe. Debug verwendet
# die bereits von swift test gebauten Artefakte statt eines zweiten Release-Baus.
SPARKLE_FEED_URL="$feed" "$root/build.sh" --debug

plist="$root/TagExplosion.app/Contents/Info.plist"
plutil -lint "$plist" >/dev/null
actual=$(plutil -extract SUFeedURL raw -o - "$plist")
[ "$actual" = "$feed" ] || {
    echo "FEHLER: SUFeedURL wurde nicht unveraendert in die Info.plist geschrieben." >&2
    exit 1
}

echo "Build-Plist-Test: OK"
