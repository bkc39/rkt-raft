#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ $# -ne 3 ]; then
  echo "usage: gates-test.sh DEV-LIBRAFTRKT STALE-ABI-LIBRARY RAPIDS-LIBDIR" >&2
  exit 2
fi
dev=$1
stale=$2
rapids=$3
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
fixture() {
  local name=$1 shim=$2
  mkdir -p "$work/$name"
  cp "$shim" "$work/$name/libraftrkt.so"
  cp "$rapids/librmm.so" "$rapids/librapids_logger.so" "$work/$name/"
  chmod u+w "$work/$name"/*
  (cd "$work/$name" && sha256sum libraftrkt.so librmm.so librapids_logger.so >SHA256SUMS)
  printf '{}\n' >"$work/$name/manifest.json"
  (cd "$work/$name" && sha256sum manifest.json >>SHA256SUMS)
}
expect() {
  local name=$1 result
  shift
  if bash "$here/gates.sh" "$work/$name" >"$work/$name.out" 2>&1; then
    echo "gates-test: $name passed every gate" >&2
    failures=1
  fi
  for result in "$@"; do
    if ! grep -q "^${result%%:*} *${result#*:}:" "$work/$name.out"; then
      echo "gates-test: $name: want ${result%%:*} ${result#*:}" >&2
      failures=1
    fi
  done
  sed "s/^/$name: /" "$work/$name.out"
}

fixture dev "$dev"
awk '$2 == "librmm.so" { $1 = sprintf("%064d", 0) } { print $1 "  " $2 }' \
  "$work/dev/SHA256SUMS" >"$work/sums" && mv "$work/sums" "$work/dev/SHA256SUMS"
expect dev FAIL:runpath FAIL:nix-store FAIL:glibc FAIL:glibcxx FAIL:architectures FAIL:checksums \
  ok:files ok:needed ok:companion-needed ok:abi

fixture stale "$stale"
expect stale FAIL:needed FAIL:abi FAIL:architectures ok:checksums

exit "$failures"
