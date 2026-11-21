#!/bin/sh
# Schreibbares HFS+-Image befüllen, zu UDZO komprimieren und notarisieren.
set -eu

here=$1
app=$2
dmg=$3
finder_layout=$4
identity=$5
. "$here/scripts/macos-signing.sh"

echo "== DMG bauen =="
rm -f "$dmg"
vol_name="Tag Explosion"
mount_name="$vol_name-$(uuidgen)"
mount_dir="/Volumes/$mount_name"
mounted=0
staging="$(mktemp -d)"
rw_dmg="$staging/rw.dmg"
# Aufräumen auch bei Fehlern: evtl. gemountetes Volume aushängen, Staging löschen.
cleanup_dmg() {
    if [ "$mounted" = "1" ]; then
        if ! hdiutil detach "$mount_dir" -quiet 2>/dev/null; then
            echo "FEHLER: Eigenes DMG noch eingehängt: $mount_dir; Arbeitsdaten bleiben in $staging" >&2
            return
        fi
        mounted=0
    fi
    rm -rf "$staging"
}
trap cleanup_dmg EXIT
trap 'exit 1' HUP INT TERM

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
#    abgebrochenen Lauf ein anderes Volume, bleibt es unangetastet.
size_mb=$(( $(du -sm "$app" | cut -f1) + 30 ))
hdiutil create -size "${size_mb}m" -fs HFS+ -volname "$vol_name" -ov -quiet "$rw_dmg"
mounted=1
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
    # Der Finder kennt ein frisch eingehängtes Volume nicht sofort: Ein direkt
    # nach `hdiutil attach` folgendes `tell disk` scheitert mit -1728 („kann
    # nicht gelesen werden"), zwei Sekunden später ist dasselbe Volume da
    # (belegt 2026-09-10 mit einem Wegwerf-Image). Deshalb warten, bis der
    # Finder es kennt, statt sich auf glückliches Timing zu verlassen.
    for _ in $(seq 1 20); do
        osascript -e "tell application \"Finder\" to get name of (POSIX file \"$mount_dir\" as alias)" \
            >/dev/null 2>&1 && break
        sleep 0.5
    done
    osascript <<EOF
tell application "Finder"
    -- Ein roher AppleScript-alias akzeptiert open nicht; Finder braucht ein Ordnerobjekt.
    tell folder (POSIX file "$mount_dir" as alias)
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
mounted=0
hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 -quiet -o "$dmg"

# f) Auch das DMG selbst signieren (sonst meckert Quarantine beim Öffnen),
#    notarisieren und stapeln — dann läuft es auch offline ohne Gatekeeper-
#    Warnung. Geht schnell, die App darin ist bereits notarisiert.
codesign --force --timestamp --sign "$identity" "$dmg"
echo "== Notarisierung des DMG eingereicht =="
tagx_notarize_submit "$dmg"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"

echo "App (notarisiert): $app"
echo "Verteilbares DMG:  $dmg"
