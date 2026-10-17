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

sums() {
  local listed
  release_words listed "$RELEASE_SHIPPED" "$RELEASE_LICENSES" manifest.json
  (cd "$work/$1" && sha256sum "${listed[@]}" >SHA256SUMS)
}
fixture() {
  local name=$1 shim=$2 f
  mkdir -p "$work/$name"
  cp "$shim" "$work/$name/libraftrkt.so"
  cp "$rapids/librmm.so" "$rapids/librapids_logger.so" "$work/$name/"
  for f in $RELEASE_LICENSES; do echo "Apache-2.0" >"$work/$name/$f"; done
  printf '{}\n' >"$work/$name/manifest.json"
  chmod u+w "$work/$name"/*
  sums "$name"
}

gates() {
  local name=$1 status=0
  shift
  timeout 60 bash "${tree:-$here/../..}/scripts/release/gates.sh" "$work/$name" "$@" >"$work/$name.out" 2>&1 || status=$?
  echo "$status" >"$work/$name.status"
  [ "$status" -ne 124 ] || problem "$name: gates.sh timed out"
  sed "s|$work/||; s|^|$name: |" "$work/$name.out"
}
want_ok() {
  local name=$1 gate=$2
  grep -q "^ok *$gate: " "$work/$name.out" || problem "$name: want ok $gate"
}
want_fail() {
  local name=$1 file=$2 gate=$3 reason=$4
  grep -F "$file: $gate gate: " "$work/$name.out" | grep -F -- "$reason" >/dev/null ||
    problem "$name: want $file: $gate gate: ...$reason..."
  [ "$(cat "$work/$name.status")" = 1 ] || problem "$name: gates.sh exited $(cat "$work/$name.status"), want 1"
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
want_fail stale "$work/stale/libraftrkt.so" architectures "no .nv_fatbin module"
want_ok stale checksums

fixture corrupt "$dev"
awk '$2 == "librmm.so" { $1 = sprintf("%064d", 0) } { print $1 "  " $2 }' \
  "$work/corrupt/SHA256SUMS" >"$work/sums" && mv "$work/sums" "$work/corrupt/SHA256SUMS"
gates corrupt checksums
want_fail corrupt "$work/corrupt/SHA256SUMS" checksums "librmm.so: FAILED"

fixture dropped "$dev"
sed -i '/ librmm\.so$/d' "$work/dropped/SHA256SUMS"
gates dropped checksums
want_fail dropped "$work/dropped/SHA256SUMS" checksums "lists [LICENSE LICENSE.librmm LICENSE.rapids_logger NOTICE libraftrkt.so librapids_logger.so manifest.json]"

fixture no-logger "$dev"
rm "$work/no-logger/librapids_logger.so"
gates no-logger files
want_fail no-logger "$work/no-logger" files "missing librapids_logger.so"

for licence in $RELEASE_LICENSES; do
  fixture "no-$licence" "$dev"
  rm -f "$work/no-$licence/$licence"
  gates "no-$licence" files
  want_fail "no-$licence" "$work/no-$licence" files "missing $licence"
done

fixture notelf "$dev"
echo "not a library" >"$work/notelf/librapids_logger.so"
sums notelf
gates notelf
want_fail notelf "$work/notelf/librapids_logger.so" files "not an x86-64 ELF64 shared object"
want_fail notelf "$work/notelf/librapids_logger.so" runpath "RUNPATH [] RPATH []"
want_ok notelf checksums

fixture pie "$dev"
"${CC:-cc}" -fPIE -pie -o "$work/pie/librmm.so" "$here/abi-probe.c" -ldl
sums pie
gates pie files
want_fail pie "$work/pie/librmm.so" files "has a PT_INTERP: an executable, not a shared object"

patch_byte() { printf '%b' "\\x$3" | dd of="$1" bs=1 seek="$2" conv=notrunc status=none; }
fixture elf32 "$dev"
patch_byte "$work/elf32/librmm.so" 4 01
sums elf32
gates elf32 files
want_fail elf32 "$work/elf32/librmm.so" files "not an x86-64 ELF64 shared object"
fixture aarch64 "$dev"
patch_byte "$work/aarch64/librmm.so" 18 b7
sums aarch64
gates aarch64 files
want_fail aarch64 "$work/aarch64/librmm.so" files "not an x86-64 ELF64 shared object"

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
GITHUB_ACTIONS=true gates no-abi-version abi
want_fail no-abi-version "$tree/raft/private/foreign/library.rkt" abi "no (define abi-version N)"
grep -qxF "::error file=raft/private/foreign/library.rkt::abi gate: no (define abi-version N)" "$work/no-abi-version.out" ||
  problem "no-abi-version: want a repo-relative ::error file= annotation"
unset tree

fixture arch-full "$arch/full.so"
gates arch-full architectures
grep -q "^ok   architectures: 1 fatbin module(s), " "$work/arch-full.out" || problem "arch-full: want ok architectures, 1 module"
fixture arch-short "$arch/short.so"
gates arch-short architectures
want_fail arch-short "$work/arch-short/libraftrkt.so" architectures "fatbin module 2 has elf [sm_86] ptx []"
! grep -qF .nvFatBinSegment "$work/arch-short.out" || problem "arch-short: 2 modules and 2 wrappers reported a mismatch"

fixture arch-many "$arch/full.so"
objcopy --dump-section .nv_fatbin="$work/one.nv_fatbin" "$work/arch-many/libraftrkt.so"
many=$((2 + 131072 / $(stat -c %s "$work/one.nv_fatbin")))
for ((i = 0; i < many; i++)); do cat "$work/one.nv_fatbin"; done >"$work/many.nv_fatbin"
head -c $((24 * many)) /dev/zero >"$work/many-wrappers"
objcopy --update-section .nv_fatbin="$work/many.nv_fatbin" --update-section .nvFatBinSegment="$work/many-wrappers" \
  "$arch/full.so" "$work/arch-many/libraftrkt.so"
gates arch-many architectures
grep -q "^ok   architectures: $many fatbin module(s), " "$work/arch-many.out" || problem "arch-many: want ok architectures, $many modules"
[ "$(cat "$work/arch-many.status")" = 0 ] || problem "arch-many: gates.sh exited $(cat "$work/arch-many.status"), want 0"

fixture arch-zero "$arch/full.so"
printf '\x50\xed\x55\xba\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' >"$work/zero-header"
objcopy --update-section .nv_fatbin="$work/zero-header" "$arch/full.so" "$work/arch-zero/libraftrkt.so"
gates arch-zero architectures
want_fail arch-zero "$work/arch-zero/libraftrkt.so" architectures "fatbin header at 0: header 0, size 0"

fatbin_fixture() {
  local name=$1 bytes=$2
  fixture "$name" "$arch/full.so"
  printf '%b' "$bytes" >"$work/$name.nv_fatbin"
  objcopy --update-section .nv_fatbin="$work/$name.nv_fatbin" "$arch/full.so" "$work/$name/libraftrkt.so"
  sums "$name"
}
magic='\x50\xed\x55\xba\x01\x00\x10\x00'
fatbin_fixture arch-truncated-4 '\x50\xed\x55\xba'
fatbin_fixture arch-truncated-12 "$magic\x00\x00\x00\x00"
for name in arch-truncated-4 arch-truncated-12; do
  gates "$name" architectures checksums
  want_fail "$name" "$work/$name/libraftrkt.so" architectures "fatbin header at 0: header none, size none"
  want_ok "$name" checksums
done
fatbin_fixture arch-overrun "$magic\x01\x00\x00\x00\x00\x00\x00\x00"
gates arch-overrun architectures
want_fail arch-overrun "$work/arch-overrun/libraftrkt.so" architectures "fatbin header at 0: header 16, size 1"
fatbin_fixture arch-huge "$magic\xff\xff\xff\xff\xff\xff\xff\xff"
gates arch-huge architectures
want_fail arch-huge "$work/arch-huge/libraftrkt.so" architectures "fatbin header at 0: header 16, size 18446744073709551615"

fixture arch-segment "$arch/short.so"
head -c 24 /dev/zero >"$work/one-wrapper"
objcopy --update-section .nvFatBinSegment="$work/one-wrapper" "$arch/short.so" "$work/arch-segment/libraftrkt.so"
gates arch-segment architectures
want_fail arch-segment "$work/arch-segment/libraftrkt.so" architectures \
  "2 fatbin module(s) in .nv_fatbin, 24 bytes of .nvFatBinSegment hold 1"

gha="gha:%,"
fixture "$gha" "$arch/short.so"
GITHUB_ACTIONS=true gates "$gha" architectures abi
message=$(sed -n "s|^$work/$gha/libraftrkt.so: \(architectures gate: fatbin module 2 .*\)\$|\1|p" "$work/$gha.out")
grep -qxF "::error title=$work/gha%3A%25%2C/libraftrkt.so::$message" "$work/$gha.out" ||
  problem "$gha: want an escaped ::error title= annotation for module 2"
grep -qF "::error title=$work/gha%3A%25%2C/libraftrkt.so::abi gate: does not load: dlopen: $work/gha:%25,/libraftrkt.so: " "$work/$gha.out" ||
  problem "$gha: want the abi message's % escaped"

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
cublas=$(release_wheel_version "$RELEASE_WHEEL_CUBLAS")
racket=$(release_racket_version "$RELEASE_RACKET")
cuda_wheels="$here/../../raft/private/cuda-wheels.rktd"
bash "$here/check-pins.sh" "${pins[@]}" "$cublas" "$racket" "$cuda_wheels" >/dev/null ||
  problem "check-pins: the pins' own values failed"
sed "s/$RELEASE_WHEEL_CUBLAS_SHA256/$(printf '0%.0s' {1..64})/" "$cuda_wheels" >"$work/cuda-wheels.rktd"
if bash "$here/check-pins.sh" "${pins[@]}" "$cublas" "$racket" "$work/cuda-wheels.rktd" >"$work/raft-pins.out"; then
  problem "check-pins: a raft cuBLAS pin with another sha256 passed"
fi
grep -qF "$work/cuda-wheels.rktd: pins the cuBLAS wheel as" "$work/raft-pins.out" ||
  problem "check-pins: a raft cuBLAS pin with another sha256 said $(cat "$work/raft-pins.out")"
if bash "$here/check-pins.sh" "${pins[@]}" 0.0.0 "$racket" "$cuda_wheels" >"$work/pins.out"; then
  problem "check-pins: a cuBLAS 0.0.0 flake passed"
fi
grep -qF "scripts/release/pins.sh: pins the cuBLAS wheel version as" "$work/pins.out" ||
  problem "check-pins: a cuBLAS 0.0.0 flake said $(cat "$work/pins.out")"
if bash "$here/check-pins.sh" "${pins[@]}" "$cublas" 9.9 "$cuda_wheels" >"$work/racket-pins.out"; then
  problem "check-pins: a Racket 9.9 floor passed"
fi
grep -qF "scripts/release/pins.sh: pins the catalog test's Racket as $racket; the flake has 9.9" "$work/racket-pins.out" ||
  problem "check-pins: a Racket 9.9 floor said $(cat "$work/racket-pins.out")"

versions="$here/fixtures/versions"
version_check() {
  local name=$1 native=$2 raft=$3 tag=$4 status=0
  racket "$here/catalog.rkt" check "$native" "$raft" "$tag" >"$work/$name.out" 2>&1 || status=$?
  echo "$status" >"$work/$name.status"
}
want_version() {
  local name=$1 want=$2
  [ "$(cat "$work/$name.status")" = 0 ] && [ "$(cat "$work/$name.out")" = "$want" ] ||
    problem "$name: want version $want, got status $(cat "$work/$name.status"): $(cat "$work/$name.out")"
}
want_refused() {
  local name=$1 reason=$2
  if [ "$(cat "$work/$name.status")" = 0 ] || ! grep -qF -- "$reason" "$work/$name.out"; then
    problem "$name: want a refusal saying $reason, got status $(cat "$work/$name.status"): $(cat "$work/$name.out")"
  fi
}
native_version=$(sed -n 's/^(define version "\(.*\)")$/\1/p' "$here/../../$RELEASE_NATIVE_PACKAGE/info.rkt")
version_check versions-repo "$here/../../$RELEASE_NATIVE_PACKAGE" "$here/../../raft" ""
want_version versions-repo "$native_version"
grep -qxF "(define native-version \"$native_version\")" "$versions/raft/info.rkt" ||
  problem "$versions/raft/info.rkt: native-version is not $native_version, $RELEASE_NATIVE_PACKAGE's version"
[ -f "$versions/$native_version/$RELEASE_NATIVE_PACKAGE/info.rkt" ] ||
  problem "$versions: no $native_version/$RELEASE_NATIVE_PACKAGE, $RELEASE_NATIVE_PACKAGE's version"
version_check versions-same "$versions/0.2/$RELEASE_NATIVE_PACKAGE" "$versions/raft" ""
want_version versions-same 0.2
version_check versions-tag "$versions/0.2/$RELEASE_NATIVE_PACKAGE" "$versions/raft" v0.2
want_version versions-tag 0.2
version_check versions-older "$versions/0.1/$RELEASE_NATIVE_PACKAGE" "$versions/raft" ""
want_refused versions-older "$RELEASE_NATIVE_PACKAGE is version 0.1, raft needs version 0.2"
version_check versions-dependency "$versions/0.2/$RELEASE_NATIVE_PACKAGE" "$versions/raft-dep-0.1" ""
want_refused versions-dependency "raft depends on $RELEASE_NATIVE_PACKAGE #:version 0.1, not 0.2"
version_check versions-wrong-tag "$versions/0.2/$RELEASE_NATIVE_PACKAGE" "$versions/raft" v0.3
want_refused versions-wrong-tag "tag v0.3 does not name version 0.2 (want v0.2)"

for copyright in "Copyright (c) 2016 Gabi Melman." \
  "Copyright (c) 2012 - present, Victor Zverovich and {fmt} contributors"; do
  grep -qF "$copyright" "$here/../../$RELEASE_NATIVE_PACKAGE/NOTICE" ||
    problem "NOTICE: lacks \"$copyright\", which librapids_logger.so's spdlog and {fmt} need"
done
readme=$(tr -s ' \n' ' ' <"$here/../../README.md")
[[ $readme == *"spdlog 1.14.1 and {fmt} 10.2.1, MIT"* ]] ||
  problem "README.md: the licence summary lacks spdlog 1.14.1 and {fmt} 10.2.1, MIT"

racket "$here/catalog.rkt" license "$here/../../$RELEASE_NATIVE_PACKAGE" >"$work/license.out" 2>&1 ||
  problem "license: $(cat "$work/license.out")"
license_case() {
  local name=$1 expression=$2 reason=$3
  mkdir -p "$work/$name"
  cp "$here/../../$RELEASE_NATIVE_PACKAGE/NOTICE" "$work/$name/"
  printf '#lang info\n(define license %s)\n' "$expression" >"$work/$name/info.rkt"
  if racket "$here/catalog.rkt" license "$work/$name" >"$work/$name.out" 2>&1 ||
    ! grep -qF -- "$reason" "$work/$name.out"; then
    problem "$name: want a refusal saying $reason, got $(cat "$work/$name.out")"
  fi
}
license_case license-no-mit "'(Apache-2.0 AND LicenseRef-NVIDIA-CUDA-EULA)" "lacks (MIT), which NOTICE names"
license_case license-n-ary "'(Apache-2.0 AND MIT AND LicenseRef-NVIDIA-CUDA-EULA)" "is not a license S-expression"

draft_case() {
  local tag=$1 want=$2 got
  got=$(bash "$here/draft-tag.sh" "$tag" 2>/dev/null) || got="exit $?"
  [ "$got" = "tag=$want" ] || problem "draft-tag: ${tag:-no tag} said $got, want tag=$want"
}
draft_case "v$native_version" "v$native_version"
draft_case "v$native_version.1" ""
draft_case "" ""
grep -qF "needs.plan.outputs.tag != ''" "$here/../../.github/workflows/release.yml" ||
  problem "release.yml: draft-release does not wait for a tag that draft-tag.sh names"

for path in "raft/**" "$RELEASE_NATIVE_PACKAGE/**"; do
  grep -qxF "      - $path" "$here/../../.github/workflows/release.yml" ||
    problem "release.yml: no pull_request path $path, which the catalog test installs"
done

exit "$failures"
