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

dnf install -y -q "gcc-toolset-$RELEASE_GCC_TOOLSET-gcc-c++" time >/dev/null
# shellcheck disable=SC1090
. "/opt/rh/gcc-toolset-$RELEASE_GCC_TOOLSET/enable"

mkdir -p "$work/tools" "$work/wheels" "$out"
tar -xzf "$(release_fetch "$RELEASE_CMAKE" "$RELEASE_CMAKE_SHA256" "$cache")" -C "$work/tools" --strip-components 1
PATH="$work/tools/bin:$PATH"
(cd "$work/tools/bin" && cmake -E tar xf "$(release_fetch "$RELEASE_NINJA" "$RELEASE_NINJA_SHA256" "$cache")")

wheel_files=()
for pin in LIBRAFT LIBRMM RAPIDS_LOGGER; do
  url_var=RELEASE_WHEEL_$pin
  sha_var=${url_var}_SHA256
  wheel=$(release_fetch "${!url_var}" "${!sha_var}" "$cache")
  wheel_files+=("$wheel")
  (cd "$work/wheels" && cmake -E tar xf "$wheel")
done

cmake -S "$src/shim" -B "$work/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTING=OFF \
  -DRAFTRKT_RELEASE=ON \
  "-DCMAKE_CUDA_ARCHITECTURES=$RELEASE_CUDA_ARCHITECTURES" \
  "-DCMAKE_CUDA_HOST_COMPILER=$(command -v g++)" \
  "-DCMAKE_PREFIX_PATH=$work/wheels/libraft;$work/wheels/librmm;$work/wheels/rapids_logger"

start=$(date +%s)
/usr/bin/time -f '%M' -o "$work/max-rss-kb" cmake --build "$work/build" --target raftrkt -j "$jobs"
seconds=$(($(date +%s) - start))
cgroup_peak=$(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo unknown)
printf 'build: %s s, largest process %s kB, container peak %s bytes\n' \
  "$seconds" "$(cat "$work/max-rss-kb")" "$cgroup_peak"

cp "$work/build/libraftrkt.so" "$out/"
cp "$work/wheels/librmm/lib64/librmm.so" "$out/"
cp "$work/wheels/rapids_logger/lib64/librapids_logger.so" "$out/"

sha() { sha256sum "$1" | cut -d' ' -f1; }
nvcc_version=$(nvcc --version | sed -n 's/.*, V\([0-9.]*\)$/\1/p')
{
  printf '{\n'
  printf '  "shim_commit": "%s",\n' "${RELEASE_COMMIT:-unknown}"
  printf '  "shim_tree_dirty": %s,\n' "${RELEASE_DIRTY:-true}"
  printf '  "abi_version": %s,\n' "$(sed -n 's/^#define RR_ABI_VERSION \([0-9]*\)$/\1/p' "$src/shim/include/raftrkt/abi.h")"
  printf '  "image": "%s",\n' "$RELEASE_BUILD_IMAGE"
  printf '  "cuda_toolkit": "%s",\n' "${CUDA_VERSION:-unknown}"
  printf '  "nvcc": "%s",\n' "$nvcc_version"
  printf '  "host_compiler": "%s",\n' "$(g++ -dumpfullversion)"
  printf '  "cuda_architectures": "%s",\n' "$RELEASE_CUDA_ARCHITECTURES"
  printf '  "glibc_max": "%s",\n' "$RELEASE_GLIBC_MAX"
  printf '  "glibcxx_max": "%s",\n' "$RELEASE_GLIBCXX_MAX"
  printf '  "wheels": {\n'
  for wheel in "${wheel_files[@]}"; do
    printf '    "%s": "%s",\n' "${wheel##*/}" "$(sha "$wheel")"
  done
  printf '    "%s": "%s"\n' "${RELEASE_WHEEL_CUBLAS##*/}" "$RELEASE_WHEEL_CUBLAS_SHA256"
  printf '  },\n'
  printf '  "files": {\n'
  read -ra shipped <<<"$RELEASE_SHIPPED"
  for i in "${!shipped[@]}"; do
    printf '    "%s": "%s"%s\n' "${shipped[i]}" "$(sha "$out/${shipped[i]}")" \
      "$([ "$i" -lt $((${#shipped[@]} - 1)) ] && echo ,)"
  done
  printf '  }\n}\n'
} >"$out/manifest.json"
(cd "$out" && sha256sum "${shipped[@]}" manifest.json >SHA256SUMS)

status=0
LD_LIBRARY_PATH=/usr/local/cuda/lib64 "$here/gates.sh" "$out" || status=$?
[ -z "${HOST_UID:-}" ] || chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$out" "$cache"
exit "$status"
