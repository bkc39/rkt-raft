#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release/pins.sh
. "$here/pins.sh"

usage="usage: install-test.sh pkg-build-install|pkg-build-test|gpu DIST RAFT-SOURCE WORK"
phase=${1:?$usage}
dist=${2:?$usage}
raft_src=${3:?$usage}
work=${4:?$usage}
cache=${RELEASE_CACHE:-/cache}
case $phase in
  pkg-build-test) release_on_exit "$work" ;;
  *) release_on_exit "$work" "$cache" ;;
esac

export PLTUSERHOME="$work/user"
export PATH="$work/racket/bin:$PATH"
catalog="$work/catalog"
declare -a catalogs draw_libs
release_words catalogs "$RELEASE_RACKET_CATALOGS"
release_words draw_libs "cairo pango libjpeg-turbo libpng glib2 fontconfig dejavu-sans-fonts"

say() { echo "install test ($phase): $*"; }

prepare() {
  dnf -y -q install "${draw_libs[@]}" >/dev/null
  release_use_racket "$cache" "$work/racket"
  mkdir -p "$catalog/pkg" "$work/files/raft"
  cp -R "$raft_src/." "$work/files/raft/"
  raco pkg create --format zip --dest "$work/files" "$work/files/raft"
  racket "$here/catalog.rkt" entry "$work/files/raft" "$work/files/raft.zip" "$work/files/raft.zip" \
    >"$catalog/pkg/raft"
}

serve_native() {
  local zip="$dist/$RELEASE_NATIVE_PACKAGE.zip"
  mkdir -p "$work/files/native"
  unzip -q "$zip" -d "$work/files/native/$RELEASE_NATIVE_PACKAGE"
  racket "$here/catalog.rkt" entry "$work/files/native/$RELEASE_NATIVE_PACKAGE" "$zip" "$zip" \
    >"$catalog/pkg/$RELEASE_NATIVE_PACKAGE"
}

installed_cleanly() {
  local log=$1 status=$2
  grep -E "raco setup: (error|  error)|setup reported errors" "$log" && return 1
  [ "$status" -eq 0 ] || return 1
  find "$PLTUSERHOME" -path '*/raft/doc/raft/index.html' | grep -q . || {
    say "no rendered manual under $PLTUSERHOME"
    return 1
  }
}

install_raft() {
  local log=$1 status=0
  shift
  say "raco pkg install $*, with docs"
  raco pkg install --batch "$@" >"$log" 2>&1 || status=$?
  grep -E "^raft: |RAFT_DOCS|raft-x86_64-linux" "$log" || true
  say "raco pkg install exited $status"
  installed_cleanly "$log" "$status" || {
    tail -n 40 "$log"
    exit 1
  }
}

case $phase in
  pkg-build-install)
    prepare
    raco pkg config --set --scope installation catalogs "file://$catalog" "${catalogs[@]}"
    mapfile -t deps < <(racket "$here/catalog.rkt" deps-except "$raft_src" "$RELEASE_NATIVE_PACKAGE")
    say "raft's other dependencies: ${deps[*]}"
    raco pkg install --batch --auto --skip-installed --no-docs --scope installation "${deps[@]}" >"$work/deps.log" 2>&1 || {
      tail -n 40 "$work/deps.log"
      exit 1
    }
    install_raft "$work/install.log" --deps force raft
    if racket -l racket/base -e "(exit (if (collection-file-path \"main.rkt\" \"$RELEASE_NATIVE_PACKAGE\" #:fail (lambda (_) #f)) 1 0))"; then
      say "no $RELEASE_NATIVE_PACKAGE installed, as on pkg-build"
    else
      say "$RELEASE_NATIVE_PACKAGE is installed, so this is not pkg-build"
      exit 1
    fi
    say "passed"
    ;;
  pkg-build-test)
    if curl -fsS --max-time 5 -o /dev/null https://pkgs.racket-lang.org; then
      say "the network is reachable; run this phase with --network none"
      exit 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
      say "running as uid $(id -u); pkg-build runs the tests as root"
      exit 1
    fi
    say "raco test --drdr --package raft, offline, as root"
    status=0
    raco test --drdr --package raft >"$work/test.log" 2>&1 || status=$?
    grep -E "tests? passed|test failures?|non-zero exit|timeout" "$work/test.log" | sort | uniq -c | sort -rn | head -n 20
    grep -cE '^raco test: ' "$work/test.log" | sed 's/^/install test (pkg-build-test): modules run: /'
    say "raco test exited $status"
    [ "$status" -eq 0 ] || {
      grep -B4 -A20 -E "^(FAILURE|ERROR)$|non-zero exit" "$work/test.log" | head -n 120
      exit 1
    }
    say "passed"
    ;;
  gpu)
    echo /host-nvidia >/etc/ld.so.conf.d/host-nvidia.conf
    ldconfig
    prepare
    serve_native
    raco pkg config --set --scope installation catalogs "file://$catalog" "${catalogs[@]}"
    wheel=$(release_fetch "$RELEASE_WHEEL_CUBLAS" "$RELEASE_WHEEL_CUBLAS_SHA256" "$cache")
    export RAFT_CUDA_WHEEL_URL_BASE="file://${wheel%/*}"
    unset LD_LIBRARY_PATH RAFT_KMEANS_CANARY RAFT_DOCS
    install_raft "$work/install.log" --auto raft
    racket -l racket/base -l raft \
      -e '(printf "install test (gpu): raft ~a, native ~a, devices ~a\n" (raft-version) (dynamic-require (quote raft-x86_64-linux) (quote native-libs-dir)) (device-count))'
    say "passed"
    ;;
  *)
    echo "$usage" >&2
    exit 2
    ;;
esac
