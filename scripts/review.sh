#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

mapfile -t files < <(find .fmt.rkt bench downstream lint raft raft-x86_64-linux scripts -name '*.rkt' -not -path '*/compiled/*' | sort)
raco review "${files[@]}"
echo "review: ${#files[@]} files clean"
raco test lint
