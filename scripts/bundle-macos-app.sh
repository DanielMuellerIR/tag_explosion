#!/bin/sh
# Intern von build.sh aufgerufen, nachdem SwiftPM die App gebaut hat.
set -eu

here=$1
config=$2
version=$3

# Update-Feed: normale und Release-Builds nutzen immer den öffentlichen
# GitHub-Pages-Feed; für einen echten Upgrade-Test kann per Umgebungsvariable
# ein separater HTTPS-Testfeed gesetzt werden.
sparkle_feed_url="${SPARKLE_FEED_URL:-https://danielmuellerir.github.io/tag_explosion/appcast.xml}"

# 3) App-Bundle zusammensetzen
app="$here/TagExplosion.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$here/App/.build/$config/TagExplosionApp" "$app/Contents/MacOS/TagExplosion"
printf 'APPL????' > "$app/Contents/PkgInfo"

# Moderne Quick-Look-Erweiterung: SwiftPM baut das Executable mit dem
# Foundation-Einstieg NSExtensionMain; ein Xcode-Projekt ist nicht nötig.
preview="$app/Contents/PlugIns/TagExplosionPreview.appex"
mkdir -p "$preview/Contents/MacOS"
cp "$here/App/.build/$config/TagExplosionPreview" "$preview/Contents/MacOS/TagExplosionPreview"
cp "$here/App/Extensions/Preview-Info.plist" "$preview/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$preview/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$preview/Contents/Info.plist"

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
cp "$here/LICENSE" "$app/Contents/Resources/LICENSE"

# Beide Prüfer und ihre Quellen müssen vor dem Bündeln zum Inventar passen.
package_validator() {
    local bundle=$1 sources=$2 preparer=$3 verifier=$4 destination=$5 suffix=$6
    if [ ! -d "$bundle" ]; then
        python3 "$here/scripts/$preparer" --output "$bundle" --sources-output "$sources"
    fi
    python3 "$here/scripts/$verifier" "$bundle" --sources "$sources"
    ditto "$bundle" "$app/Contents/Resources/$destination"
    # AppleDouble-Dateien würden das geprüfte Quelleninventar beim Entpacken ändern.
    ditto --norsrc --noextattr --noqtn -c -k --keepParent \
        "$sources" "$here/TagExplosion-$version-$suffix.zip"
}

validation_key="$(shasum -a 256 "$here/licenses/validation/components.lock.json" | cut -c1-16)"
validation_bundle="${XRECHNUNG_VALIDATOR_BUNDLE:-$here/.validation-build/xrechnung-$validation_key-$(uname -m)}"
validation_sources="${VALIDATION_SOURCES:-${validation_bundle}-sources}"
package_validator "$validation_bundle" "$validation_sources" \
    prepare-xrechnung-validator.py validation_compliance.py XRechnungValidator validation-sources

# veraPDF verwendet dieselbe Java-Laufzeit mit eigenem Inventar.
pdf_key="$(shasum -a 256 "$here/licenses/pdf-validation/components.lock.json" | cut -c1-16)"
pdf_bundle="${PDF_VALIDATOR_BUNDLE:-$here/.validation-build/pdf-$pdf_key}"
pdf_sources="${PDF_VALIDATION_SOURCES:-${pdf_bundle}-sources}"
package_validator "$pdf_bundle" "$pdf_sources" \
    prepare-pdf-validator.py pdf_validation_compliance.py PDFValidator pdf-validation-sources

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
    <key>NSServices</key>
    <array><dict>
        <key>NSMessage</key><string>openFilesInTagExplosion</string>
        <key>NSPortName</key><string>Tag Explosion</string>
        <key>NSMenuItem</key><dict><key>default</key><string>Open in Tag Explosion</string></dict>
        <key>NSSendTypes</key><array><string>public.file-url</string><string>NSFilenamesPboardType</string></array>
        <key>NSSendFileTypes</key><array><string>public.data</string><string>public.folder</string></array>
        <key>NSRequiredContext</key><dict><key>NSApplicationIdentifier</key><string>com.apple.finder</string></dict>
    </dict></array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict><key>UTTypeIdentifier</key><string>org.xiph.flac</string>
            <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
            <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>flac</string></array>
                <key>public.mime-type</key><string>audio/flac</string></dict></dict>
        <dict><key>UTTypeIdentifier</key><string>org.xiph.ogg-audio</string>
            <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
            <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>ogg</string><string>oga</string></array>
                <key>public.mime-type</key><string>audio/ogg</string></dict></dict>
        <dict><key>UTTypeIdentifier</key><string>org.xiph.opus</string>
            <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
            <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>opus</string></array></dict></dict>
        <dict><key>UTTypeIdentifier</key><string>org.matroska.mkv</string>
            <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
            <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mkv</string></array></dict></dict>
        <dict><key>UTTypeIdentifier</key><string>org.matroska.mka</string>
            <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
            <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mka</string></array></dict></dict>
    </array>
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
            <key>CFBundleTypeName</key><string>Dokument</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.openxmlformats.wordprocessingml.document</string>
                <string>org.openxmlformats.spreadsheetml.sheet</string>
                <string>org.openxmlformats.presentationml.presentation</string>
                <string>org.oasis-open.opendocument.text</string>
                <string>org.oasis-open.opendocument.spreadsheet</string>
                <string>org.oasis-open.opendocument.presentation</string>
                <string>net.daringfireball.markdown</string>
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

mkdir -p "$app/Contents/Resources/de.lproj" "$app/Contents/Resources/en.lproj"
printf '"Open in Tag Explosion" = "In Tag Explosion öffnen";\n' > "$app/Contents/Resources/de.lproj/ServicesMenu.strings"
printf '"Open in Tag Explosion" = "Open in Tag Explosion";\n' > "$app/Contents/Resources/en.lproj/ServicesMenu.strings"

# Nicht per Textersetzung in XML schreiben: Ein gueltiger Testfeed darf Query-
# Parameter enthalten. plutil übernimmt deren XML-Kodierung und prüft danach
# zugleich, dass das erzeugte Bundle eine lesbare Property List besitzt.
plutil -replace SUFeedURL -string "$sparkle_feed_url" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

# Auch die erzeugten ZIPs müssen portabel entpackt exakt zum Bundle passen.
python3 "$here/scripts/verify-validation-distribution.py" "$app" --artifacts "$here" --version "$version"
