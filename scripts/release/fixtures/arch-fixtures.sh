#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release/pins.sh
. "$here/../pins.sh"

out=${1:?usage: arch-fixtures.sh OUT}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

gencode() {
  local a
  for a in ${1//;/ }; do
    case $a in
      *-real) printf -- '-gencode=arch=compute_%s,code=sm_%s\n' "${a%-real}" "${a%-real}" ;;
      *) printf -- '-gencode=arch=compute_%s,code=[sm_%s,compute_%s]\n' "$a" "$a" "$a" ;;
    esac
  done
}
module() {
  local source=$1 architectures=$2
  mapfile -t flags < <(gencode "$architectures")
  nvcc -Xcompiler -fPIC "${flags[@]}" -c "$here/$source.cu" -o "$work/$source.o"
}

module full-module "$RELEASE_CUDA_ARCHITECTURES"
module short-module 86-real
nvcc -shared -cudart none "$work/full-module.o" -o "$out/full.so"
nvcc -shared -cudart none "$work/full-module.o" "$work/short-module.o" -o "$out/short.so"
