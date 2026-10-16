#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release/pins.sh
. "$here/pins.sh"

if [ $# -ne 6 ]; then
  echo "usage: check-pins.sh 'LIBRAFT-URL SHA256' 'LIBRMM-URL SHA256' 'RAPIDS-LOGGER-URL SHA256' LIBCUBLAS-VERSION RACKET-FLOOR CUDA-WHEELS-RKTD" >&2
  exit 2
fi

cuda_wheels=$6
status=0
pinned() {
  local name=$1 release=$2 flake=$3
  [ "$release" != "$flake" ] || return 0
  echo "scripts/release/pins.sh: pins $name as $release; the flake has $flake"
  status=1
}

pinned libraft "$RELEASE_WHEEL_LIBRAFT $RELEASE_WHEEL_LIBRAFT_SHA256" "$1"
pinned librmm "$RELEASE_WHEEL_LIBRMM $RELEASE_WHEEL_LIBRMM_SHA256" "$2"
pinned rapids_logger "$RELEASE_WHEEL_RAPIDS_LOGGER $RELEASE_WHEEL_RAPIDS_LOGGER_SHA256" "$3"
pinned "the cuBLAS wheel version" "$(release_wheel_version "$RELEASE_WHEEL_CUBLAS")" "$4"
pinned "the catalog test's Racket" "$(release_racket_version "$RELEASE_RACKET")" "$5"
raft_cublas=$(racket -e '
(define wheel (cdr (assoc "nvidia-cublas" (call-with-input-file (vector-ref (current-command-line-arguments) 0) read))))
(printf "~a ~a ~a" (cadr (assq (quote version) wheel)) (cadr (assq (quote url) wheel)) (cadr (assq (quote sha256) wheel)))' "$cuda_wheels")
raft_pinned() {
  [ "$1" = "$2" ] && return 0
  echo "$cuda_wheels: pins the cuBLAS wheel as $2; scripts/release/pins.sh has $1"
  status=1
}
raft_pinned "$(release_wheel_version "$RELEASE_WHEEL_CUBLAS") $RELEASE_WHEEL_CUBLAS $RELEASE_WHEEL_CUBLAS_SHA256" "$raft_cublas"
[ "$status" -ne 0 ] || echo "check-pins: the release pins match nix/rapids.nix, cudaPackages.libcublas, the Racket floor and raft's cuBLAS pin"
exit "$status"
