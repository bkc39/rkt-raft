#!/usr/bin/env bash
# shellcheck disable=SC2329
set -euo pipefail
export LC_ALL=C

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release/pins.sh
. "$here/pins.sh"
root=$(cd "$here/../.." && pwd)
racket_abi_source="$root/raft/private/foreign/library.rkt"

gate_names="files runpath nix-store glibc glibcxx needed companion-needed architectures abi checksums"

if [ $# -lt 1 ]; then
  echo "usage: gates.sh DIR [GATE...] (gates: $gate_names)" >&2
  exit 2
fi
dir=$1
shift
gates=${*:-$gate_names}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

failed=0
gate_failed=0
# shellcheck disable=SC2016
origin='$ORIGIN'
ok() { [ "$gate_failed" -eq 1 ] || printf 'ok   %s: %s\n' "$1" "$2"; }
escape_data() {
  local s=${1//%/%25}
  s=${s//$'\r'/%0D}
  printf '%s' "${s//$'\n'/%0A}"
}
escape_property() {
  local s
  s=$(escape_data "$1")
  s=${s//,/%2C}
  printf '%s' "${s//:/%3A}"
}
annotate() {
  local file=$1 message=$2 where
  case $file in
    "$root"/*) where="file=$(escape_property "${file#"$root"/}")" ;;
    *) where="title=$(escape_property "$file")" ;;
  esac
  printf '::error %s::%s\n' "$where" "$(escape_data "$message")"
}
fail() {
  local gate=$1 file=$2 message="$1 gate: $3"
  echo "$file: $message"
  [ -z "${GITHUB_ACTIONS:-}" ] || annotate "$file" "$message"
  gate_failed=1
  failed=1
}

present() {
  local f
  for f in $RELEASE_SHIPPED; do
    [ -f "$dir/$f" ] && printf '%s\n' "$dir/$f"
  done
}
elf_problem() {
  local header segments
  header=$(readelf -h "$1" 2>/dev/null) || true
  segments=$(readelf -l "$1" 2>/dev/null) || true
  if ! grep -q '^ *Class: *ELF64$' <<<"$header" || ! grep -q '^ *Type: *DYN ' <<<"$header" ||
    ! grep -q '^ *Machine: *Advanced Micro Devices X86-64$' <<<"$header"; then
    echo "not an x86-64 ELF64 shared object"
  elif grep -q '^ *INTERP ' <<<"$segments"; then
    echo "has a PT_INTERP: an executable, not a shared object"
  fi
}
dynamic() { { readelf -d "$1" 2>/dev/null || true; } | sed -n "s/.*($2).*\[\(.*\)\]\$/\1/p"; }
words() { tr ' ' '\n' <<<"$1" | sed '/^$/d' | sort -u; }
line() { tr '\n' ' ' <<<"$1" | sed 's/ $//'; }
required_versions() {
  { objdump -p "$1" 2>/dev/null || true; } | awk -v p="$2_" '
    /^Version References:/ { r = 1; next }
    r && /^[^ ]/ { r = 0 }
    r && index($NF, p) == 1 && $NF ~ /[0-9]$/ { print substr($NF, length(p) + 1) }'
}
version_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$2" ]; }

version_floor() {
  local gate=$1 prefix=$2 limit=$3 f v highest="" worst=""
  for f in $(present); do
    v=$(required_versions "$f" "$prefix" | sort -V | tail -n1)
    [ -n "$v" ] || continue
    if [ -z "$highest" ] || ! version_le "$v" "$highest"; then
      highest=$v
      worst=$f
    fi
  done
  if [ -z "$highest" ]; then
    fail "$gate" "$dir" "no ${prefix}_ version references"
  elif ! version_le "$highest" "$limit"; then
    fail "$gate" "$worst" "${prefix}_$highest > $limit"
  fi
  ok "$gate" "${prefix}_$highest <= $limit"
}

gate_files() {
  local want actual f problem
  want=$(words "$RELEASE_SHIPPED $RELEASE_LICENSES manifest.json SHA256SUMS")
  actual=$(find "$dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -u)
  for f in $(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$actual")); do
    fail files "$dir" "missing $f"
  done
  for f in $(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$actual")); do
    fail files "$dir/$f" "not a release file"
  done
  for f in $(present); do
    problem=$(elf_problem "$f")
    [ -z "$problem" ] || fail files "$f" "$problem"
  done
  ok files "$(line "$want")"
}

gate_runpath() {
  local f runpath rpath
  for f in $(present); do
    runpath=$(dynamic "$f" RUNPATH)
    rpath=$(dynamic "$f" RPATH)
    [ "$runpath" = "$origin" ] && [ -z "$rpath" ] ||
      fail runpath "$f" "RUNPATH [$runpath] RPATH [$rpath], want RUNPATH \$ORIGIN only"
  done
  ok runpath "$origin"
}

gate_nix_store() {
  local f
  for f in $(present); do
    if grep -aq /nix/store "$f"; then fail nix-store "$f" "names /nix/store"; fi
  done
  ok nix-store "absent"
}

gate_glibc() { version_floor glibc GLIBC "$RELEASE_GLIBC_MAX"; }
gate_glibcxx() { version_floor glibcxx GLIBCXX "$RELEASE_GLIBCXX_MAX"; }

gate_needed() {
  local lib="$dir/libraftrkt.so" actual extra
  if [ ! -f "$lib" ]; then
    fail needed "$lib" "missing"
    return
  fi
  actual=$(dynamic "$lib" NEEDED | sort -u)
  extra=$(comm -23 <(printf '%s\n' "$actual") <(words "$RELEASE_LIBC_FAMILY"))
  [ "$extra" = "$(words "$RELEASE_SHIM_NEEDED")" ] ||
    fail needed "$lib" "outside the libc family: [$(line "$extra")], want [$RELEASE_SHIM_NEEDED]"
  ok needed "$(line "$actual")"
}

gate_companion_needed() {
  local f name stray
  for name in $RELEASE_SHIPPED; do
    f="$dir/$name"
    [ "$name" != libraftrkt.so ] && [ -f "$f" ] || continue
    stray=$(comm -23 <(dynamic "$f" NEEDED | sort -u) <(words "$RELEASE_SHIPPED $RELEASE_LIBC_FAMILY"))
    [ -z "$stray" ] || fail companion-needed "$f" "needs $(line "$stray") outside the shipped set and the libc family"
  done
  ok companion-needed "shipped set and libc family"
}

fatbin_modules() {
  local lib=$1 work=$2 size offset=0 n=0 header fat
  : >"$work/modules"
  objcopy -O binary --only-section=.nv_fatbin "$lib" "$work/nv_fatbin" 2>/dev/null || return 0
  size=$(stat -c %s "$work/nv_fatbin")
  while [ "$offset" -lt "$size" ]; do
    if [ "$(od -An -t x4 -j "$offset" -N 4 "$work/nv_fatbin" | tr -d ' ')" != ba55ed50 ]; then
      offset=$((offset + 8))
      continue
    fi
    header=""
    fat=""
    if [ $((offset + 16)) -le "$size" ]; then
      header=$(od -An -t u2 -j $((offset + 6)) -N 2 "$work/nv_fatbin" | tr -d ' ')
      fat=$(od -An -t u8 -j $((offset + 8)) -N 8 "$work/nv_fatbin" | tr -d ' ')
    fi
    if [ -z "$fat" ] || [ "${#fat}" -gt 18 ] || [ "$header" -lt 16 ] ||
      [ $((offset + header + fat)) -gt "$size" ]; then
      fail architectures "$lib" "fatbin header at $offset: header ${header:-none}, size ${fat:-none}"
      return 0
    fi
    n=$((n + 1))
    tail -c +$((offset + 1)) "$work/nv_fatbin" | head -c $((header + fat)) >"$work/module-$n.fatbin"
    printf '%s\n' "$work/module-$n.fatbin" >>"$work/modules"
    offset=$((offset + header + fat))
  done
}

gate_architectures() {
  local lib="$dir/libraftrkt.so" a want_elf="" want_ptx="" work="$scratch/architectures" modules module n=0 wrappers embedded elf ptx
  for a in ${RELEASE_CUDA_ARCHITECTURES//;/ }; do
    case $a in
      *-real) want_elf="$want_elf sm_${a%-real}" ;;
      *-virtual) want_ptx="$want_ptx sm_${a%-virtual}" ;;
      *)
        want_elf="$want_elf sm_$a"
        want_ptx="$want_ptx sm_$a"
        ;;
    esac
  done
  want_elf=$(words "$want_elf")
  want_ptx=$(words "$want_ptx")
  mkdir -p "$work"
  fatbin_modules "$lib" "$work"
  [ "$gate_failed" -eq 0 ] || return 0
  mapfile -t modules <"$work/modules"
  for module in "${modules[@]}"; do
    n=$((n + 1))
    embedded=$(cuobjdump -elf -ptx "$module" 2>&1 |
      awk '/^Fatbin (elf|ptx) code:$/ { kind = $2 } /^arch = / && kind { print kind, $3; kind = "" }' || true)
    elf=$(sed -n 's/^elf //p' <<<"$embedded" | sort -u)
    ptx=$(sed -n 's/^ptx //p' <<<"$embedded" | sort -u)
    [ "$elf" = "$want_elf" ] && [ "$ptx" = "$want_ptx" ] ||
      fail architectures "$lib" "fatbin module $n has elf [$(line "$elf")] ptx [$(line "$ptx")], want elf [$(line "$want_elf")] ptx [$(line "$want_ptx")]"
  done
  objcopy -O binary --only-section=.nvFatBinSegment "$lib" "$work/segment" 2>/dev/null || : >"$work/segment"
  wrappers=$(stat -c %s "$work/segment")
  if [ "$n" -eq 0 ]; then
    fail architectures "$lib" "no .nv_fatbin module"
  elif [ $((wrappers % 24)) -ne 0 ] || [ $((wrappers / 24)) -ne "$n" ]; then
    fail architectures "$lib" "$n fatbin module(s) in .nv_fatbin, $wrappers bytes of .nvFatBinSegment hold $((wrappers / 24))"
  fi
  ok architectures "$n fatbin module(s), each elf $(line "$want_elf") ptx $(line "$want_ptx")"
}

gate_abi() {
  local lib="$dir/libraftrkt.so" want work found=""
  want=$(sed -n 's/^(define abi-version \([0-9]*\))$/\1/p' "$racket_abi_source")
  if [ -z "$want" ]; then
    fail abi "$racket_abi_source" "no (define abi-version N)"
    return
  fi
  work="$scratch/abi"
  mkdir -p "$work"
  if ! "${CC:-cc}" -o "$work/abi-probe" "$here/abi-probe.c" -ldl; then
    fail abi "$here/abi-probe.c" "the probe does not compile"
  elif ! found=$("$work/abi-probe" "$lib" 2>&1); then
    fail abi "$lib" "does not load: $found"
  elif [ "$found" != "$want" ]; then
    fail abi "$lib" "rr_abi $found, raft wants $want"
  fi
  ok abi "rr_abi $found = raft $want"
}

gate_checksums() {
  local sums="$dir/SHA256SUMS" listed want
  if [ ! -f "$sums" ]; then
    fail checksums "$sums" "missing"
    return
  fi
  listed=$(awk '{ print $2 }' "$sums" | sort -u)
  want=$(words "$RELEASE_SHIPPED $RELEASE_LICENSES manifest.json")
  if [ "$listed" != "$want" ]; then
    fail checksums "$sums" "lists [$(line "$listed")], want [$(line "$want")]"
  elif ! (cd "$dir" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1); then
    fail checksums "$sums" "$(cd "$dir" && sha256sum -c --quiet SHA256SUMS 2>&1 | tr '\n' ' ' | sed 's/ $//')"
  fi
  ok checksums "$(wc -l <"$sums") files"
}

for gate in $gates; do
  if ! [[ " $gate_names " == *" $gate "* ]]; then
    echo "gates.sh: no gate $gate (gates: $gate_names)" >&2
    exit 2
  fi
  gate_failed=0
  "gate_${gate//-/_}"
done
exit "$failed"
