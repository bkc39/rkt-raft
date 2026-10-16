#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release/pins.sh
. "$here/pins.sh"

if [ $# -ne 4 ]; then
  echo "usage: check-pins.sh 'LIBRAFT-URL SHA256' 'LIBRMM-URL SHA256' 'RAPIDS-LOGGER-URL SHA256' LIBCUBLAS-VERSION" >&2
  exit 2
fi

status=0
pinned() {
  local name=$1 release=$2 flake=$3
  [ "$release" != "$flake" ] || return 0
  local file=scripts/release/pins.sh message="pins $name as $release; the flake has $flake"
  echo "$file: $message"
  [ -z "${GITHUB_ACTIONS:-}" ] || echo "::error file=$file::$message"
  status=1
}

pinned libraft "$RELEASE_WHEEL_LIBRAFT $RELEASE_WHEEL_LIBRAFT_SHA256" "$1"
pinned librmm "$RELEASE_WHEEL_LIBRMM $RELEASE_WHEEL_LIBRMM_SHA256" "$2"
pinned rapids_logger "$RELEASE_WHEEL_RAPIDS_LOGGER $RELEASE_WHEEL_RAPIDS_LOGGER_SHA256" "$3"
pinned "the cuBLAS wheel version" "$(release_wheel_version "$RELEASE_WHEEL_CUBLAS")" "$4"
[ "$status" -ne 0 ] || echo "check-pins: the release wheels match nix/rapids.nix and cudaPackages.libcublas"
exit "$status"
