#!/usr/bin/env bash
# Spike #32: build the spike shim and canary outside nix, inside `nix develop`,
# from the checkout root; stages libraftrkt and prints the canary path to export:
#   export RAFT_KMEANS_CANARY=$(bench/executor-spike/build-local.sh /tmp/xspike)
set -euo pipefail
out=${1:-/tmp/xspike}
cmake -S shim -B "$out/shim-build" -G Ninja -DBUILD_TESTING=OFF \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$out/shim-install" >&2
cmake --build "$out/shim-build" -j4 --target raftrkt >&2
cmake --install "$out/shim-build" >&2
cp -f "$out/shim-build/libraftrkt.so" raft/native-libs/.libraftrkt.so.tmp
chmod 0555 raft/native-libs/.libraftrkt.so.tmp
mv -f raft/native-libs/.libraftrkt.so.tmp raft/native-libs/libraftrkt.so
cmake -S downstream/kmeans-canary -B "$out/canary-build" -G Ninja -DBUILD_TESTING=OFF \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$out/shim-install;${CMAKE_PREFIX_PATH:-}" >&2
cmake --build "$out/canary-build" -j4 >&2
echo "$out/canary-build/libkmeans_canary.so"
