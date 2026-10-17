#!/usr/bin/env bash
set -euo pipefail

exec racket "$(dirname "${BASH_SOURCE[0]}")/chapter.rkt" "${1:?usage: render-docs.sh <dest-dir>}"
