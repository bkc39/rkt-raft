#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

: "${RAFT_SHIM_TESTS:?run inside nix develop}"
: "${RAFT_SHIM_SANITIZED_TESTS:?run inside nix develop}"

log=$(mktemp)
racket_log=$(mktemp)
trap 'rm -f "$log" "$racket_log"' EXIT

echo "== shim gtests"
"$RAFT_SHIM_TESTS/raftrkt_tests" --gtest_brief=1 | tee -a "$log"
"$RAFT_SHIM_TESTS/raftrkt_error_tests" --gtest_brief=1 | tee -a "$log"

echo "== shim gtests under ASAN and UBSAN"
for t in raftrkt_tests raftrkt_error_tests; do
  ASAN_OPTIONS=$RAFT_ASAN_OPTIONS UBSAN_OPTIONS=$RAFT_UBSAN_OPTIONS \
    "$RAFT_SHIM_SANITIZED_TESTS/$t" --gtest_brief=1 | tee -a "$log"
done

echo "== shim gtests under compute-sanitizer memcheck (death tests ran above)"
deliberate='Buffers.AnImpossibleAllocationIsOutOfMemory:Release.AnUnreachableDeviceLeaksAndIsCounted'
memcheck=(compute-sanitizer --tool memcheck --leak-check full --error-exitcode 1)
"${memcheck[@]}" --report-api-errors explicit \
  "$RAFT_SHIM_TESTS/raftrkt_tests" --gtest_brief=1 --gtest_filter="-$deliberate:*DeathTest.*" | tee -a "$log"
"${memcheck[@]}" --report-api-errors no \
  "$RAFT_SHIM_TESTS/raftrkt_tests" --gtest_brief=1 --gtest_filter="$deliberate" | tee -a "$log"
"${memcheck[@]}" --report-api-errors explicit \
  "$RAFT_SHIM_TESTS/raftrkt_error_tests" --gtest_brief=1 | tee -a "$log"

echo "== LD_BIND_NOW load of the staged shim"
case ":$LD_LIBRARY_PATH:" in
  *:/usr/local/cuda*)
    echo "host CUDA is still on LD_LIBRARY_PATH" >&2
    exit 1
    ;;
esac
LD_BIND_NOW=1 racket -l racket/base -l ffi/unsafe \
  -e '(void (ffi-lib (simplify-path (build-path "raft" "native-libs" "libraftrkt"))))' \
  -e '(displayln "libraftrkt: every symbol bound")'

echo "== Racket tests"
raco make -v raft/main.rkt scripts/check-bindings.rkt
raco test raft >"$racket_log" 2>&1 || {
  cat "$racket_log"
  exit 1
}
grep -E "^SKIP|tests? passed|failure" "$racket_log"
cat "$racket_log" >>"$log"

echo "== binding census"
racket scripts/check-bindings.rkt

unexpected=$(grep "^SKIP" "$log" | grep -v "^SKIP: a GPU is present" |
  grep -v "^SKIP: no memory-pool support" || true)
if [ -n "$unexpected" ]; then
  echo "== cases that should have run here were skipped:" >&2
  echo "$unexpected" >&2
  exit 1
fi
echo "== SKIP lines: $(grep -c "^SKIP" "$log" || true), all of them cases that need no GPU"
