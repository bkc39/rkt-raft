# pylibraft and rmm are patched against the same RAPIDS prefix the shim links,
# so both sides of a parity test load one libraft.so and one librmm.so.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  zlib,
  rapids,
  cudaPackages,
}:

self: super:

let
  pypi = "https://files.pythonhosted.org/packages";

  cupyCudaLibs =
    with cudaPackages;
    map lib.getLib [
      cuda_nvrtc
      libcublas
      libcufft
      libcurand
      libcusolver
      libcusparse
    ];

  wheel =
    {
      pname,
      version,
      url,
      sha256,
      dependencies ? [ ],
      libs ? [ ],
      extra ? { },
    }:
    self.buildPythonPackage (
      {
        inherit pname version dependencies;
        format = "wheel";
        src = fetchurl { inherit url sha256; };
        nativeBuildInputs = [ autoPatchelfHook ];
        buildInputs = [ stdenv.cc.cc.lib ] ++ libs;
        dontStrip = true;
      }
      // extra
    );

  rapidsWheel =
    {
      libs ? [ ],
      ...
    }@args:
    wheel (
      args
      // {
        libs = [ rapids ] ++ rapids.cudaLibs ++ libs;
        extra = {
          # They also name the RAPIDS loader packages (libraft-cu13 and the
          # rest), whose libraries the native prefixes provide instead, and
          # cudf caps pandas, pyarrow and numba below the nixpkgs pin's.
          dontCheckRuntimeDeps = true;
        };
      }
    );

  # cuml imports cudf when it loads, so the twins carry cudf's native
  # libraries; no shim links them.
  libnvcomp = rapids.wheelPrefix {
    pname = "nvcomp-cu13";
    root = "nvidia/libnvcomp";
    dirs = [ "lib64" ];
    wheel = {
      version = "5.3.0.16";
      url = "${pypi}/8d/50/df4132c3e4171462130ddfc793e042fb8724d68249f14c16eff44236d5d2/nvidia_libnvcomp_cu13-5.3.0.16-py3-none-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";
      sha256 = "8bf2594c9a3d83bf485c95bffa8ac6406d98b5407ca9e8d9bef5e8fb5d6f5116";
    };
  };

  libkvikio = rapids.wheelPrefix {
    pname = "libkvikio-cu13";
    root = "libkvikio";
    dirs = [ "lib64" ];
    deps = [
      rapids
      zlib
    ];
    wheel = {
      url = "${pypi}/29/71/d724f4c4125feda81350550aeb401bf999f9bd29b7466f1ff241e8441520/libkvikio_cu13-26.8.0-py3-none-manylinux_2_28_x86_64.whl";
      sha256 = "6356b6c624086817e067eef25a961667951f85c594449aad7053aaa4be9dc3b9";
    };
  };

  libcudf = rapids.wheelPrefix {
    pname = "libcudf-cu13";
    root = "libcudf";
    dirs = [ "lib64" ];
    deps = [
      rapids
      libkvikio
      libnvcomp
      zlib
    ];
    wheel = {
      version = "26.8.1";
      url = "${pypi}/2e/1f/19ff9f3f6706ceb8d16af9ccfcad0850e41588283c08fe6e1a7ca0f13fae/libcudf_cu13-26.8.1-py3-none-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";
      sha256 = "6d15014328be85d648b748aee252b978e22092c6ade2bb50d400aa8e1be1ae1f";
    };
  };

  cudfLibs = [
    libcudf
    libkvikio
    libnvcomp
  ];
