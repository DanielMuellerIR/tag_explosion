#!/usr/bin/env bash
# Prüft echte Cache-Entpackung und pkg-config-Pfade mit Shell-Sonderzeichen.
# Das Archiv ist synthetisch; Netzwerk und dessen Prüfsummenprüfung sind hier
# Attrappen. Die reale Release-Flasche wird separat am Build geprüft.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/Tests/shell-test-support.sh"
work=$(tagx_make_test_workdir tagx-portable-taglib)
trap 'rm -rf -- "$work"' EXIT
fake_bin="$work/bin"
cache="$work/cache & path|with\\slash"
mkdir -p "$fake_bin" "$cache" "$work/bottle/taglib/test/lib/pkgconfig"
version=$(sed -n 's/^version="\(.*\)"/\1/p' "$root/scripts/prepare-portable-taglib.sh")
sha=$(sed -n 's/^bottle_sha="\(.*\)"/\1/p' "$root/scripts/prepare-portable-taglib.sh")
printf 'prefix=@@HOMEBREW_CELLAR@@/taglib/%s\nVersion: %s\n' "$version" "$version" \
    > "$work/bottle/taglib/test/lib/pkgconfig/taglib.pc"
tar -czf "$cache/taglib-$version-arm64-sonoma.tar.gz" -C "$work/bottle" taglib
cat > "$fake_bin/uname" <<'FAKE'
#!/bin/sh
printf 'arm64\n'
FAKE
cat > "$fake_bin/shasum" <<'FAKE'
#!/bin/sh
printf '%s  %s\n' "$TEST_SHA" "$3"
FAKE
cat > "$fake_bin/curl" <<'FAKE'
#!/bin/sh
exit 74
FAKE
chmod +x "$fake_bin"/*
prepared=$(PATH="$fake_bin:$PATH" TEST_SHA="$sha" TAGX_PORTABLE_TAGLIB_CACHE="$cache" \
    "$root/scripts/prepare-portable-taglib.sh")
[ "$prepared" = "$cache/taglib-$version-arm64-sonoma" ]
IFS= read -r prefix < "$prepared/lib/pkgconfig/taglib.pc"
[ "$prefix" = "prefix=$prepared" ] || { echo "FEHLER: Cache-Pfad verändert" >&2; exit 1; }
echo "Portable-TagLib-Cachetest: OK"
