#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

allowed=raft/private/resource.rkt
non_moving=raft/private/foreign/host.rkt
pattern='\((malloc|free)([[:space:]]|\)|$)'

hits=$(grep -rnE --include='*.rkt' --include='*.scrbl' "$pattern" downstream lint raft scripts |
  grep -v -e "^$allowed:" -e "^$non_moving:" || true)

if [ -n "$hits" ]; then
  while IFS=: read -r file line _; do
    message="raw malloc/free outside $allowed: use a with-* form from it"
    echo "$file:$line: $message"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "::error file=$file,line=$line::$message"
    fi
  done <<<"$hits"
  exit 1
fi
echo "no-raw-malloc: none outside $allowed and $non_moving"
