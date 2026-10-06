#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

dirs=(downstream lint raft scripts)
before='(^|[^-[:alnum:]!?*<>=/+.$%&^~_])'
after='([^-[:alnum:]!?*<>=/+:.$%&^~_]|$)'

status=0
flag() {
  local form=$1 message=$2 hits
  hits=$(grep -rnE --include='*.rkt' --include='*.scrbl' \
    "$before$form$after" "${dirs[@]}" || true)
  [ -n "$hits" ] || return 0
  status=1
  while IFS=: read -r file line _; do
    echo "$file:$line: $message"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "::error file=$file,line=$line::$message"
    fi
  done <<<"$hits"
}

flag define-syntax-rule "use define-syntax-parse-rule (require syntax/parse/define)"
flag syntax-rules "use define-syntax-parse-rule or define-syntax-parser"

if [ "$status" -eq 0 ]; then
  echo "no-syntax-rule: none in ${dirs[*]}"
fi
exit "$status"
