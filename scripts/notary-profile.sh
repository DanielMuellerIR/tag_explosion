#!/usr/bin/env bash
# Gemeinsame, public-safe Verwaltung des lokalen notarytool-Profils.
#
# Notarisierungs-Zugangsdaten liegen ausschließlich im macOS-Schlüsselbund und
# werden von iCloud NICHT zwischen Macs synchronisiert — jeder Mac braucht das
# Profil also einmal selbst. Im Repository landet nichts davon; der (nicht
# geheime, aber interne) Profilname wird höchstens clone-lokal in .git/config
# abgelegt und kann damit weder committet noch gepusht werden.
#
# Reihenfolge: $NOTARY_PROFILE → clone-lokale git config → interaktive Abfrage.

tagx_require_notary_profile() {
    local profile="${NOTARY_PROFILE:-}"

    if [ -z "$profile" ]; then
        profile="$(git config --local --get tagexplosion.notaryProfile 2>/dev/null || true)"
    fi

    if [ -z "$profile" ]; then
        if [ ! -t 0 ]; then
            echo "✗ Kein Notary-Profil für diesen Mac konfiguriert." >&2
            echo "  Einmalig setzen (nur für diesen Clone, nicht im Repository):" >&2
            echo "  git config --local tagexplosion.notaryProfile <profil>" >&2
            echo "  Oder pro Aufruf: NOTARY_PROFILE=<profil> ./install.sh" >&2
            return 1
        fi
        printf "Notary-Profilname für diesen Mac: " >&2
        IFS= read -r profile
        [ -n "$profile" ] || { echo "✗ Kein Profilname angegeben." >&2; return 1; }
    fi

    # `history` ist der verlässliche Test. Ein `security find-generic-password`
    # findet gültige Profile nicht immer und meldet sie fälschlich als fehlend.
    #
    # Fünf Versuche statt einem: `history` meldet gelegentlich fälschlich „No
    # Keychain password item found", obwohl das Profil da ist (2026-07-26 auf M3
    # belegt — Versuch 1 fehlgeschlagen, Versuch 2 sofort ok). Ein einzelner
    # Fehlversuch würde sonst einen ganzen Lauf grundlos abbrechen oder unnötig
    # nach store-credentials fragen; ein wirklich fehlendes Profil scheitert auch
    # nach fünf Versuchen.
    local attempt profile_ok=0
    for attempt in 1 2 3 4 5; do
        if xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
            profile_ok=1
            break
        fi
        sleep 3
    done
    if [ "$profile_ok" = 0 ]; then
        echo "✗ Notary-Profil '$profile' ist auf diesem Mac nicht verwendbar." >&2
        if [ ! -t 0 ]; then
            echo "  In einer lokalen GUI-Terminalsitzung einmalig einrichten:" >&2
            echo "  xcrun notarytool store-credentials '$profile' \\" >&2
            echo "      --apple-id '<apple-id>' --team-id '<team-id>'" >&2
            echo "  Das App-spezifische Passwort nur an der Abfrage eingeben, nie als Argument." >&2
            return 1
        fi

        printf "Profil jetzt interaktiv im Schlüsselbund einrichten? [j/N] " >&2
        local answer
        IFS= read -r answer
        case "$answer" in
            j|J|ja|Ja|JA|y|Y|yes|Yes|YES) ;;
            *) return 1 ;;
        esac

        local apple_id team_id
        printf "Apple-ID: " >&2
        IFS= read -r apple_id
        printf "Team-ID: " >&2
        IFS= read -r team_id
        if [ -z "$apple_id" ] || [ -z "$team_id" ]; then
            echo "✗ Apple-ID und Team-ID dürfen nicht leer sein." >&2
            return 1
        fi
        # Bewusst ohne --password: notarytool fragt das App-spezifische Passwort
        # verdeckt ab und legt es direkt im lokalen Schlüsselbund ab.
        xcrun notarytool store-credentials "$profile" \
            --apple-id "$apple_id" --team-id "$team_id"
        xcrun notarytool history --keychain-profile "$profile" >/dev/null
    fi

    git config --local tagexplosion.notaryProfile "$profile" 2>/dev/null || true
    NOTARY_PROFILE="$profile"
    export NOTARY_PROFILE
}
