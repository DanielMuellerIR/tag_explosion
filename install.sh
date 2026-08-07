#!/usr/bin/env bash
# Tag Explosion — notarisierten Build erzeugen und nach /Applications installieren.
#
# Baut CLI und App als Release, bündelt TagLib und Sparkle, signiert mit
# Developer ID und Hardened Runtime, notarisiert bei Apple, heftet das Ticket
# ans Bundle und installiert es. Danach startet die App ohne Gatekeeper-
# Rückfrage, auch auf einem anderen Mac.
#
# Nach /Applications wandert ausschließlich ein nachweislich notarisiertes
# Bundle: Stapler, Gatekeeper und Signatur werden vor dem Kopieren geprüft.
# Ein nur signierter Test-Build (--no-notarize) bleibt im Projektordner.
#
# Aufruf:
#   ./install.sh                          # Notary-Profil aus git config/Abfrage
#   NOTARY_PROFILE=<profil> ./install.sh  # Profil für diesen Lauf
#   ./install.sh --no-notarize            # schneller Testbau, ohne Installation
#
# Das notarytool-Profil ist pro Mac lokal (kein iCloud-Sync). Beim ersten Lauf
# auf einem neuen Mac fragt das Skript danach und richtet es auf Wunsch ein.
#
# Letzte Zeile bei Erfolg (maschinenlesbar):
#   INSTALL OK: /Applications/TagExplosion.app (<version>)

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

NOTARIZE=1
for arg in "$@"; do
    case "$arg" in
        --no-notarize) NOTARIZE=0 ;;
        *) echo "Unbekannte Option: $arg" >&2
           echo "Aufruf: ./install.sh [--no-notarize]" >&2; exit 2 ;;
    esac
done

version="$(tr -d '[:space:]' < "$here/VERSION")"
app="$here/TagExplosion.app"
dest="/Applications/TagExplosion.app"

if [ "$NOTARIZE" -eq 0 ]; then
    # Nur bauen und ad-hoc signieren — bleibt bewusst im Projektordner.
    ./build.sh
    echo
    echo "BUILD OK: $app ($version, nicht notarisiert — nicht für /Applications)"
    exit 0
fi

# Das Profil vor dem teuren Build klären.
# shellcheck source=scripts/notary-profile.sh
source "$here/scripts/notary-profile.sh"
tagx_require_notary_profile

# Baut, bündelt, signiert, notarisiert und stapelt die App (ohne DMG).
./build.sh --release --no-dmg

# Vor dem Kopieren beweisen, dass das Bundle wirklich notarisiert ist.
echo "== Prüfe das Bundle vor der Installation =="
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
codesign --verify --deep --strict --verbose=2 "$app"

# Eine laufende Instanz würde beim Kopieren ein offenes Binary treffen.
# Nur regulär beenden (Apple Event) und auf den echten Prozessausstieg warten:
# Ein hartes pkill würde ungesicherte Änderungen verwerfen und träfe zudem
# jeden gleichnamigen Prozess. Lehnt die App das Beenden ab (z.B. offener
# Sichern-Dialog) oder dauert es zu lange, bricht die Installation ab.
if pgrep -x TagExplosion >/dev/null 2>&1; then
    echo "== Beende die laufende Instanz (regulär) =="
    osascript -e 'tell application id "io.github.danielmuellerir.tagexplosion" to quit' \
        >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
        pgrep -x TagExplosion >/dev/null 2>&1 || break
        sleep 1
    done
    if pgrep -x TagExplosion >/dev/null 2>&1; then
        echo "FEHLER: TagExplosion läuft noch (Beenden abgelehnt oder zu langsam)." >&2
        echo "Bitte die App beenden — ungesicherte Änderungen vorher sichern — und ./install.sh erneut starten." >&2
        exit 1
    fi
fi

echo "== Installiere nach /Applications =="
# Erst vollständig in ein verstecktes Geschwisterverzeichnis kopieren und DORT
# prüfen; die funktionierende Installation weicht erst, wenn der Ersatz
# nachweislich gültig ist. Ein Kopier- oder Prüffehler lässt sie unangetastet.
new="/Applications/.TagExplosion.app.new.$$"
old="/Applications/.TagExplosion.app.old.$$"
# Erst nach der bestandenen Endprüfung gilt die Installation als geglückt.
installed=0
# Bei jedem Ausgang (Prüf-Abbruch via set -e, Signal, regulär) zustandsabhängig
# aufräumen: Solange der Austausch nicht bis zur bestandenen Endprüfung
# gekommen ist, kommt die bisherige, funktionierende Installation zurück. Sie
# liegt zwischen den beiden mv-Schritten nur beiseite — ein Abbruch genau dort
# ließ "/Applications/TagExplosion.app" sonst ganz verschwinden, und ein
# nachträglich abgelehntes Bundle bliebe an ihrer Stelle stehen.
cleanup() {
    if [ "$installed" -eq 0 ] && [ -d "$old" ]; then
        rm -rf "$dest"
        mv "$old" "$dest" 2>/dev/null || true
    fi
    rm -rf "$new" "$old"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
rm -rf "$new"
ditto "$app" "$new"
xcrun stapler validate "$new"
spctl --assess --type execute --verbose=2 "$new"
codesign --verify --deep --strict --verbose=2 "$new"

# Austausch: alt beiseite stellen, neu einsetzen. Die alte Fassung bleibt bis
# nach den Endprüfungen liegen; das Zurückholen und Entfernen macht `cleanup`.
if [ -d "$dest" ]; then mv "$dest" "$old"; fi
if ! mv "$new" "$dest"; then
    echo "FEHLER: Konnte $dest nicht ersetzen — alte Installation wird wiederhergestellt." >&2
    exit 1
fi

# Dieselben Prüfungen noch einmal am tatsächlich installierten Bundle: Erst das
# beweist, dass in /Applications eine gültige, notarisierte App liegt. Fällt
# eine davon durch, holt `cleanup` die alte Installation zurück.
xcrun stapler validate "$dest"
spctl --assess --type execute --verbose=2 "$dest"
codesign --verify --deep --strict --verbose=2 "$dest"
installed=1

echo
echo "INSTALL OK: $dest ($version)"
