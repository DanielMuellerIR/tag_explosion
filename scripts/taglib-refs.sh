# Ladepfade der gebündelten TagLib-Bibliotheken prüfen und umbiegen.
# Wird von build.sh eingebunden (POSIX sh) und von Tests/taglib-refs-tests.sh
# einzeln geprüft — deshalb eine eigene Datei ohne Seiteneffekte beim Einbinden.

# Abhängigkeits-Ladepfade einer Mach-O-Datei, einer je Zeile.
#
# Zwei Fallen, die hier bewusst vermieden werden: Ein Fehler von otool darf
# nicht in einer Pipeline verschwinden (dort bestimmt nur der letzte Befehl den
# Status), und der Pfad darf nicht an Leerzeichen zerlegt werden — ein
# Build-Verzeichnis mit Leerzeichen im Namen zerbräche sonst jeden Ladepfad.
# Zeile 1 der otool-Ausgabe wiederholt den Dateinamen. Bei einer dylib nennt
# Zeile 2 zusätzlich ihre eigene Install-ID (LC_ID_DYLIB) — auch das ist keine
# Abhängigkeit und darf nicht als Verweis mitgezählt werden.
dylib_deps() {
    _deps_out="$(otool -L "$1")" || {
        echo "FEHLER: otool konnte $1 nicht lesen." >&2
        return 1
    }
    _deps_skip=1
    case "$1" in *.dylib) _deps_skip=2 ;; esac
    printf '%s\n' "$_deps_out" \
        | sed -e "1,${_deps_skip}d" -e 's/ (compatibility version .*)$//' \
              -e 's/^[[:space:]]*//' \
        | sed -n '/./p'
}

# Trifft der Ladepfad eine der beiden TagLib-Bibliotheken?
is_taglib_ref() {
    case "$1" in
        *libtag.[0-9]*.dylib|*libtag_c.[0-9]*.dylib) return 0 ;;
        *) return 1 ;;
    esac
}

# Biegt alle TagLib-Verweise einer Datei auf die gebündelten Bibliotheken um.
rewrite_taglib_refs() {
    _rewrite_deps="$(dylib_deps "$1")" || return 1
    while IFS= read -r _dep; do
        is_taglib_ref "$_dep" || continue
        case "$_dep" in
            @executable_path/../Frameworks/*) continue ;;
        esac
        install_name_tool -change "$_dep" \
            "@executable_path/../Frameworks/${_dep##*/}" "$1" || return 1
    done <<EOF
$_rewrite_deps
EOF
}

# Kontrolle nach dem Umbiegen: Jeder verbliebene TagLib-Verweis muss in das
# Bundle zeigen, und es müssen mindestens $2 Verweise gefunden worden sein.
# Ohne die Mindestzahl ginge ein Lauf, der gar keinen Verweis erkannt hat, als
# Erfolg durch — die App startete dann nur auf diesem Mac. Signatur,
# Notarisierung und Mindestversionsprüfung lösen Ladepfade nicht auf.
verify_taglib_refs() {
    _verify_deps="$(dylib_deps "$1")" || return 1
    _seen=0
    while IFS= read -r _dep; do
        is_taglib_ref "$_dep" || continue
        _seen=$((_seen + 1))
        case "$_dep" in
            @executable_path/../Frameworks/libtag.[0-9]*.dylib) ;;
            @executable_path/../Frameworks/libtag_c.[0-9]*.dylib) ;;
            *)
                echo "FEHLER: $1 lädt TagLib von außerhalb des Bundles: $_dep" >&2
                return 1
                ;;
        esac
    done <<EOF
$_verify_deps
EOF
    if [ "$_seen" -lt "$2" ]; then
        echo "FEHLER: $1 nennt $_seen TagLib-Verweise (erwartet: mindestens $2)." >&2
        return 1
    fi
}
