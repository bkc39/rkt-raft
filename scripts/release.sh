#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/release/pins.sh
. "$root/scripts/release/pins.sh"

usage() {
  echo "usage: scripts/release.sh build|load-check ARTIFACT | package|catalog-test ARTIFACT DIST | install-test pkg-build|gpu DIST" >&2
  exit 2
}
step=${1:-}
case $step in
  build | load-check) [ $# -eq 2 ] || usage ;;
  package | catalog-test) [ $# -eq 3 ] || usage ;;
  install-test)
    [ $# -eq 3 ] || usage
    case $2 in pkg-build | gpu) ;; *) usage ;; esac
    ;;
  *) usage ;;
esac
out=""
dist=""
case $step in
  install-test) dist=$(cd "$3" && pwd) ;;
  *)
    mkdir -p "$2"
    out=$(cd "$2" && pwd)
    if [ $# -eq 3 ]; then
      mkdir -p "$3"
      dist=$(cd "$3" && pwd)
    fi
    ;;
esac
cache=${RELEASE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/rkt-raft-release}
mkdir -p "$cache"
commit=$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)
dirty=false
[ -z "$(git -C "$root" status --porcelain 2>/dev/null)" ] || dirty=true

run() {
  docker run --rm --init --name "rr-release-$$-$1" \
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

tracked_copy() {
  git -C "$root" ls-files -z -- "$1" | tar -C "$root" --null -T - -cf - | tar -C "$2" -xf -
}

catalog_test() {
  local raft
  raft=$(mktemp -d)
  release_on_exit --remove "$raft"
  tracked_copy raft "$raft"
  run catalog -v "$out:/artifact:ro" -v "$dist:/dist:ro" -v "$raft/raft:/raft:ro" -e CATALOG_TEST_OMIT_NATIVE \
    "$RELEASE_LOAD_IMAGE" bash /src/scripts/release/catalog-test.sh /dist /raft /artifact
}

pkg_build_env=(-e PLT_PKG_BUILD_SERVICE=1 -e "PLT_INFO_ALLOW_VARS=;PLT_PKG_BUILD_SERVICE" -e CI=true)

gpu_flags() {
  local -n flags=$1
  local dev lib real
  for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
    flags+=(--device "$dev")
  done
  for lib in libcuda.so.1 libnvidia-ptxjitcompiler.so.1 libnvidia-nvvm.so.4; do
    real=$(/sbin/ldconfig -p | grep -F "$lib (libc6,x86-64)" | grep -oE '/[^ ]+$' | head -n1)
    [ -n "$real" ] || {
      echo "install-test: the host has no $lib" >&2
      exit 1
    }
    real=$(readlink -f "$real")
    flags+=(-v "$real:/host-nvidia/${real##*/}:ro")
  done
}

install_test() {
  local mode=$1 scratch
  scratch=$(mktemp -d)
  release_on_exit --remove "$scratch"
  mkdir -p "$scratch/work"
  tracked_copy raft "$scratch"
  local mounts=(-v "$dist:/dist:ro" -v "$scratch/raft:/raft:ro" -v "$scratch/work:/work")
  local script=(bash /src/scripts/release/install-test.sh)
  case $mode in
    pkg-build)
      run pkg-build-install "${mounts[@]}" "${pkg_build_env[@]}" \
        "$RELEASE_LOAD_IMAGE" "${script[@]}" pkg-build-install /dist /raft /work
      run pkg-build-test --network none -e HOME=/work \
        "${mounts[@]}" "${pkg_build_env[@]}" \
        "$RELEASE_LOAD_IMAGE" "${script[@]}" pkg-build-test /dist /raft /work
      ;;
    gpu)
      local gpu=()
      gpu_flags gpu
      run gpu-install "${mounts[@]}" "${gpu[@]}" \
        "$RELEASE_LOAD_IMAGE" "${script[@]}" gpu /dist /raft /work
      ;;
  esac
}

case $step in
  install-test) install_test "$2" ;;
  build) build ;;
  load-check) load_check ;;
  package) package ;;
  catalog-test) catalog_test ;;
esac
