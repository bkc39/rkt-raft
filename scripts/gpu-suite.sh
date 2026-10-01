#!/usr/bin/env bash
#
# The GPU suite, run inside `nix develop` on a host with an NVIDIA GPU: the
# shim's gtests, a load of the shim with every symbol bound, the Racket tests
# (twin parity included) and the binding census. Any SKIP line means a case
# did not run here.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

: "${RAFT_SHIM_TESTS:?run inside nix develop}"

echo "== shim gtests"
"$RAFT_SHIM_TESTS/raftrkt_tests" --gtest_brief=1
"$RAFT_SHIM_TESTS/raftrkt_error_tests" --gtest_brief=1

echo "== LD_BIND_NOW load of the staged shim"
case ":$LD_LIBRARY_PATH:" in
  *:/usr/local/cuda*) echo "host CUDA is still on LD_LIBRARY_PATH" >&2; exit 1 ;;
esac
LD_BIND_NOW=1 racket -l racket/base -l ffi/unsafe \
  -e '(void (ffi-lib (simplify-path (build-path "raft" "native-libs" "libraftrkt"))))' \
  -e '(displayln "libraftrkt: every symbol bound")'

echo "== Racket tests"
raco make -v raft/main.rkt scripts/check-bindings.rkt
log=$(mktemp)
trap 'rm -f "$log"' EXIT
raco test raft > "$log" 2>&1 || { cat "$log"; exit 1; }
grep -E "^SKIP|tests? passed|failure" "$log"
skips=$(grep -c "^SKIP" "$log" || true)

echo "== binding census"
racket scripts/check-bindings.rkt

echo "== SKIP lines in the Racket tests: $skips"
