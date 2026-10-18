#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
problem() {
  echo "record-docs-test: $*" >&2
  failures=1
}

repo=$work/repo
mkdir -p "$repo/scripts" "$repo/raft/scribblings"
cp "$here/record-docs.sh" "$here/fixtures/record-docs/chapter.rkt" "$repo/scripts/"
{
  echo "#!$BASH"
  tail -n +2 "$here/fixtures/record-docs/render-docs.sh"
} >"$repo/scripts/render-docs.sh"
chmod +x "$repo/scripts/render-docs.sh"
cp "$here/../raft/scribblings/logged-eval.rkt" "$repo/raft/scribblings/"
git -C "$repo" init -q
export RAFT_KMEANS_CANARY=unused
export GIT_AUTHOR_NAME=record-docs-test GIT_AUTHOR_EMAIL=record-docs-test@localhost
export GIT_COMMITTER_NAME=record-docs-test GIT_COMMITTER_EMAIL=record-docs-test@localhost

record() {
  local name=$1 message=$2 status=0
  shift 2
  SAMPLE_MESSAGE=$message bash "$repo/scripts/record-docs.sh" "$@" >"$work/$name.out" 2>&1 || status=$?
  echo "$status" >"$work/$name.status"
}
want_status() {
  local name=$1 want=$2
  [ "$(cat "$work/$name.status")" = "$want" ] ||
    problem "$name: exited $(cat "$work/$name.status"), want $want: $(cat "$work/$name.out")"
}

record first "no such row"
want_status first 0
git -C "$repo" add raft/scribblings/logs
git -C "$repo" commit -qm logs
grep -qF '"lookup: no such row"' "$repo/raft/scribblings/logs/sample.rktd" ||
  problem "first: the log does not hold the eval:error message"

record unchanged "no such row" --check
want_status unchanged 0

record changed "no row by that name" --check
want_status changed 1
grep -qF "the manual's output differs from raft/scribblings/logs" "$work/changed.out" ||
  problem "changed: --check did not name the stale logs: $(cat "$work/changed.out")"

git -C "$repo" checkout -q -- raft/scribblings/logs
cp "$repo/raft/scribblings/logs/sample.rktd" "$work/sample.rktd"
SAMPLE_RAISE=1 record raised "no such row"
want_status raised 1
cmp -s "$work/sample.rktd" "$repo/raft/scribblings/logs/sample.rktd" ||
  problem "raised: a failed record rewrote the log"
leftover=$(find "$repo/raft/scribblings/logs" -name '*.recording')
[ -z "$leftover" ] || problem "raised: a failed record left $leftover"

exit "$failures"
