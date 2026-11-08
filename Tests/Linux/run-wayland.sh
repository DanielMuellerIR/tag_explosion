#!/usr/bin/env bash
# Eigene virtuelle KWin-Sitzung; der angemeldete Desktop bleibt unberührt.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$root/.build"
runtime="$(mktemp -d /tmp/tagx-wayland.XXXXXX)"
chmod 700 "$runtime"
cleanup() {
    if mountpoint -q "$runtime/doc"; then fusermount3 -u "$runtime/doc" || true; fi
    if ! mountpoint -q "$runtime/doc"; then rm -rf -- "$runtime"; fi
}
trap cleanup EXIT
export TAGX_TEST_ROOT="$root" XDG_RUNTIME_DIR="$runtime"
unset DISPLAY WAYLAND_DISPLAY
export QT_QPA_PLATFORM=offscreen
dbus-run-session -- bash -eu -c '
  kwin_wayland --virtual --socket wayland-tagx --width "${TAGX_TEST_WIDTH:-1280}" --height "${TAGX_TEST_HEIGHT:-900}" --scale "${TAGX_TEST_SCALE:-1}" \
    --no-lockscreen --no-global-shortcuts --no-kactivities \
    > "$TAGX_TEST_ROOT/.build/kwin-smoke.log" 2>&1 &
  compositor=$!
  trap '\''kill "$compositor" 2>/dev/null || true; wait "$compositor" 2>/dev/null || true'\'' EXIT
  for attempt in {1..100}; do
    test -S "$XDG_RUNTIME_DIR/wayland-tagx" && break
    kill -0 "$compositor"
    sleep .1
  done
  test -S "$XDG_RUNTIME_DIR/wayland-tagx"
  export WAYLAND_DISPLAY=wayland-tagx GDK_BACKEND=wayland
  dbus-update-activation-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR GDK_BACKEND
  "${TAGX_TEST_PYTHON:-python3}" "$TAGX_TEST_ROOT/Tests/Linux/gui_smoke.py" "$@"
' bash "$@"
