#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release/pins.sh
. "$here/pins.sh"

if [ $# -ne 3 ]; then
  echo "usage: fetch-native.sh RAFT-INFO-RKT OWNER/REPO DEST-DIR" >&2
  exit 2
fi
info=$1
repository=$2
dest=$3
native=$(sed -n 's/^(define native-version "\(.*\)")$/\1/p' "$info")
if [ -z "$native" ]; then
  echo "fetch-native: $info has no (define native-version \"...\")" >&2
  exit 1
fi
mkdir -p "$dest"
zip=$dest/$RELEASE_NATIVE_PACKAGE.zip
url=https://github.com/$repository/releases/download/v$native/$RELEASE_NATIVE_PACKAGE.zip
trap '[ "${found:-}" = true ] || rm -f "$zip"' EXIT
code=$(curl -sSL --retry 3 -o "$zip" -w '%{http_code}' "$url")
case $code in
  200)
    found=true
    echo "found=true"
    ;;
  404)
    echo "SKIP: no v$native release yet, so the GPU install test cannot run" >&2
    ;;
  *)
    echo "fetch-native: $url answered HTTP $code" >&2
    exit 1
    ;;
esac
