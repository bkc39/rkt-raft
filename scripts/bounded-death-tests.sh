#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

lint() {
  for f in "$@"; do
    awk '
      FNR == 1 { pass++ }
      /^[^ \t}#\/]/ { scope = FNR }
      pass == 1 && match($0, /^(\[\[noreturn\]\] )?(static )?void [A-Za-z_0-9]+\(/) {
        name = $0
        sub(/^(\[\[noreturn\]\] )?(static )?void /, "", name)
        sub(/\(.*/, "", name)
        pending = name
      }
      pass == 1 && match($0, /[A-Za-z_0-9]+[ \t]*=[ \t]*\[/) {
        name = substr($0, RSTART, RLENGTH)
        sub(/[ \t]*=.*/, "", name)
        local[scope, name] = 1
      }
      pass == 1 && opened != "" {
        if ($0 ~ /^[ \t]*alarm\(/ && $0 !~ /^[ \t]*alarm\([ \t]*0*[ \t]*\)/) armed[opened] = 1
        opened = ""
      }
      pass == 1 && pending != "" && $0 ~ /\{[ \t]*$/ { opened = pending; pending = "" }
      pass == 2 && waiting { check(FILENAME, start, $0); waiting = 0; next }
      pass == 2 && match($0, /(EXPECT|ASSERT)_(EXIT|DEATH|DEBUG_DEATH)(_IF_SUPPORTED)?\(/) {
        rest = substr($0, RSTART + RLENGTH)
        if (rest ~ /^[ \t]*$/) { waiting = 1; start = FNR } else check(FILENAME, FNR, rest)
      }
      function check(file, line, text,   body) {
        body = text
        sub(/^[ \t]*/, "", body)
        match(body, /^[A-Za-z_0-9:]+/)
        body = substr(body, RSTART, RLENGTH)
        if (body != "std::_Exit" && (!(body in armed) || (scope, body) in local)) print file ":" line ": " body
      }
    ' "$f" "$f"
  done
}

fixture=scripts/fixtures/death-test-bodies.cpp
want=$(awk '
  match($0, /^TEST\([A-Za-z]+,/) { suite = substr($0, 6, RLENGTH - 6) }
  suite == "Unbounded" && /(EXPECT|ASSERT)_[A-Z_]+\(/ { print FNR }
' "$fixture")
got=$(lint "$fixture" | cut -d: -f2)
if [ "$got" != "$want" ]; then
  echo "bounded-death-tests: the self-test on $fixture flagged lines ${got//$'\n'/ }" \
    "instead of ${want//$'\n'/ }" >&2
  exit 1
fi

files=$(find shim/tests downstream -name '*.cpp' -path '*tests*' | sort)
# shellcheck disable=SC2086
hits=$(lint $files)

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
