# NVIDIA's RAPIDS C++ wheels for one release, unpacked into plain prefixes
# and patched against nixpkgs' CUDA libraries. nixpkgs packages no RAPIDS.
{ lib, stdenv, fetchurl, unzip, autoPatchelfHook, symlinkJoin, cudaPackages }:

let
  version = "26.8.0";
  pypi = "https://files.pythonhosted.org/packages";

  wheels = {
    libraft = {
      url = "${pypi}/15/d1/73884e51dd205cfaf97989df2d50cfda08df0ccca2f18403b36f44325ae2/libraft_cu13-${version}-py3-none-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";
      sha256 = "71fdb1987d61f0ecf78771ca6cf363a5b587cc3a7e45808017d3a034f8506b1e";
    };
    librmm = {
      url = "${pypi}/a0/b6/694ca2f1144ad0de4a66595cbf92c3af677941257c56b8e7c1aa4e5b4b94/librmm_cu13-${version}-py3-none-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl";
      sha256 = "b99105380532b1176c29ddaf115a4ed38a1c8004e2a12372469cb6dac9b47a24";
    };
    rapids_logger = {
      version = "0.2.3";
      url = "${pypi}/69/b6/139d9df6d0f7bd289a9a6286cecfff999e41c36865515d7fdb56b7b32a14/rapids_logger-0.2.3-py3-none-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";
      sha256 = "7fe67ef4049c5d8ba6154746325dcf7cc0f327f0efa8f2611fc8f64e67510f60";
    };
  };

  cudaLibs = with cudaPackages; map lib.getLib [
    libcublas libcurand libcusolver libcusparse libnvjitlink
  ];

  # The prefix keeps the wheel's lib64/ because the CMake configs name it;
  # lib/ is a link so nix's own tooling finds the libraries too.
  prefix = { module, deps ? [ ] }:
    let w = wheels.${module}; in
    stdenv.mkDerivation {
      pname = "${module}-cu13";
      version = w.version or version;
      src = fetchurl { inherit (w) url sha256; };
      nativeBuildInputs = [ unzip autoPatchelfHook ];
      buildInputs = [ stdenv.cc.cc.lib ] ++ deps;
      unpackPhase = ''
        runHook preUnpack
        unzip -q "$src" -d wheel
        runHook postUnpack
      '';
      dontConfigure = true;
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp -r wheel/${module}/include wheel/${module}/lib64 $out/
        for vendored in wheel/*.libs; do
          [ -d "$vendored" ] && cp "$vendored"/* $out/lib64/
        done
        ln -s lib64 $out/lib
        runHook postInstall
      '';
      dontStrip = true;
      dontMoveLib64 = true;
      passthru.wheel = w;
    };

  rapids-logger = prefix { module = "rapids_logger"; };
  librmm = prefix { module = "librmm"; deps = [ rapids-logger ]; };
  libraft = prefix { module = "libraft"; deps = [ librmm rapids-logger ] ++ cudaLibs; };
in
symlinkJoin {
  name = "rapids-cu13-${version}";
  paths = [ libraft librmm rapids-logger ];
  postBuild = ''
    rm $out/lib
    ln -s lib64 $out/lib
  '';
  passthru = {
    inherit version libraft librmm rapids-logger cudaLibs;
    raftVersion = "26.08.00";
  };
}
