#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

usage() {
  cat <<'USAGE'
usage: scripts/record-docs.sh [--check]

Re-records raft/scribblings/logs/ by rendering the manual once with
RAFT_DOCS=record (every example evaluated live, its output written to its
chapter's log), then renders it again with RAFT_DOCS=replay and fails unless
the two manuals are byte for byte the same. Run it inside `nix develop` on
the GPU host, then commit the logs.

--check also fails when the new logs differ from the committed ones: an
example whose output changed while its expression did not.
USAGE
}
case ${1:-} in
  "" | --check) ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
: "${RAFT_KMEANS_CANARY:?run inside nix develop, which builds the k-means canary}"

dest=$(mktemp -d)
trap 'rm -rf "$dest"' EXIT
RAFT_DOCS=record scripts/render-docs.sh "$dest/live"
RAFT_DOCS=replay scripts/render-docs.sh "$dest/replay"
if ! diff -r "$dest/live" "$dest/replay"; then
  echo "record-docs: the replayed manual differs from the live one (above)" >&2
  exit 1
fi
echo "record-docs: the replayed manual is the live one, byte for byte"
logs=raft/scribblings/logs
git status --short -- "$logs"
if [ "${1:-}" = --check ] && [ -n "$(git status --porcelain -- "$logs")" ]; then
  git --no-pager diff -- "$logs" | head -n 60 || true
  echo "record-docs: the manual's output differs from $logs; re-record with scripts/record-docs.sh and commit it" >&2
  exit 1
fi
echo "record-docs: $(find "$logs" -name '*.rktd' | wc -l) logs in $logs"
