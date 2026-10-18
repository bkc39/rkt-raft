{
  description = "rkt-raft - Racket bindings to NVIDIA RAFT";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/07e1d92cdc0ed416cfa11ff3ca40d17e61cfba7a";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    # polars (rkt-polars) and datasets, which the Device arrays chapter loads,
    # at glmnet's pins. The sandboxed builds cannot reach the package catalog,
    # so they install these from source; rkt-polars' nixpkgs is not followed,
    # since its racket-deps hash is taken with its own Racket.
    rkt-polars.url = "github:bkc39/rkt-polars/9d1555e1515837b5bfd7ae7e829dfc996e81eb23";
    datasets-src = {
      url = "github:bkc39/datasets/007c85a57b4e5c638227c5e7b90c50ce18cc63fd";
      flake = false;
    };
    data-frame-src = {
      url = "github:alex-hhh/data-frame/ab3980c4da5a99d2b79172a32b9cb86b2c2b63b4";
      flake = false;
    };
    al2-test-runner-src = {
      url = "github:alex-hhh/al2-test-runner/b6757271932151dff6507ee6f1b690d0268da808";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      rkt-polars,
      datasets-src,
      data-frame-src,
      al2-test-runner-src,
    }:
    let
      system = "x86_64-linux";
      version = "0.1.0";
      minRacketVersion = "9.3";
      cudaArchitectures = "86";
      buildJobs = 4;
      singleProcessSeconds = 60;
      capJobs = ''
        NIX_BUILD_CORES=$(( NIX_BUILD_CORES < ${toString buildJobs} ? NIX_BUILD_CORES : ${toString buildJobs} ))
        export CMAKE_BUILD_PARALLEL_LEVEL=$NIX_BUILD_CORES
      '';

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      inherit (pkgs) lib;
      # libcuvs needs nvJitLink 13.3's versioned symbols, and only one
      # libnvJitLink.so.13 loads per process, so every library gets 13.3's.
      cudaPackages = pkgs.cudaPackages_13.overrideScope (
        _: _: { inherit (pkgs.cudaPackages_13_3) libnvjitlink; }
      );
      racket = pkgs.racket;

      rapids = pkgs.callPackage ./nix/rapids.nix { inherit cudaPackages; };
      racketTools = pkgs.callPackage ./nix/racket-tools.nix { inherit racket; };
      treefmtEval = treefmt-nix.lib.evalModule pkgs (import ./nix/treefmt.nix { inherit racketTools; });

      cudaDevLibs = with cudaPackages; [
        cuda_cudart
        libcublas
        libcurand
        libcusolver
        libcusparse
      ];

      shim = cudaPackages.backendStdenv.mkDerivation {
        pname = "raftrkt";
        inherit version;
        src = ./shim;
        outputs = [
          "out"
          "dev"
          "tests"
        ];
        nativeBuildInputs = [
          pkgs.cmake
          pkgs.ninja
          cudaPackages.cuda_nvcc
        ];
        buildInputs = [
          rapids.core
          pkgs.gtest
        ]
        ++ cudaDevLibs;
        cmakeFlags = [
          "-DBUILD_TESTING=ON"
          "-DCMAKE_CUDA_ARCHITECTURES=${cudaArchitectures}"
          "-DRAFTRKT_TESTS_PREFIX=${placeholder "tests"}"
          "-DRAFTRKT_CMAKE_DIR=${placeholder "dev"}/lib/cmake/raftrkt"
        ];
        preBuild = capJobs;
        doCheck = true;
        checkPhase = ''
          runHook preCheck
          ctest -j1 --output-on-failure
          runHook postCheck
        '';
        passthru = { inherit rapids; };
      };

      canarySource = lib.fileset.toSource {
        root = ./downstream/kmeans-canary;
        fileset = lib.fileset.unions [
          ./downstream/kmeans-canary/.clang-tidy
          ./downstream/kmeans-canary/CMakeLists.txt
          ./downstream/kmeans-canary/include
          ./downstream/kmeans-canary/src
          ./downstream/kmeans-canary/tests
        ];
      };

      kmeansCanary = cudaPackages.backendStdenv.mkDerivation {
        pname = "kmeans-canary";
        inherit version;
        src = canarySource;
        outputs = [
          "out"
          "tests"
        ];
        nativeBuildInputs = [
          pkgs.cmake
          pkgs.ninja
          cudaPackages.cuda_nvcc
        ];
        buildInputs = [
          rapids
          shim
          shim.dev
          pkgs.gtest
        ]
        ++ cudaDevLibs;
        cmakeFlags = [
          "-DBUILD_TESTING=ON"
          "-DKC_TESTS_PREFIX=${placeholder "tests"}"
        ];
        preBuild = capJobs;
        doCheck = true;
        checkPhase = ''
          runHook preCheck
          ctest -j1 --output-on-failure
          runHook postCheck
        '';
      };

      # An in-place write rewrites pages a live process has mapped (rktorch
      # #72); rename leaves the old inode to whoever still runs it.
      stageNativeLibs = src: ''
        _dest="$PWD/raft/native-libs"
        _stage_failed=0
        mkdir -p "$_dest"
        for _f in ${src}/lib/libraftrkt.*; do
          _b=$(basename "$_f")
          if cmp -s "$_f" "$_dest/$_b"; then
            continue
          fi
          if cp -f "$_f" "$_dest/.$_b.tmp.$$" \
             && chmod 0555 "$_dest/.$_b.tmp.$$" \
             && mv -f "$_dest/.$_b.tmp.$$" "$_dest/$_b"; then
            echo "Staged $_b from ${src}"
          else
            rm -f "$_dest/.$_b.tmp.$$"
            echo "ERROR: staging $_b failed; the existing shim stays in place" >&2
            _stage_failed=1
          fi
        done
      '';

      installNativePackage =
        mode:
        "raco pkg install --batch --deps fail --no-docs --no-setup --scope user ${mode} --name raft-x86_64-linux \"$PWD/raft-x86_64-linux\"";

      # polars and its dependency closure, then datasets, offline into
      # $PLTUSERHOME (glmnet's recipe). polars' dependencies are set up first:
      # setup copies tzdata's zoneinfo where gregor, which polars loads, finds
      # it. polars is installed from a writable copy of its source with the
      # prebuilt Linux library already in native-libs/ and no candidates/, so
      # its pre-install hook leaves the library be.
      installDocsDeps = skip: ''
        raco pkg install --batch --copy --no-docs --scope user ${skip} \
          ${rkt-polars.packages.${system}.racket-deps}/*/
        _polars_src="$(mktemp -d)/polars"
        cp -r ${rkt-polars}/polars "$_polars_src"
        chmod -R u+w "$_polars_src"
        cp ${rkt-polars}/polars/native-libs/candidates/linux/libcompat.so "$_polars_src/native-libs/"
        rm -rf "$_polars_src/native-libs/candidates"
        raco pkg install --batch --copy --no-docs --scope user ${skip} --name polars "$_polars_src"
        raco pkg install --batch --deps fail --no-setup --copy --scope user ${skip} \
          --name al2-test-runner ${al2-test-runner-src}
        raco pkg install --batch --deps fail --no-setup --copy --scope user ${skip} \
          --name data-frame ${data-frame-src}
        raco pkg install --batch --deps fail --no-setup --copy --scope user ${skip} \
          --name datasets-core ${datasets-src}/datasets-core
        raco pkg install --batch --deps fail --no-setup --copy --scope user ${skip} \
          --name datasets ${datasets-src}/datasets
      '';

      racketPackage = pkgs.stdenv.mkDerivation {
        pname = "rkt-raft";
        inherit version;
        src = lib.cleanSource ./.;
        nativeBuildInputs = [
          racket
          pkgs.binutils
        ];
        buildInputs = [ shim ];
        buildPhase = ''
          runHook preBuild
          export HOME=$TMPDIR/home
          export PLTUSERHOME=$TMPDIR/racket-home
          mkdir -p $PLTUSERHOME
          ${stageNativeLibs shim}
          [ "$_stage_failed" = 0 ] || exit 1
          ${installDocsDeps ""}
          ${installNativePackage "--copy"}
          raco pkg install --batch --deps fail --no-setup --copy --scope user \
            --name raft ./raft
          raco setup --no-docs --check-pkg-deps --unused-pkg-deps --pkgs raft-x86_64-linux raft
          runHook postBuild
        '';
        doCheck = true;
        checkPhase = ''
          runHook preCheck
          export RAFT_SHIM_PROBE="${shim.tests}/lib/libraftrkt_probe.so"
          raco test --process --timeout 45 raft
          raco make -v raft/scribblings/raft.scrbl
          racket scripts/check-bindings.rkt
          runHook postCheck
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out/share
          cp -r $PLTUSERHOME $out/share/racket-home
          runHook postInstall
        '';
      };

      python = pkgs.python314.override {
        self = python;
        packageOverrides = import ./nix/python-twins.nix {
          inherit (pkgs)
            lib
            stdenv
            fetchurl
            autoPatchelfHook
            zlib
            ;
          inherit rapids cudaPackages;
        };
      };

      # CuPy finds the libraries it dlopens, and NVRTC's headers, here.
      cudaHome = pkgs.symlinkJoin {
        name = "rkt-raft-cuda-home";
        paths =
          lib.concatMap
            (p: [
              (lib.getLib p)
              (lib.getDev p)
            ])
            (
              with cudaPackages;
              [
                cuda_cudart
                cuda_nvrtc
                cuda_cccl
                libcublas
                libcufft
                libcurand
                libcusolver
                libcusparse
                libnvjitlink
              ]
            );
      };

      pythonEnv =
        assert lib.assertMsg
          (
            python.pkgs.pylibraft-cu13.version == rapids.version
            && python.pkgs.rmm-cu13.version == rapids.version
            && python.pkgs.cuml-cu13.version == rapids.version
          )
          (
            "the twins' pylibraft/rmm/cuml wheels must be the RAPIDS release the "
            + "shims link ("
            + rapids.version
            + ")"
          );
        (python.withPackages (ps: [
          ps.cuml-cu13
          ps.cupy-cuda13x
          ps.numpy
          ps.pylibraft-cu13
          ps.rmm-cu13
          ps.scikit-learn
        ])).override
          {
            makeWrapperArgs = [ "--set CUDA_PATH ${cudaHome}" ];
          };

      lineCount =
        pkgs.runCommand "rkt-raft-line-count"
          {
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./shim
                ./downstream
              ];
            };
          }
          ''
            failed=0
            while IFS= read -r file; do
              lines=$(wc -l < "$file")
              if [ "$lines" -gt 500 ]; then
                echo "ERROR: $file has $lines lines; the limit is 500" >&2
                failed=1
              fi
            done < <(find $src -type f \( -name '*.c' -o -name '*.h' -o -name '*.hpp' \
                       -o -name '*.cpp' -o -name '*.cu' \))
            [ "$failed" = 0 ] || exit 1
            touch $out
          '';

      clangTidy = shim.overrideAttrs (old: {
        pname = "raftrkt-clang-tidy";
        outputs = [ "out" ];
        nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.clang-tools ];
        cmakeFlags = [
          "-DBUILD_TESTING=ON"
          "-DCMAKE_CUDA_ARCHITECTURES=${cudaArchitectures}"
        ];
        buildPhase = ''
          runHook preBuild
          ${capJobs}
          cmake --build . --target tidy
          runHook postBuild
        '';
        doCheck = false;
        installPhase = "touch $out";
      });

      canaryTidy = kmeansCanary.overrideAttrs (old: {
        pname = "kmeans-canary-clang-tidy";
        outputs = [ "out" ];
        nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.clang-tools ];
        cmakeFlags = [ "-DBUILD_TESTING=ON" ];
        buildPhase = ''
          runHook preBuild
          ${capJobs}
          cmake --build . --target tidy
          runHook postBuild
        '';
        doCheck = false;
        installPhase = "touch $out";
      });

      sanitizerOptions = {
        asan = "protect_shadow_gap=0:detect_leaks=1:detect_stack_use_after_return=1:abort_on_error=1";
        ubsan = "print_stacktrace=1:halt_on_error=1";
      };

      shimSanitizers = shim.overrideAttrs (old: {
        pname = "raftrkt-sanitizers";
        cmakeFlags = old.cmakeFlags ++ [ "-DRAFTRKT_SANITIZE=ON" ];
        hardeningDisable = [
          "fortify"
          "fortify3"
        ];
        checkPhase = ''
          runHook preCheck
          export ASAN_OPTIONS=${sanitizerOptions.asan}
          export UBSAN_OPTIONS=${sanitizerOptions.ubsan}
          ctest -j1 --output-on-failure
          timeout --kill-after=10 ${toString singleProcessSeconds} ./raftrkt_tests --gtest_brief=1
          runHook postCheck
        '';
      });

      racketReview = pkgs.stdenv.mkDerivation {
        pname = "rkt-raft-racket-review";
        inherit version;
        src = lib.cleanSource ./.;
        nativeBuildInputs = [ racket ];
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          export HOME=$TMPDIR/home
          export PLTUSERHOME=$TMPDIR/racket-home
          mkdir -p $PLTUSERHOME
          raco pkg install --batch --copy --no-docs --deps fail --scope user \
            ${racketTools.sources}/*/
          ${installDocsDeps ""}
          raco pkg install --batch --no-docs --no-setup --deps fail --scope user \
            --link --name raft-lint ./lint
          ${installNativePackage "--link"}
          raco pkg install --batch --no-docs --no-setup --deps fail --scope user \
            --link --name raft ./raft
          raco setup --no-docs --pkgs raft-x86_64-linux raft raft-lint
          bash scripts/review.sh
          runHook postBuild
        '';
        installPhase = "touch $out";
      };

      docsReplay = pkgs.stdenv.mkDerivation {
        pname = "rkt-raft-docs-replay";
        inherit version;
        src = lib.cleanSource ./.;
        nativeBuildInputs = [
          racket
          pkgs.git
        ];
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          export HOME=$TMPDIR/home
          export PLTUSERHOME=$TMPDIR/racket-home
          mkdir -p $PLTUSERHOME
          ${installDocsDeps ""}
          ${installNativePackage "--link"}
          raco pkg install --batch --no-docs --no-setup --deps fail --scope user \
            --link --name raft ./raft
          raco setup --no-docs --pkgs raft-x86_64-linux raft
          unset RAFT_DOCS
          bash scripts/render-docs.sh $TMPDIR/docs
          bash scripts/record-docs-test.sh
          runHook postBuild
        '';
        installPhase = "cp -r $TMPDIR/docs $out";
      };

      cHeaders =
        pkgs.runCommand "rkt-raft-c-headers"
          {
            src = ./shim/include;
            nativeBuildInputs = [ pkgs.stdenv.cc ];
          }
          ''
            printf '#include "raftrkt/c_api.h"\nint main(void) { return 0; }\n' > t.c
            cc -std=c11 -Wall -Wextra -Wpedantic -Werror -I $src -c t.c -o t.o
            touch $out
          '';

      releaseArchFixtures = cudaPackages.backendStdenv.mkDerivation {
        name = "rkt-raft-release-arch-fixtures";
        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./scripts/release/pins.sh
            ./scripts/release/fixtures
          ];
        };
        nativeBuildInputs = [ cudaPackages.cuda_nvcc ];
        buildInputs = [ cudaPackages.cuda_cudart ];
        buildPhase = ''
          bash scripts/release/fixtures/arch-fixtures.sh $out
        '';
        dontInstall = true;
      };

      releaseGates =
        pkgs.runCommand "rkt-raft-release-gates"
          {
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./scripts/release
                ./raft/info.rkt
                ./raft/private/foreign/library.rkt
                ./raft/private/cuda-wheels.rkt
                ./raft/private/cuda-wheels.rktd
                ./raft-x86_64-linux/info.rkt
                ./raft-x86_64-linux/NOTICE
                ./README.md
                ./.github/workflows/release.yml
              ];
            };
            nativeBuildInputs = [
              pkgs.binutils
              pkgs.curl
              pkgs.stdenv.cc
              cudaPackages.cuda_cuobjdump
              racket
            ];
          }
          ''
            export HOME=$TMPDIR/home PLTUSERHOME=$TMPDIR/racket-home
            ${pkgs.bash}/bin/bash $src/scripts/release/check-pins.sh \
              "${rapids.libraft.wheel.url} ${rapids.libraft.wheel.sha256}" \
              "${rapids.librmm.wheel.url} ${rapids.librmm.wheel.sha256}" \
              "${rapids.rapids-logger.wheel.url} ${rapids.rapids-logger.wheel.sha256}" \
              ${cudaPackages.libcublas.version} ${minRacketVersion} $src/raft/private/cuda-wheels.rktd
            timeout 900 ${pkgs.bash}/bin/bash $src/scripts/release/gates-test.sh ${shim}/lib/libraftrkt.so \
              ${shim.tests}/lib/libraftrkt_stale_abi.so ${rapids.core}/lib64 ${releaseArchFixtures}
            touch $out
          '';

      racketVersion =
        pkgs.runCommand "rkt-raft-racket-version"
          {
            nativeBuildInputs = [ racket ];
          }
          ''
            have=$(racket -e '(display (version))')
            lowest=$(printf '%s\n%s\n' "$have" "${minRacketVersion}" | sort -V | head -1)
            if [ "$lowest" != "${minRacketVersion}" ]; then
              echo "ERROR: rkt-raft needs Racket >= ${minRacketVersion}; nixpkgs pins $have" >&2
              exit 1
            fi
            touch $out
          '';

      grepGate =
        name: script:
        pkgs.runCommand "rkt-raft-${name}"
          {
            src = lib.cleanSource ./.;
          }
          ''
            cd $src
            ${pkgs.bash}/bin/bash scripts/${script}
            touch $out
          '';

      resyntaxSource = "https://github.com/jackfirth/resyntax.git#40f3497321f8590eb6a0b7c7984a9116323b7ebf";

      # PLTUSERHOME lives outside $PWD and is keyed on the checkout's path:
      # raco refuses a --link target inside a collects dir, and worktrees
      # must not share installed packages.
      racketHome = ''
        _cache_root="''${XDG_CACHE_HOME:-$HOME/.cache}/rkt-raft-devshell"
        _project_id=$(printf '%s' "$PWD" | sha256sum | cut -c1-12)
        export PLTUSERHOME="$_cache_root/$_project_id"
        mkdir -p "$PLTUSERHOME"
      '';

      provisionRacket = ''
        ${stageNativeLibs shim}
        if [ "$_stage_failed" != 0 ]; then
          echo "  *** libraftrkt was NOT staged; raft will load a stale shim or none." >&2
        fi
        _canary_pkg="$PWD/downstream/kmeans-canary/kmeans-canary"
        _info_hash=$(cat raft/info.rkt raft-x86_64-linux/info.rkt "$_canary_pkg/info.rkt" \
          | sha256sum | cut -c1-16)
        _pkg_stamp="$PLTUSERHOME/.raft-installed-$_info_hash"
        if [ ! -f "$_pkg_stamp" ]; then
          echo "Installing raft and kmeans-canary into $PLTUSERHOME (link mode)"
          rm -f "$PLTUSERHOME"/.raft-installed-* 2>/dev/null || true
          ${installDocsDeps "--skip-installed"}
          if ${installNativePackage "--link --skip-installed"} \
             && raco pkg install --batch --auto --no-setup --link --scope user \
                  --skip-installed --name raft "$PWD/raft" \
             && raco pkg install --batch --auto --no-setup --link --scope user \
                  --skip-installed --name kmeans-canary "$_canary_pkg" \
             && raco setup --no-docs --pkgs raft-x86_64-linux raft kmeans-canary; then
            touch "$_pkg_stamp"
          else
            echo "raft setup FAILED; not stamped, so the next shell entry retries" >&2
          fi
        fi
      '';

      provisionTools = ''
        _tools_id=$(printf '%s' "${racketTools.sources}" | sha256sum | cut -c1-16)
        _tools_stamp="$PLTUSERHOME/.tools-installed-$_tools_id"
        if [ ! -f "$_tools_stamp" ]; then
          echo "Installing raco fmt, raco review and raft-lint into $PLTUSERHOME"
          rm -f "$PLTUSERHOME"/.tools-installed-* 2>/dev/null || true
          if raco pkg install --batch --copy --no-docs --scope user --skip-installed \
               ${racketTools.sources}/*/ \
             && raco pkg install --batch --no-docs --scope user --skip-installed \
                  --link --name raft-lint "$PWD/lint"; then
            touch "$_tools_stamp"
          else
            echo "tool setup FAILED; not stamped, so the next shell entry retries" >&2
          fi
        fi
      '';

      provisionResyntax = ''
        _lint_id=$(printf '%s' "${resyntaxSource}" | sha256sum | cut -c1-16)
        _lint_stamp="$PLTUSERHOME/.resyntax-installed-$_lint_id"
        if [ ! -f "$_lint_stamp" ]; then
          echo "Installing Resyntax into $PLTUSERHOME"
          rm -f "$PLTUSERHOME"/.resyntax-installed-* 2>/dev/null || true
          if raco pkg install --batch --auto --no-docs --scope user \
               --skip-installed "${resyntaxSource}" \
             && raco pkg update --batch --auto --update-deps --no-docs \
                  --scope user "${resyntaxSource}"; then
            touch "$_lint_stamp"
          else
            echo "Resyntax setup FAILED; not stamped, so the next shell entry retries" >&2
          fi
        fi
        export PATH="$(racket -e '(require setup/dirs)(display (path->string (find-user-console-bin-dir)))'):$PATH"
      '';

      # The host's ~/.bashrc puts CUDA 11.7 on LD_LIBRARY_PATH, where it would
      # shadow the CUDA 13 libraries. The host has no /run/opengl-driver, so
      # the driver's own libraries are linked into .cuda-driver/ instead.
      gpuHook = ''
        _filtered=""
        IFS=: read -ra _entries <<< "''${LD_LIBRARY_PATH:-}"
        for _e in "''${_entries[@]}"; do
          case "$_e" in
            ""|/usr/local/cuda*) ;;
            *) _filtered="''${_filtered:+$_filtered:}$_e" ;;
          esac
        done
        _drv_farm="$PWD/.cuda-driver"
        rm -rf "$_drv_farm"; mkdir -p "$_drv_farm"
        for _l in libcuda.so.1 libnvidia-ml.so.1 libnvidia-ptxjitcompiler.so.1; do
          _p=$(/sbin/ldconfig -p 2>/dev/null | grep -F "$_l (libc6,x86-64" \
                 | grep -oE '/[^ ]+' | head -1)
          if [ -n "$_p" ]; then
            ln -sf "$_p" "$_drv_farm/$_l"
          else
            echo "WARNING: $_l not found via ldconfig; GPU tests will skip" >&2
          fi
        done
        export LD_LIBRARY_PATH="$_drv_farm''${_filtered:+:$_filtered}"
        export RAFT_CUDA_DRIVER_PATH="$_drv_farm"
        export RAFT_SHIM_TESTS="${shim.tests}/bin"
        export RAFT_SHIM_PROBE="${shim.tests}/lib/libraftrkt_probe.so"
        export RAFT_SHIM_SANITIZED_TESTS="${shimSanitizers.tests}/bin"
        export RAFT_KMEANS_CANARY="${kmeansCanary}/lib/libkmeans_canary.so"
        export RAFT_KMEANS_CANARY_TESTS="${kmeansCanary.tests}/bin"
        export RAFT_RAPIDS_PREFIX="${rapids}"
        export RAFT_ASAN_OPTIONS="${sanitizerOptions.asan}"
        export RAFT_UBSAN_OPTIONS="${sanitizerOptions.ubsan}"
        export CMAKE_BUILD_PARALLEL_LEVEL=${toString buildJobs}
        export RAFT_DOCS=live
      '';
    in
    {
      packages.${system} = {
        default = racketPackage;
        racket = racketPackage;
        inherit rapids shim;
        raft-dev = shim.dev;
        kmeans-canary = kmeansCanary;
        python-twins = pythonEnv;
        copy-native-libs = pkgs.writeShellApplication {
          name = "copy-native-libs";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.diffutils
          ];
          text = ''
            if [ ! -f raft/info.rkt ]; then
              echo "copy-native-libs: run from the root of an rkt-raft checkout" >&2
              exit 1
            fi
            ${stageNativeLibs shim}
            [ "$_stage_failed" = 0 ] || exit 1
            ls -la "$PWD/raft/native-libs"
          '';
        };
      };

      apps.${system}.copy-native-libs = {
        type = "app";
        program = "${self.packages.${system}.copy-native-libs}/bin/copy-native-libs";
        meta.description = "Stage the nix-built libraftrkt into raft/native-libs";
      };

      checks.${system} = {
        inherit shim;
        racket = racketPackage;
        racket-review = racketReview;
        docs-replay = docsReplay;
        shim-sanitizers = shimSanitizers;
        formatting = treefmtEval.config.build.check self;
        c-headers = cHeaders;
        clang-tidy = clangTidy;
        clang-tidy-canary = canaryTidy;
        kmeans-canary = kmeansCanary;
        line-count = lineCount;
        racket-version = racketVersion;
        release-gates = releaseGates;
        no-syntax-rule = grepGate "no-syntax-rule" "no-syntax-rule.sh";
        no-raw-malloc = grepGate "no-raw-malloc" "no-raw-malloc.sh";
        bounded-death-tests = grepGate "bounded-death-tests" "bounded-death-tests.sh";
        gpu-suite-signals = grepGate "gpu-suite-signals" "gpu-suite-signals.sh";
      };

      devShells.${system} = {
        default = pkgs.mkShell {
          packages = [
            racket
            pythonEnv
            rapids
            pkgs.binutils
            pkgs.clang-tools
            pkgs.cmake
            pkgs.gtest
            pkgs.ninja
            cudaPackages.cuda_nvcc
            cudaPackages.cuda_sanitizer_api
            treefmtEval.config.build.wrapper
          ]
          ++ cudaDevLibs;
          shellHook = ''
            if [ -f raft/info.rkt ]; then
              ${gpuHook + racketHome + provisionRacket + provisionTools + provisionResyntax}
            else
              echo "rkt-raft: enter the shell from the checkout's root; nothing was provisioned" >&2
            fi
          '';
        };

        ci = pkgs.mkShell {
          packages = [ racket ];
          shellHook = ''
            if [ -f raft/info.rkt ]; then
              ${racketHome + provisionTools + provisionResyntax}
            else
              echo "rkt-raft: enter the shell from the checkout's root; nothing was provisioned" >&2
            fi
          '';
        };
      };

      formatter.${system} = treefmtEval.config.build.wrapper;
    };
}
