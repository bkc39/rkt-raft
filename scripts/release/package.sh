#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release/pins.sh
. "$here/pins.sh"

src=$(cd "$here/../.." && pwd)
artifact=${1:?usage: package.sh ARTIFACT DIST}
dist=${2:?usage: package.sh ARTIFACT DIST}
cache=${RELEASE_CACHE:-/cache}
work=$(mktemp -d)

hand_back() {
  rm -rf "$work"
  [ -z "${HOST_UID:-}" ] || chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$dist" "$cache"
}
trap hand_back EXIT

"$here/gates.sh" "$artifact" files checksums
release_install_racket "$cache" "$work/racket"
PATH="$work/racket/bin:$PATH"

pkg="$work/$RELEASE_NATIVE_PACKAGE"
mkdir -p "$pkg/native-libs" "$dist"
cp "$src/$RELEASE_NATIVE_PACKAGE/info.rkt" "$src/$RELEASE_NATIVE_PACKAGE/main.rkt" "$pkg/"
read -ra licences <<<"$RELEASE_LICENSES"
read -ra shipped <<<"$RELEASE_SHIPPED"
(cd "$artifact" && cp "${licences[@]}" manifest.json "$pkg/" && cp "${shipped[@]}" "$pkg/native-libs/")
cmp "$pkg/NOTICE" "$src/$RELEASE_NATIVE_PACKAGE/NOTICE"

version=$(racket "$here/catalog.rkt" check "$pkg" "$src/raft" "${RELEASE_TAG:-}")

rm -f "$dist/$RELEASE_NATIVE_PACKAGE.zip" "$dist/$RELEASE_NATIVE_PACKAGE.zip.CHECKSUM"
raco pkg create --format zip --dest "$dist" "$pkg"
racket "$here/catalog.rkt" entry "$pkg" "$dist/$RELEASE_NATIVE_PACKAGE.zip" \
  "$RELEASE_DOWNLOADS/v$version/$RELEASE_NATIVE_PACKAGE.zip" >"$dist/catalog-entry.rktd"
echo "package: $dist/$RELEASE_NATIVE_PACKAGE.zip, version $version, sha1 $(cat "$dist/$RELEASE_NATIVE_PACKAGE.zip.CHECKSUM")"
cat "$dist/catalog-entry.rktd"
