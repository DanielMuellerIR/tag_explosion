#!/usr/bin/env bash
# Reproduzierbarer Linux-Bau ohne Swift-/Rust-Installation auf dem Zielsystem.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
if [[ "${1:-}" == --help ]]; then
    echo 'Aufruf: ./build.sh --linux [--debug|--release] [--no-package]'
    echo 'Docker baut auf Ubuntu 24.04; Linux x86_64. --release verlangt einen Updateschlüssel.'
    exit 0
fi
config=release
package=1
sign=0
for option in "$@"; do
    case "$option" in
        --debug) config=debug ;;
        --release) sign=1 ;;
        --no-package) package=0 ;;
        *) echo "Unbekannte Linux-Bauoption: $option" >&2; exit 2 ;;
    esac
done
python3 scripts/linux-version.py
python3 scripts/linux-translations.py
if [[ "${TAGX_IN_BUILDER:-}" != 1 ]]; then
    command -v docker >/dev/null || { echo 'Docker wird für den isolierten Linux-Bau benötigt.' >&2; exit 2; }
    key_args=()
    # Nur der signierende Paketbau benötigt Schlüssel; Quellen schließen sich aus.
    if [[ "$sign" == 1 && "$config" != debug && "$package" == 1 ]]; then
        if [[ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" && -n "${TAURI_SIGNING_PRIVATE_KEY_PATH:-}" ]]; then
            echo 'Inline-Updateschlüssel und Updateschlüsseldatei sind gegenseitig ausgeschlossen; bitte nur TAURI_SIGNING_PRIVATE_KEY oder TAURI_SIGNING_PRIVATE_KEY_PATH setzen.' >&2
            exit 2
        fi
        key_args=(-e TAURI_SIGNING_PRIVATE_KEY -e TAURI_SIGNING_PRIVATE_KEY_PASSWORD)
        if [[ -n "${TAURI_SIGNING_PRIVATE_KEY_PATH:-}" ]]; then
            [[ -f "$TAURI_SIGNING_PRIVATE_KEY_PATH" && -r "$TAURI_SIGNING_PRIVATE_KEY_PATH" ]] || { echo 'Updateschlüsseldatei ist nicht lesbar.' >&2; exit 2; }
            key_path="$(cd "$(dirname "$TAURI_SIGNING_PRIVATE_KEY_PATH")" && pwd)/$(basename "$TAURI_SIGNING_PRIVATE_KEY_PATH")"
            key_args+=(-v "$key_path:/run/tagx-signing-key:ro" -e TAURI_SIGNING_PRIVATE_KEY_PATH=/run/tagx-signing-key)
        fi
    fi
    docker build --platform linux/amd64 -t tag-explosion-linux-builder:local -f Linux/Dockerfile .
    docker build --platform linux/amd64 -t tag-explosion-linux-ui:local -f Linux/Dockerfile.ui .
    docker run --rm --init --platform linux/amd64 --user "$(id -u):$(id -g)" \
        -e HOME=/src/.build/linux-home -e TAGX_IN_BUILDER=1 -e CARGO_HOME=/src/.build/cargo-cache \
        -e TAGX_BUILD_JOBS="${TAGX_BUILD_JOBS:-3}" \
        ${key_args[@]+"${key_args[@]}"} \
        -v "$root:/src" -w /src tag-explosion-linux-ui:local bash Linux/build.sh "$@"
    exit
fi
mkdir -p "$HOME" .build
jobs="${TAGX_BUILD_JOBS:-3}"
if [[ "$config" == debug ]]; then
    swift build -j "$jobs" --product tagx-engine
    cargo build --manifest-path Linux/Cargo.toml --locked -j "$jobs"
    exit
fi
swift build -c release --static-swift-stdlib -j "$jobs" --product tagx-engine
mkdir -p Linux/binaries
install -m 755 .build/release/tagx-engine Linux/binaries/tagx-engine-x86_64-unknown-linux-gnu
if [[ "$package" == 0 ]]; then
    cargo build --release --manifest-path Linux/Cargo.toml --locked -j "$jobs"
    exit
fi
# Die CLI-Version ist gepinnt; sie dient nur zum Bauen und wird nicht ausgeliefert.
(cd Linux && npm exec --cache ../.build/npm-cache --yes --package @tauri-apps/cli@2.11.4 -- tauri build --no-bundle -- --jobs "$jobs")
python3 scripts/linux-package.py
if [[ "$sign" == 1 ]]; then python3 scripts/linux-release.py; fi
