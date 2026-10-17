#!/usr/bin/env bash
#
# Re-records raft/scribblings/logs/, the evaluations the manual replays where
# no GPU is (RAFT_DOCS unset), by rendering it live once. Run inside
# `nix develop` on the GPU host, with the k-means canary built. Fails when the
# manual replayed from the new logs differs from the live render; with --check,
# also when the logs differ from the committed ones.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

case ${1:-} in
  "" | --check) ;;
  *)
    echo "usage: scripts/record-docs.sh [--check]" >&2
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
  git diff --stat -- "$logs"
  echo "record-docs: the manual's output differs from $logs; re-record with scripts/record-docs.sh and commit it" >&2
  exit 1
fi
echo "record-docs: $(find "$logs" -name '*.rktd' | wc -l) logs in $logs"
