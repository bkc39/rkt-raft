# shellcheck shell=bash
# shellcheck disable=SC2034

RELEASE_BUILD_IMAGE="nvidia/cuda:13.2.1-devel-rockylinux8@sha256:826d035d433c935c86ecabd0b108fee87389e005b3fd8b4d1152f7bfcebe3a4a"
RELEASE_LOAD_IMAGE="quay.io/pypa/manylinux_2_28_x86_64@sha256:4131ddd7acb9c6c966af02fe7e71edc51e078c2d41f475966697676430bfa2ae"
RELEASE_GCC_TOOLSET=14

RELEASE_CUDA_ARCHITECTURES="75-real;80-real;86-real;90a-real;100f-real;120a-real;120"

RELEASE_GLIBC_MAX=2.28
RELEASE_GLIBCXX_MAX=3.4.25
RELEASE_SHIPPED="libraftrkt.so librmm.so librapids_logger.so"
RELEASE_SHIM_NEEDED="libcublas.so.13 libcublasLt.so.13 librapids_logger.so librmm.so"
RELEASE_LIBC_FAMILY="ld-linux-x86-64.so.2 libc.so.6 libdl.so.2 libgcc_s.so.1 libm.so.6 libpthread.so.0 librt.so.1 libstdc++.so.6"

RELEASE_PYPI="https://files.pythonhosted.org/packages"

RELEASE_WHEEL_LIBRAFT="$RELEASE_PYPI/15/d1/73884e51dd205cfaf97989df2d50cfda08df0ccca2f18403b36f44325ae2/libraft_cu13-26.8.0-py3-none-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl"
RELEASE_WHEEL_LIBRAFT_SHA256="71fdb1987d61f0ecf78771ca6cf363a5b587cc3a7e45808017d3a034f8506b1e"
RELEASE_WHEEL_LIBRMM="$RELEASE_PYPI/a0/b6/694ca2f1144ad0de4a66595cbf92c3af677941257c56b8e7c1aa4e5b4b94/librmm_cu13-26.8.0-py3-none-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl"
RELEASE_WHEEL_LIBRMM_SHA256="b99105380532b1176c29ddaf115a4ed38a1c8004e2a12372469cb6dac9b47a24"
RELEASE_WHEEL_RAPIDS_LOGGER="$RELEASE_PYPI/69/b6/139d9df6d0f7bd289a9a6286cecfff999e41c36865515d7fdb56b7b32a14/rapids_logger-0.2.3-py3-none-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl"
RELEASE_WHEEL_RAPIDS_LOGGER_SHA256="7fe67ef4049c5d8ba6154746325dcf7cc0f327f0efa8f2611fc8f64e67510f60"
RELEASE_WHEEL_CUBLAS="$RELEASE_PYPI/3d/ec/c9b2998aebe3149dee2769e501257e048c8701de51263925f4dff76ddedc/nvidia_cublas-13.4.0.1-py3-none-manylinux_2_27_x86_64.whl"
RELEASE_WHEEL_CUBLAS_SHA256="53bf22e2ccbf644db74b6cc21cea7f5efb1a52aa64515438b430abbd05af4106"

RELEASE_CMAKE="https://github.com/Kitware/CMake/releases/download/v4.1.2/cmake-4.1.2-linux-x86_64.tar.gz"
RELEASE_CMAKE_SHA256="773cc679c3a7395413bd096523f8e5d6c39f8718af4e12eb4e4195f72f35e4ab"
RELEASE_NINJA="https://github.com/ninja-build/ninja/releases/download/v1.13.1/ninja-linux.zip"
RELEASE_NINJA_SHA256="0830252db77884957a1a4b87b05a1e2d9b5f658b8367f82999a941884cbe0238"

release_fetch() {
  local url=$1 sha=$2 dir=$3
  local file="$dir/${url##*/}"
  mkdir -p "$dir"
  if ! { [ -f "$file" ] && echo "$sha  $file" | sha256sum -c --status; }; then
    curl -fsSL --retry 3 -o "$file.part" "$url"
    mv "$file.part" "$file"
    echo "$sha  $file" | sha256sum -c --quiet
  fi
  printf '%s\n' "$file"
}
