#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

base_ref=${1:-origin/master}
rc=0
out=$(resyntax analyze --local-git-repository . "$base_ref" --analyzer-timeout 30000 2>&1) || rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then
  echo "resyntax exited $rc without completing the analysis" >&2
  exit 1
fi
if grep -qE "resyntax: .*\.rkt:[0-9]+:[0-9]+ \[" <<<"$out"; then
  echo "resyntax found refactoring suggestions; run: resyntax fix --local-git-repository . $base_ref" >&2
  exit 1
fi
echo "resyntax: no suggestions against $base_ref"
