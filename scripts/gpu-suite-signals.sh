#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

work=$(mktemp -d)
marker="gpu-suite-signals-$$-$RANDOM"

survivors() {
  local e
  { grep -lsz "^RAFT_SIGNAL_PROBE=$marker\$" /proc/[0-9]*/environ || true; } | while read -r e; do
    e=${e#/proc/}
    echo "${e%/environ}"
  done
}

reap() {
  local p
  for p in $(survivors); do
    kill -KILL "$p" 2>/dev/null || true
  done
}

trap 'reap; rm -rf "$work"' EXIT

stubs="$work/stubs"
mkdir -p "$stubs"
for t in raftrkt_tests raftrkt_error_tests kmeans_canary_tests; do
  printf '#!%s\ntouch %q\nexec sleep 60\n' "$BASH" "$work/started" >"$stubs/$t"
  chmod +x "$stubs/$t"
done

failed=0
for sig in INT TERM HUP; do
  rm -f "$work/started"
  RAFT_SIGNAL_PROBE=$marker RAFT_SHIM_TESTS=$stubs RAFT_SHIM_SANITIZED_TESTS=$stubs \
    RAFT_KMEANS_CANARY_TESTS=$stubs \
    env --default-signal=INT "$BASH" scripts/gpu-suite.sh >"$work/out-$sig" 2>&1 &
  outer=$!
  for _ in $(seq 50); do
    [ ! -e "$work/started" ] || break
    sleep 0.1
  done
  if [ ! -e "$work/started" ]; then
    echo "gpu-suite-signals: the stub suite never started" >&2
    cat "$work/out-$sig" >&2
    exit 1
  fi
  if [ -z "$(survivors | grep -vx "$outer" || true)" ]; then
    echo "gpu-suite-signals: no suite process carries the probe marker" >&2
    exit 1
  fi
  kill -"$sig" "$outer"
  for _ in $(seq 20); do
    [ -n "$(survivors)" ] || break
    sleep 0.1
  done 2>/dev/null
  left=$(survivors | tr '\n' ' ')
  reap
  rc=0
  wait "$outer" 2>/dev/null || rc=$?
  if [ -n "$left" ]; then
    echo "gpu-suite-signals: SIG$sig to gpu-suite.sh left pids $left running after 2 s" >&2
    failed=1
  fi
  if [ "$rc" -ne $((128 + $(kill -l "$sig"))) ]; then
    echo "gpu-suite-signals: SIG$sig to gpu-suite.sh exited $rc, not by SIG$sig" >&2
    cat "$work/out-$sig" >&2
    failed=1
  fi
done

[ "$failed" = 0 ] || exit 1
echo "gpu-suite-signals: SIGINT, SIGTERM and SIGHUP stop the whole suite and re-raise"
