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
native=$(sed -n 's/^(define version "\(.*\)")$/\1/p' "$here/../../$RELEASE_NATIVE_PACKAGE/info.rkt")
if [ -z "$native" ]; then
  echo "draft-tag: $RELEASE_NATIVE_PACKAGE/info.rkt has no (define version \"...\")" >&2
  exit 1
fi
if [ "$tag" = "v$native" ]; then
  echo "tag=$tag"
  echo "draft-tag: $tag drafts the $RELEASE_NATIVE_PACKAGE $native release" >&2
else
  echo "tag="
  echo "draft-tag: ${tag:-no tag} is not v$native, so no $RELEASE_NATIVE_PACKAGE release is drafted" >&2
fi
