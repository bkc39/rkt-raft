#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release/pins.sh
. "$here/pins.sh"
racket_abi_source="$here/../../raft/private/foreign/library.rkt"

if [ $# -lt 1 ]; then
  echo "usage: gates.sh DIR [GATE...]" >&2
  exit 2
fi
dir=$1
shift
all_gates="files runpath nix-store glibc glibcxx needed companion-needed architectures abi checksums"
gates=${*:-$all_gates}

failed=0
# shellcheck disable=SC2016
origin='$ORIGIN'
ok() { printf 'ok   %s: %s\n' "$1" "$2"; }
fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  failed=1
}

present() {
  local f
  for f in $RELEASE_SHIPPED; do
    [ -f "$dir/$f" ] && printf '%s\n' "$dir/$f"
  done
}
dynamic() { readelf -d "$1" | sed -n "s/.*($2).*\[\(.*\)\]\$/\1/p"; }
words() { tr ' ' '\n' <<<"$1" | sed '/^$/d' | sort -u; }
required_versions() {
  objdump -p "$1" | awk -v p="$2_" '
    /^Version References:/ { r = 1; next }
    r && /^[^ ]/ { r = 0 }
    r && index($NF, p) == 1 && $NF ~ /[0-9]$/ { print substr($NF, length(p) + 1) }'
}
version_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$2" ]; }

gate_files() {
  local f missing=""
  for f in $RELEASE_SHIPPED; do
    [ -f "$dir/$f" ] || missing="$missing $f"
  done
  if [ -n "$missing" ]; then fail files "missing$missing"; else ok files "$RELEASE_SHIPPED"; fi
}

gate_runpath() {
  local f bad=""
  for f in $(present); do
    [ "$(dynamic "$f" RUNPATH)" = "$origin" ] && [ -z "$(dynamic "$f" RPATH)" ] ||
      bad="$bad ${f##*/}=[$(dynamic "$f" RUNPATH)$(dynamic "$f" RPATH)]"
  done
  if [ -n "$bad" ]; then fail runpath "not \$ORIGIN only:$bad"; else ok runpath "$origin"; fi
}

gate_nix_store() {
  local f bad=""
  for f in $(present); do
    if grep -aq /nix/store "$f"; then bad="$bad ${f##*/}"; fi
  done
  if [ -n "$bad" ]; then fail nix-store "/nix/store in$bad"; else ok nix-store "absent"; fi
}

gate_version_floor() {
  local gate=$1 prefix=$2 limit=$3 f highest
  highest=$(for f in $(present); do required_versions "$f" "$prefix"; done | sort -V | tail -n1)
  if [ -z "$highest" ]; then
    fail "$gate" "no ${prefix}_ version references"
  elif version_le "$highest" "$limit"; then
    ok "$gate" "${prefix}_$highest <= $limit"
  else
    fail "$gate" "${prefix}_$highest > $limit"
  fi
}

gate_needed() {
  local lib="$dir/libraftrkt.so" actual extra
  if [ ! -f "$lib" ]; then
    fail needed "no libraftrkt.so"
    return
  fi
  actual=$(dynamic "$lib" NEEDED | sort -u)
  extra=$(comm -23 <(printf '%s\n' "$actual") <(words "$RELEASE_LIBC_FAMILY"))
  if [ "$extra" = "$(words "$RELEASE_SHIM_NEEDED")" ]; then
    ok needed "$(tr '\n' ' ' <<<"$actual")"
  else
    fail needed "outside the libc family: $(tr '\n' ' ' <<<"$extra")(want $RELEASE_SHIM_NEEDED)"
  fi
}

gate_companion_needed() {
  local f name stray bad=""
  for name in $RELEASE_SHIPPED; do
    f="$dir/$name"
    [ "$name" != libraftrkt.so ] && [ -f "$f" ] || continue
    stray=$(comm -23 <(dynamic "$f" NEEDED | sort -u) <(words "$RELEASE_SHIPPED $RELEASE_LIBC_FAMILY"))
    [ -z "$stray" ] || bad="$bad $name needs $(tr '\n' ' ' <<<"$stray")"
  done
  if [ -n "$bad" ]; then fail companion-needed "$bad"; else ok companion-needed "shipped set and libc family"; fi
}

gate_architectures() {
  local lib="$dir/libraftrkt.so" a want_elf="" want_ptx="" embedded elf ptx
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
  embedded=$(cuobjdump -elf -ptx "$lib" 2>&1 |
    awk '/^Fatbin (elf|ptx) code:$/ { kind = $2 } /^arch = / && kind { print kind, $3; kind = "" }' || true)
  elf=$(sed -n 's/^elf //p' <<<"$embedded" | sort -u)
  ptx=$(sed -n 's/^ptx //p' <<<"$embedded" | sort -u)
  if [ "$elf" = "$(words "$want_elf")" ] && [ "$ptx" = "$(words "$want_ptx")" ]; then
    ok architectures "elf $(tr '\n' ' ' <<<"$elf")ptx $(tr '\n' ' ' <<<"$ptx")"
  else
    fail architectures "elf [$(tr '\n' ' ' <<<"$elf")] ptx [$(tr '\n' ' ' <<<"$ptx")], want elf [${want_elf# }] ptx [${want_ptx# }]"
  fi
}

gate_abi() {
  local want work found
  want=$(sed -n 's/^(define abi-version \([0-9]*\))$/\1/p' "$racket_abi_source")
  work=$(mktemp -d)
  if ! "${CC:-cc}" -o "$work/abi-probe" "$here/abi-probe.c" -ldl; then
    fail abi "the probe does not compile"
  elif ! found=$("$work/abi-probe" "$dir/libraftrkt.so" 2>&1); then
    fail abi "does not load: $found"
  elif [ -n "$want" ] && [ "$found" = "$want" ]; then
    ok abi "rr_abi $found = raft $want"
  else
    fail abi "rr_abi $found, raft wants ${want:-nothing (no abi-version in $racket_abi_source)}"
  fi
  rm -rf "$work"
}

gate_checksums() {
  local sums="$dir/SHA256SUMS" listed
  if [ ! -f "$sums" ]; then
    fail checksums "no SHA256SUMS"
    return
  fi
  listed=$(awk '{ print $2 }' "$sums" | sort -u)
  if [ "$listed" != "$(words "$RELEASE_SHIPPED manifest.json")" ]; then
    fail checksums "SHA256SUMS lists $(tr '\n' ' ' <<<"$listed")"
  elif (cd "$dir" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1); then
    ok checksums "$(wc -l <"$sums") files"
  else
    fail checksums "$(cd "$dir" && sha256sum -c --quiet SHA256SUMS 2>&1 | tr '\n' ' ')"
  fi
}

for gate in $gates; do
  case $gate in
    files) gate_files ;;
    runpath) gate_runpath ;;
    nix-store) gate_nix_store ;;
    glibc) gate_version_floor glibc GLIBC "$RELEASE_GLIBC_MAX" ;;
    glibcxx) gate_version_floor glibcxx GLIBCXX "$RELEASE_GLIBCXX_MAX" ;;
    needed) gate_needed ;;
    companion-needed) gate_companion_needed ;;
    architectures) gate_architectures ;;
    abi) gate_abi ;;
    checksums) gate_checksums ;;
    *)
      echo "gates.sh: no gate $gate (gates: $all_gates)" >&2
      exit 2
      ;;
  esac
done
exit "$failed"