in
{
  cuda-pathfinder = wheel {
    pname = "cuda-pathfinder";
    version = "1.8.2";
    url = "${pypi}/98/59/239c7259e669c46ddbcac0aa60e3a0ef00bfeaaa687f905b24dd6a7a10fe/cuda_pathfinder-1.8.2-py3-none-any.whl";
    sha256 = "4e65059febdb4d19d5cbc4798677e19db2b582f2f702f457b609e571690d357e";
  };

  cuda-bindings = wheel {
    pname = "cuda-bindings";
    version = "13.4.3";
    url = "${pypi}/a3/49/7a3769c43e432b0434dd46424058b47af4347167f0dfca1ecb27e2de92a1/cuda_bindings-13.4.3-cp314-cp314-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl";
    sha256 = "bbacde6f75665b197016b986164cfdaa33b17515e5e635a63ddb75926aaa71c3";
    dependencies = [ self.cuda-pathfinder ];
  };

  rmm-cu13 = rapidsWheel {
    pname = "rmm-cu13";
    version = "26.8.0";
    url = "${pypi}/33/5a/8146d352b3232a637f2055b27462a7d08a7ed3698d2092bc7cd9f21982a0/rmm_cu13-26.8.0-cp311-abi3-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl";
    sha256 = "cf696080ee307d9067eb3e283f0bab84aef82302dcd844ad98229025ef0ff058";
    dependencies = [
      self.cuda-bindings
      self.numpy
    ];
  };

  pylibraft-cu13 = rapidsWheel {
    pname = "pylibraft-cu13";
    version = "26.8.0";
    url = "${pypi}/25/7e/997b324730fa3719e1d77ce4ab30ddba6b7330365ba3bd22f3a9c8a14eed/pylibraft_cu13-26.8.0-cp311-abi3-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl";
    sha256 = "025461bafc04c6f6cec061d1d1322d402dde568935289ae2ffd238fd0d4de134";
    dependencies = [
      self.cuda-bindings
      self.numpy
      self.rmm-cu13
    ];
  };

  cupy-cuda13x = wheel {
    pname = "cupy-cuda13x";
    version = "14.2.0";
    url = "${pypi}/c2/b8/4f4c4f34fc31ab8d136ed965a919505297974629d9852c50e15bfd616281/cupy_cuda13x-14.2.0-cp314-cp314-manylinux2014_x86_64.whl";
    sha256 = "ff0bdebd1b43c0c6db53095784c787c4e4eae671356cf521c4b7482ed78a1a7e";
    dependencies = [
      self.cuda-pathfinder
      self.numpy
    ];
    libs = cupyCudaLibs;
    extra = {
      # cuTENSOR and NCCL back optional CuPy modules the twins do not use.
      autoPatchelfIgnoreMissingDeps = [
        "libcutensor.so.2"
        "libcutensorMg.so.2"
        "libnccl.so.2"
      ];
    };
  };

  cuda-core = wheel {
    pname = "cuda-core";
    version = "1.2.1";
    url = "${pypi}/4b/68/7482871b9da7d2239f512192339fad405d83af8fb8915319b31afeb42071/cuda_core-1.2.1-cp314-cp314-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl";
    sha256 = "cfa6b43cd62560f707f11a63d88cefa8f8acf98ccb338a6a747b4a02ff6a0c66";
    dependencies = [
      self.cuda-bindings
      self.cuda-pathfinder
      self.numpy
    ];
  };

  numba-cuda = wheel {
    pname = "numba-cuda";
    version = "0.30.4";
    url = "${pypi}/df/73/8934508d27efd9a930489059b980bc1e75336574be31bffb284a9e782fa7/numba_cuda-0.30.4-cp314-cp314-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl";
    sha256 = "ec8e14ab7d4ecacaa1ff8d662efe5ab3c268e2f1cdad0330d28804b0d19a78c1";
    dependencies = [
      self.cuda-bindings
      self.cuda-core
      self.cuda-pathfinder
      self.numba
      self.packaging
    ];
    extra = {
      # numba-cuda 0.30.4 registers np.row_stack, which NumPy 2.5 (the pin's)
      # removed.
      postInstall = ''
        substituteInPlace $out/${self.python.sitePackages}/numba_cuda/numba/cuda/np/arrayobj.py \
          --replace-fail "    overload(np.row_stack)(impl_np_vstack)" \
                         "    if hasattr(np, 'row_stack'): overload(np.row_stack)(impl_np_vstack)"
      '';
    };
  };

  nvtx = wheel {
    pname = "nvtx";
    version = "0.2.16";
    url = "${pypi}/04/fb/8d570c9cd23eaacebd29064d4f883f3548db90594c21d0e7fc2ea4970112/nvtx-0.2.16-cp314-cp314-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl";
    sha256 = "f1ce0c2509a6136ceaaebf73bb4b4d20fb741a2852c5c63ae4b6c1e5a5bb8fac";
  };

  treelite = wheel {
    pname = "treelite";
    version = "4.7.2";
    url = "${pypi}/02/97/531e12ab4a78a4df24a1aae31bc2416318042f0dc6ba974d4cc6898ea9a0/treelite-4.7.2-py3-none-manylinux_2_28_x86_64.whl";
    sha256 = "b86f0613ab8164b401cf542550c12c0633f8fb0ac0373888f9a7a04a2d47f42a";
    dependencies = [
      self.numpy
      self.packaging
      self.scipy
    ];
  };

  pylibcudf-cu13 = rapidsWheel {
    pname = "pylibcudf-cu13";
    version = "26.8.1";
    url = "${pypi}/19/10/7968baec0b2d276e36d68ee8108473a94575bf41b1c0d3be598ae8aa6a42/pylibcudf_cu13-26.8.1-cp311-abi3-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl";
    sha256 = "0de721c79a4281db4a76bad05ded2962234f95cb31a9ee9ec4dbf59d03d1d062";
    libs = cudfLibs;
    dependencies = [
      self.cuda-bindings
      self.nvtx
      self.rmm-cu13
    ];
  };

  cudf-cu13 = rapidsWheel {
    pname = "cudf-cu13";
    version = "26.8.1";
    url = "${pypi}/72/5f/cd12e0d44c2284079c436808c357b8798940642b0ca87ee7333bbf3dfef5/cudf_cu13-26.8.1-cp311-abi3-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl";
    sha256 = "3d111060e5d9685491211c3fe637e77a0621d3820da3ee0d017f934def02e6c5";
    libs = cudfLibs;
    dependencies = [
      self.cachetools
      self.cuda-bindings
      self.cupy-cuda13x
      self.fsspec
      self.numba
      self.numba-cuda
      self.numpy
      self.nvtx
      self.packaging
      self.pandas
      self.pyarrow
      self.pylibcudf-cu13
      self.rich
      self.rmm-cu13
    ];
  };

  nvforest-cu13 = rapidsWheel {
    pname = "nvforest-cu13";
    version = "26.8.0";
    url = "${pypi}/a7/ea/32021f1bd3e6cad97c3be607d32d7796f303164a0fea323649913e1af423/nvforest_cu13-26.8.0-cp311-abi3-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl";
    sha256 = "067152f3dbec3ba62de21a49fe7c802fc4ae40ecec74bbb480f7125cdc61e9af";
    dependencies = [
      self.cuda-bindings
      self.cupy-cuda13x
      self.numpy
      self.pylibraft-cu13
      self.scikit-learn
      self.treelite
    ];
  };

  cuml-cu13 = rapidsWheel {
    pname = "cuml-cu13";
    version = "26.8.0";
    url = "${pypi}/d6/0b/391de929589fb60a71349ae7c05f32453fb3b7335886dc6f2268d5036914/cuml_cu13-26.8.0-cp311-abi3-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";
    sha256 = "176609835a0e06e9604227a597146e70f7f7caa11b736bdf7746725e4941680d";
    dependencies = [
      self.cudf-cu13
      self.cuda-bindings
      self.cupy-cuda13x
      self.joblib
      self.numba
      self.numba-cuda
      self.numpy
      self.nvforest-cu13
      self.packaging
      self.pylibraft-cu13
      self.rich
      self.rmm-cu13
      self.scikit-learn
      self.scipy
      self.treelite
    ];
  };
}
