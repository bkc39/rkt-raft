#!/usr/bin/env bash
# Spike #32 measurement d. Run inside the dev shell from the checkout root:
#   bench/executor-spike/exit-runs.sh <runs> <what> <code> [bound]   (env passes through)
runs=$1
shift
for i in $(seq "$runs"); do
  log=$(RAFTRKT_EXIT_TRACE=1 racket bench/executor-spike/exit.rkt "$@" 2>&1)
  rc=$?
  bad=$(grep -cE 'terminate called|Aborted|abort|core dumped' <<<"$log")
  printf 'run %s: rc %s, abort lines %s | %s\n' "$i" "$rc" "$bad" "$(grep -oE '\[[^]]*\]' <<<"$log" | tr '\n' ' ')"
done
