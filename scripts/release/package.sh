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

release_on_exit --remove "$work" "$dist" "$cache"

"$here/gates.sh" "$artifact" files checksums
release_use_racket "$cache" "$work/racket"

pkg="$work/$RELEASE_NATIVE_PACKAGE"
mkdir -p "$pkg/native-libs" "$dist"
cp "$src/$RELEASE_NATIVE_PACKAGE/info.rkt" "$src/$RELEASE_NATIVE_PACKAGE/main.rkt" "$pkg/"
declare -a licences shipped
release_words licences "$RELEASE_LICENSES"
release_words shipped "$RELEASE_SHIPPED"
(cd "$artifact" && cp "${licences[@]}" manifest.json "$pkg/" && cp "${shipped[@]}" "$pkg/native-libs/")
cmp "$pkg/NOTICE" "$src/$RELEASE_NATIVE_PACKAGE/NOTICE"

version=$(racket "$here/catalog.rkt" check "$pkg" "$src/raft" "${RELEASE_TAG:-}")
racket "$here/catalog.rkt" license "$pkg" >/dev/null

rm -f "$dist/$RELEASE_NATIVE_PACKAGE.zip" "$dist/$RELEASE_NATIVE_PACKAGE.zip.CHECKSUM"
raco pkg create --format zip --dest "$dist" "$pkg"
racket "$here/catalog.rkt" entry "$pkg" "$dist/$RELEASE_NATIVE_PACKAGE.zip" \
  "$RELEASE_DOWNLOADS/v$version/$RELEASE_NATIVE_PACKAGE.zip" >"$dist/catalog-entry.rktd"
echo "package: $dist/$RELEASE_NATIVE_PACKAGE.zip, version $version, sha1 $(cat "$dist/$RELEASE_NATIVE_PACKAGE.zip.CHECKSUM")"
cat "$dist/catalog-entry.rktd"
