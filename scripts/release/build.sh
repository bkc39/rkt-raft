#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release/pins.sh
. "$here/pins.sh"

src=$(cd "$here/../.." && pwd)
out=${1:?usage: build.sh OUT}
cache=${RELEASE_CACHE:-/cache}
work=${RELEASE_WORK:-/work}
jobs=${RELEASE_JOBS:-4}

hand_back() {
  [ -z "${HOST_UID:-}" ] || chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$out" "$cache"
}
trap hand_back EXIT

read -ra dnf_packages <<<"$RELEASE_DNF_PACKAGES"
dnf install -y -q "${dnf_packages[@]}" >/dev/null
# shellcheck disable=SC1090
. "/opt/rh/gcc-toolset-$RELEASE_GCC_TOOLSET/enable"

mkdir -p "$work/tools" "$work/wheels" "$out"
cmake_archive=$(release_fetch "$RELEASE_CMAKE" "$RELEASE_CMAKE_SHA256" "$cache")
tar -xzf "$cmake_archive" -C "$work/tools" --strip-components 1
PATH="$work/tools/bin:$PATH"
ninja_archive=$(release_fetch "$RELEASE_NINJA" "$RELEASE_NINJA_SHA256" "$cache")
(cd "$work/tools/bin" && cmake -E tar xf "$ninja_archive")

wheels='[]'
for pin in LIBRAFT LIBRMM RAPIDS_LOGGER CUBLAS; do
  url_var=RELEASE_WHEEL_$pin
  sha_var=${url_var}_SHA256
  wheels=$(jq -c --arg url "${!url_var}" --arg version "$(release_wheel_version "${!url_var}")" \
    --arg sha256 "${!sha_var}" '. + [{name: ($url | split("/") | last), $url, $version, $sha256}]' <<<"$wheels")
  [ "$pin" != CUBLAS ] || continue
  wheel=$(release_fetch "${!url_var}" "${!sha_var}" "$cache")
  (cd "$work/wheels" && cmake -E tar xf "$wheel")
done

cmake -S "$src/shim" -B "$work/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTING=OFF \
  -DRAFTRKT_RELEASE=ON \
  "-DCMAKE_CUDA_ARCHITECTURES=$RELEASE_CUDA_ARCHITECTURES" \
  "-DCMAKE_CUDA_HOST_COMPILER=$(command -v g++)" \
  "-DCMAKE_PREFIX_PATH=$work/wheels/libraft;$work/wheels/librmm;$work/wheels/rapids_logger"
cmake --build "$work/build" --target raftrkt -j "$jobs"

cp "$work/build/libraftrkt.so" "$out/"
cp "$work/wheels/librmm/lib64/librmm.so" "$out/"
cp "$work/wheels/rapids_logger/lib64/librapids_logger.so" "$out/"
cp "$work/wheels"/librmm_*.dist-info/licenses/LICENSE "$out/LICENSE.librmm"
cp "$work/wheels"/rapids_logger-*.dist-info/licenses/LICENSE "$out/LICENSE.rapids_logger"

read -ra shipped <<<"$RELEASE_SHIPPED $RELEASE_LICENSES"
files=$(cd "$out" && sha256sum "${shipped[@]}" | jq -R -n '[inputs | split("  ") | {(.[1]): .[0]}] | add')
jq -n \
  --arg shim_commit "${RELEASE_COMMIT:-unknown}" \
  --argjson shim_tree_dirty "${RELEASE_DIRTY:-true}" \
  --argjson abi_version "$(sed -n 's/^#define RR_ABI_VERSION \([0-9]*\)$/\1/p' "$src/shim/include/raftrkt/abi.h")" \
  --arg image "$RELEASE_BUILD_IMAGE" \
  --arg dnf_packages "$RELEASE_DNF_PACKAGES" \
  --arg cuda_toolkit "${CUDA_VERSION:-unknown}" \
  --arg nvcc "$(nvcc --version | sed -n 's/.*, V\([0-9.]*\)$/\1/p')" \
  --arg host_compiler "$(g++ -dumpfullversion)" \
  --arg cuda_architectures "$RELEASE_CUDA_ARCHITECTURES" \
  --arg glibc_max "$RELEASE_GLIBC_MAX" \
  --arg glibcxx_max "$RELEASE_GLIBCXX_MAX" \
  --argjson wheels "$wheels" \
  --argjson files "$files" \
  '{$shim_commit, $shim_tree_dirty, $abi_version, $image,
    dnf_packages: ($dnf_packages | split(" ")), $cuda_toolkit, $nvcc, $host_compiler,
    $cuda_architectures, $glibc_max, $glibcxx_max, $wheels, $files}' >"$out/manifest.json"
(cd "$out" && sha256sum "${shipped[@]}" manifest.json >SHA256SUMS)

LD_LIBRARY_PATH=/usr/local/cuda/lib64 "$here/gates.sh" "$out"
