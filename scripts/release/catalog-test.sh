#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release/pins.sh
. "$here/pins.sh"

usage="usage: catalog-test.sh DIST RAFT-SOURCE ARTIFACT"
dist=${1:?$usage}
raft_src=${2:?$usage}
artifact=${3:?$usage}
cache=${RELEASE_CACHE:-/cache}
work=$(mktemp -d)
release_on_exit --remove "$work" "$cache"

echo "catalog test: $(ldd --version | head -n1), no GPU, no nix"
release_use_racket "$cache" "$work/racket"
check="$here/catalog-check.rkt"

catalog="$work/catalog"
mkdir -p "$catalog/pkg" "$work/files/raft"
cp -R "$raft_src/." "$work/files/raft/"
raco pkg create --format zip --dest "$work/files" "$work/files/raft"
racket "$here/catalog.rkt" entry "$work/files/raft" "$work/files/raft.zip" "$work/files/raft.zip" \
  >"$catalog/pkg/raft"
native_zip="$dist/$RELEASE_NATIVE_PACKAGE.zip"
mkdir -p "$work/files/native"
unzip -q "$native_zip" -d "$work/files/native/$RELEASE_NATIVE_PACKAGE"
cmp "$artifact/manifest.json" "$work/files/native/$RELEASE_NATIVE_PACKAGE/manifest.json"

# Until #44 fetches cuBLAS, the pinned wheel's copy on LD_LIBRARY_PATH.
cublas_from_wheel() {
  local wheel
  cublas="$work/cublas"
  wheel=$(release_fetch "$RELEASE_WHEEL_CUBLAS" "$RELEASE_WHEEL_CUBLAS_SHA256" "$cache")
  unzip -q -j "$wheel" nvidia/cu13/lib/libcublas.so.13 nvidia/cu13/lib/libcublasLt.so.13 -d "$cublas"
  export LD_LIBRARY_PATH=$cublas
}
cublas_from_wheel

install_raft() {
  local scope=$1
  echo "catalog test: raco pkg install raft, $scope scope"
  raco pkg install --batch --auto --no-docs --scope "$scope" raft
}

export PLTUSERHOME="$work/user"
declare -a catalogs
release_words catalogs "$RELEASE_RACKET_CATALOGS"

if [ -n "${CATALOG_TEST_OMIT_NATIVE:-}" ]; then
  echo "catalog test: $RELEASE_NATIVE_PACKAGE left out of the catalog, only the Racket release catalog behind it"
  raco pkg config --set --scope installation catalogs "file://$catalog" "${catalogs[0]}"
  if install_raft user >"$work/omit.log" 2>&1; then
    echo "catalog test: raft installed with no $RELEASE_NATIVE_PACKAGE in any catalog" >&2
    exit 1
  fi
  cat "$work/omit.log"
  grep -A1 -F "cannot find package on catalogs" "$work/omit.log" | grep -qxF "  package: $RELEASE_NATIVE_PACKAGE"
  echo "catalog test: passed, the install failed for want of $RELEASE_NATIVE_PACKAGE"
  exit 0
fi

racket "$here/catalog.rkt" entry "$work/files/native/$RELEASE_NATIVE_PACKAGE" "$native_zip" "$native_zip" \
  >"$catalog/pkg/$RELEASE_NATIVE_PACKAGE"
raco pkg config --set --scope installation catalogs "file://$catalog" "${catalogs[@]}"

install_raft user
racket "$check" installed "$cublas"

echo "catalog test: raco pkg remove $RELEASE_NATIVE_PACKAGE, then load raft and set it up"
raco pkg remove --batch --force --no-setup --scope user "$RELEASE_NATIVE_PACKAGE"
racket "$check" missing "$work/load.txt"
if racket "$check" installed "$cublas" >"$work/installed.log" 2>&1; then
  echo "catalog test: the installed check passed with no $RELEASE_NATIVE_PACKAGE" >&2
  exit 1
fi
setup_status=0
raco setup --no-docs --pkgs raft >"$work/setup.log" 2>&1 || setup_status=$?
racket "$check" setup "$setup_status" "$work/load.txt" "$work/setup.log"

export PLTUSERHOME="$work/installation-user"
install_raft installation
racket "$check" installed "$cublas"
echo "catalog test: passed"
