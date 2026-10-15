#!/usr/bin/env bash
set -euo pipefail

self=$(realpath "${BASH_SOURCE[0]}")
cd "$(dirname "$self")/.."

header=shim/tests/death.hpp
raw='\b(EXPECT|ASSERT)_(EXIT|DEATH|DEBUG_DEATH)(_IF_SUPPORTED)?\b'

lint() {
  for f in "$@"; do
    if [ "$f" != "$header" ]; then
      grep -nHE "$raw" "$f" || [ "$?" -eq 1 ]
    fi
  done
}

if [ "$#" -gt 0 ]; then
  roots=("$@")
else
  roots=(shim/tests downstream)
  fixture=scripts/fixtures/death-tests.cpp
  want=$(awk '
    match($0, /^TEST\([A-Za-z]+,/) { suite = substr($0, 6, RLENGTH - 6) }
    suite == "Raw" && /^[ \t]*(EXPECT|ASSERT)_[A-Z_]+\(/ { print FNR }
  ' "$fixture")
  got=$(lint "$fixture" | cut -d: -f2)
  if [ -z "$want" ] || [ "$got" != "$want" ]; then
    echo "bounded-death-tests: the self-test on $fixture flagged lines ${got//$'\n'/ }" \
      "instead of ${want//$'\n'/ }" >&2
    exit 1
  fi
  if ! grep -qE "$raw" "$header" || [ -n "$(lint "$header")" ]; then
    echo "bounded-death-tests: the self-test did not exempt $header" >&2
    exit 1
  fi
  if "$BASH" "$self" scripts/fixtures/no-such-root >/dev/null 2>&1; then
    echo "bounded-death-tests: the self-test passed with a missing root" >&2
    exit 1
  fi
fi

listing=$(find "${roots[@]}" -type f \( -name '*.c' -o -name '*.cpp' -o -name '*.cu' -o -name '*.cuh' -o -name '*.h' -o -name '*.hpp' \) | sort)
mapfile -t files <<<"$listing"
hits=$(lint "${files[@]}")

if [ -n "$hits" ]; then
  while IFS=: read -r file line _; do
    message="raw gtest death test: use RR_EXPECT_EXIT from $header, which arms alarm() in the child"
    echo "$file:$line: $message"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "::error file=$file,line=$line::$message"
    fi
  done <<<"$hits"
  exit 1
fi
echo "bounded-death-tests: every death test goes through RR_EXPECT_EXIT"
