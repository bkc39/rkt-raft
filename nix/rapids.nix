{
  lib,
  stdenv,
  fetchurl,
  unzip,
  autoPatchelfHook,
  symlinkJoin,
  cudaPackages,
}:

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
    libcuml = {
      url = "${pypi}/24/11/ac6e36e5b54f748c4dbc499013a03d87fb62a217d0d40657bfed944cda6a/libcuml_cu13-${version}-py3-none-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";
      sha256 = "ac125ac6a279c59e932faac87b88eda06561d5ea68de0ba2893492e7f3599652";
    };
    # PyPI has no libcuvs-cu13 26.8.0; 26.8.1 is the 26.08 release libcuml
    # requires (libcuvs-cu13==26.8.*).
    libcuvs = {
      version = "26.8.1";
      url = "${pypi}/d3/91/0cae0a916aeb92b5b2cce067fc385c87ead7bbf0830ca85fc51b4e10b140/libcuvs_cu13-26.8.1-py3-none-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";
      sha256 = "023a28bebad0ed80cb753c5099687eb6d14fbad9e7e4b49bdaca805014667d0e";
    };
    libnvforest = {
      url = "${pypi}/19/b2/9d95a272433b3ef7b70778739917ec7e90538a86b65f013fa8f04156ca96/libnvforest_cu13-${version}-py3-none-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";
      sha256 = "646b61a8ee8299ae88e22e3729a03ef6e3ed09cf51d5099e50d36c5e14d96734";
    };
    nccl = {
      version = "2.32.3";
      url = "${pypi}/5b/29/6b277e63c92d91f9cb4d1a3a554e148983de39d54baa652bb52c798af78e/nvidia_nccl_cu13-2.32.3-py3-none-manylinux_2_27_x86_64.whl";
      sha256 = "1459723080ac889d73a26edfa3e04383a7928ab31ac8f0ec43b3ea9548b04ff3";
    };
  };

  cudaLibs =
    with cudaPackages;
    map lib.getLib [
      libcublas
      libcurand
      libcusolver
      libcusparse
      libnvjitlink
    ];

  # The prefix keeps the wheel's lib64/ because the CMake configs name it;
  # lib/ is a link so nix's own tooling finds the libraries too.
  wheelPrefix =
    {
      pname,
      wheel,
      root,
      dirs ? [
        "include"
        "lib64"
      ],
      deps ? [ ],
    }:
    stdenv.mkDerivation {
      inherit pname;
      version = wheel.version or version;
      src = fetchurl { inherit (wheel) url sha256; };
      nativeBuildInputs = [
        unzip
        autoPatchelfHook
      ];
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
        mkdir -p $out/lib64
        for d in ${lib.concatStringsSep " " dirs}; do
          cp -r wheel/${root}/$d $out/
        done
        for vendored in wheel/*.libs; do
          [ -d "$vendored" ] && cp "$vendored"/* $out/lib64/
        done
        ln -s lib64 $out/lib
        runHook postInstall
      '';
      dontStrip = true;
      dontMoveLib64 = true;
      passthru = { inherit wheel; };
    };

  prefix =
    {
      module,
      dirs ? [
        "include"
        "lib64"
      ],
      deps ? [ ],
    }:
    wheelPrefix {
      pname = "${module}-cu13";
      wheel = wheels.${module};
      root = module;
      inherit dirs deps;
    };

  rapids-logger = prefix { module = "rapids_logger"; };
  librmm = prefix {
    module = "librmm";
    deps = [ rapids-logger ];
  };
  libraft = prefix {
    module = "libraft";
    deps = [
      librmm
      rapids-logger
    ]
    ++ cudaLibs;
  };

  nccl = stdenv.mkDerivation {
    pname = "nccl-cu13";
    inherit (wheels.nccl) version;
    src = fetchurl { inherit (wheels.nccl) url sha256; };
    nativeBuildInputs = [
      unzip
      autoPatchelfHook
    ];
    buildInputs = [ stdenv.cc.cc.lib ];
    unpackPhase = ''
      runHook preUnpack
      unzip -q "$src" -d wheel
      runHook postUnpack
    '';
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib64
      cp wheel/nvidia/nccl/lib/libnccl.so.2 $out/lib64/
      ln -s lib64 $out/lib
      runHook postInstall
    '';
    dontStrip = true;
    dontMoveLib64 = true;
  };

  # cuVS is internal to libcuml (plan §12), and libnvforest ships its own
  # CCCL headers: both join the prefix for run time only.
  libcuvs = prefix {
    module = "libcuvs";
    dirs = [ "lib64" ];
    deps = [
      librmm
      rapids-logger
      nccl
      (lib.getLib cudaPackages.cuda_nvrtc)
    ]
    ++ cudaLibs;
  };
  libnvforest = prefix {
    module = "libnvforest";
    dirs = [ "lib64" ];
    deps = [
      librmm
      rapids-logger
    ];
  };
  libcuml = prefix {
    module = "libcuml";
    deps = [
      libcuvs
      libnvforest
      libraft
      librmm
      rapids-logger
      (lib.getLib cudaPackages.libcufft)
    ]
    ++ cudaLibs;
  };

  core = symlinkJoin {
    name = "rapids-cu13-${version}";
    paths = [
      libraft
      librmm
      rapids-logger
    ];
    postBuild = ''
      rm $out/lib
      ln -s lib64 $out/lib
    '';
  };
in
symlinkJoin {
  name = "rapids-cuml-cu13-${version}";
  paths = [
    libraft
    librmm
    rapids-logger
    libcuml
    libcuvs
    libnvforest
    nccl
  ];
  postBuild = ''
    rm $out/lib
    ln -s lib64 $out/lib
  '';
  passthru = {
    inherit
      version
      core
      libraft
      librmm
      rapids-logger
      libcuml
      libcuvs
      libnvforest
      nccl
      cudaLibs
      wheelPrefix
      ;
    raftVersion = "26.08.00";
    cumlVersion = "26.08.00";
  };
}
