#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
raco make raft/scribblings/chapter.rkt
exec racket raft/scribblings/chapter.rkt "${1:?usage: render-docs.sh <dest-dir>}"
