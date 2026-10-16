#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release/pins.sh
. "$here/pins.sh"
if [ $# -ne 4 ]; then
  echo "usage: gates-test.sh DEV-LIBRAFTRKT STALE-ABI-LIBRARY RAPIDS-LIBDIR ARCH-FIXTURES" >&2
  exit 2
fi
dev=$1
stale=$2
rapids=$3
arch=$4
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
problem() {
  echo "gates-test: $*" >&2
  failures=1
}

fixture() {
  local name=$1 shim=$2 f listed
  mkdir -p "$work/$name"
  cp "$shim" "$work/$name/libraftrkt.so"
  cp "$rapids/librmm.so" "$rapids/librapids_logger.so" "$work/$name/"
  for f in $RELEASE_LICENSES; do echo "Apache-2.0" >"$work/$name/$f"; done
  printf '{}\n' >"$work/$name/manifest.json"
  chmod u+w "$work/$name"/*
  read -ra listed <<<"$RELEASE_SHIPPED $RELEASE_LICENSES manifest.json"
  (cd "$work/$name" && sha256sum "${listed[@]}" >SHA256SUMS)
}

gates() {
  local name=$1
  shift
  if bash "${tree:-$here/../..}/scripts/release/gates.sh" "$work/$name" "$@" >"$work/$name.out" 2>&1; then
    echo 0 >"$work/$name.status"
  else
    echo 1 >"$work/$name.status"
  fi
  sed "s|$work/||; s|^|$name: |" "$work/$name.out"
}
want_ok() {
  local name=$1 gate=$2
  grep -q "^ok *$gate: " "$work/$name.out" || problem "$name: want ok $gate"
}
want_fail() {
  local name=$1 file=$2 gate=$3 reason=$4
  grep -F "$file: $gate gate: " "$work/$name.out" | grep -qF -- "$reason" ||
    problem "$name: want $file: $gate gate: ...$reason..."
  [ "$(cat "$work/$name.status")" = 1 ] || problem "$name: gates.sh exited 0"
}

fixture dev "$dev"
gates dev
# shellcheck disable=SC2016
want_fail dev "$work/dev/libraftrkt.so" runpath 'want RUNPATH $ORIGIN only'
want_fail dev "$work/dev/libraftrkt.so" nix-store "names /nix/store"
want_fail dev "$work/dev/libraftrkt.so" glibc "> $RELEASE_GLIBC_MAX"
want_fail dev "$work/dev/libraftrkt.so" glibcxx "> $RELEASE_GLIBCXX_MAX"
want_fail dev "$work/dev/libraftrkt.so" architectures "fatbin module 1 has elf [sm_86] ptx [sm_86],"
for gate in files needed companion-needed abi checksums; do want_ok dev "$gate"; done

fixture stale "$stale"
gates stale
want_fail stale "$work/stale/libraftrkt.so" needed "outside the libc family"
want_fail stale "$work/stale/libraftrkt.so" abi "raft wants "
want_ok stale checksums

fixture corrupt "$dev"
awk '$2 == "librmm.so" { $1 = sprintf("%064d", 0) } { print $1 "  " $2 }' \
  "$work/corrupt/SHA256SUMS" >"$work/sums" && mv "$work/sums" "$work/corrupt/SHA256SUMS"
gates corrupt checksums
want_fail corrupt "$work/corrupt/SHA256SUMS" checksums "librmm.so: FAILED"

fixture dropped "$dev"
sed -i '/ librmm\.so$/d' "$work/dropped/SHA256SUMS"
gates dropped checksums
want_fail dropped "$work/dropped/SHA256SUMS" checksums "lists [LICENSE.librmm LICENSE.rapids_logger libraftrkt.so librapids_logger.so manifest.json]"

fixture no-logger "$dev"
rm "$work/no-logger/librapids_logger.so"
gates no-logger files
want_fail no-logger "$work/no-logger" files "missing librapids_logger.so"

fixture no-licence "$dev"
rm "$work/no-licence/LICENSE.rapids_logger"
gates no-licence files
want_fail no-licence "$work/no-licence" files "missing LICENSE.rapids_logger"

fixture stray "$dev"
cp "$dev" "$work/stray/libraftrkt.so.old"
gates stray files
want_fail stray "$work/stray/libraftrkt.so.old" files "not a release file"

fixture companion "$dev"
cp "$dev" "$work/companion/librmm.so"
gates companion companion-needed
want_fail companion "$work/companion/librmm.so" companion-needed "needs libcublas.so.13"

fixture unloadable "$dev"
echo "not a library" >"$work/unloadable/libraftrkt.so"
gates unloadable abi
want_fail unloadable "$work/unloadable/libraftrkt.so" abi "does not load: dlopen: "

tree=$work/tree
mkdir -p "$tree/scripts/release" "$tree/raft/private/foreign"
cp "$here/gates.sh" "$here/pins.sh" "$here/abi-probe.c" "$tree/scripts/release/"
echo "#lang racket/base" >"$tree/raft/private/foreign/library.rkt"
fixture no-abi-version "$dev"
gates no-abi-version abi
want_fail no-abi-version "$tree/scripts/release/../../raft/private/foreign/library.rkt" abi "no (define abi-version N)"
unset tree

fixture arch-full "$arch/full.so"
gates arch-full architectures
want_ok arch-full architectures
fixture arch-short "$arch/short.so"
gates arch-short architectures
want_fail arch-short "$work/arch-short/libraftrkt.so" architectures "fatbin module 2 has elf [sm_86] ptx []"

mkdir -p "$work/fetch/cache"
echo "wheel" >"$work/fetch/remote.whl"
sha=$(sha256sum "$work/fetch/remote.whl" | cut -d' ' -f1)
if fetched=$(release_fetch "file://$work/fetch/remote.whl" "$(printf '%064d' 0)" "$work/fetch/cache" 2>"$work/fetch.err"); then
  problem "release_fetch: a wrong pin returned 0"
fi
[ -z "$fetched" ] || problem "release_fetch: a wrong pin printed $fetched"
[ -z "$(ls -A "$work/fetch/cache")" ] || problem "release_fetch: a wrong pin left $(ls -A "$work/fetch/cache")"
grep -qF "sha256 is not" "$work/fetch.err" || problem "release_fetch: a wrong pin said $(cat "$work/fetch.err")"
fetched=$(release_fetch "file://$work/fetch/remote.whl" "$sha" "$work/fetch/cache") ||
  problem "release_fetch: the right pin failed"
[ "$fetched" = "$work/fetch/cache/remote.whl" ] && [ -f "$fetched" ] ||
  problem "release_fetch: the right pin printed [$fetched]"

pins=("$RELEASE_WHEEL_LIBRAFT $RELEASE_WHEEL_LIBRAFT_SHA256"
  "$RELEASE_WHEEL_LIBRMM $RELEASE_WHEEL_LIBRMM_SHA256"
  "$RELEASE_WHEEL_RAPIDS_LOGGER $RELEASE_WHEEL_RAPIDS_LOGGER_SHA256")
bash "$here/check-pins.sh" "${pins[@]}" "$(release_wheel_version "$RELEASE_WHEEL_CUBLAS")" >/dev/null ||
  problem "check-pins: the pins' own values failed"
if bash "$here/check-pins.sh" "${pins[@]}" 0.0.0 >"$work/pins.out"; then
  problem "check-pins: a cuBLAS 0.0.0 flake passed"
fi
grep -qF "scripts/release/pins.sh: pins the cuBLAS wheel version as" "$work/pins.out" ||
  problem "check-pins: a cuBLAS 0.0.0 flake said $(cat "$work/pins.out")"

exit "$failures"
