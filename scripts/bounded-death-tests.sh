#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

files=$(find shim/tests downstream -name '*.cpp' -path '*tests*' | sort)

hits=$(
  for f in $files; do
    awk '
      FNR == 1 { pass++ }
      pass == 1 && match($0, /^(\[\[noreturn\]\] )?(static )?void [A-Za-z_0-9]+\(/) {
        name = $0
        sub(/^(\[\[noreturn\]\] )?(static )?void /, "", name)
        sub(/\(.*/, "", name)
        pending = name
      }
      pass == 1 && opened != "" { if ($0 ~ /^[ \t]*alarm\(/) armed[opened] = 1; opened = "" }
      pass == 1 && pending != "" && $0 ~ /\{[ \t]*$/ { opened = pending; pending = "" }
      pass == 2 && waiting { check(FILENAME, start, $0); waiting = 0; next }
      pass == 2 && match($0, /(EXPECT|ASSERT)_(EXIT|DEATH)(_IF_SUPPORTED)?\(/) {
        rest = substr($0, RSTART + RLENGTH)
        if (rest ~ /^[ \t]*$/) { waiting = 1; start = FNR } else check(FILENAME, FNR, rest)
      }
      function check(file, line, text,   body) {
        body = text
        sub(/^[ \t]*/, "", body)
        match(body, /^[A-Za-z_0-9:]+/)
        body = substr(body, RSTART, RLENGTH)
        if (body != "std::_Exit" && !(body in armed)) print file ":" line ": " body
      }
    ' "$f" "$f"
  done
)

if [ -n "$hits" ]; then
  while IFS=: read -r file line body; do
    message="death-test body${body} does not arm alarm() first: bound the child as exit_test.cpp does"
    echo "$file:$line: $message"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "::error file=$file,line=$line::$message"
    fi
  done <<<"$hits"
  exit 1
fi
echo "bounded-death-tests: every death-test body arms alarm() first or exits at once"
