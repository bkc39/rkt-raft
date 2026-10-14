#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

cache_dir=/var/tmp/rkt-raft-resyntax-cache

pr_base() {
  git fetch -q origin || echo "resyntax: git fetch failed; using the local origin refs" >&2
  local branch
  branch=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null) || branch=master
  git merge-base HEAD "origin/${branch:-master}" 2>/dev/null || git merge-base HEAD origin/master
}

cache_key() {
  {
    echo "$1"
    git diff "$1" -- '*.rkt' '*.scrbl'
    raco pkg show --scope user --full-checksum resyntax
    cat scripts/resyntax.sh
  } | sha256sum | cut -d' ' -f1
}

key=""
if [ $# -gt 0 ]; then
  base_ref=$1
else
  base_ref=$(pr_base)
  key=$(cache_key "$base_ref")
  echo "resyntax: against $base_ref, the merge base with the PR's base branch"
fi

if [ -n "$key" ] && [ "${RESYNTAX_NO_CACHE:-0}" != 1 ] && [ -e "$cache_dir/$key" ]; then
  echo "resyntax: unchanged since a green run (key $key)"
  exit 0
fi

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
if [ -n "$key" ]; then
  mkdir -p "$cache_dir"
  touch "$cache_dir/$key"
fi
