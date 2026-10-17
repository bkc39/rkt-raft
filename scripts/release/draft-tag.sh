#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release/pins.sh
. "$here/pins.sh"

if [ $# -ne 1 ]; then
  echo "usage: draft-tag.sh TAG" >&2
  exit 2
fi
tag=$1
info_version() {
  local found
  found=$(sed -n 's/^(define version "\(.*\)")$/\1/p' "$here/../../$1/info.rkt")
  if [ -z "$found" ]; then
    echo "draft-tag: $1/info.rkt has no (define version \"...\")" >&2
    exit 1
  fi
  echo "$found"
}
native=$(info_version "$RELEASE_NATIVE_PACKAGE")
raft=$(info_version raft)
case $tag in
  "v$native")
    echo "tag=$tag"
    echo "draft-tag: $tag drafts the $RELEASE_NATIVE_PACKAGE $native release" >&2
    ;;
  "" | "v$raft")
    echo "tag="
    echo "draft-tag: ${tag:-no tag} is not v$native, so no $RELEASE_NATIVE_PACKAGE release is drafted" >&2
    ;;
  *)
    echo "draft-tag: $tag names neither $RELEASE_NATIVE_PACKAGE (v$native) nor raft (v$raft)" >&2
    exit 1
    ;;
esac
