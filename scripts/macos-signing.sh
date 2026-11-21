#!/bin/sh
# Signatur- und Notar-Helfer für die macOS-Artefakte von build.sh.

# SwiftPM schreibt absolute Objektpfade in die Debug-Map der eigenen Binaries.
# Vor der Signatur entfernt strip -S diese Pfade und erhält die Symboltabelle
# für Absturzberichte.
tagx_strip_app_binaries() {
    local app=$1
    strip -S "$app/Contents/MacOS/TagExplosion"
    strip -S "$app/Contents/PlugIns/TagExplosionPreview.appex/Contents/MacOS/TagExplosionPreview"
}

tagx_sign_local_app() {
    local here=$1 app=$2 config=$3
    local preview="$app/Contents/PlugIns/TagExplosionPreview.appex"

    # Debug-Artefakte behalten ihre Debug-Symbole.
    if [ "$config" = "release" ]; then
        tagx_strip_app_binaries "$app"
    fi
    codesign --force --sign - --entitlements "$here/App/Extensions/Preview.entitlements" "$preview"
    codesign --force --sign - "$app/Contents/MacOS/TagExplosion"
    codesign --force --sign - "$app"
}

tagx_developer_id() {
    : "${NOTARY_PROFILE:?NOTARY_PROFILE muss gesetzt sein (notarytool-Keychain-Profil)}"
    local identity
    identity="$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')"
    [ -n "$identity" ] || { echo "Kein Developer-ID-Zertifikat im Schlüsselbund" >&2; return 1; }
    printf '%s\n' "$identity"
}

tagx_sign_release_app() {
    local here=$1 app=$2 portable_taglib_root=$3 identity=$4
    local bin="$app/Contents/MacOS/TagExplosion" fw="$app/Contents/Frameworks"
    local preview="$app/Contents/PlugIns/TagExplosionPreview.appex" preview_fw preview_bin base lib

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

    # Jede Erweiterung läuft mit einem eigenen executable_path. Ihre beiden
    # TagLib-Bibliotheken liegen deshalb im eigenen Frameworks-Verzeichnis.
    preview_fw="$preview/Contents/Frameworks"
    preview_bin="$preview/Contents/MacOS/TagExplosionPreview"
    mkdir -p "$preview_fw"
    for base in libtag.2.dylib libtag_c.2.dylib; do
        cp "$fw/$base" "$preview_fw/$base"
    done
    rewrite_taglib_refs "$preview_bin"
    verify_taglib_refs "$preview_bin" 1
    for lib in "$preview_fw"/*.dylib; do
        verify_taglib_refs "$lib" 0
    done

    # Die App lädt TagLib über den C-Shim, libtag_c wiederum libtag: Beide Verweise
    # müssen existieren und ins Bundle zeigen.
    verify_taglib_refs "$bin" 1
    verify_taglib_refs "$fw/libtag_c.2.dylib" 1
    for lib in "$fw"/*.dylib; do
        verify_taglib_refs "$lib" 0
    done
    echo "Gebündelte Bibliotheken:"
    ls "$fw"

    # Letzter maschinenlesbarer Vertrag vor der Signatur: Jede ausführbare Datei
    # und Bibliothek im Bundle muss die in Info.plist genannte Mindestversion halten.
    "$here/scripts/verify-macos-minimums.sh" "$app"

    # Erst jetzt strippen: install_name_tool oben hat die Binärdatei noch verändert,
    # und strip muss vor dem Signieren laufen (siehe Erklärung bei
    # tagx_strip_app_binaries weiter oben).
    tagx_strip_app_binaries "$app"

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
    for lib in "$preview_fw"/*.dylib; do
        codesign --force --options runtime --timestamp --sign "$identity" "$lib"
    done
    codesign --force --options runtime --timestamp --sign "$identity" \
        --entitlements "$here/App/Extensions/Preview.entitlements" "$preview"
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
    codesign --verify --strict --verbose=2 "$app"
}

# notarytool liest das Keychain-Profil gelegentlich falsch-negativ ("No
# Keychain password item found", obwohl das Profil da ist — belegt u.a.
# 2026-08-16: dieselbe Sitzung hatte Sekunden zuvor die App mit genau diesem
# Profil eingereicht). Der Falsch-Negativ-Fall scheitert sofort und lokal;
# NUR er wird kurz wiederholt. Jeder andere Fehler (echte Ablehnung,
# Netzproblem) schlägt unverändert beim ersten Versuch durch.
tagx_notarize_submit() {
    local target=$1 attempt status output
    for attempt in 1 2 3 4 5; do
        status=0
        output=$(xcrun notarytool submit "$target" \
            --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || status=$?
        printf '%s\n' "$output"
        [ "$status" -eq 0 ] && return 0
        case $output in
            *"No Keychain password item found"*)
                # Beim LETZTEN Versuch gibt es nichts mehr anzukuendigen: Ein
                # "neuer Versuch in 3 s" mit anschliessendem Schlaf war falsch
                # protokolliert und verzoegerte den endgueltigen Fehler nur
                # (Review-Fund 2026-08-17).
                if [ "$attempt" -lt 5 ]; then
                    echo "Hinweis: Keychain-Falsch-Negativ (Versuch $attempt/5) — neuer Versuch in 3 s." >&2
                    sleep 3
                else
                    echo "FEHLER: Keychain-Profil auch nach 5 Versuchen nicht lesbar." >&2
                    return "$status"
                fi ;;
            *) return "$status" ;;
        esac
    done
    return "$status"
}

# 4) App notarisieren + Ticket anheften. Das ZIP ist nur der Upload-Container
#    für notarytool; verteilt wird das DMG aus Schritt 5.
tagx_notarize_app() {
    local app=$1 zip=$2
    ditto -c -k --keepParent "$app" "$zip"
    echo "== Notarisierung der App eingereicht (dauert 1-10 min) =="
    tagx_notarize_submit "$zip"
    rm -f "$zip"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute -vv "$app"
}
