# The parity twins' Python packages, as a python packageOverrides function.
# pylibraft and rmm are patched against the same RAPIDS prefix the shim links,
# so both sides of a parity test load one libraft.so and one librmm.so.
{ lib, stdenv, fetchurl, autoPatchelfHook, rapids, cudaPackages }:

self: super:

let
  pypi = "https://files.pythonhosted.org/packages";

  cupyCudaLibs = with cudaPackages; map lib.getLib [
    cuda_nvrtc libcublas libcufft libcurand libcusolver libcusparse
  ];

  wheel = { pname, version, url, sha256, dependencies ? [ ], libs ? [ ]
          , extra ? { } }:
    self.buildPythonPackage ({
      inherit pname version dependencies;
      format = "wheel";
      src = fetchurl { inherit url sha256; };
      nativeBuildInputs = [ autoPatchelfHook ];
      buildInputs = [ stdenv.cc.cc.lib ] ++ libs;
      dontStrip = true;
    } // extra);

  rapidsWheel = args: wheel (args // {
    libs = [ rapids ] ++ rapids.cudaLibs;
    extra = {
      # They also name the libraft-cu13 and librmm-cu13 loader packages,
      # whose libraries the RAPIDS prefix provides instead.
      dontCheckRuntimeDeps = true;
    };
  });
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
    inherit (rapids) version;
    url = "${pypi}/33/5a/8146d352b3232a637f2055b27462a7d08a7ed3698d2092bc7cd9f21982a0/rmm_cu13-${rapids.version}-cp311-abi3-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl";
    sha256 = "cf696080ee307d9067eb3e283f0bab84aef82302dcd844ad98229025ef0ff058";
    dependencies = [ self.cuda-bindings self.numpy ];
  };

  pylibraft-cu13 = rapidsWheel {
    pname = "pylibraft-cu13";
    inherit (rapids) version;
    url = "${pypi}/25/7e/997b324730fa3719e1d77ce4ab30ddba6b7330365ba3bd22f3a9c8a14eed/pylibraft_cu13-${rapids.version}-cp311-abi3-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl";
    sha256 = "025461bafc04c6f6cec061d1d1322d402dde568935289ae2ffd238fd0d4de134";
    dependencies = [ self.cuda-bindings self.numpy self.rmm-cu13 ];
  };

  cupy-cuda13x = wheel {
    pname = "cupy-cuda13x";
    version = "14.2.0";
    url = "${pypi}/c2/b8/4f4c4f34fc31ab8d136ed965a919505297974629d9852c50e15bfd616281/cupy_cuda13x-14.2.0-cp314-cp314-manylinux2014_x86_64.whl";
    sha256 = "ff0bdebd1b43c0c6db53095784c787c4e4eae671356cf521c4b7482ed78a1a7e";
    dependencies = [ self.cuda-pathfinder self.numpy ];
    libs = cupyCudaLibs;
    extra = {
      # cuTENSOR and NCCL back optional CuPy modules the twins do not use.
      autoPatchelfIgnoreMissingDeps = [
        "libcutensor.so.2" "libcutensorMg.so.2" "libnccl.so.2"
      ];
    };
  };
}
