#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/roots.sh
. scripts/roots.sh

mapfile -t files < <(find .fmt.rkt bench "${racket_roots[@]}" -name '*.rkt' -not -path '*/compiled/*' | sort)
raco review "${files[@]}"
echo "review: ${#files[@]} files clean"
raco test lint
