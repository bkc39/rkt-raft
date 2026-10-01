#!/usr/bin/env bash
#
# Renders the manual to <dest>/raft/ and fails on any warning Scribble prints
# (raco scribble exits 0 on an undefined tag or a duplicate definition) and
# on any broken link left in the HTML. Run inside `nix develop`.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

dest=${1:?usage: scripts/render-docs.sh <dest-dir>}
mkdir -p "$dest"
log=$(mktemp)
trap 'rm -f "$log"' EXIT

raco make -v raft/scribblings/raft.scrbl
raco scribble --htmls ++xref-in setup/xref load-collections-xref \
  --dest "$dest" raft/scribblings/raft.scrbl 2>&1 | tee "$log"

status=0
if grep -iE "undefined tag|badlink|multiple times|warning" "$log"; then
  echo "render-docs: Scribble warned (above)" >&2
  status=1
fi
if grep -rl 'class="badlink"' "$dest/raft"; then
  echo "render-docs: broken links in the pages above" >&2
  status=1
fi
printf '<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="0; url=raft/index.html"><a href="raft/index.html">RAFT: CUDA primitives for Racket</a>\n' \
  > "$dest/index.html"
[ "$status" -eq 0 ] && echo "render-docs: $dest/raft/index.html"
exit "$status"
