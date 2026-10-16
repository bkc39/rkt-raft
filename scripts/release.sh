#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/release/pins.sh
. "$root/scripts/release/pins.sh"

usage() {
  echo "usage: scripts/release.sh build|load-check ARTIFACT | package|catalog-test ARTIFACT DIST" >&2
  exit 2
}
step=${1:-}
case $step in
  build | load-check) [ $# -eq 2 ] || usage ;;
  package | catalog-test) [ $# -eq 3 ] || usage ;;
  *) usage ;;
esac
mkdir -p "$2"
out=$(cd "$2" && pwd)
dist=""
if [ $# -eq 3 ]; then
  mkdir -p "$3"
  dist=$(cd "$3" && pwd)
fi
cache=${RELEASE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/rkt-raft-release}
mkdir -p "$cache"
commit=$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)
dirty=false
[ -z "$(git -C "$root" status --porcelain 2>/dev/null)" ] || dirty=true

run() {
  docker run --rm --init --name "${RELEASE_CONTAINER:-rr-release}-$$-$1" \
    -v "$root:/src:ro" -v "$cache:/cache" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e GITHUB_ACTIONS \
    "${@:2}"
}

build() {
  run build -v "$out:/out" \
    -e RELEASE_COMMIT="$commit" -e RELEASE_DIRTY="$dirty" -e RELEASE_JOBS="${RELEASE_JOBS:-4}" \
    "$RELEASE_BUILD_IMAGE" bash /src/scripts/release/build.sh /out
}

load_check() {
  run load -v "$out:/artifact:ro" \
    "$RELEASE_LOAD_IMAGE" bash /src/scripts/release/load-check.sh /artifact
}

package() {
  run package -v "$out:/artifact:ro" -v "$dist:/dist" -e RELEASE_TAG \
    "$RELEASE_LOAD_IMAGE" bash /src/scripts/release/package.sh /artifact /dist
}

catalog_test() {
  local raft
  raft=$(mktemp -d)
  trap 'rm -rf "$raft"' RETURN
  git -C "$root" ls-files -z -- raft | tar -C "$root" --null -T - -cf - | tar -C "$raft" -xf -
  run catalog -v "$out:/artifact:ro" -v "$dist:/dist:ro" -v "$raft/raft:/raft:ro" -e CATALOG_TEST_OMIT_NATIVE \
    "$RELEASE_LOAD_IMAGE" bash /src/scripts/release/catalog-test.sh /dist /raft /artifact
}

case $step in
  build) build ;;
  load-check) load_check ;;
  package) package ;;
  catalog-test) catalog_test ;;
esac
