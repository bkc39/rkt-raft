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

unset LD_LIBRARY_PATH
wheel=$(release_fetch "$RELEASE_WHEEL_CUBLAS" "$RELEASE_WHEEL_CUBLAS_SHA256" "$cache")
export RAFT_CUDA_WHEEL_URL_BASE="file://${wheel%/*}"
fetched() {
  local root
  root=$(racket -l racket/base -l setup/dirs -e "(display $1)")
  printf '%s/rapids/cu13/nvidia-cublas-%s/lib\n' "${root%/}" "$(release_wheel_version "$RELEASE_WHEEL_CUBLAS")"
}

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
cublas=$(fetched "(find-system-path 'addon-dir)")
racket "$check" installed "$cublas"
racket -l- raft/fetch-cuda >"$work/fetch.log"
cat "$work/fetch.log"
grep -qxF "raft: cuBLAS is in $cublas" "$work/fetch.log"

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
echo "catalog test: offline, the installation-scope install warns and succeeds"
RAFT_CUDA_WHEEL_URL_BASE=http://127.0.0.1:9 install_raft installation >"$work/offline.log" 2>&1 || {
  cat "$work/offline.log"
  exit 1
}
grep -F "raft: could not fetch cuBLAS" -A1 "$work/offline.log"
racket "$check" cuda-missing
echo "catalog test: raco setup --pkgs raft, online, fetches cuBLAS into the installation"
raco setup --no-docs --pkgs raft
racket "$check" installed "$(fetched "(find-share-dir)")"
echo "catalog test: passed"
