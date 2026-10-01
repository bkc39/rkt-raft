# AGENTS.md

This file is the canonical guidance for agents and contributors. `CLAUDE.md`
only points here.

## Project overview

`raft` is a Racket binding to [NVIDIA RAFT](https://github.com/rapidsai/raft):
CUDA device arrays and data-science primitives, and the base a later Racket
cuML binding (`rkt-cuml`) stands on. The approved scoping plan is
`plans/scoping-plan.html` (approved 2026-10-01); read its §3 Architecture, §5
raft/core, §6 raft/array and raft/compat, §7 Memory model, §8 Shim ABI, §9
Parity, §10 Build and §12 Starting cuML work before changing the design.

- **Pins.** RAPIDS **26.08** (the `libraft-cu13`, `librmm-cu13` and
  `rapids-logger` 0.2.3 wheels from PyPI). 26.10 is not on PyPI; never bump
  without its own leg (#7). **CUDA 13 only.** Development builds target
  **sm_86** (the lab host's RTX 3090 Ti). Racket **9.3**. One nixpkgs pin,
  `07e1d92`, which carries Racket 9.3 and `cudaPackages_13` = CUDA 13.2.
- **Platforms.** `x86_64-linux` with an NVIDIA GPU. No CPU fallback, no macOS.
- **Package.** One package and one collection, `raft` (the `raft/`
  directory), one manual. Apache-2.0.
- **Status.** Milestone M1 "cuML-ready" (epic #1) is in progress. Leg 0 (#2)
  landed the scaffold: the flake, the wheels, the `nvcc` shim, the FFI layer,
  the gates, CI and the manual skeleton. Its public surface is `raft-version`
  and `raft-abi`.

## Layout

```
flake.nix  flake.lock         one system: x86_64-linux
nix/rapids.nix                the RAPIDS wheels as one patched prefix (packages.rapids)
nix/python-twins.nix          pylibraft, rmm, CuPy, cuda-bindings wheels for the twins
shim/                         libraftrkt: CUDA C++20 built with nvcc
  include/raftrkt/            C headers: core.h memory.h array.h, umbrella c_api.h
  src/{core,array,detail}/    .cu for anything that includes RAFT, .cpp for host-only code
  tests/                      gtest; GPU cases print SKIP without a device
raft/                         the Racket package and collection
  main.rkt core.rkt           the public surface
  private/foreign/*.rkt       FFI bindings, one module per shim header
  private/{error,resource,install-native}.rkt
  scribblings/                the manual: guide/ chapters, reference/ sections
  tests/                      raco tests; tests/private/ the harness; tests/python/ the twins
scripts/                      gates, the GPU suite, the docs render, the binding census
plans/scoping-plan.html       the approved plan, byte for byte
```

## Owner rules

1. **AGENTS.md is canonical.** Keep it current in the same PR as the change.
2. **No explanatory comments in source.** Usage docs live in Scribble. A
   comment survives only if it states an invariant the code cannot show, a
   cross-boundary gotcha, or a deliberate deviation from upstream behaviour;
   the owner deletes the rest in review. Delete, don't shorten.
3. **No contracts in M1** (owner decision, a deviation from rktorch and
   rkt-polars).
   - Plain `provide`. No `define/contract-out`, no `define/checked-out`, and
     no hand-written argument validation in Racket in their place.
   - One exception type, `exn:fail:raft`, carrying RAFT's or the shim's
     message, prefixed with the Racket caller's name, plus a `kind` field
     (`'out-of-memory`, `'cuda`, `'logic`, `'generic`) for the memory retry.
   - The shim keeps the memory-safety checks: C++ exceptions are translated
     into a status, and an unsupported dtype, layout or rank, a NULL handle,
     or output extents that do not fit are refused before the GPU is touched.
     A bad call raises; it never corrupts memory or crashes.
   - Contracts arrive in their own later leg.
4. **Constructors are named after the type:** `(device-matrix 1000 128)`,
   `(device-resources)`, `(cuda-async-memory-resource)`. Never `make-…`.
   Predicates look like `device-matrix?`. On a name collision prefix rather
   than fall back to `make-`: `cuda-stream`, because `racket/stream` exports
   `stream`.
5. **Names.** `->` for conversions (`device-matrix->list*`), never `-to-`. A
   star means nested, as in `math/array` (`list*->array`). `in-*` sequences
   use `make-do-sequence`. The short getters `shape`, `dtype`, `layout`
   collide with rktorch's; accepted for M1 (#8).
6. **Macros.** `define-syntax-parse-rule`, or `define-syntax-parser` for
   several clauses, with a syntax class on every pattern variable. Never
   `define-syntax-rule` or `syntax-rules`: `scripts/no-syntax-rule.sh` gates it.
7. **Scoped native resources** go through `with-*` forms that expand into
   `dynamic-wind` (`raft/private/resource.rkt`), with the finalizer as the
   backstop. No raw `malloc`/`free` outside that module:
   `scripts/no-raw-malloc.sh` gates it.
8. **Imports and size.** `(only-in …)` with alphabetised names. Exempt, with a
   comment at the require: pure re-export facades (`main.rkt`, marked
   `#|review: ignore|#`), `racket/runtime-path` and `syntax/parse/define`,
   whose expansions need bindings `only-in` strips. Racket modules of 500
   lines or fewer is a target; C, C++ and CUDA files of 500 lines or fewer is
   a gate.
9. **The FFI layer** lives in `raft/private/foreign/`, one module per shim
   header, defined with `define-raft` (`define-ffi-definer`,
   `convention:hyphen->underscore`, so `rr-buffer-alloc` is `rr_buffer_alloc`).
   - Handles come back through out-parameters typed `_rr-…/null`, and every
     handle-returning binding carries `#:wrap resources-allocator` or
     `#:wrap buffer-allocator` from `foreign/memory.rkt`. No binding returns a
     bare `_pointer`, and no binding takes one. Every release is wrapped by
     `release-once` (a `deallocator` that retags the handle `'rr-released`
     after the native free): releasing it again does nothing, any other use
     fails the cpointer tag check in Racket instead of reaching freed memory,
     and a handle of the wrong type fails that check before its finalizer is
     dropped. `raft/tests/allocator-audit-test.rkt` reads every binding and
     enforces all of this, including that each allocator releases its own
     handle type through `release-once`; a new handle type needs an entry
     there.
   - A host buffer crosses with its own length: the copy bindings take an
     `f64vector` and compute the byte count from it, so a copy cannot run past
     the host side; the shim checks the device side. A raw `_pointer` plus a
     caller-chosen size is not allowed for host memory. The vector lives in
     the GC heap, so these calls must stay non-blocking.
   - A fallible binding answers its result (or `#t`) on success and `#f` on
     failure, from the `_fun` result expression. The caller wraps it in
     `call/raft` (`raft/private/error.rkt`), which makes the call and reads
     the error message and kind in one `call-as-atomic`: the last-error slot
     belongs to the OS thread, which every Racket thread in the place shares.
   - The native drop counters (`rr_resources_drop_count`,
     `rr_buffer_drop_count`) count every release, and
     `rr_release_failure_count` every release that leaked because its device
     was unreachable; reclamation tests assert on them, because Racket cannot
     otherwise observe a native free.
   - A changed C signature gets a new symbol name, so a stale library fails
     at load, not at the call. L0's `rr_resources_create(device, out)` and
     `rr_buffer_alloc(resources, bytes, out)` are narrower than the plan's §8
     sketches; when L1a and L1b need the plan's signatures (a stream and
     stream count, a memory kind), they get new names.
   - `scripts/check-bindings.rkt` compares the `rr_` exports (`nm -D`) with
     the bindings, both ways.
10. **Staging the native library.** `libraftrkt.so` reaches
    `raft/native-libs/` by temp file plus `rename(2)`, and only when the
    bytes differ (the flake's shell hook, `nix run .#copy-native-libs`, and
    the pre-install hook `raft/private/install-native.rkt`). Never `cp` in
    place: rewriting a mapped library faults live REPLs (rktorch #72). Restart
    a REPL to pick up a new shim.
11. **Nix builds see only tracked files.** `git add` new files before any nix
    command.
12. **Skips are visible.** A self-skipping test prints `SKIP: <reason>`
    (`test-gpu` and `test-twin` in `raft/tests/private/`, `RR_REQUIRE_GPU` in
    the gtests). Never assume a case ran because the run was green.
13. **Python twins** run the same RAPIDS build as the shim: the
    `pylibraft-cu13` and `rmm-cu13` 26.8.0 wheels are patched against the very
    `packages.rapids` prefix the shim links, `cupy-cuda13x` against the same
    `cudaPackages_13`. The flake asserts the twins' version equals the
    shim's. Twins are compared by machine, never by eye.
14. **Every doc example is a test** (rkt-polars #152): the behaviour each
    manual example shows is pinned in `raft/tests/docs-test.rkt`.
15. **Every review finding is addressed**, from reviewer agents and from bots
    (`chatgpt-codex-connector[bot]` leaves inline comments): fixed with a
    test, or explained with evidence. No silent deferrals.

## Architecture

### The shim (`shim/`)

- `extern "C"`, prefix `rr_`, every export marked `RR_API`. Status codes:
  `RR_OK` 0, `RR_ERROR` 1, `RR_BUFFER_TOO_SMALL` 2. Error kinds:
  `RR_ERROR_GENERIC` 0, `RR_ERROR_OOM` 1, `RR_ERROR_CUDA` 2,
  `RR_ERROR_LOGIC` 3. The headers are C11-clean (the `c-headers` check and
  `tests/c_api_compile_test.c`).
- Every entry point body runs inside `rr::translate_exceptions`
  (`src/detail/error.hpp`), which clears the last error, catches
  `std::exception` and `...`, classifies the failure and records the cause.
  The message lives in a fixed 4 KiB thread-local buffer, so recording an
  error never allocates (the out-of-memory path included); longer messages
  are truncated at a UTF-8 character boundary, and Racket decodes the message
  leniently all the same. An out-pointer is set to NULL before any work.
- Every entry point selects the device recorded in its object
  (`rr::device_guard`, which throws when `cudaSetDevice` fails, where
  `rmm::cuda_set_device_raii` ignores the failure), so calls and finalizers
  work from any OS thread. Releases (`rr_resources_free`, `rr_buffer_free`) accept NULL, never
  throw, and leak rather than unwind if the device is unreachable.
- `rr_resources` holds its device and a `std::shared_ptr<raft::handle_t>`
  that aliases an owner holding an `rmm::cuda_stream` and the handle. Each
  resources object owns its stream; the per-thread default stream would bind
  to whichever OS thread a finalizer ran on.
- `rr_buffer` holds that same `shared_ptr`, its device and an
  `rmm::device_buffer` allocated on the handle's stream from the current
  device resource. The `shared_ptr` is declared first, so the buffer is freed
  on a stream that still exists, even after its resources were released.
- Visibility: our code is `-fvisibility=hidden` and exports only `RR_API`
  names. RAFT and RMM declare their namespaces default-visibility on purpose
  and must stay exported: RMM's per-device memory-resource registry is a set
  of header-inline statics that the dynamic linker unifies across every
  library that uses RMM. A `local: *` version script would give the shim a
  private registry and break the one-memory-pool rule with a cuML shim (#10
  asks L1a and L1d to test it). The
  static CUDA runtime that `rmm::rmm` links is hidden with
  `--exclude-libs,ALL`; `--no-undefined` catches a missing library at link.
- Two gtest binaries, installed in the shim derivation's `tests` output:
  `raftrkt_tests` (the C API, black box) and `raftrkt_error_tests` (white box;
  it compiles `error.cpp` itself and does not link the library, so its
  `rr_last_error` cannot interpose the library's).
- clang-tidy covers the host `.cpp` files; the `.cu` files get `nvcc`'s
  `-Wall -Wextra` only: clang-tidy (LLVM 21) rejects nvcc's flags and cannot
  parse CUDA 13.2's headers (its CUDA wrapper wants
  `texture_fetch_functions.h`, which CUDA 13 removed). Keep logic that does
  not need RAFT's headers in `.cpp`.

### Racket (`raft/`)

- `main.rkt` re-exports `core.rkt` (`raft-version`, `raft-abi`).
- `private/foreign/library.rkt`: the runtime path to `native-libs/`, `ffi-lib`
  (default local binding: only one copy of each RAPIDS library can load per
  process), `define-raft`, and the cpointer types `_rr-resources`,
  `_rr-buffer`. `core.rkt`, `memory.rkt`, `array.rkt` bind `core.h`,
  `memory.h`, `array.h`.
- `private/error.rkt`: `exn:fail:raft` and `call/raft`.
  `private/resource.rkt`: `with-release`. `private/install-native.rkt`: the
  pre-install hook, honouring `RAFT_NATIVE_LIB_PATH` (a directory whose
  `lib/` holds `libraftrkt.so`).
- Tests: `tests/private/gpu.rkt` (`gpu-available?`, `test-gpu`),
  `tests/private/python-env.rkt` (the twin runner: `PYTHONSAFEPATH` probes,
  a temp directory, JSON in and out, `check-close`, `test-twin`),
  `tests/private/bindings.rkt` (the binding reader shared by the audit and
  the census).

## Build and test

```bash
nix develop                        # the GPU shell (first entry builds and provisions)
nix flake check --max-jobs 1 --cores 4   # the CI-equivalent; GPU cases print SKIP
scripts/gpu-suite.sh               # in the shell, on the GPU host: gtests, LD_BIND_NOW
                                   #   load, raco tests with twin parity, the census;
                                   #   red on any SKIP but the no-driver cases
raco test raft                     # the Racket tests
racket scripts/check-bindings.rkt  # rr_ exports against the bindings
scripts/render-docs.sh <dir>       # the manual, red on any warning or broken link
resyntax analyze --local-git-repository . origin/master
nix run --max-jobs 1 --cores 4 .#copy-native-libs   # restage the shim after a C++ change
cmake -S shim -B shim/build -G Ninja -DBUILD_TESTING=ON   # the shim's inner loop
```

`nix develop` does this on entry, from the checkout's root only:

- **Filters `LD_LIBRARY_PATH`.** The lab host's `~/.bashrc` puts CUDA 11.7
  (`/usr/local/cuda-11.7/lib64`) on it, which would shadow the CUDA 13
  libraries; every `/usr/local/cuda*` entry is removed. Verify with the GPU
  suite's `LD_BIND_NOW=1` load of the shim.
- **Links the driver.** The host is Ubuntu with no `/run/opengl-driver`, so
  `libcuda.so.1`, `libnvidia-ml.so.1` and `libnvidia-ptxjitcompiler.so.1` are
  found with `ldconfig -p` and symlinked into `.cuda-driver/`, which goes
  first on `LD_LIBRARY_PATH` (rktorch's `cudaHook`). Twin subprocesses get
  only that directory (`RAFT_CUDA_DRIVER_PATH`).
- **Stages the shim** and exports `RAFT_NATIVE_LIB_PATH` and
  `RAFT_SHIM_TESTS` (the gtest binaries).
- **Gives each checkout its own `PLTUSERHOME`** under
  `~/.cache/rkt-raft-devshell/<hash of the path>`, installs `raft` there in
  link mode once (re-run when `raft/info.rkt` changes) and installs the pinned
  Resyntax.
- Provides `python3` with the twins, `CUDA_PATH` set for CuPy, and `nvcc`,
  CMake and the CUDA headers for the shim's inner loop.

The GPU is shared with other sessions: keep test sizes small and leave no
process running.

### Build memory

The lab host has 62 GB of RAM shared with other sessions, and a global OOM on
2026-10-01 took down the owner's session; nvcc jobs were part of it. So:

- Run nix as `nix … --max-jobs 1 --cores 4`, and never two builds of the shim
  at once.
- The shim builds at most `buildJobs` = 4 compile jobs at a time (the flake
  caps ninja and `CMAKE_BUILD_PARALLEL_LEVEL`; the dev shell exports
  `CMAKE_BUILD_PARALLEL_LEVEL=4`), and nvcc runs with `--threads 1`.
- Measured with GNU `time -f %M` (one translation unit, sm_86, the shim's
  flags), a RAFT translation unit (`gemm.cuh` or `reduce.cuh`, one
  instantiation) peaks at 730–760 MB. The cap keeps a build near 3 GB; keep
  `buildJobs` × peak RSS under about 24 GB, and measure again when a heavier
  header family (`linalg/svd`, `sparse`, `cluster`) arrives.
- Check `free -g` before a heavy build; with less than 30 GB available, wait
  and retry rather than start.

### Gates

`.racket-dev.rktd` declares them for the racket-dev plugin's runner
(`racket <plugin>/hooks/gate.rkt . all`). Before every push: `nix flake check`
green, the GPU suite green with its counts, the docs rendered with no
warnings, Resyntax clean (it exits 0 with findings; grep for
`resyntax: .*\.rkt:N:N [`), clang-format and clang-tidy clean. After pushing,
poll `gh pr checks <n>` (it exits non-zero while checks are pending) until
green.

`nix flake check` runs: `shim` (build plus both gtest binaries), `c-headers`
(the umbrella header compiled as C11 with `-Werror`), `clang-format`,
`clang-tidy`, `line-count` (500 lines per C/C++/CUDA file), `racket` (the
package build, `raco setup --check-pkg-deps`, `raco test raft`, the manual
compiled but not rendered, the binding census), `racket-version` (at least
9.3), `no-syntax-rule` and `no-raw-malloc`.

## CI

- `.github/workflows/nix.yml`: `nix flake check` on `ubuntu-latest` (after
  freeing disk: the CUDA 13 redistributables are unfree, so no public cache
  serves them) and a Resyntax job in the lean `.#ci` shell. The
  `nix-cache` action is rktorch's; this repository has no Tailscale secrets,
  so it falls back to `cache.nixos.org`.
- `.github/workflows/gpu.yml`: the GPU suite and the docs render on
  `runs-on: [self-hosted, linux, gpu]`, only when `vars.GPU_RUNNER == 'true'`
  and the pull request's author is `bkc39` (or a manual dispatch). No runner
  is registered yet (#9); until then the GPU gates run by hand on the lab
  host and their counts go in the review packet. The `if:` is not a security
  boundary: a fork's PR runs workflow files it controls, so keeping forks off
  the runner is the runner group's job (#9 lists the settings).
- No docs build in GitHub CI: doc examples need the GPU.

## Documentation

- One manual, `raft/scribblings/raft.scrbl`: a guide (chapters under
  `guide/`) and a reference (one section per module under `reference/`).
  `utils.rkt` holds `make-raft-eval`, the `python` block helper and the
  `status` marker for names that arrive in a later leg.
- **The owner reviews each leg's docs.** Every leg adds its own guide chapter
  and reference section. A guide chapter is a tutorial on realistic client
  code, evaluated live, with the equivalent Python (pylibraft, rmm, CuPy,
  NumPy) after the key Racket blocks as a non-evaluated block, and a sentence
  on where the two sides differ. Run each Python block in the shell's
  `python3` before quoting its output.
- Every exported name gets a `@defproc`/`@defform`/`@defthing` with prose and
  at least three live examples showing real use, not trivial calls.
- Examples run through `scribble/example`; output is never pasted by hand.
  Each one's behaviour is pinned in `raft/tests/docs-test.rkt`.
- Render after the leg's final commit with
  `scripts/render-docs.sh ~/dev/rkt/rkt-raft-docs/<leg-slug>`
  (`l0`, `l1a`, `l1b`, `l1c`, `l1d`); it fails on `undefined tag`,
  `badlink`, `multiple times` or any warning.

## Process

- **Arcs and legs.** Epic #1 (M1) lists the legs #2 L0, #3 L1a, #4 L1b, #5
  L1c, #6 L1d. Follow-ups: #7 (RAPIDS 26.10), #8 (shared array protocol with
  rktorch), #9 (the self-hosted GPU runner), #10 (test the one-pool rule
  across shims).
- **The stack.** M1 is one GitHub native stack: `master` ← L0 ← L1a ← L1b ←
  L1c ← L1d. Branch with `git fetch origin && git checkout -B <branch>
  origin/<base>`. Never force-push and never rebase a pushed branch; pick up
  the leg below with `git merge origin/<base>`. Never push to `master`, merge
  a PR or close an issue; the orchestrator links the stack with
  `gh stack link`.
- **gh is a snap and cannot read hidden directories:** pass bodies on stdin,
  `gh pr create … --body-file - < /path/body.md`.
- Commits end with a blank line and the `Co-Authored-By:` trailer. PR titles
  are `<area>: <what lands> (#<leg issue>)`; bodies are short.
- **The review packet is the PR's first comment** (racket-dev
  `review-packet`), then a comment on the epic: the PR number, the decisions
  taken, what was deferred and to which issue. A follow-up is a new issue,
  never a TODO comment.
- **Spec step.** A leg adding public surface commits its spec first:
  signatures, Scribble entries and failing tests (no contracts in M1).

## Decisions recorded in leg 0

- **One nixpkgs pin** (`07e1d92`) for everything: it carries Racket 9.3 and
  CUDA 13.2, so the shim, the Racket binary and the twins share one glibc.
  rktorch needs two pins only because its main pin predates Racket 9.3.
- **nvcc 13.2 against wheels built with 13.3.** Verified: nvcc 13.2 compiles
  the wheels' RAFT, RMM and CCCL 3.4.3 headers (the wheel's CCCL comes first
  on the include path), and the 13.3-built `libraft.so`/`librmm.so` run with
  13.2's cuBLAS, cuSOLVER, cuSPARSE, cuRAND and nvJitLink on driver 580 (CUDA
  13.0), since `libraft.so` references no versioned nvJitLink symbol. The
  pin also carries `cudaPackages_13_3` if that ever changes.
- **SASS and PTX for sm_86** (`CMAKE_CUDA_ARCHITECTURES=86`): the driver runs
  the SASS; the driver cannot JIT 13.2 PTX, so the PTX is inert.
- **RAPIDS Python wheels skip their loader packages.** `pylibraft` and `rmm`
  import `libraft`/`librmm` only if installed; the twins omit them and patch
  the extensions against `packages.rapids` instead, so both sides load the
  same `libraft.so` and `librmm.so`.
- **The ABI tag is a hash** in Racket (`raft-abi`) and `rr_abi_tag` in C:
  tag version, RAFT, RMM and CCCL versions, CUDA runtime,
  `sizeof(raft::handle_t)` and the resource-type count.
- **Errors carry a kind** (a field of `exn:fail:raft`, not a subtype).
