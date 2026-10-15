#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

mapfile -t files < <(find .fmt.rkt bench lint raft scripts -name '*.rkt' -not -path '*/compiled/*' | sort)
raco review "${files[@]}"
echo "review: ${#files[@]} files clean"
