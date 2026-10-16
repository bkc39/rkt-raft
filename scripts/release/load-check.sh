#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release/pins.sh
. "$here/pins.sh"

artifact=${1:?usage: load-check.sh ARTIFACT}
cache=${RELEASE_CACHE:-/cache}
cublas=$(mktemp -d)

release_on_exit --remove "$cublas" "$cache"

echo "load check: $(ldd --version | head -n1), no GPU"
wheel=$(release_fetch "$RELEASE_WHEEL_CUBLAS" "$RELEASE_WHEEL_CUBLAS_SHA256" "$cache")
unzip -q -j "$wheel" nvidia/cu13/lib/libcublas.so.13 nvidia/cu13/lib/libcublasLt.so.13 -d "$cublas"
LD_LIBRARY_PATH=$cublas "$here/gates.sh" "$artifact" abi
