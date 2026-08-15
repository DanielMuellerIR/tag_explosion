#!/usr/bin/env bash
# Gemeinsame Helfer der Shell-Regressionen. Diese Datei wird nur eingebunden;
# sie startet selbst keine Tests.

tagx_make_test_workdir() {
    if [ "$#" -ne 1 ] || [ -z "$1" ]; then
        echo "FEHLER: tagx_make_test_workdir braucht genau einen Präfix" >&2
        return 2
    fi

    local prefix=$1
    local temp_parent=${TMPDIR:-/tmp}
    # Manche Starter hinterlassen TMPDIR mit einem inzwischen gelöschten
    # Sitzungsordner. In diesem Fall ist /tmp der portable sichere Rückfall.
    if [ ! -d "$temp_parent" ] || [ ! -w "$temp_parent" ]; then
        temp_parent=/tmp
    fi
    if [ ! -d "$temp_parent" ] || [ ! -w "$temp_parent" ]; then
        echo "FEHLER: kein beschreibbarer temporärer Ordner verfügbar" >&2
        return 1
    fi

    /usr/bin/mktemp -d "$temp_parent/$prefix.XXXXXX"
}
